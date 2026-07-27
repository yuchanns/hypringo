local ipc = require "hypringo.ipc"
local ltask = require "ltask"
local mpris = require "hypringo.mpris"

local config = ...
local source_config = config.sources.mpris
local state_service = ltask.queryservice "state"
local wait_message, wake_fd = ltask.eventinit()

local reconnect_ms = source_config.reconnect_min_ms
local source
local stopping = false

local function unavailable(message)
	return {
		album = "",
		art = "",
		artist = "",
		available = false,
		error = message or "",
		player = "",
		status = "stopped",
		title = "",
	}
end

local function publish(snapshot)
	ltask.send(state_service, "merge", "media", snapshot)
end

local function disconnect(message)
	if source then
		source:close()
		source = nil
	end
	if not stopping then
		publish(unavailable(message))
	end
end

local function connect()
	local opened, open_error = mpris.open()
	if not opened then
		disconnect(open_error)
		return nil
	end
	source = opened
	publish(source:snapshot())
	reconnect_ms = source_config.reconnect_min_ms
	ltask.log.info "MPRIS source connected"
	return true
end

ltask.idle_handler(function()
	if stopping then
		return
	end
	if not source and not connect() then
		local ready, wait_error = ipc.wait_wakeup(wake_fd, reconnect_ms)
		if wait_error then
			ltask.log.error("MPRIS reconnect wait failed", wait_error)
		elseif ready then
			wait_message()
		else
			reconnect_ms = math.min(
				source_config.reconnect_max_ms,
				reconnect_ms * 2)
		end
		return
	end

	local changed, wake_ready, closed, wait_error = source:wait(wake_fd)
	if wake_ready then
		wait_message()
	end
	if changed then
		publish(source:snapshot())
	end
	if wait_error then
		disconnect(wait_error)
	elseif closed then
		disconnect "MPRIS session bus closed"
	end
end)

local S = {}

function S.dispatch(name)
	if not source then
		return false, "MPRIS source is unavailable"
	end
	return source:dispatch(name)
end

function S.status()
	return {
		connected = source ~= nil,
		reconnect_ms = reconnect_ms,
	}
end

function S.quit()
	stopping = true
	if source then
		source:close()
		source = nil
	end
	ltask.quit()
end

return S
