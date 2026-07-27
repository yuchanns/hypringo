local json = require "hypringo.json"

local M = {}

local domains = {
	audio = true,
	github = true,
	hyprland = true,
	media = true,
	runtime = true,
	system = true,
	weather = true,
}

local array_fields = {
	github = {
		notifications = true,
	},
	hyprland = {
		monitors = true,
		workspaces = true,
	},
}

local function copy(value, visiting)
	if type(value) ~= "table" then
		return value
	end
	if visiting[value] then
		error "state values must not contain cycles"
	end
	visiting[value] = true
	local result = json.is_array(value) and json.array() or {}
	for key, child in pairs(value) do
		result[copy(key, visiting)] = copy(child, visiting)
	end
	visiting[value] = nil
	return result
end

local function equal(left, right, compared)
	if left == right then
		return true
	end
	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end
	if json.is_array(left) ~= json.is_array(right) then
		return false
	end
	compared[left] = compared[left] or {}
	if compared[left][right] then
		return true
	end
	compared[left][right] = true
	for key, value in pairs(left) do
		if not equal(value, right[key], compared) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

function M.new(config_path, config)
	return {
		revision = 0,
		state = {
			audio = {
				available = false,
				capabilities = {
					set_mute = config.sources.audio.enabled,
					set_volume = config.sources.audio.enabled,
					toggle_mute = config.sources.audio.enabled,
				},
				connected = false,
				error = "",
				muted = false,
				sink = "",
				volume = 0,
			},
			hyprland = {
				active_window = {
					address = "",
					class = "",
					floating = false,
					fullscreen = 0,
					initial_class = "",
					initial_title = "",
					pid = 0,
					title = "",
					workspace = {
						id = 0,
						name = "",
					},
					xwayland = false,
				},
				active_workspace = {
					id = 0,
					monitor = "",
					name = "",
				},
				available = false,
				capabilities = {
					switch_workspace = config.sources.hyprland.enabled,
				},
				error = "",
				monitors = json.array(),
				workspaces = json.array(),
			},
			github = {
				available = false,
				error = "",
				failures = 0,
				last_attempt_at = 0,
				last_success_at = 0,
				notifications = json.array(),
				refresh_in_ms = 0,
				stale = false,
			},
			media = {
				album = "",
				artist = "",
				art = "",
				available = false,
				capabilities = {
					next = false,
					pause = false,
					play = false,
					play_pause = false,
					previous = false,
				},
				connected = false,
				error = "",
				player = "",
				status = "stopped",
				title = "",
			},
			runtime = {
				config_generation = 1,
				config_path = config_path,
				last_reload_error = "",
				ready = false,
				socket_path = config.runtime.socket_path,
				workers = config.runtime.workers,
			},
			system = {
				available = false,
				battery = {
					available = false,
					capacity = 0,
					device = "",
					status = "",
				},
				brightness = {
					available = false,
					capabilities = {
						set = false,
					},
					device = "",
					percent = 0,
				},
				error = "",
			},
			weather = {
				available = false,
				condition = "",
				error = "",
				failures = 0,
				feels_like = "",
				last_attempt_at = 0,
				last_success_at = 0,
				location = "",
				precipitation = "",
				pressure = "",
				refresh_in_ms = 0,
				stale = false,
				temperature = "",
				wind = "",
			},
		},
	}
end

function M.merge(snapshot, domain, patch)
	if not domains[domain] then
		error("unknown state domain: " .. tostring(domain))
	end
	if type(patch) ~= "table" then
		error "state patch must be a table"
	end
	local target = snapshot.state[domain]
	local changed = false
	for key, value in pairs(patch) do
		if array_fields[domain] and array_fields[domain][key] and
			type(value) == "table" and next(value) == nil then
			value = json.array()
		end
		if not equal(target[key], value, {}) then
			target[key] = copy(value, {})
			changed = true
		end
	end
	if changed then
		snapshot.revision = snapshot.revision + 1
	end
	return changed, snapshot.revision
end

function M.copy(snapshot)
	return copy(snapshot, {})
end

return M
