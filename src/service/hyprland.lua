local ltask = require "ltask"
local hyprland = require "hypringo.hyprland"
local ipc = require "hypringo.ipc"
local json = require "hypringo.json"

local config = ...
local source_config = config.sources.hyprland
local state_service = ltask.queryservice "state"
local wait_message, wake_fd = ltask.eventinit()

local event_buffer = ""
local event_stream
local reconnect_ms = source_config.reconnect_min_ms
local stopping = false

local function publish_unavailable(message)
	ltask.send(state_service, "merge", "hyprland", hyprland.unavailable(message))
end

local function decode_response(command)
	local response, request_error = ipc.request(source_config.command_socket, command)
	if not response then
		return nil, ("%s request failed: %s"):format(command, request_error)
	end
	local ok, decoded = pcall(json.decode, response)
	if not ok then
		return nil, ("%s returned invalid JSON: %s"):format(command, decoded)
	end
	if type(decoded) ~= "table" or decoded == json.null then
		return nil, ("%s returned a non-container JSON value"):format(command)
	end
	return decoded
end

local function resync()
	local monitors, monitors_error = decode_response "j/monitors"
	if not monitors then
		return nil, monitors_error
	end
	local workspaces, workspaces_error = decode_response "j/workspaces"
	if not workspaces then
		return nil, workspaces_error
	end
	local active_window, window_error = decode_response "j/activewindow"
	if not active_window then
		return nil, window_error
	end
	ltask.send(
		state_service,
		"merge",
		"hyprland",
		hyprland.snapshot(monitors, workspaces, active_window))
	return true
end

local function disconnect(message)
	if event_stream then
		event_stream:close()
		event_stream = nil
	end
	event_buffer = ""
	if not stopping then
		publish_unavailable(message)
	end
end

local function connect()
	local stream, connect_error = ipc.connect(source_config.event_socket)
	if not stream then
		disconnect(connect_error)
		return nil
	end
	event_stream = stream
	local ok, sync_error = resync()
	if not ok then
		disconnect(sync_error)
		return nil
	end
	reconnect_ms = source_config.reconnect_min_ms
	ltask.log.info("Hyprland source connected", source_config.event_socket)
	return true
end

local function consume(chunk)
	local ok, remainder, relevant = pcall(hyprland.consume_events, event_buffer, chunk)
	if not ok then
		disconnect(remainder)
		return
	end
	event_buffer = remainder
	if relevant then
		local synced, sync_error = resync()
		if not synced then
			disconnect(sync_error)
			return
		end
	end
end

ltask.idle_handler(function()
	if stopping then
		return
	end
	if not event_stream and not connect() then
		local ready, wait_error = ipc.wait_wakeup(wake_fd, reconnect_ms)
		if wait_error then
			ltask.log.error("Hyprland reconnect wait failed", wait_error)
		elseif ready then
			wait_message()
		else
			reconnect_ms = math.min(
				source_config.reconnect_max_ms,
				reconnect_ms * 2)
		end
		return
	end

	local chunk, wake_ready, closed, wait_error = event_stream:wait(wake_fd)
	if wake_ready then
		wait_message()
	end
	if chunk then
		consume(chunk)
	end
	if wait_error then
		disconnect(wait_error)
	elseif closed then
		disconnect "Hyprland event socket closed"
	end
end)

local S = {}

function S.dispatch(name, value)
	if name ~= "switch" or math.type(value) ~= "integer" then
		return false, "unsupported Hyprland action"
	end
	local response, dispatch_error = ipc.request(
		source_config.command_socket,
		("/dispatch workspace %d"):format(value))
	if not response then
		return false, dispatch_error
	end
	if response ~= "" and not response:match "^ok" then
		return false, response
	end
	return true
end

function S.status()
	return {
		connected = event_stream ~= nil,
		event_socket = source_config.event_socket,
		reconnect_ms = reconnect_ms,
	}
end

function S.quit()
	stopping = true
	if event_stream then
		event_stream:close()
		event_stream = nil
	end
	ltask.quit()
end

return S
