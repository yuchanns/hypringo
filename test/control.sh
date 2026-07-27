#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-control.XXXXXX")
socket_path="$runtime_dir/hypringo.sock"
log_path="$runtime_dir/hypringo.log"
subscribe_path="$runtime_dir/subscribe.jsonl"
eww_subscribe_path="$runtime_dir/subscribe-eww.jsonl"
pid=
subscriber_pid=

cleanup() {
	if [ -n "$subscriber_pid" ] && kill -0 "$subscriber_pid" 2>/dev/null; then
		kill -TERM "$subscriber_pid" 2>/dev/null || true
		wait "$subscriber_pid" 2>/dev/null || true
	fi
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
	rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

start_daemon() {
	XDG_RUNTIME_DIR="$runtime_dir" "$binary" example/config.lua >>"$log_path" 2>&1 &
	pid=$!
	count=0
	while :; do
		if [ -S "$socket_path" ] &&
			XDG_RUNTIME_DIR="$runtime_dir" "$binary" status >/dev/null 2>&1; then
			break
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			cat "$log_path" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 100 ]; then
			echo "control socket did not become ready" >&2
			exit 1
		fi
		sleep 0.01
	done
}

assert_cloexec() {
	fd=$1
	description=$2
	flags=$(awk '$1 == "flags:" { print $2 }' "/proc/$pid/fdinfo/$fd")
	if [ $((flags & 02000000)) -eq 0 ]; then
		echo "$description fd $fd is missing FD_CLOEXEC" >&2
		exit 1
	fi
}

start_daemon

status=$(XDG_RUNTIME_DIR="$runtime_dir" "$binary" status)
case "$status" in
	*'"revision":1'*'"monitors":[]'*'"workspaces":[]'*'"ready":true'*'"type":"snapshot"'*) ;;
	*)
		echo "unexpected status response: $status" >&2
		exit 1
		;;
esac

listener_inode=$(
	awk -v path="$socket_path" '$NF == path { print $(NF - 1); exit }' /proc/net/unix
)
listener_fd=
for fd_path in "/proc/$pid/fd/"*; do
	if [ "$(readlink "$fd_path")" = "socket:[$listener_inode]" ]; then
		listener_fd=${fd_path##*/}
		break
	fi
done
test -n "$listener_fd"
assert_cloexec "$listener_fd" "control listener"

for fd_path in "/proc/$pid/fd/"*; do
	case "$(readlink "$fd_path")" in
	pipe:*)
		assert_cloexec "${fd_path##*/}" "control wake pipe"
		;;
	esac
done

before_fds=$(printf '%s\n' "/proc/$pid/fd/"* | sed 's!.*/!!' | tr '\n' ' ')
XDG_RUNTIME_DIR="$runtime_dir" timeout 5 "$binary" subscribe >"$subscribe_path" &
subscriber_pid=$!
accepted_fd=
count=0
while [ -z "$accepted_fd" ]; do
	for fd_path in "/proc/$pid/fd/"*; do
		fd=${fd_path##*/}
		case " $before_fds " in
		*" $fd "*) ;;
		*)
			case "$(readlink "$fd_path")" in
			socket:*)
				accepted_fd=$fd
				break
				;;
			esac
			;;
		esac
	done
	count=$((count + 1))
	if [ "$count" -ge 100 ]; then
		echo "control subscriber was not accepted" >&2
		exit 1
	fi
	sleep 0.01
done
assert_cloexec "$accepted_fd" "accepted control client"
count=0
while ! grep -q '"revision":1' "$subscribe_path" 2>/dev/null; do
	if ! kill -0 "$subscriber_pid" 2>/dev/null; then
		echo "control subscriber exited before receiving a snapshot" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 100 ]; then
		echo "control subscriber did not receive a snapshot" >&2
		exit 1
	fi
	sleep 0.01
done
kill -TERM "$subscriber_pid" 2>/dev/null || true
wait "$subscriber_pid" 2>/dev/null || true
subscriber_pid=

set +e
XDG_RUNTIME_DIR="$runtime_dir" timeout 1 "$binary" subscribe --format eww >"$eww_subscribe_path"
eww_subscribe_status=$?
set -e
if [ "$eww_subscribe_status" -ne 124 ]; then
	echo "subscribe exited with unexpected status $eww_subscribe_status" >&2
	exit 1
fi
grep -q '"revision":1' "$subscribe_path"
grep -q '"ready":true' "$eww_subscribe_path"
if grep -q '"type":"snapshot"' "$eww_subscribe_path"; then
	echo "Eww subscription unexpectedly contains the control envelope" >&2
	exit 1
fi

if XDG_RUNTIME_DIR="$runtime_dir" "$binary" example/config.lua >/dev/null 2>&1; then
	echo "a second daemon unexpectedly acquired the control socket" >&2
	exit 1
fi

kill -TERM "$pid"
wait "$pid" 2>/dev/null || true
pid=

start_daemon
XDG_RUNTIME_DIR="$runtime_dir" "$binary" status | grep -q '"ready":true'

echo "control integration tests passed"
