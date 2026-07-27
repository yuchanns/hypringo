#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)

cleanup() {
	rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

state_file=$test_dir/state
log_file=$test_dir/eww.log
snapshots_file=$test_dir/snapshots.jsonl
: >"$state_file"
: >"$log_file"

cat >"$snapshots_file" <<'EOF'
{"hyprland":{"monitors":[{"name":"eDP-1"},{"name":"HDMI-A-2"}]}}
{"hyprland":{"monitors":[{"name":"HDMI-A-2"},{"name":"eDP-1"}]}}
{"hyprland":{"monitors":[{"name":"eDP-1"}]}}
EOF

set +e
EWW_BIN="$project_dir/test/fake-eww-command.sh" \
EWW_CONFIG_DIR="$test_dir/config" \
FAKE_EWW_LOG="$log_file" \
FAKE_EWW_STATE="$state_file" \
FAKE_EWW_SNAPSHOTS="$snapshots_file" \
HYPRINGO_EWW_LISTENER="$project_dir/test/fake-eww-listener.sh" \
XDG_RUNTIME_DIR="$test_dir" \
	"$project_dir/contrib/eww/hypringo-bars"
status=$?
set -e

if [ "$status" -eq 0 ]; then
	printf 'expected the manager to request a service restart after EOF\n' >&2
	exit 1
fi

cat >"$test_dir/expected.log" <<'EOF'
open bar hypringo-bar-HDMI-A-2 HDMI-A-2
open bar hypringo-bar-eDP-1 eDP-1
close hypringo-bar-HDMI-A-2
EOF
cmp "$test_dir/expected.log" "$log_file"

cat >"$test_dir/expected.state" <<'EOF'
hypringo-bar-eDP-1: bar
EOF
cmp "$test_dir/expected.state" "$state_file"

printf 'eww bar reconciliation passed\n'
