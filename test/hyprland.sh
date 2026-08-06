#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac
handler="$(pwd)/test/fake-hyprland-command.sh"
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-source.XXXXXX")
fake_dir="$runtime_dir/fake"
command_socket="$runtime_dir/command.sock"
event_socket="$runtime_dir/event.sock"
event_pipe="$runtime_dir/event.pipe"
control_socket="$runtime_dir/hypringo.sock"
config_path="$runtime_dir/config.lua"
session_path="$runtime_dir/session.json"
session_marker="$runtime_dir/session-marker"
session_helper="$(pwd)/test/session-helper.sh"
daemon_log="$runtime_dir/hypringo.log"
command_log="$runtime_dir/command.log"
command_request_log="$runtime_dir/command-requests.log"
event_log="$runtime_dir/event.log"
command_pid=
event_pid=
daemon_pid=

cleanup() {
	exec 3>&- 2>/dev/null || true
	for pid in "$daemon_pid" "$event_pid" "$command_pid"; do
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			kill -TERM "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
	done
	rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

mkdir "$fake_dir"
mkfifo "$event_pipe"

cat >"$fake_dir/monitors.json" <<'JSON'
[{"id":7,"name":"FAKE-1","description":"Fake monitor","width":1920,"height":1080,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"dpmsStatus":true,"activeWorkspace":{"id":2,"name":"2"}}]
JSON
cat >"$fake_dir/workspaces.json" <<'JSON'
[{"id":2,"name":"2","monitor":"FAKE-1","monitorID":7,"windows":1,"hasfullscreen":false,"lastwindow":"0x123","lastwindowtitle":"Initial, title","ispersistent":true}]
JSON
cat >"$fake_dir/activewindow.json" <<'JSON'
{"address":"0x123","class":"example","title":"Initial, title","workspace":{"id":2,"name":"2"},"floating":false,"fullscreen":0,"pid":42,"xwayland":false}
JSON
cat >"$fake_dir/clients.json" <<'JSON'
[{"address":"0x123","class":"example","initialClass":"example","initialTitle":"Initial, title","title":"Initial, title","workspace":{"id":2,"name":"2"},"floating":false,"fullscreen":0,"pid":42,"at":[0,0],"size":[1200,800],"monitor":7,"mapped":true,"hidden":false,"xwayland":false}]
JSON
cat >"$config_path" <<EOF
return {
	runtime = {
		socket_path = "$control_socket",
		workers = 2,
	},
	session = {
		enabled = true,
		path = "$session_path",
		restore = true,
		debounce_ms = 20,
	},
	sources = {
		hyprland = {
			command_socket = "$command_socket",
			enabled = true,
			event_socket = "$event_socket",
			reconnect_max_ms = 100,
			reconnect_min_ms = 20,
		},
	},
}
EOF

cat >"$session_path" <<EOF
{"captured_at":1,"clients":[{"application":{"argv":["$session_helper","restored"],"cwd":"$(pwd)/test","executable":"$session_helper","initial_class":"restorable-test"},"reason":"","restore":"automatic","window":{"class":"restorable-test","floating":false,"fullscreen":0,"height":800,"initial_class":"restorable-test","initial_title":"","title":"Restored test application","width":1200,"workspace":{"monitor":"FAKE-1","name":"2"},"x":0,"y":0}}],"format":"hypringo-session","monitors":[],"skipped":[],"version":1,"workspaces":[]}
EOF

start_command_server() {
	FAKE_HYPRLAND_DIR="$fake_dir" \
		FAKE_HYPRLAND_REQUEST_LOG="$command_request_log" \
		socat \
		"UNIX-LISTEN:$command_socket,unlink-early,fork" \
		"SYSTEM:sh '$handler'" \
		>>"$command_log" 2>&1 &
	command_pid=$!
}

start_event_server() {
	socat \
		"UNIX-LISTEN:$event_socket,unlink-early" \
		"OPEN:$event_pipe,rdonly" \
		>>"$event_log" 2>&1 &
	event_pid=$!
	count=0
	while [ ! -S "$event_socket" ]; do
		if ! kill -0 "$event_pid" 2>/dev/null; then
			cat "$event_log" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 100 ]; then
			echo "event socket did not become ready" >&2
			exit 1
		fi
		sleep 0.01
	done
}

wait_for_status() {
	pattern=$1
	count=0
	while :; do
		status=$("$binary" status --socket "$control_socket" 2>/dev/null || true)
		case "$status" in
			*"$pattern"*)
				printf '%s\n' "$status"
				return
				;;
		esac
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			cat "$daemon_log" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 300 ]; then
			echo "timed out waiting for status pattern: $pattern" >&2
			cat "$daemon_log" >&2
			exit 1
		fi
		sleep 0.01
	done
}

assert_contains() {
	value=$1
	pattern=$2
	message=$3
	case "$value" in
		*"$pattern"*) ;;
		*)
			echo "$message: missing $pattern in $value" >&2
			exit 1
			;;
	esac
}

start_command_server
start_event_server
HYPRINGO_SESSION_TEST_MARKER="$session_marker" \
	XDG_RUNTIME_DIR="$runtime_dir" "$binary" --config "$config_path" >>"$daemon_log" 2>&1 &
daemon_pid=$!
exec 3>"$event_pipe"

wait_for_status '"ready":true' >/dev/null
initial=$(wait_for_status '"available":true')
assert_contains "$initial" '"monitor":"FAKE-1"' "initial Hyprland snapshot is incomplete"
assert_contains "$initial" '"monitor_id":7' "initial Hyprland snapshot is incomplete"
assert_contains "$initial" '"title":"Initial, title"' "initial Hyprland snapshot is incomplete"
assert_contains "$initial" '"address":"0x123"' "Hyprland clients were not captured"
doctor=$("$binary" doctor --socket "$control_socket")
assert_contains "$doctor" '"healthy":true' "connected Hyprland doctor state was unhealthy"
assert_contains "$doctor" '"switch_workspace":true' "Hyprland capability was not published"
eww_initial=$(printf 'status eww\n' | socat - "UNIX-CONNECT:$control_socket")
assert_contains "$eww_initial" '"title":"Initial, title"' "Eww snapshot is incomplete"
case "$eww_initial" in
	*'"type":"snapshot"'*)
		echo "Eww snapshot unexpectedly contains the control envelope" >&2
		exit 1
		;;
esac

count=0
while ! grep -q '"restore":"skipped"' "$session_path" 2>/dev/null; do
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$daemon_log" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 400 ]; then
		echo "automatic session snapshot was not refreshed" >&2
		exit 1
	fi
	sleep 0.01
done
session_snapshot=$(cat "$session_path")
assert_contains "$session_snapshot" '"format":"hypringo-session"' "automatic session snapshot has the wrong format"
assert_contains "$session_snapshot" '"restore":"skipped"' "unsupported process was not marked skipped"
count=0
while [ ! -f "$session_marker" ]; do
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$daemon_log" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 100 ]; then
		echo "automatic session restore did not launch the supported test application" >&2
		exit 1
	fi
	sleep 0.01
done

dispatch_result=$(
	"$binary" dispatch workspace switch 8 --socket "$control_socket"
)
assert_contains "$dispatch_result" '"type":"accepted"' "workspace dispatch was rejected"
count=0
while ! grep -Fxq '/dispatch workspace 8' "$command_request_log"; do
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$daemon_log" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 100 ]; then
		echo "workspace dispatch did not reach the Hyprland adapter" >&2
		exit 1
	fi
	sleep 0.01
done
negative_dispatch=$(
	"$binary" dispatch workspace switch -3 --socket "$control_socket"
)
assert_contains "$negative_dispatch" '"type":"accepted"' "negative workspace dispatch was rejected"
count=0
while ! grep -Fxq '/dispatch workspace -3' "$command_request_log"; do
	if ! kill -0 "$daemon_pid" 2>/dev/null; then
		cat "$daemon_log" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 100 ]; then
		echo "negative workspace dispatch did not reach the Hyprland adapter" >&2
		exit 1
	fi
	sleep 0.01
done

cat >"$fake_dir/activewindow.json" <<'JSON'
{"address":"0x456","class":"example","title":"Updated, title","workspace":{"id":2,"name":"2"},"floating":false,"fullscreen":0,"pid":43,"xwayland":false}
JSON
printf 'activewindow>>example,Updated' >&3
sleep 0.01
printf ', title\n' >&3
updated=$(wait_for_status '"title":"Updated, title"')
updated_revision=$(printf '%s\n' "$updated" | sed -n 's/.*"revision":\\([0-9][0-9]*\\).*/\\1/p')

cat >"$fake_dir/activewindow.json" <<'JSON'
{"address":"0x999","class":"example","title":"Ignored change","workspace":{"id":2,"name":"2"},"floating":false,"fullscreen":0,"pid":44,"xwayland":false}
JSON
printf 'submap>>resize\n' >&3
sleep 0.05
unchanged=$("$binary" status --socket "$control_socket")
assert_contains "$unchanged" '"title":"Updated, title"' "an unrelated event unexpectedly changed state"
assert_contains "$unchanged" '"revision":'"$updated_revision" "an unrelated event unexpectedly changed revision"

cat >"$fake_dir/monitors.json" <<'JSON'
[{"id":7,"name":"FAKE-1","description":"Primary fake monitor","width":1920,"height":1080,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":false,"dpmsStatus":true,"activeWorkspace":{"id":2,"name":"2"}},{"id":99,"name":"FAKE-2","description":"Hot-plugged fake monitor","width":2560,"height":1440,"refreshRate":120,"x":1920,"y":0,"scale":1,"transform":0,"focused":true,"dpmsStatus":true,"activeWorkspace":{"id":8,"name":"8"}}]
JSON
cat >"$fake_dir/workspaces.json" <<'JSON'
[{"id":2,"name":"2","monitor":"FAKE-1","monitorID":7,"windows":0,"hasfullscreen":false,"lastwindow":"","lastwindowtitle":"","ispersistent":true},{"id":8,"name":"8","monitor":"FAKE-2","monitorID":99,"windows":1,"hasfullscreen":false,"lastwindow":"0x888","lastwindowtitle":"Hot-plugged monitor","ispersistent":true}]
JSON
cat >"$fake_dir/activewindow.json" <<'JSON'
{"address":"0x888","class":"example","title":"Hot-plugged monitor","workspace":{"id":8,"name":"8"},"floating":false,"fullscreen":0,"pid":88,"xwayland":false}
JSON
printf 'monitoraddedv2>>99,FAKE-2,Hot-plugged fake monitor\n' >&3
hotplugged=$(wait_for_status '"title":"Hot-plugged monitor"')
assert_contains "$hotplugged" '"name":"FAKE-1"' "existing monitor disappeared after hot-plug"
assert_contains "$hotplugged" '"name":"FAKE-2"' "new monitor was not auto-detected"
assert_contains "$hotplugged" '"monitor":"FAKE-2"' "focused monitor was not updated"

cat >"$fake_dir/monitors.json" <<'JSON'
[{"id":99,"name":"FAKE-2","description":"Remaining fake monitor","width":2560,"height":1440,"refreshRate":120,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"dpmsStatus":true,"activeWorkspace":{"id":8,"name":"8"}}]
JSON
cat >"$fake_dir/workspaces.json" <<'JSON'
[{"id":8,"name":"8","monitor":"FAKE-2","monitorID":99,"windows":1,"hasfullscreen":false,"lastwindow":"0x888","lastwindowtitle":"Remaining monitor","ispersistent":true}]
JSON
cat >"$fake_dir/activewindow.json" <<'JSON'
{"address":"0x888","class":"example","title":"Remaining monitor","workspace":{"id":8,"name":"8"},"floating":false,"fullscreen":0,"pid":88,"xwayland":false}
JSON
printf 'monitorremoved>>FAKE-1\n' >&3
removed=$(wait_for_status '"title":"Remaining monitor"')
case "$removed" in
	*'"name":"FAKE-1"'*)
		echo "removed monitor remained in the normalized snapshot" >&2
		exit 1
		;;
esac
assert_contains "$removed" '"name":"FAKE-2"' "remaining monitor disappeared after removal"

kill -TERM "$event_pid"
wait "$event_pid" 2>/dev/null || true
event_pid=
exec 3>&-
wait_for_status '"available":false' >/dev/null
doctor=$("$binary" doctor --socket "$control_socket")
assert_contains "$doctor" '"healthy":false' "disconnected Hyprland doctor state was healthy"
assert_contains "$doctor" '"status":"degraded"' "disconnected Hyprland source was not degraded"

cat >"$fake_dir/monitors.json" <<'JSON'
[{"id":99,"name":"FAKE-2","description":"Replacement monitor","width":2560,"height":1440,"refreshRate":120,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"dpmsStatus":true,"activeWorkspace":{"id":3,"name":"3"}}]
JSON
cat >"$fake_dir/workspaces.json" <<'JSON'
[{"id":3,"name":"3","monitor":"FAKE-2","monitorID":99,"windows":1,"hasfullscreen":false,"lastwindow":"0x999","lastwindowtitle":"Recovered title","ispersistent":true}]
JSON
cat >"$fake_dir/activewindow.json" <<'JSON'
{"address":"0x999","class":"example","title":"Recovered title","workspace":{"id":3,"name":"3"},"floating":false,"fullscreen":0,"pid":44,"xwayland":false}
JSON
start_event_server
exec 3>"$event_pipe"
recovered=$(wait_for_status '"title":"Recovered title"')
assert_contains "$recovered" '"id":99' "Hyprland reconnect snapshot is incomplete"
assert_contains "$recovered" '"monitor":"FAKE-2"' "Hyprland reconnect snapshot is incomplete"
assert_contains "$recovered" '"monitor_id":99' "Hyprland reconnect snapshot is incomplete"

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

echo "Hyprland source integration tests passed"
