local json = require "hypringo.json"
local actions = assert(loadfile("src/lualib/actions.lua", "t"))()
local doctor = assert(loadfile("src/lualib/doctor.lua", "t"))()
local hyprland = assert(loadfile("src/lualib/hyprland.lua", "t"))()
local remote = assert(loadfile("src/lualib/remote.lua", "t"))()
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
assert_equal(config.sources.github.enabled, false)
assert_equal(config.sources.weather.enabled, false)

local hyprland_config = config_module.load "test/config-hyprland.lua"
assert_equal(hyprland_config.sources.hyprland.enabled, true)
assert_equal(hyprland_config.sources.hyprland.reconnect_min_ms, 20)
assert_equal(hyprland_config.sources.hyprland.reconnect_max_ms, 200)

local all_sources_config = config_module.load "test/config-all-sources.lua"
assert_equal(all_sources_config.runtime.workers, 4)
assert_equal(all_sources_config.sources.audio.enabled, true)
assert_equal(all_sources_config.sources.hyprland.enabled, true)
assert_equal(all_sources_config.sources.mpris.enabled, true)
local remote_config = config_module.load "test/config-remote.lua"
assert_equal(remote_config.runtime.workers, 3)
assert_equal(remote_config.sources.github.enabled, true)
assert_equal(remote_config.sources.github.max_items, 7)
assert_equal(
	remote_config.sources.github.token_env,
	"HYPRINGO_TEST_GITHUB_TOKEN")
assert_equal(remote_config.sources.weather.enabled, true)
assert_equal(remote_config.sources.weather.interval_ms, 600000)
ok = pcall(config_module.load, "test/config-too-few-workers.lua")
assert_equal(ok, false)
ok = pcall(config_module.load, "test/config-invalid-remote.lua")
assert_equal(ok, false)
local reload_current = config_module.load "test/config-all-sources.lua"
local reload_candidate = config_module.load "test/config-all-sources.lua"
reload_candidate.sources.audio.reconnect_min_ms = 250
local reloadable, reload_error =
	config_module.reloadable(reload_current, reload_candidate)
assert_equal(reloadable, true)
assert_equal(reload_error, nil)
reload_candidate.runtime.workers = 5
reloadable, reload_error =
	config_module.reloadable(reload_current, reload_candidate)
assert_equal(reloadable, false)
assert(reload_error:match "restart required")
assert(reload_error:match "runtime%.workers")
reload_current = config_module.load "test/config-remote.lua"
reload_candidate = config_module.load "test/config-remote.lua"
reload_candidate.sources.weather.interval_ms = 900000
reloadable, reload_error =
	config_module.reloadable(reload_current, reload_candidate)
assert_equal(reloadable, true)
assert_equal(reload_error, nil)
reload_candidate.sources.weather.enabled = false
reloadable, reload_error =
	config_module.reloadable(reload_current, reload_candidate)
assert_equal(reloadable, false)
assert(reload_error:match "sources%.weather%.enabled")

local snapshot = state.new("example/config.lua", config)
assert_equal(snapshot.revision, 0)
assert_equal(snapshot.state.runtime.ready, false)
assert_equal(snapshot.state.runtime.config_generation, 1)
assert_equal(snapshot.state.runtime.last_reload_error, "")
assert_equal(snapshot.state.media.available, false)
assert_equal(snapshot.state.media.connected, false)
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

local healthy_doctor = doctor.build(snapshot, config)
assert_equal(healthy_doctor.type, "doctor")
assert_equal(healthy_doctor.healthy, true)
assert_equal(healthy_doctor.sources.audio.status, "disabled")
assert_equal(healthy_doctor.sources.github.status, "disabled")
assert_equal(healthy_doctor.sources.hyprland.status, "disabled")
assert_equal(healthy_doctor.sources.mpris.status, "disabled")
assert_equal(healthy_doctor.sources.weather.status, "disabled")

local degraded_snapshot =
	state.new("test/config-all-sources.lua", all_sources_config)
state.merge(degraded_snapshot, "runtime", { ready = true })
local degraded_doctor = doctor.build(degraded_snapshot, all_sources_config)
assert_equal(degraded_doctor.healthy, false)
assert_equal(degraded_doctor.sources.audio.status, "degraded")
assert_equal(degraded_doctor.sources.hyprland.status, "degraded")
assert_equal(degraded_doctor.sources.mpris.status, "degraded")
state.merge(degraded_snapshot, "audio", {
	available = true,
	connected = true,
})
state.merge(degraded_snapshot, "hyprland", { available = true })
state.merge(degraded_snapshot, "media", { connected = true })
local ready_doctor = doctor.build(degraded_snapshot, all_sources_config)
assert_equal(ready_doctor.healthy, true)
assert_equal(ready_doctor.sources.audio.status, "ready")
assert_equal(ready_doctor.sources.hyprland.status, "ready")
assert_equal(ready_doctor.sources.mpris.status, "ready")

assert_equal(remote.exponential_delay(1, 100, 800), 100)
assert_equal(remote.exponential_delay(3, 100, 800), 400)
assert_equal(remote.exponential_delay(8, 100, 800), 800)
assert_equal(remote.success_delay({ x_poll_interval = "5" }, 1000), 5000)
assert_equal(
	remote.failure_delay(
		{ retry_after = "2" },
		1,
		{
			retry_max_ms = 800,
			retry_min_ms = 100,
		},
		100),
	2000)
local weather = remote.parse_weather [[
{
	"cond": "Sunny",
	"loc": "Shenzhen",
	"precip": "0.0mm",
	"pressure": "1012hPa",
	"temp": "+30°C",
	"temp_like": "+32°C",
	"wind": "8km/h"
}
]]
assert_equal(weather.condition, "Sunny")
assert_equal(weather.location, "Shenzhen")
assert_equal(weather.temperature, "+30°C")
local notifications = remote.parse_github([[
[
	{
		"id": "1",
		"reason": "mention",
		"repository": {
			"full_name": "owner/repo",
			"html_url": "https://github.com/owner/repo"
		},
		"subject": {
			"title": "Review requested",
			"type": "PullRequest",
			"url": "https://api.github.com/repos/owner/repo/pulls/7"
		},
		"unread": true,
		"updated_at": "2026-07-27T00:00:00Z"
	},
	{
		"id": "2",
		"repository": {
			"full_name": "owner/second"
		},
		"subject": {
			"title": "Issue updated",
			"type": "Issue"
		}
	}
]
]], 1)
assert_equal(json.is_array(notifications), true)
assert_equal(#notifications, 1)
assert_equal(notifications[1].subject.title, "Review requested")
assert_equal(notifications[1].repository.full_name, "owner/repo")

local remote_snapshot =
	state.new("test/config-remote.lua", remote_config)
state.merge(remote_snapshot, "runtime", { ready = true })
local remote_doctor = doctor.build(remote_snapshot, remote_config)
assert_equal(remote_doctor.healthy, false)
assert_equal(remote_doctor.sources.github.status, "degraded")
assert_equal(remote_doctor.sources.weather.status, "degraded")
state.merge(remote_snapshot, "weather", {
	available = true,
	stale = false,
})
state.merge(remote_snapshot, "github", {
	available = true,
	stale = true,
})
remote_doctor = doctor.build(remote_snapshot, remote_config)
assert_equal(remote_doctor.sources.weather.status, "ready")
assert_equal(remote_doctor.sources.github.status, "degraded")

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
