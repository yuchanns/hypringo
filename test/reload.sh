#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-reload.XXXXXX")
socket_path="$runtime_dir/hypringo.sock"
config_path="$runtime_dir/config.lua"
log_path="$runtime_dir/hypringo.log"
daemon_pid=

cleanup() {
	if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
		kill -TERM "$daemon_pid" 2>/dev/null || true
		wait "$daemon_pid" 2>/dev/null || true
	fi
	rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

write_config() {
	workers=$1
	reconnect_min_ms=$2
	reconnect_max_ms=$3
	cat >"$config_path" <<EOF
return {
	runtime = {
		socket_path = "$socket_path",
		workers = $workers,
	},
	sources = {
		audio = {
			reconnect_min_ms = $reconnect_min_ms,
			reconnect_max_ms = $reconnect_max_ms,
		},
		hyprland = {
			reconnect_min_ms = $reconnect_min_ms,
			reconnect_max_ms = $reconnect_max_ms,
		},
		mpris = {
			reconnect_min_ms = $reconnect_min_ms,
			reconnect_max_ms = $reconnect_max_ms,
		},
	},
}
EOF
}

wait_for_doctor() {
	filter=$1
	count=0
	while :; do
		doctor=$("$binary" doctor --socket "$socket_path" 2>/dev/null || true)
		if [ -n "$doctor" ] &&
			printf "%s\n" "$doctor" | jq -e "$filter" >/dev/null 2>&1; then
			printf "%s\n" "$doctor"
			return
		fi
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			cat "$log_path" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 500 ]; then
			echo "timed out waiting for doctor filter: $filter" >&2
			printf "%s\n" "$doctor" >&2
			cat "$log_path" >&2
			exit 1
		fi
		sleep 0.01
	done
}

write_config 2 100 5000
XDG_RUNTIME_DIR="$runtime_dir" \
	"$binary" --config "$config_path" >>"$log_path" 2>&1 &
daemon_pid=$!
wait_for_doctor '.ready == true and .healthy == true and .runtime.config_generation == 1' >/dev/null

write_config 2 250 750
accepted=$("$binary" reload --socket "$socket_path")
printf "%s\n" "$accepted" | jq -e '.type == "accepted"' >/dev/null
wait_for_doctor '.runtime.config_generation == 2 and .runtime.last_reload_error == ""' >/dev/null

write_config 3 250 750
"$binary" reload --socket "$socket_path" >/dev/null
rejected=$(wait_for_doctor \
	'.runtime.config_generation == 2 and (.runtime.last_reload_error | contains("restart required after changing runtime.workers"))')
printf "%s\n" "$rejected" | jq -e '.healthy == false' >/dev/null

cat >"$config_path" <<'EOF'
return {
	runtime = {
		workers = 0,
	},
}
EOF
"$binary" reload --socket "$socket_path" >/dev/null
wait_for_doctor \
	'.runtime.config_generation == 2 and (.runtime.last_reload_error | contains("runtime.workers must be an integer"))' \
	>/dev/null

write_config 2 300 900
"$binary" reload --socket "$socket_path" >/dev/null
wait_for_doctor '.healthy == true and .runtime.config_generation == 3 and .runtime.last_reload_error == ""' >/dev/null

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

echo "configuration reload integration tests passed"
