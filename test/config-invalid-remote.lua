return {
	runtime = {
		socket_path = "/tmp/hypringo-invalid-remote.sock",
		workers = 2,
	},
	sources = {
		weather = {
			enabled = true,
			url = "file:///tmp/weather.json",
		},
	},
}
