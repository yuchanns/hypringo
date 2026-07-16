local json = assert(loadfile("src/lualib/json.lua", "t"))()
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

local config = config_module.load "example/config.lua"
assert_equal(config.runtime.workers, 2)
assert(config.runtime.socket_path:match "/hypringo%.sock$")

local snapshot = state.new("example/config.lua", config)
assert_equal(snapshot.revision, 0)
assert_equal(snapshot.state.runtime.ready, false)
assert_equal(snapshot.state.media.available, false)

local changed, revision = state.merge(snapshot, "runtime", { ready = true })
assert_equal(changed, true)
assert_equal(revision, 1)

changed, revision = state.merge(snapshot, "runtime", { ready = true })
assert_equal(changed, false)
assert_equal(revision, 1)

changed, revision = state.merge(snapshot, "media", {
	artist = "Artist",
	available = true,
	player = "test",
	status = "playing",
	title = "Title",
})
assert_equal(changed, true)
assert_equal(revision, 2)
assert_equal(snapshot.state.media.title, "Title")

changed, revision = state.merge(snapshot, "media", {
	artist = "",
	art = "",
	available = false,
	player = "",
	status = "stopped",
	title = "",
})
assert_equal(changed, true)
assert_equal(revision, 3)
assert_equal(snapshot.state.media.available, false)
assert_equal(snapshot.state.media.title, "")

local copied = state.copy(snapshot)
copied.state.runtime.ready = false
assert_equal(snapshot.state.runtime.ready, true)

local ok = pcall(state.merge, snapshot, "unknown", {})
assert_equal(ok, false)

print "unit tests passed"
