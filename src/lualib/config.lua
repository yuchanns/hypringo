local M = {}

local function default_socket_path()
	local runtime_dir = os.getenv "XDG_RUNTIME_DIR"
	if not runtime_dir or runtime_dir == "" then
		error "cannot resolve control socket path: XDG_RUNTIME_DIR is not set"
	end
	return runtime_dir .. "/hypringo.sock"
end

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

local function default_hyprland_socket(name)
	local runtime_dir = os.getenv "XDG_RUNTIME_DIR"
	if not runtime_dir or runtime_dir == "" then
		error("cannot resolve Hyprland " .. name .. " socket: XDG_RUNTIME_DIR is not set")
	end
	local signature = os.getenv "HYPRLAND_INSTANCE_SIGNATURE"
	if not signature or signature == "" then
		error("cannot resolve Hyprland " .. name .. " socket: HYPRLAND_INSTANCE_SIGNATURE is not set")
	end
	return runtime_dir .. "/hypr/" .. signature .. "/" .. name
end

local function require_table(parent, key, path)
	local value = parent[key]
	if value == nil then
		value = {}
		parent[key] = value
	elseif type(value) ~= "table" then
		error(("configuration field %s must be a table"):format(path))
	end
	return value
end

local function validate_absolute_path(value, path)
	if type(value) ~= "string" or value == "" then
		error(("configuration field %s must be a non-empty string"):format(path))
	end
	if value:sub(1, 1) ~= "/" then
		error(("configuration field %s must be an absolute path"):format(path))
	end
	return value
end

local function validate_milliseconds(value, path, fallback)
	value = value or fallback
	if math.type(value) ~= "integer" or value < 10 or value > 60000 then
		error(("configuration field %s must be an integer between 10 and 60000"):format(path))
	end
	return value
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

	local runtime = require_table(config, "runtime", "runtime")
	local workers = config.runtime.workers or 2
	if math.type(workers) ~= "integer" or workers < 1 or workers > 256 then
		error "configuration field runtime.workers must be an integer between 1 and 256"
	end
	runtime.workers = workers

	runtime.socket_path = validate_absolute_path(
		runtime.socket_path or default_socket_path(),
		"runtime.socket_path")

	local sources = require_table(config, "sources", "sources")
	local hyprland = require_table(sources, "hyprland", "sources.hyprland")
	if hyprland.enabled == nil then
		hyprland.enabled = false
	elseif type(hyprland.enabled) ~= "boolean" then
		error "configuration field sources.hyprland.enabled must be a boolean"
	end
	hyprland.reconnect_min_ms = validate_milliseconds(
		hyprland.reconnect_min_ms,
		"sources.hyprland.reconnect_min_ms",
		100)
	hyprland.reconnect_max_ms = validate_milliseconds(
		hyprland.reconnect_max_ms,
		"sources.hyprland.reconnect_max_ms",
		5000)
	if hyprland.reconnect_max_ms < hyprland.reconnect_min_ms then
		error "configuration field sources.hyprland.reconnect_max_ms must not be less than reconnect_min_ms"
	end
	if hyprland.enabled then
		hyprland.command_socket = validate_absolute_path(
			hyprland.command_socket or default_hyprland_socket ".socket.sock",
			"sources.hyprland.command_socket")
		hyprland.event_socket = validate_absolute_path(
			hyprland.event_socket or default_hyprland_socket ".socket2.sock",
			"sources.hyprland.event_socket")
		if hyprland.command_socket == hyprland.event_socket then
			error "configuration fields sources.hyprland.command_socket and event_socket must differ"
		end
	end

	validate_value(config, "configuration", {}, {})
	return config
end

function M.default_socket_path()
	return default_socket_path()
end

return M
