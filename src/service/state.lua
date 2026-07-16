local ltask = require "ltask"
local control = require "hypringo.control"

local config_path, config = ...
local json = require "hypringo.json"
local state = require "hypringo.state"

local snapshot = state.new(config_path, config)

local function publish()
	local payload = json.encode {
		revision = snapshot.revision,
		state = snapshot.state,
		type = "snapshot",
	} .. "\n"
	control.publish(payload)
end

control.start(config.runtime.socket_path)
publish()
ltask.log.info("control socket listening", config.runtime.socket_path)

local S = {}

function S.snapshot()
	return state.copy(snapshot)
end

function S.merge(domain, patch)
	local changed, revision = state.merge(snapshot, domain, patch)
	if changed then
		publish()
	end
	return revision
end

function S.quit()
	control.stop()
end

return S
