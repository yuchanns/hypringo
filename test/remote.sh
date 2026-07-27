#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-remote.XXXXXX")
socket_path="$runtime_dir/hypringo.sock"
config_path="$runtime_dir/config.lua"
log_path="$runtime_dir/hypringo.log"
port_path="$runtime_dir/port"
request_log="$runtime_dir/requests.jsonl"
daemon_pid=
mock_pid=

cleanup() {
	if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
		kill -TERM "$daemon_pid" 2>/dev/null || true
		wait "$daemon_pid" 2>/dev/null || true
	fi
	if [ -n "$mock_pid" ] && kill -0 "$mock_pid" 2>/dev/null; then
		kill -TERM "$mock_pid" 2>/dev/null || true
		wait "$mock_pid" 2>/dev/null || true
	fi
	rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

python3 test/remote_mock.py "$port_path" "$request_log" &
mock_pid=$!
count=0
while [ ! -s "$port_path" ]; do
	if ! kill -0 "$mock_pid" 2>/dev/null; then
		echo "remote mock exited before publishing its port" >&2
		exit 1
	fi
	count=$((count + 1))
	if [ "$count" -ge 500 ]; then
		echo "timed out waiting for remote mock" >&2
		exit 1
	fi
	sleep 0.01
done
port=$(cat "$port_path")

write_config() {
	interval_ms=$1
	token_env=${2:-HYPRINGO_TEST_GITHUB_TOKEN}
	cat >"$config_path" <<EOF
return {
	runtime = {
		socket_path = "$socket_path",
		workers = 3,
	},
	sources = {
		github = {
			enabled = true,
			interval_ms = $interval_ms,
			max_items = 1,
			max_response_bytes = 4096,
			retry_max_ms = 400,
			retry_min_ms = 100,
			timeout_ms = 100,
			token_env = "$token_env",
			url = "http://127.0.0.1:$port/github",
		},
		weather = {
			enabled = true,
			interval_ms = $interval_ms,
			max_response_bytes = 512,
			retry_max_ms = 400,
			retry_min_ms = 100,
			timeout_ms = 50,
			url = "http://127.0.0.1:$port/weather-redirect",
		},
	},
}
EOF
}

write_config 150
HYPRINGO_TEST_GITHUB_TOKEN=test-token \
	XDG_RUNTIME_DIR="$runtime_dir" \
	"$binary" --check-config --config "$config_path" >/dev/null
HYPRINGO_TEST_GITHUB_TOKEN=test-token \
	XDG_RUNTIME_DIR="$runtime_dir" \
	"$binary" --config "$config_path" >>"$log_path" 2>&1 &
daemon_pid=$!

wait_state() {
	filter=$1
	count=0
	while :; do
		status=$(
			XDG_RUNTIME_DIR="$runtime_dir" \
				"$binary" status --socket "$socket_path" 2>/dev/null || true
		)
		if [ -n "$status" ] &&
			printf "%s\n" "$status" |
			jq -e "$filter" >/dev/null 2>&1; then
			printf "%s\n" "$status"
			return
		fi
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			cat "$log_path" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 1000 ]; then
			echo "timed out waiting for remote state: $filter" >&2
			printf "%s\n" "$status" >&2
			cat "$log_path" >&2
			exit 1
		fi
		sleep 0.01
	done
}

initial=$(wait_state '
	.state.runtime.ready == true and
	.state.weather.available == true and
	.state.weather.stale == false and
	.state.weather.condition == "Sunny" and
	.state.github.available == true and
	.state.github.stale == false and
	(.state.github.notifications | length) == 1 and
	.state.github.notifications[0].subject.title == "First notification"
')
printf "%s\n" "$initial" |
	jq -e '.state.github.notifications[0].repository.full_name == "owner/repo"' \
	>/dev/null

wait_state '
	.state.weather.stale == true and
	.state.weather.failures == 1 and
	(.state.weather.error | test("timed out"; "i"))
' >/dev/null

bounded=$(wait_state '
	.state.weather.stale == true and
	.state.weather.failures == 2 and
	(.state.weather.error | contains("exceeds configured max_bytes"))
')
printf "%s\n" "$bounded" |
	jq -e '
		.state.weather.available == true and
		.state.weather.condition == "Sunny" and
		.state.github.available == true
	' >/dev/null

rate_limited=$(wait_state '
	.state.github.stale == true and
	.state.github.failures == 1 and
	(.state.github.error | contains("HTTP status 429"))
')
printf "%s\n" "$rate_limited" |
	jq -e '
		.state.github.available == true and
		.state.github.refresh_in_ms >= 1000 and
		.state.weather.available == true
	' >/dev/null

recovered=$(wait_state '
	.state.weather.available == true and
	.state.weather.stale == false and
	.state.weather.condition == "Cloudy" and
	.state.github.available == true and
	.state.github.stale == false and
	.state.github.failures == 0 and
	.state.github.notifications[0].subject.title == "Recovered notification"
')
printf "%s\n" "$recovered" |
	jq -e '
		.state.weather.failures == 0 and
		.state.github.notifications[0].id == "3"
	' >/dev/null

doctor=$(
	XDG_RUNTIME_DIR="$runtime_dir" \
		"$binary" doctor --socket "$socket_path"
)
printf "%s\n" "$doctor" |
	jq -e '
		.healthy == true and
		.sources.weather.status == "ready" and
		.sources.github.status == "ready" and
		.sources.weather.stale == false and
		.sources.github.stale == false
	' >/dev/null

write_config 250
"$binary" reload --socket "$socket_path" >/dev/null
wait_state '
	.state.runtime.config_generation == 2 and
	.state.runtime.last_reload_error == "" and
	.state.weather.stale == false and
	.state.github.stale == false
' >/dev/null

write_config 250 HYPRINGO_MISSING_GITHUB_TOKEN
"$binary" reload --socket "$socket_path" >/dev/null
missing_token=$(wait_state '
	.state.runtime.config_generation == 3 and
	.state.github.stale == true and
	.state.github.failures >= 1 and
	(.state.github.error | contains("HYPRINGO_MISSING_GITHUB_TOKEN")) and
	.state.weather.stale == false
')
printf "%s\n" "$missing_token" |
	jq -e '
		.state.github.available == true and
		.state.weather.available == true
	' >/dev/null

write_config 250 HYPRINGO_TEST_GITHUB_TOKEN
"$binary" reload --socket "$socket_path" >/dev/null
wait_state '
	.state.runtime.config_generation == 4 and
	.state.runtime.last_reload_error == "" and
	.state.github.stale == false and
	.state.github.failures == 0
' >/dev/null

jq -s -e '
	any(.[]; .path == "/github" and .authorization == "Bearer test-token") and
	any(.[]; .path == "/github" and .if_none_match == "\"v1\"") and
	([.[] | select(.path == "/weather-redirect")] | length) >= 4 and
	([.[] | select(.path == "/weather")] | length) >= 4 and
	([.[] | select(.path == "/github")] | length) >= 4
' "$request_log" >/dev/null

kill -TERM "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=

echo "remote source integration tests passed"
