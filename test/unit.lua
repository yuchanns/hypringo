local json = require "hypringo.json"
local actions = assert(loadfile("src/lualib/actions.lua", "t"))()
local hyprland = assert(loadfile("src/lualib/hyprland.lua", "t"))()
local state = assert(loadfile("src/lualib/state.lua", "t"))()
local config_module = assert(loadfile("src/lualib/config.lua", "t"))()

local function assert_equal(actual, expected)
	if actual ~= expected then
		error(("expected %s, got %s"):format(tostring(expected), tostring(actual)), 2)
	end
end

local encoded = json.encode {
	message = "line\n\"quoted\"",
	items = { "first", "second" },
	ready = true,
}
assert_equal(
	encoded,
	'{"items":["first","second"],"message":"line\\n\\\"quoted\\\"","ready":true}')
assert_equal(json._VERSION, "0.12.0")
assert_equal(json.encode({}), "{}")
assert_equal(json.encode(json.array()), "[]")
assert_equal(json.is_array(json.decode "[]"), true)
assert_equal(json.encode(json.decode "[]"), "[]")
assert_equal(json.encode(json.decode "{}"), "{}")
assert_equal(json.encode { ["a\0b"] = "value" }, '{"a\\u0000b":"value"}')
assert_equal(json.decode "-9223372036854775808", math.mininteger)
assert_equal(json.encode(math.mininteger), "-9223372036854775808")

local action_command, action_error =
	actions.from_cli { "workspace", "switch", "8" }
assert_equal(action_error, nil)
assert_equal(action_command, "dispatch workspace switch 8")
local action = assert(actions.parse(action_command))
assert_equal(action.domain, "workspace")
assert_equal(action.name, "switch")
assert_equal(action.value, 8)
action_command, action_error =
	actions.from_cli { "audio", "set-volume", "101" }
assert_equal(action_command, nil)
assert_equal(type(action_error), "string")
action, action_error = actions.parse "dispatch media play-pause"
assert_equal(action_error, nil)
assert_equal(action.domain, "media")
assert_equal(action.name, "play-pause")
action, action_error = actions.parse "dispatch audio set-mute false"
assert_equal(action_error, nil)
assert_equal(action.domain, "audio")
assert_equal(action.name, "set-mute")
assert_equal(action.value, false)
action, action_error = actions.parse "dispatch audio set-mute true"
assert_equal(action_error, nil)
assert_equal(action.value, true)
action, action_error = actions.parse "dispatch audio set-mute maybe"
assert_equal(action, nil)
assert_equal(type(action_error), "string")
action, action_error = actions.parse "dispatch workspace switch 8;shutdown"
assert_equal(action, nil)
assert_equal(type(action_error), "string")

local decoded = json.decode '{"items":[1,null,\"\\ud83d\\ude80\"],\"ready\":true}'
assert_equal(decoded.ready, true)
assert_equal(decoded.items[1], 1)
assert_equal(decoded.items[2], json.null)
assert_equal(decoded.items[3], "🚀")
assert_equal(json.encode(decoded), '{"items":[1,null,"🚀"],"ready":true}')

local ok = pcall(json.decode, '{"trailing":true} garbage')
assert_equal(ok, false)
for _, invalid in ipairs { "01", "1.", "1e", "1.e2" } do
	ok = pcall(json.decode, invalid)
	assert_equal(ok, false)
end
ok = pcall(json.decode, '"' .. string.char(0xff) .. '"')
assert_equal(ok, false)
ok = pcall(json.decode, 1)
assert_equal(ok, false)
ok = pcall(json.encode, 0 / 0)
assert_equal(ok, false)
ok = pcall(json.encode, json.array { [2] = "sparse" })
assert_equal(ok, false)
ok = pcall(json.encode, { [0] = "not an object key" })
assert_equal(ok, false)
local circular = {}
circular.self = circular
ok = pcall(json.encode, circular)
assert_equal(ok, false)

local config = config_module.load "example/config.lua"
assert_equal(config.runtime.workers, 2)
assert(config.runtime.socket_path:match "/hypringo%.sock$")
assert_equal(config.sources.audio.enabled, false)
assert_equal(config.sources.hyprland.enabled, false)
assert_equal(config.sources.mpris.enabled, false)

local hyprland_config = config_module.load "test/config-hyprland.lua"
assert_equal(hyprland_config.sources.hyprland.enabled, true)
assert_equal(hyprland_config.sources.hyprland.reconnect_min_ms, 20)
assert_equal(hyprland_config.sources.hyprland.reconnect_max_ms, 200)

local all_sources_config = config_module.load "test/config-all-sources.lua"
assert_equal(all_sources_config.runtime.workers, 4)
assert_equal(all_sources_config.sources.audio.enabled, true)
assert_equal(all_sources_config.sources.hyprland.enabled, true)
assert_equal(all_sources_config.sources.mpris.enabled, true)
ok = pcall(config_module.load, "test/config-too-few-workers.lua")
assert_equal(ok, false)

local snapshot = state.new("example/config.lua", config)
assert_equal(snapshot.revision, 0)
assert_equal(snapshot.state.runtime.ready, false)
assert_equal(snapshot.state.media.available, false)
assert_equal(snapshot.state.hyprland.active_workspace.id, 0)
assert_equal(snapshot.state.hyprland.available, false)
assert_equal(#snapshot.state.hyprland.workspaces, 0)
assert_equal(json.is_array(snapshot.state.hyprland.workspaces), true)
assert_equal(json.encode(snapshot.state.hyprland.workspaces), "[]")

local shape_snapshot = state.new("example/config.lua", config)
local shape_changed, shape_revision =
	state.merge(shape_snapshot, "hyprland", { workspaces = {} })
assert_equal(shape_changed, true)
assert_equal(shape_revision, 1)
assert_equal(json.encode(shape_snapshot.state.hyprland.workspaces), "{}")
shape_changed, shape_revision =
	state.merge(shape_snapshot, "hyprland", { workspaces = json.array() })
assert_equal(shape_changed, true)
assert_equal(shape_revision, 2)
assert_equal(json.encode(shape_snapshot.state.hyprland.workspaces), "[]")

local changed, revision = state.merge(snapshot, "runtime", { ready = true })
assert_equal(changed, true)
assert_equal(revision, 1)

changed, revision = state.merge(snapshot, "runtime", { ready = true })
assert_equal(changed, false)
assert_equal(revision, 1)

changed, revision = state.merge(snapshot, "media", {
	album = "Album",
	artist = "Artist",
	art = "file:///art.png",
	available = true,
	error = "",
	player = "test",
	status = "playing",
	title = "Title",
})
assert_equal(changed, true)
assert_equal(revision, 2)
assert_equal(snapshot.state.media.title, "Title")

changed, revision = state.merge(snapshot, "media", {
	album = "",
	artist = "",
	art = "",
	available = false,
	error = "player unavailable",
	player = "",
	status = "stopped",
	title = "",
})
assert_equal(changed, true)
assert_equal(revision, 3)
assert_equal(snapshot.state.media.available, false)
assert_equal(snapshot.state.media.album, "")
assert_equal(snapshot.state.media.error, "player unavailable")
assert_equal(snapshot.state.media.title, "")

local copied = state.copy(snapshot)
copied.state.runtime.ready = false
assert_equal(snapshot.state.runtime.ready, true)
assert_equal(json.is_array(copied.state.hyprland.workspaces), true)

ok = pcall(state.merge, snapshot, "unknown", {})
assert_equal(ok, false)

local hyprland_snapshot = hyprland.snapshot(
	{
		{
			activeWorkspace = {
				id = 2,
				name = "2",
			},
			description = "External",
			dpmsStatus = true,
			focused = true,
			height = 1080,
			id = 7,
			name = "OUTPUT-A",
			refreshRate = 60,
			scale = 1,
			transform = 0,
			width = 1920,
			x = 0,
			y = 0,
		},
	},
	{
		{
			hasfullscreen = false,
			id = 2,
			ispersistent = true,
			lastwindow = "0x123",
			lastwindowtitle = "Title, with comma",
			monitor = "OUTPUT-A",
			monitorID = 7,
			name = "2",
			windows = 1,
		},
	},
	{
		address = "0x123",
		class = "example",
		floating = false,
		fullscreen = 0,
		pid = 42,
		title = "Title, with comma",
		workspace = {
			id = 2,
			name = "2",
		},
		xwayland = false,
	})
assert_equal(hyprland_snapshot.available, true)
assert_equal(hyprland_snapshot.active_workspace.monitor, "OUTPUT-A")
assert_equal(hyprland_snapshot.active_workspace.id, 2)
assert_equal(hyprland_snapshot.active_window.title, "Title, with comma")
assert_equal(hyprland_snapshot.workspaces[1].monitor_id, 7)

local remainder, relevant, event_count =
	hyprland.consume_events("", "activewindow>>example,Title")
assert_equal(remainder, "activewindow>>example,Title")
assert_equal(relevant, false)
assert_equal(event_count, 0)
remainder, relevant, event_count =
	hyprland.consume_events(remainder, ", with comma\nsubmap>>resize\n")
assert_equal(remainder, "")
assert_equal(relevant, true)
assert_equal(event_count, 1)

print "unit tests passed"
