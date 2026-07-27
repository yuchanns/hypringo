return {
	runtime = {
		socket_path = "/tmp/hypringo-all-sources.sock",
		workers = 4,
	},
	sources = {
		audio = {
			enabled = true,
		},
		hyprland = {
			command_socket = "/tmp/hypringo-command.sock",
			enabled = true,
			event_socket = "/tmp/hypringo-event.sock",
		},
		mpris = {
			enabled = true,
		},
	},
}
