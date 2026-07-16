local M = {}

local function default_path()
	local config_home = os.getenv "XDG_CONFIG_HOME"
	if config_home and config_home ~= "" then
		return config_home .. "/hypringo/config.lua"
	end
	local home = os.getenv "HOME"
	if not home or home == "" then
		error "cannot resolve configuration path: HOME is not set"
	end
	return home .. "/.config/hypringo/config.lua"
end

local function validate_value(value, path, visiting, validated)
	local value_type = type(value)
	if value_type == "nil" or value_type == "boolean" or value_type == "number" or value_type == "string" then
		return
	end
	if value_type ~= "table" then
		error(("%s must contain serializable data, got %s"):format(path, value_type))
	end
	if getmetatable(value) ~= nil then
		error(("%s must not have a metatable"):format(path))
	end
	if visiting[value] then
		error(("%s contains a circular table reference"):format(path))
	end
	if validated[value] then
		return
	end

	visiting[value] = true
	for key, child in pairs(value) do
		local key_type = type(key)
		if key_type ~= "string" and key_type ~= "number" then
			error(("%s contains an unsupported %s key"):format(path, key_type))
		end
		validate_value(child, ("%s[%s]"):format(path, tostring(key)), visiting, validated)
	end
	visiting[value] = nil
	validated[value] = true
end

function M.resolve_path(path)
	if path and path ~= "" then
		return path
	end
	return default_path()
end

function M.load(path)
	local chunk, load_error = loadfile(path, "t")
	if not chunk then
		error(("cannot load configuration %s: %s"):format(path, load_error))
	end
	local ok, config = pcall(chunk)
	if not ok then
		error(("cannot evaluate configuration %s: %s"):format(path, config))
	end
	if type(config) ~= "table" then
		error(("configuration %s must return a table"):format(path))
	end

	if config.runtime == nil then
		config.runtime = {}
	elseif type(config.runtime) ~= "table" then
		error "configuration field runtime must be a table"
	end
	local workers = config.runtime.workers or 2
	if math.type(workers) ~= "integer" or workers < 1 or workers > 256 then
		error "configuration field runtime.workers must be an integer between 1 and 256"
	end
	config.runtime.workers = workers

	validate_value(config, "configuration", {}, {})
	return config
end

return M
