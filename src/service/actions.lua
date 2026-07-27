local actions = require "hypringo.actions"
local control = require "hypringo.control"
local ltask = require "ltask"

local config = ...
local state_service = ltask.queryservice "state"
local stopping = false

local function call_service(service_name, action)
	local service = ltask.queryservice(service_name)
	local ok, result, action_error =
		pcall(ltask.call, service, "dispatch", action.name, action.value)
	if not ok then
		ltask.log.error(
			("dispatch %s.%s failed"):format(action.domain, action.name),
			result)
	elseif not result then
		ltask.log.error(
			("dispatch %s.%s failed"):format(action.domain, action.name),
			action_error or "unknown error")
	end
end

local function dispatch(command)
	if command == "reload" then
		local ok, reloaded, reload_error =
			pcall(ltask.call, state_service, "reload")
		if not ok then
			ltask.log.error("configuration reload failed", reloaded)
		elseif not reloaded then
			ltask.log.error(
				"configuration reload failed",
				reload_error or "unknown error")
		end
		return
	end
	local action, parse_error = actions.parse(command)
	if not action then
		ltask.log.error("rejected invalid dispatch command", parse_error)
		return
	end
	if action.domain == "workspace" then
		if not config.sources.hyprland.enabled then
			ltask.log.error "workspace dispatch requires the Hyprland source"
			return
		end
		call_service("hyprland", action)
		return
	end
	if action.domain == "media" then
		if not config.sources.mpris.enabled then
			ltask.log.error "media dispatch requires the MPRIS source"
			return
		end
		call_service("mpris", action)
		return
	end
	if action.domain == "audio" then
		if not config.sources.audio.enabled then
			ltask.log.error "audio dispatch requires the audio source"
			return
		end
		call_service("audio", action)
		return
	end
	ltask.log.error("dispatch source is not enabled", action.domain)
end

ltask.fork(function()
	while not stopping do
		local command = control.pop_action()
		if command then
			dispatch(command)
		else
			ltask.sleep(1)
		end
	end
end)

local S = {}

function S.quit()
	stopping = true
	ltask.quit()
end

return S
