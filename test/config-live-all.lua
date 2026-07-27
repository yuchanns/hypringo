local socket_dir = assert(
	os.getenv "HYPRINGO_TEST_HYPRLAND_DIR",
	"HYPRINGO_TEST_HYPRLAND_DIR is required")

return {
	runtime = {
		workers = 4,
	},
	sources = {
		audio = {
			enabled = true,
		},
		hyprland = {
			command_socket = socket_dir .. "/.socket.sock",
			enabled = true,
			event_socket = socket_dir .. "/.socket2.sock",
		},
		mpris = {
			enabled = true,
		},
	},
}
