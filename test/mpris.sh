#!/bin/sh
set -eu

binary=${1:-build/bin/hypringo}
mock=${2:-build/bin/mpris_mock}
case "$binary" in
	/*) ;;
	*) binary="$(pwd)/$binary" ;;
esac
case "$mock" in
	/*) ;;
	*) mock="$(pwd)/$mock" ;;
esac

exec dbus-run-session -- sh -eu -c '
	binary=$1
	mock=$2
	runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/hypringo-mpris.XXXXXX")
	control_socket="$runtime_dir/hypringo.sock"
	config_path="$runtime_dir/config.lua"
	daemon_log="$runtime_dir/hypringo.log"
	alpha_log="$runtime_dir/alpha-actions.log"
	zeta_log="$runtime_dir/zeta-actions.log"
	alpha_pid=
	zeta_pid=
	daemon_pid=

	cleanup() {
		for pid in "$daemon_pid" "$zeta_pid" "$alpha_pid"; do
			if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
				kill -TERM "$pid" 2>/dev/null || true
				wait "$pid" 2>/dev/null || true
			fi
		done
		rm -rf "$runtime_dir"
	}
	trap cleanup EXIT INT TERM

	write_config() {
		reconnect_min_ms=$1
		reconnect_max_ms=$2
		cat >"$config_path" <<EOF
return {
	runtime = {
		socket_path = "$control_socket",
		workers = 3,
	},
	sources = {
		mpris = {
			enabled = true,
			reconnect_max_ms = $reconnect_max_ms,
			reconnect_min_ms = $reconnect_min_ms,
		},
	},
}
EOF
	}
	write_config 20 100

	wait_for_status() {
		pattern=$1
		count=0
		while :; do
			status=$("$binary" status --socket "$control_socket" 2>/dev/null || true)
			case "$status" in
				*"$pattern"*)
					printf "%s\n" "$status"
					return
					;;
			esac
			if ! kill -0 "$daemon_pid" 2>/dev/null; then
				cat "$daemon_log" >&2
				exit 1
			fi
			count=$((count + 1))
			if [ "$count" -ge 300 ]; then
				echo "timed out waiting for MPRIS status: $pattern" >&2
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

	"$mock" \
		org.mpris.MediaPlayer2.alpha \
		Alpha \
		Paused \
		"Alpha title" \
		"$alpha_log" &
	alpha_pid=$!
	"$mock" \
		org.mpris.MediaPlayer2.zeta \
		Zeta \
		Paused \
		"Zeta title" \
		"$zeta_log" &
	zeta_pid=$!
	sleep 0.05

	XDG_RUNTIME_DIR="$runtime_dir" \
		"$binary" --config "$config_path" >>"$daemon_log" 2>&1 &
	daemon_pid=$!

	wait_for_status "\"ready\":true" >/dev/null
	initial=$(wait_for_status "\"player\":\"Alpha\"")
	assert_contains "$initial" "\"status\":\"paused\"" "MPRIS status was not normalized"
	assert_contains "$initial" "\"title\":\"Alpha title\"" "MPRIS metadata was not published"
	assert_contains "$initial" "\"album\":\"Mock album\"" "MPRIS album was not published"
	assert_contains "$initial" "\"connected\":true" "MPRIS bus health was not published"
	assert_contains "$initial" "\"next\":true" "supported MPRIS capability was not published"
	assert_contains "$initial" "\"previous\":false" "unsupported MPRIS capability was not published"
	doctor=$("$binary" doctor --socket "$control_socket")
	assert_contains "$doctor" "\"healthy\":true" "connected MPRIS doctor state was unhealthy"
	assert_contains "$doctor" "\"status\":\"ready\"" "MPRIS doctor state was not ready"
	write_config 30 80
	"$binary" reload --socket "$control_socket" >/dev/null
	count=0
	while :; do
		doctor=$("$binary" doctor --socket "$control_socket")
		case "$doctor" in
			*"\"config_generation\":2"*) break ;;
		esac
		count=$((count + 1))
		if [ "$count" -ge 100 ]; then
			echo "MPRIS source did not apply reconnect policy reload" >&2
			exit 1
		fi
		sleep 0.01
	done
	sleep 0.05
	initial=$("$binary" status --socket "$control_socket")
	initial_revision=$(printf "%s\n" "$initial" | jq -r .revision)
	kill -USR2 "$alpha_pid"
	sleep 0.05
	unchanged=$("$binary" status --socket "$control_socket")
	unchanged_revision=$(printf "%s\n" "$unchanged" | jq -r .revision)
	if [ "$unchanged_revision" != "$initial_revision" ]; then
		echo "irrelevant MPRIS property changed the state revision" >&2
		exit 1
	fi

	"$binary" dispatch media previous --socket "$control_socket" >/dev/null
	sleep 0.05
	if grep -Fxq Previous "$alpha_log" 2>/dev/null; then
		echo "unsupported MPRIS action reached the selected player" >&2
		exit 1
	fi
	kill -WINCH "$alpha_pid"
	capable=$(wait_for_status "\"previous\":true")
	assert_contains "$capable" "\"player\":\"Alpha\"" "capability update changed the selected player"
	"$binary" dispatch media previous --socket "$control_socket" >/dev/null
	count=0
	while ! grep -Fxq Previous "$alpha_log" 2>/dev/null; do
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			cat "$daemon_log" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 100 ]; then
			echo "newly supported MPRIS action did not reach the player" >&2
			exit 1
		fi
		sleep 0.01
	done

	kill -USR1 "$zeta_pid"
	playing=$(wait_for_status "\"player\":\"Zeta\"")
	assert_contains "$playing" "\"status\":\"playing\"" "playing player was not preferred"

	dispatch=$(
		"$binary" dispatch media play-pause --socket "$control_socket"
	)
	assert_contains "$dispatch" "\"type\":\"accepted\"" "MPRIS dispatch was rejected"
	count=0
	while ! grep -Fxq PlayPause "$zeta_log" 2>/dev/null; do
		if ! kill -0 "$daemon_pid" 2>/dev/null; then
			cat "$daemon_log" >&2
			exit 1
		fi
		count=$((count + 1))
		if [ "$count" -ge 100 ]; then
			echo "MPRIS dispatch did not reach selected player" >&2
			exit 1
		fi
		sleep 0.01
	done

	kill -TERM "$zeta_pid"
	wait "$zeta_pid" 2>/dev/null || true
	zeta_pid=
	wait_for_status "\"player\":\"Alpha\"" >/dev/null

	kill -TERM "$alpha_pid"
	wait "$alpha_pid" 2>/dev/null || true
	alpha_pid=
	unavailable=$(wait_for_status "\"available\":false")
	assert_contains "$unavailable" "\"player\":\"\"" "MPRIS removal did not reset player"
	assert_contains "$unavailable" "\"title\":\"\"" "MPRIS removal did not reset metadata"
	assert_contains "$unavailable" "\"connected\":true" "empty MPRIS bus was marked disconnected"
	doctor=$("$binary" doctor --socket "$control_socket")
	assert_contains "$doctor" "\"healthy\":true" "empty but connected MPRIS source was unhealthy"

	kill -TERM "$daemon_pid"
	wait "$daemon_pid" 2>/dev/null || true
	daemon_pid=

	echo "MPRIS source integration tests passed"
' sh "$binary" "$mock"
