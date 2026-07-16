local ltask = require "ltask"

local config_path, config = ...

ltask.log.info("configuration loaded", config_path)

local state_service = ltask.queryservice "state"
ltask.call(state_service, "merge", "runtime", {
	ready = true,
})

local S = {}

function S.status()
	return {
		config_path = config_path,
		workers = config.runtime.workers,
		socket_path = config.runtime.socket_path,
	}
end

function S.quit()
	ltask.quit()
end

return S
