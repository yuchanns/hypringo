#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-audio.XXXXXX")
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

cat >"$config_path" <<EOF
return {
	runtime = {
		socket_path = "$control_socket",
		workers = 2,
	},
	sources = {
		audio = {
			enabled = true,
			reconnect_max_ms = 100,
			reconnect_min_ms = 20,
		},
	},
}
EOF

expected_sink=$(pactl get-default-sink)
expected_volume=$(
	pactl -f json list sinks 2>/dev/null |
		jq -r --arg sink "$expected_sink" '
			map(select(.name == $sink))[0].volume
			| [.[].value]
			| (((add / length | floor) * 100 + 32768) / 65536 | floor)
		'
)
expected_mute=$(
	pactl -f json list sinks 2>/dev/null |
		jq -r --arg sink "$expected_sink" '
			map(select(.name == $sink))[0].mute
		'
)

"$binary" --config "$config_path" >>"$daemon_log" 2>&1 &
daemon_pid=$!

count=0
while :; do
	status=$("$binary" status --socket "$control_socket" 2>/dev/null || true)
	available=$(printf '%s\n' "$status" | jq -r '.state.audio.available // false' 2>/dev/null || true)
	ready=$(printf '%s\n' "$status" | jq -r '.state.runtime.ready // false' 2>/dev/null || true)
	if [ "$available" = "true" ] && [ "$ready" = "true" ]; then
		break
	fi
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$daemon_log" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 300 ]; then
		echo "timed out waiting for audio snapshot" >&2
		cat "$daemon_log" >&2
		exit 1
	fi
	sleep 0.01
done

actual_sink=$(printf '%s\n' "$status" | jq -r '.state.audio.sink')
actual_volume=$(printf '%s\n' "$status" | jq -r '.state.audio.volume')
actual_mute=$(printf '%s\n' "$status" | jq -r '.state.audio.muted')
if [ "$actual_sink" != "$expected_sink" ]; then
	echo "audio sink mismatch: expected $expected_sink, got $actual_sink" >&2
	exit 1
fi
if [ "$actual_volume" != "$expected_volume" ]; then
	echo "audio volume mismatch: expected $expected_volume, got $actual_volume" >&2
	exit 1
fi
if [ "$actual_mute" != "$expected_mute" ]; then
	echo "audio mute mismatch: expected $expected_mute, got $actual_mute" >&2
	exit 1
fi
doctor=$("$binary" doctor --socket "$control_socket")
printf '%s\n' "$doctor" |
	jq -e '
		.healthy == true and
		.sources.audio.status == "ready" and
		.sources.audio.capabilities.set_volume == true and
		.sources.audio.capabilities.set_mute == true
	' >/dev/null

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

PULSE_SERVER="unix:$runtime_dir/missing-pulse.sock" \
	"$binary" --config "$config_path" >>"$daemon_log" 2>&1 &
daemon_pid=$!
count=0
while :; do
	status=$("$binary" status --socket "$control_socket" 2>/dev/null || true)
	ready=$(printf '%s\n' "$status" | jq -r '.state.runtime.ready // false' 2>/dev/null || true)
	error=$(printf '%s\n' "$status" | jq -r '.state.audio.error // ""' 2>/dev/null || true)
	if [ "$ready" = "true" ] && [ -n "$error" ]; then
		break
	fi
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$daemon_log" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 300 ]; then
		echo "timed out waiting for unavailable audio snapshot" >&2
		cat "$daemon_log" >&2
		exit 1
	fi
	sleep 0.01
done
printf '%s\n' "$status" |
	jq -e '
		.state.audio.available == false and
		.state.audio.connected == false and
		.state.audio.muted == false and
		.state.audio.sink == "" and
		.state.audio.volume == 0
	' >/dev/null
doctor=$("$binary" doctor --socket "$control_socket")
printf '%s\n' "$doctor" |
	jq -e '
		.healthy == false and
		.sources.audio.status == "degraded" and
		.sources.audio.connected == false
	' >/dev/null

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

echo "Audio source read-only integration tests passed"
