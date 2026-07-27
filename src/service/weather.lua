local http = require "hypringo.http"
local ipc = require "hypringo.ipc"
local ltask = require "ltask"
local remote = require "hypringo.remote"

local config = ...
local source_config = config.sources.weather
local state_service = ltask.queryservice "state"
local wait_message, wake_fd = ltask.eventinit()

local deadline = 0
local failures = 0
local last_success_at = 0
local stopping = false

local function merge(left, right)
	for key, value in pairs(right) do
		left[key] = value
	end
	return left
end

local function publish(patch)
	ltask.send(state_service, "merge", "weather", patch)
end

local function schedule(delay_ms, now_centiseconds)
	deadline = now_centiseconds + (delay_ms + 9) // 10
end

local function fail(message, headers, now, now_centiseconds)
	failures = failures + 1
	local delay = remote.failure_delay(
		headers,
		failures,
		source_config,
		now)
	schedule(delay, now_centiseconds)
	publish(remote.failure_patch(
		message,
		failures,
		last_success_at,
		delay,
		now))
	ltask.log.error("weather refresh failed", message, "retry_ms", delay)
end

local function refresh(now, now_centiseconds)
	local called, response, request_error = pcall(http.request, {
		headers = {
			"Accept: application/json",
		},
		max_bytes = source_config.max_response_bytes,
		timeout_ms = source_config.timeout_ms,
		url = source_config.url,
	})
	if not called then
		fail(response, nil, now, now_centiseconds)
		return
	end
	if not response then
		fail(request_error, nil, now, now_centiseconds)
		return
	end
	if response.status < 200 or response.status >= 300 then
		fail(
			("weather HTTP status %d"):format(response.status),
			response.headers,
			now,
			now_centiseconds)
		return
	end
	local parsed, weather = pcall(remote.parse_weather, response.body)
	if not parsed then
		fail(weather, response.headers, now, now_centiseconds)
		return
	end
	local delay = remote.success_delay(
		response.headers,
		source_config.interval_ms)
	last_success_at = now
	failures = 0
	schedule(delay, now_centiseconds)
	publish(merge(weather, remote.success_metadata(delay, now)))
end

ltask.idle_handler(function()
	if stopping then
		return
	end
	local now, now_centiseconds = ltask.now()
	if now_centiseconds < deadline then
		local remaining_ms = (deadline - now_centiseconds) * 10
		local ready, wait_error = ipc.wait_wakeup(wake_fd, remaining_ms)
		if wait_error then
			ltask.log.error("weather wait failed", wait_error)
			deadline = now_centiseconds
		elseif ready then
			wait_message()
		end
		return
	end
	refresh(now, now_centiseconds)
end)

local S = {}

function S.status()
	local _, now_centiseconds = ltask.now()
	return {
		failures = failures,
		refresh_in_ms = math.max(0, (deadline - now_centiseconds) * 10),
	}
end

function S.reload(new_config)
	source_config = new_config.sources.weather
	local _, now_centiseconds = ltask.now()
	deadline = now_centiseconds
	return true
end

function S.quit()
	stopping = true
	ltask.quit()
end

return S
