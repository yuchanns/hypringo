return {
	runtime = {
		socket_path = "/tmp/hypringo-too-few-workers.sock",
		workers = 3,
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
