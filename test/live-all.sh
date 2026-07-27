#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-live-all.XXXXXX")
control_socket="$runtime_dir/hypringo.sock"
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

instance=$(hyprctl instances -j | jq -r 'if length == 1 then .[0].instance else empty end')
if [ -z "$instance" ]; then
	echo "live test requires exactly one Hyprland instance" >&2
	exit 1
fi
session_runtime_dir=${XDG_RUNTIME_DIR:-"/run/user/$(id -u)"}
hyprland_dir="$session_runtime_dir/hypr/$instance"
test -S "$hyprland_dir/.socket.sock"
test -S "$hyprland_dir/.socket2.sock"
test -S "$session_runtime_dir/bus"
test -S "$session_runtime_dir/pulse/native"

legacy_pid=$(pgrep -f '^/usr/bin/lua ./main.lua$' || true)
legacy_workspaces=$(eww get workspaces 2>/dev/null || true)
expected_sink=$(pactl get-default-sink)
printf '%s\n' "$legacy_workspaces" | jq -e 'length > 0' >/dev/null

DBUS_SESSION_BUS_ADDRESS="unix:path=$session_runtime_dir/bus" \
	HYPRINGO_TEST_HYPRLAND_DIR="$hyprland_dir" \
	PULSE_SERVER="unix:$session_runtime_dir/pulse/native" \
	XDG_RUNTIME_DIR="$runtime_dir" \
	"$binary" --config test/config-live-all.lua >>"$log_path" 2>&1 &
daemon_pid=$!

count=0
while :; do
	status=$(
		XDG_RUNTIME_DIR="$runtime_dir" \
			"$binary" status --socket "$control_socket" 2>/dev/null || true
	)
	if printf '%s\n' "$status" |
		jq -e '
			.state.runtime.ready == true and
			.state.hyprland.available == true and
			.state.audio.available == true and
			(.state.media.available | type) == "boolean"
		' >/dev/null 2>&1
	then
		break
	fi
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$log_path" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 300 ]; then
		echo "live combined sources did not become ready" >&2
		cat "$log_path" >&2
		exit 1
	fi
	sleep 0.01
done

actual_sink=$(printf '%s\n' "$status" | jq -r '.state.audio.sink')
if [ "$actual_sink" != "$expected_sink" ]; then
	echo "combined source audio sink mismatch: expected $expected_sink, got $actual_sink" >&2
	exit 1
fi

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

current_legacy_pid=$(pgrep -f '^/usr/bin/lua ./main.lua$' || true)
current_workspaces=$(eww get workspaces 2>/dev/null || true)
if [ "$current_legacy_pid" != "$legacy_pid" ]; then
	echo "combined source test changed the legacy Hypringo process" >&2
	exit 1
fi
if [ "$current_workspaces" != "$legacy_workspaces" ]; then
	echo "combined source test changed the legacy Eww workspace state" >&2
	exit 1
fi

printf '%s\n' "$status" | jq -c '{
	audio: {
		available: .state.audio.available,
		sink: .state.audio.sink
	},
	hyprland: {
		active_workspace: .state.hyprland.active_workspace,
		monitors: [.state.hyprland.monitors[].name]
	},
	media: {
		available: .state.media.available,
		player: .state.media.player
	}
}'
echo "live combined source isolation test passed"
