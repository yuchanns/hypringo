local ltask = require "ltask"
local system = require "hypringo.system"

local config = ...
local source_config = config.sources.system
local state_service = ltask.queryservice "state"
local current
local stopping = false

local function unavailable(message)
	return {
		available = false,
		battery = {
			available = false,
			capacity = 0,
			device = "",
			status = "",
		},
		brightness = {
			available = false,
			capabilities = {
				set = false,
			},
			device = "",
			percent = 0,
		},
		error = message or "",
	}
end

local function publish(snapshot)
	current = snapshot
	ltask.send(state_service, "merge", "system", snapshot)
end

local function refresh()
	local ok, snapshot = pcall(system.snapshot, source_config.sysfs_root)
	if not ok then
		publish(unavailable(snapshot))
		ltask.log.error("system source scan failed", snapshot)
		return false
	end
	snapshot.available = true
	snapshot.error = ""
	publish(snapshot)
	return true
end

ltask.fork(function()
	while not stopping do
		refresh()
		ltask.sleep(math.max(1, (source_config.interval_ms + 9) // 10))
	end
end)

local S = {}

function S.dispatch(name, value)
	if name ~= "set-brightness" then
		return false, "unsupported system action"
	end
	local brightness = current and current.brightness
	if not brightness or not brightness.available then
		return false, "brightness device is unavailable"
	end
	if not brightness.capabilities.set then
		return false, "brightness device is read-only"
	end
	local ok, changed, change_error = pcall(
		system.set_brightness,
		source_config.sysfs_root,
		brightness.device,
		value)
	if not ok then
		return false, changed
	end
	if not changed then
		return false, change_error
	end
	refresh()
	return true
end

function S.status()
	return {
		battery_available = current and current.battery.available or false,
		brightness_available =
			current and current.brightness.available or false,
	}
end

function S.reload(new_config)
	source_config = new_config.sources.system
	return true
end

function S.quit()
	stopping = true
	ltask.quit()
end

return S
