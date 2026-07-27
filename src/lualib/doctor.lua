local M = {}

local source_domains = {
	audio = "audio",
	github = "github",
	hyprland = "hyprland",
	mpris = "media",
	system = "system",
	weather = "weather",
}

local function source_health(name, config, state)
	local enabled = config.sources[name].enabled
	local domain = state[source_domains[name]]
	if name == "system" then
		local operational = domain.available and domain.error == ""
		local status
		if not enabled then
			status = "disabled"
		elseif operational then
			status = "ready"
		else
			status = "degraded"
		end
		return {
			available = enabled and domain.available or false,
			battery_available =
				enabled and domain.battery.available or false,
			brightness_available =
				enabled and domain.brightness.available or false,
			capabilities = {
				set_brightness = enabled and
					domain.brightness.capabilities.set or false,
			},
			enabled = enabled,
			error = enabled and domain.error or "",
			status = status,
		}
	end
	if name == "github" or name == "weather" then
		local operational = domain.available and not domain.stale
		local status
		if not enabled then
			status = "disabled"
		elseif operational then
			status = "ready"
		else
			status = "degraded"
		end
		return {
			available = enabled and domain.available or false,
			capabilities = {},
			enabled = enabled,
			error = enabled and domain.error or "",
			failures = enabled and domain.failures or 0,
			last_attempt_at = enabled and domain.last_attempt_at or 0,
			last_success_at = enabled and domain.last_success_at or 0,
			stale = enabled and domain.stale or false,
			status = status,
		}
	end
	local connected = name == "hyprland" and domain.available or domain.connected
	local operational = connected and
		(name == "mpris" or domain.available)
	local status
	if not enabled then
		status = "disabled"
	elseif operational then
		status = "ready"
	else
		status = "degraded"
	end
	return {
		available = enabled and domain.available or false,
		capabilities = domain.capabilities,
		connected = enabled and connected or false,
		enabled = enabled,
		error = enabled and domain.error or "",
		status = status,
	}
end

function M.build(snapshot, config)
	local sources = {}
	local healthy = snapshot.state.runtime.ready and
		snapshot.state.runtime.last_reload_error == ""
	for _, name in ipairs {
		"audio",
		"github",
		"hyprland",
		"mpris",
		"system",
		"weather",
	} do
		sources[name] = source_health(name, config, snapshot.state)
		healthy = healthy and sources[name].status ~= "degraded"
	end
	return {
		healthy = healthy,
		ready = snapshot.state.runtime.ready,
		revision = snapshot.revision,
		runtime = {
			config_generation = snapshot.state.runtime.config_generation,
			config_path = snapshot.state.runtime.config_path,
			last_reload_error = snapshot.state.runtime.last_reload_error,
			socket_path = snapshot.state.runtime.socket_path,
			workers = snapshot.state.runtime.workers,
		},
		sources = sources,
		type = "doctor",
	}
end

return M
