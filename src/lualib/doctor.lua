local M = {}

local source_domains = {
	audio = "audio",
	hyprland = "hyprland",
	mpris = "media",
}

local function source_health(name, config, state)
	local enabled = config.sources[name].enabled
	local domain = state[source_domains[name]]
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
	for _, name in ipairs { "audio", "hyprland", "mpris" } do
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
