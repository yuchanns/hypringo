return {
	runtime = {
		socket_path = "/tmp/hypringo-remote.sock",
		workers = 3,
	},
	sources = {
		github = {
			enabled = true,
			max_items = 7,
			token_env = "HYPRINGO_TEST_GITHUB_TOKEN",
			url = "http://127.0.0.1:8080/github",
		},
		weather = {
			enabled = true,
			url = "http://127.0.0.1:8080/weather",
		},
	},
}
