return {
	runtime = {
		workers = 2,
		-- socket_path = "/run/user/1000/hypringo.sock",
	},
	-- Session capture is enabled automatically with the Hyprland source.
	-- session = {
	--	path = "/home/user/.local/state/hypringo/session.json",
	--	restore = true,
	-- },
	sources = {
		audio = {
			enabled = false,
		},
		hyprland = {
			enabled = false,
		},
		mpris = {
			enabled = false,
		},
		system = {
			enabled = true,
		},
		github = {
			enabled = false,
		},
		weather = {
			enabled = false,
		},
	},
}
