#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-control.XXXXXX")
socket_path="$runtime_dir/hypringo.sock"
log_path="$runtime_dir/hypringo.log"
subscribe_path="$runtime_dir/subscribe.jsonl"
pid=

cleanup() {
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

start_daemon

status=$(XDG_RUNTIME_DIR="$runtime_dir" "$binary" status)
case "$status" in
	*'"revision":1'*'"ready":true'*'"type":"snapshot"'*) ;;
	*)
		echo "unexpected status response: $status" >&2
		exit 1
		;;
esac

set +e
XDG_RUNTIME_DIR="$runtime_dir" timeout 1 "$binary" subscribe --format eww >"$subscribe_path"
subscribe_status=$?
set -e
if [ "$subscribe_status" -ne 124 ]; then
	echo "subscribe exited with unexpected status $subscribe_status" >&2
	exit 1
fi
grep -q '"revision":1' "$subscribe_path"

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
