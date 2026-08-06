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

local function default_session_path()
	local state_home = os.getenv "XDG_STATE_HOME"
	if state_home and state_home ~= "" then
		return state_home .. "/hypringo/session.json"
	end
	local home = os.getenv "HOME"
	if not home or home == "" then
		error "cannot resolve session path: HOME is not set"
	end
	return home .. "/.local/state/hypringo/session.json"
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

local function validate_integer(value, path, fallback, minimum, maximum)
	value = value or fallback
	if math.type(value) ~= "integer" or value < minimum or value > maximum then
		error(
			("configuration field %s must be an integer between %d and %d"):format(
				path,
				minimum,
				maximum))
	end
	return value
end

local function validate_url(value, path)
	if type(value) ~= "string" or
		not value:match "^https?://[^%s]+$" then
		error(
			("configuration field %s must be a non-empty HTTP or HTTPS URL"):format(
				path))
	end
	return value
end

local function validate_remote_source(source, path, defaults)
	if source.enabled == nil then
		source.enabled = false
	elseif type(source.enabled) ~= "boolean" then
		error(("configuration field %s.enabled must be a boolean"):format(path))
	end
	source.interval_ms = validate_integer(
		source.interval_ms,
		path .. ".interval_ms",
		defaults.interval_ms,
		100,
		86400000)
	source.timeout_ms = validate_integer(
		source.timeout_ms,
		path .. ".timeout_ms",
		defaults.timeout_ms,
		10,
		600000)
	source.retry_min_ms = validate_integer(
		source.retry_min_ms,
		path .. ".retry_min_ms",
		defaults.retry_min_ms,
		100,
		86400000)
	source.retry_max_ms = validate_integer(
		source.retry_max_ms,
		path .. ".retry_max_ms",
		defaults.retry_max_ms,
		100,
		86400000)
	if source.retry_max_ms < source.retry_min_ms then
		error(
			("configuration field %s.retry_max_ms must not be less than retry_min_ms"):format(
				path))
	end
	source.max_response_bytes = validate_integer(
		source.max_response_bytes,
		path .. ".max_response_bytes",
		defaults.max_response_bytes,
		1,
		16 * 1024 * 1024)
	if source.enabled then
		source.url = validate_url(source.url or defaults.url, path .. ".url")
	elseif source.url ~= nil then
		source.url = validate_url(source.url, path .. ".url")
	end
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

	local session = require_table(config, "session", "session")
	if session.enabled == nil then
		session.enabled = hyprland.enabled
	elseif type(session.enabled) ~= "boolean" then
		error "configuration field session.enabled must be a boolean"
	end
	session.path = validate_absolute_path(
		session.path or default_session_path(),
		"session.path")
	session.debounce_ms = validate_milliseconds(
		session.debounce_ms,
		"session.debounce_ms",
		500)
	if session.restore == nil then
		session.restore = true
	elseif type(session.restore) ~= "boolean" then
		error "configuration field session.restore must be a boolean"
	end
	if session.enabled and not hyprland.enabled then
		error "configuration field session.enabled requires sources.hyprland.enabled"
	end

	local mpris = require_table(sources, "mpris", "sources.mpris")
	if mpris.enabled == nil then
		mpris.enabled = false
	elseif type(mpris.enabled) ~= "boolean" then
		error "configuration field sources.mpris.enabled must be a boolean"
	end
	mpris.reconnect_min_ms = validate_milliseconds(
		mpris.reconnect_min_ms,
		"sources.mpris.reconnect_min_ms",
		100)
	mpris.reconnect_max_ms = validate_milliseconds(
		mpris.reconnect_max_ms,
		"sources.mpris.reconnect_max_ms",
		5000)
	if mpris.reconnect_max_ms < mpris.reconnect_min_ms then
		error "configuration field sources.mpris.reconnect_max_ms must not be less than reconnect_min_ms"
	end

	local audio = require_table(sources, "audio", "sources.audio")
	if audio.enabled == nil then
		audio.enabled = false
	elseif type(audio.enabled) ~= "boolean" then
		error "configuration field sources.audio.enabled must be a boolean"
	end
	audio.reconnect_min_ms = validate_milliseconds(
		audio.reconnect_min_ms,
		"sources.audio.reconnect_min_ms",
		100)
	audio.reconnect_max_ms = validate_milliseconds(
		audio.reconnect_max_ms,
		"sources.audio.reconnect_max_ms",
		5000)
	if audio.reconnect_max_ms < audio.reconnect_min_ms then
		error "configuration field sources.audio.reconnect_max_ms must not be less than reconnect_min_ms"
	end

	local system = require_table(sources, "system", "sources.system")
	if system.enabled == nil then
		system.enabled = true
	elseif type(system.enabled) ~= "boolean" then
		error "configuration field sources.system.enabled must be a boolean"
	end
	system.interval_ms = validate_integer(
		system.interval_ms,
		"sources.system.interval_ms",
		5000,
		100,
		60000)
	system.sysfs_root = validate_absolute_path(
		system.sysfs_root or "/sys",
		"sources.system.sysfs_root")

	local weather = require_table(sources, "weather", "sources.weather")
	validate_remote_source(weather, "sources.weather", {
		interval_ms = 600000,
		max_response_bytes = 65536,
		retry_max_ms = 300000,
		retry_min_ms = 5000,
		timeout_ms = 10000,
	})

	local github = require_table(sources, "github", "sources.github")
	validate_remote_source(github, "sources.github", {
		interval_ms = 60000,
		max_response_bytes = 1024 * 1024,
		retry_max_ms = 900000,
		retry_min_ms = 5000,
		timeout_ms = 10000,
		url = "https://api.github.com/notifications?per_page=100",
	})
	github.max_items = validate_integer(
		github.max_items,
		"sources.github.max_items",
		50,
		1,
		100)
	github.token_env = github.token_env or "HYPRINGO_GITHUB_TOKEN"
	if type(github.token_env) ~= "string" or
		not github.token_env:match "^[A-Za-z_][A-Za-z0-9_]*$" then
		error(
			"configuration field sources.github.token_env must be an environment variable name")
	end

	local blocking_sources = 0
	for _, source in ipairs { hyprland, mpris, audio, weather, github } do
		if source.enabled then
			blocking_sources = blocking_sources + 1
		end
	end
	if runtime.workers <= blocking_sources then
		error(
			("configuration field runtime.workers must be greater than the number of enabled blocking sources (%d)"):format(
				blocking_sources))
	end

	validate_value(config, "configuration", {}, {})
	return config
end

function M.default_socket_path()
	return default_socket_path()
end

function M.reloadable(current, candidate)
	local immutable = {
		{
			current.runtime.workers,
			candidate.runtime.workers,
			"runtime.workers",
		},
		{
			current.runtime.socket_path,
			candidate.runtime.socket_path,
			"runtime.socket_path",
		},
	}
	for _, source_name in ipairs {
		"audio",
		"github",
		"hyprland",
		"mpris",
		"system",
		"weather",
	} do
		immutable[#immutable + 1] = {
			current.sources[source_name].enabled,
			candidate.sources[source_name].enabled,
			("sources.%s.enabled"):format(source_name),
		}
	end
	immutable[#immutable + 1] = {
		current.session.enabled,
		candidate.session.enabled,
		"session.enabled",
	}
	immutable[#immutable + 1] = {
		current.session.path,
		candidate.session.path,
		"session.path",
	}
	if current.sources.hyprland.enabled and
		candidate.sources.hyprland.enabled then
		for _, field in ipairs { "command_socket", "event_socket" } do
			immutable[#immutable + 1] = {
				current.sources.hyprland[field],
				candidate.sources.hyprland[field],
				("sources.hyprland.%s"):format(field),
			}
		end
	end
	if current.sources.system.enabled and candidate.sources.system.enabled then
		immutable[#immutable + 1] = {
			current.sources.system.sysfs_root,
			candidate.sources.system.sysfs_root,
			"sources.system.sysfs_root",
		}
	end
	for _, entry in ipairs(immutable) do
		if entry[1] ~= entry[2] then
			return false, ("restart required after changing %s"):format(entry[3])
		end
	end
	return true
end

return M
