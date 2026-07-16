local ltask = require "ltask"

local config_path, config = ...

ltask.log.info("configuration loaded", config_path)

local S = {}

function S.status()
	return {
		config_path = config_path,
		workers = config.runtime.workers,
	}
end

function S.quit()
	ltask.quit()
end

return S
