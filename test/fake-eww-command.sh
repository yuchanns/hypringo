#!/bin/sh
set -eu

: "${FAKE_EWW_LOG:?}"
: "${FAKE_EWW_STATE:?}"

if [ "${1:-}" = "-c" ]; then
	shift 2
fi

command=${1:-}
shift || true
case "$command" in
active-windows)
	cat "$FAKE_EWW_STATE"
	;;
open)
	window_name=$1
	shift
	instance_id=
	monitor_name=
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--id)
			instance_id=$2
			shift 2
			;;
		--screen)
			monitor_name=$2
			shift 2
			;;
		--arg)
			shift 2
			;;
		*)
			exit 2
			;;
		esac
	done
	printf 'open %s %s %s\n' "$window_name" "$instance_id" "$monitor_name" \
		>>"$FAKE_EWW_LOG"
	printf '%s: %s\n' "$instance_id" "$window_name" >>"$FAKE_EWW_STATE"
	;;
close)
	instance_id=$1
	printf 'close %s\n' "$instance_id" >>"$FAKE_EWW_LOG"
	temp_state="$FAKE_EWW_STATE.tmp"
	grep -Fv "$instance_id:" "$FAKE_EWW_STATE" >"$temp_state" || true
	mv "$temp_state" "$FAKE_EWW_STATE"
	;;
*)
	exit 2
	;;
esac
