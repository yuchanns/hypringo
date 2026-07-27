local audio = require "hypringo.audio"
local ipc = require "hypringo.ipc"
local ltask = require "ltask"

local config = ...
local source_config = config.sources.audio
local state_service = ltask.queryservice "state"
local wait_message, wake_fd = ltask.eventinit()

local reconnect_ms = source_config.reconnect_min_ms
local source
local stopping = false

local function unavailable(message)
	return {
		available = false,
		connected = false,
		error = message or "",
		muted = false,
		sink = "",
		volume = 0,
	}
end

local function publish(snapshot)
	ltask.send(state_service, "merge", "audio", snapshot)
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
	local opened, open_error = audio.open()
	if not opened then
		disconnect(open_error)
		return nil
	end
	source = opened
	publish(source:snapshot())
	reconnect_ms = source_config.reconnect_min_ms
	ltask.log.info "Audio source connected"
	return true
end

ltask.idle_handler(function()
	if stopping then
		return
	end
	if not source and not connect() then
		local ready, wait_error = ipc.wait_wakeup(wake_fd, reconnect_ms)
		if wait_error then
			ltask.log.error("Audio reconnect wait failed", wait_error)
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
		disconnect "Audio server connection closed"
	end
end)

local S = {}

function S.dispatch(name, value)
	if not source then
		return false, "audio source is unavailable"
	end
	return source:dispatch(name, value)
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
