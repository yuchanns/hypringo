#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-live-source.XXXXXX")
control_socket="$runtime_dir/hypringo.sock"
log_path="$runtime_dir/hypringo.log"
eww_path="$runtime_dir/eww.json"
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

legacy_pid=$(pgrep -f '^/usr/bin/lua ./main.lua$' || true)
legacy_workspaces=$(eww get workspaces 2>/dev/null || true)
printf '%s\n' "$legacy_workspaces" | jq -e 'length > 0' >/dev/null

HYPRINGO_TEST_HYPRLAND_DIR="$hyprland_dir" \
	XDG_RUNTIME_DIR="$runtime_dir" \
	"$binary" --config test/config-live-hyprland.lua >>"$log_path" 2>&1 &
daemon_pid=$!

count=0
while :; do
	status=$(
		XDG_RUNTIME_DIR="$runtime_dir" \
			"$binary" status --socket "$control_socket" 2>/dev/null || true
	)
	if printf '%s\n' "$status" |
		jq -e '.state.runtime.ready == true and .state.hyprland.available == true' \
			>/dev/null 2>&1
	then
		break
	fi
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$log_path" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 300 ]; then
		echo "live Hyprland source did not become ready" >&2
		cat "$log_path" >&2
		exit 1
	fi
	sleep 0.01
done

set +e
XDG_RUNTIME_DIR="$runtime_dir" timeout 1 \
	"$binary" subscribe --socket "$control_socket" --format eww >"$eww_path"
subscribe_status=$?
set -e
if [ "$subscribe_status" -ne 124 ]; then
	echo "Eww subscription exited with unexpected status $subscribe_status" >&2
	exit 1
fi
jq -e '.hyprland.available == true and (.hyprland.monitors | length) > 0' \
	"$eww_path" >/dev/null

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

current_legacy_pid=$(pgrep -f '^/usr/bin/lua ./main.lua$' || true)
current_workspaces=$(eww get workspaces 2>/dev/null || true)
if [ "$current_legacy_pid" != "$legacy_pid" ]; then
	echo "live source test changed the legacy Hypringo process" >&2
	exit 1
fi
printf '%s\n' "$current_workspaces" | jq -e 'length > 0' >/dev/null

printf '%s\n' "$status" | jq -c '{
	active_window: .state.hyprland.active_window.title,
	active_workspace: .state.hyprland.active_workspace,
	monitors: [.state.hyprland.monitors[].name],
	workspaces: [.state.hyprland.workspaces[].name]
}'
echo "live Hyprland source isolation test passed"
