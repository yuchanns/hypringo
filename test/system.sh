#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-system.XXXXXX")
sysfs_root="$runtime_dir/sys"
control_socket="$runtime_dir/hypringo.sock"
config_path="$runtime_dir/config.lua"
daemon_log="$runtime_dir/hypringo.log"
daemon_pid=

cleanup() {
	if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
		kill -TERM "$daemon_pid" 2>/dev/null || true
		wait "$daemon_pid" 2>/dev/null || true
	fi
	rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

mkdir -p \
	"$sysfs_root/class/backlight/acpi_video0" \
	"$sysfs_root/class/backlight/intel_backlight" \
	"$sysfs_root/class/power_supply/AC" \
	"$sysfs_root/class/power_supply/BAT9"
printf '%s\n' 100 >"$sysfs_root/class/backlight/acpi_video0/brightness"
printf '%s\n' 400 >"$sysfs_root/class/backlight/acpi_video0/max_brightness"
printf '%s\n' firmware >"$sysfs_root/class/backlight/acpi_video0/type"
printf '%s\n' 200 >"$sysfs_root/class/backlight/intel_backlight/brightness"
printf '%s\n' 800 >"$sysfs_root/class/backlight/intel_backlight/max_brightness"
printf '%s\n' raw >"$sysfs_root/class/backlight/intel_backlight/type"
printf '%s\n' Mains >"$sysfs_root/class/power_supply/AC/type"
printf '%s\n' Battery >"$sysfs_root/class/power_supply/BAT9/type"
printf '%s\n' 1 >"$sysfs_root/class/power_supply/BAT9/present"
printf '%s\n' 83 >"$sysfs_root/class/power_supply/BAT9/capacity"
printf '%s\n' Discharging >"$sysfs_root/class/power_supply/BAT9/status"

cat >"$config_path" <<EOF
return {
	runtime = {
		socket_path = "$control_socket",
		workers = 2,
	},
	sources = {
		system = {
			enabled = true,
			interval_ms = 100,
			sysfs_root = "$sysfs_root",
		},
	},
}
EOF

"$binary" --config "$config_path" >>"$daemon_log" 2>&1 &
daemon_pid=$!

wait_for_status() {
	filter=$1
	count=0
	while :; do
		status=$("$binary" status --socket "$control_socket" 2>/dev/null || true)
		if printf '%s\n' "$status" |
			jq -e "$filter" >/dev/null 2>&1; then
			printf '%s\n' "$status"
			return
		fi
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			cat "$daemon_log" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 500 ]; then
			echo "timed out waiting for system source state" >&2
			cat "$daemon_log" >&2
			exit 1
		fi
		sleep 0.01
	done
}

status=$(wait_for_status '
	.state.runtime.ready == true and
	.state.system.available == true and
	.state.system.battery.available == true and
	.state.system.battery.device == "BAT9" and
	.state.system.battery.capacity == 83 and
	.state.system.battery.status == "Discharging" and
	.state.system.brightness.available == true and
	.state.system.brightness.device == "intel_backlight" and
	.state.system.brightness.percent == 25 and
	.state.system.brightness.capabilities.set == true
')

doctor=$("$binary" doctor --socket "$control_socket")
printf '%s\n' "$doctor" |
	jq -e '
		.healthy == true and
		.sources.system.status == "ready" and
		.sources.system.battery_available == true and
		.sources.system.brightness_available == true and
		.sources.system.capabilities.set_brightness == true
	' >/dev/null

"$binary" dispatch brightness set 75 --socket "$control_socket" |
	jq -e '.type == "accepted"' >/dev/null
wait_for_status '.state.system.brightness.percent == 75' >/dev/null
test "$(cat "$sysfs_root/class/backlight/intel_backlight/brightness")" = "600"
test "$(cat "$sysfs_root/class/backlight/acpi_video0/brightness")" = "100"

rm -rf \
	"$sysfs_root/class/backlight/acpi_video0" \
	"$sysfs_root/class/backlight/intel_backlight" \
	"$sysfs_root/class/power_supply/BAT9"
wait_for_status '
	.state.system.available == true and
	.state.system.battery.available == false and
	.state.system.brightness.available == false
' >/dev/null
doctor=$("$binary" doctor --socket "$control_socket")
printf '%s\n' "$doctor" |
	jq -e '
		.healthy == true and
		.sources.system.status == "ready" and
		.sources.system.battery_available == false and
		.sources.system.brightness_available == false
	' >/dev/null

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

echo "System source auto-detection integration tests passed"
