#!/bin/sh
set -eu

request=$(cat)
printf '%s\n' "$request" >>"$FAKE_HYPRLAND_REQUEST_LOG"
case "$request" in
	/dispatch\ workspace\ *)
		printf 'ok'
		;;
	j/activewindow)
		exec cat "$FAKE_HYPRLAND_DIR/activewindow.json"
		;;
	j/monitors)
		exec cat "$FAKE_HYPRLAND_DIR/monitors.json"
		;;
	j/workspaces)
		exec cat "$FAKE_HYPRLAND_DIR/workspaces.json"
		;;
	j/clients)
		exec cat "$FAKE_HYPRLAND_DIR/clients.json"
		;;
	*)
		echo "unsupported request: $request" >&2
		exit 1
		;;
esac
