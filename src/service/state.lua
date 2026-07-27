local ltask = require "ltask"
local control = require "hypringo.control"

local config_path, config = ...
local config_module = require "hypringo.config"
local doctor = require "hypringo.doctor"
local json = require "hypringo.json"
local state = require "hypringo.state"

local snapshot = state.new(config_path, config)

local function publish()
	local payload = json.encode {
		revision = snapshot.revision,
		state = snapshot.state,
		type = "snapshot",
	} .. "\n"
	local eww_payload = json.encode(snapshot.state) .. "\n"
	local doctor_payload = json.encode(doctor.build(snapshot, config)) .. "\n"
	control.publish(payload, eww_payload, doctor_payload)
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

local function reload_failed(message)
	local changed, revision = state.merge(snapshot, "runtime", {
		last_reload_error = message,
	})
	if changed then
		publish()
	end
	ltask.log.error("configuration reload failed", message)
	return false, message
end

function S.reload()
	local ok, candidate = pcall(config_module.load, config_path)
	if not ok then
		return reload_failed(candidate)
	end
	local reloadable, compatibility_error =
		config_module.reloadable(config, candidate)
	if not reloadable then
		return reload_failed(compatibility_error)
	end
	for _, source_name in ipairs {
		"audio",
		"github",
		"hyprland",
		"mpris",
		"weather",
	} do
		if candidate.sources[source_name].enabled then
			local service = ltask.queryservice(source_name)
			local called, reloaded, reload_error =
				pcall(ltask.call, service, "reload", candidate)
			if not called then
				return reload_failed(reloaded)
			end
			if not reloaded then
				return reload_failed(reload_error or
					("cannot reload %s source"):format(source_name))
			end
		end
	end
	config = candidate
	local changed, revision = state.merge(snapshot, "runtime", {
		config_generation = snapshot.state.runtime.config_generation + 1,
		last_reload_error = "",
	})
	if changed then
		publish()
	end
	ltask.log.info("configuration reloaded", config_path, revision)
	return true, snapshot.state.runtime.config_generation
end

function S.quit()
	control.stop()
end

return S
