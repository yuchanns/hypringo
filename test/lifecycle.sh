#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-lifecycle.XXXXXX")
socket_path="$runtime_dir/hypringo.sock"
config_path="$runtime_dir/config.lua"
log_path="$runtime_dir/hypringo.log"
listener_log="$runtime_dir/listener.log"
snapshots="$runtime_dir/eww.jsonl"
daemon_pid=
listener_pid=

cleanup() {
	if [ -n "$listener_pid" ] && kill -0 "$listener_pid" 2>/dev/null; then
		kill -TERM "$listener_pid" 2>/dev/null || true
		wait "$listener_pid" 2>/dev/null || true
	fi
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
		socket_path = "$socket_path",
		workers = 2,
	},
}
EOF

start_daemon() {
	XDG_RUNTIME_DIR="$runtime_dir" \
		"$binary" --config "$config_path" >>"$log_path" 2>&1 &
	daemon_pid=$!
	count=0
	while :; do
		if [ -S "$socket_path" ] &&
			"$binary" doctor --socket "$socket_path" 2>/dev/null |
				jq -e '.ready == true' >/dev/null 2>&1; then
			return
		fi
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			cat "$log_path" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 300 ]; then
			echo "daemon did not become ready" >&2
			cat "$log_path" >&2
			exit 1
		fi
		sleep 0.01
	done
}

wait_for_ready_snapshot_after() {
	previous_lines=$1
	count=0
	while :; do
		lines=$(wc -l <"$snapshots")
		if [ "$lines" -gt "$previous_lines" ] &&
			tail -n "+$((previous_lines + 1))" "$snapshots" |
				jq -e -s 'any(.runtime.ready == true)' >/dev/null 2>&1; then
			printf "%s\n" "$lines"
			return
		fi
		if ! kill -0 "$listener_pid" 2>/dev/null; then
			cat "$listener_log" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 500 ]; then
			echo "Eww listener did not replay a ready snapshot" >&2
			cat "$listener_log" >&2
			exit 1
		fi
		sleep 0.01
	done
}

XDG_RUNTIME_DIR="$runtime_dir" HYPRINGO_BIN="$binary" \
	contrib/eww/hypringo-listen --socket "$socket_path" \
	>"$snapshots" 2>"$listener_log" &
listener_pid=$!
sleep 0.05
kill -0 "$listener_pid"

start_daemon
first_lines=$(wait_for_ready_snapshot_after 0)

kill -KILL "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

start_daemon
second_lines=$(wait_for_ready_snapshot_after "$first_lines")
if [ "$second_lines" -le "$first_lines" ]; then
	echo "Eww listener did not receive a post-crash snapshot" >&2
	exit 1
fi

kill -TERM "$listener_pid"
wait "$listener_pid" 2>/dev/null || true
listener_pid=
sleep 0.05
if pgrep -f "$binary subscribe --format eww --socket $socket_path" >/dev/null 2>&1; then
	echo "Eww listener left an orphaned subscriber" >&2
	exit 1
fi

grep -Fq 'ExecStartPre=%h/.local/bin/hypringo --check-config' \
	contrib/systemd/hypringo.service
grep -Fq 'ExecReload=%h/.local/bin/hypringo reload' \
	contrib/systemd/hypringo.service
grep -Fq 'WantedBy=graphical-session.target' \
	contrib/systemd/hypringo.service

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

echo "systemd and Eww lifecycle integration tests passed"
