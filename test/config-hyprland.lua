return {
	runtime = {
		socket_path = "/tmp/hypringo-test.sock",
		workers = 2,
	},
	sources = {
		hyprland = {
			command_socket = "/tmp/hypringo-command.sock",
			enabled = true,
			event_socket = "/tmp/hypringo-event.sock",
			reconnect_max_ms = 200,
			reconnect_min_ms = 20,
		},
	},
}
