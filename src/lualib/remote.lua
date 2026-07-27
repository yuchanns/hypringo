local json = require "hypringo.json"

local M = {}

local MAX_METADATA_DELAY_MS = 86400000
local MAX_TEXT_BYTES = 1024

local function bounded_text(value, path, optional)
	if value == nil or value == json.null then
		if optional then
			return ""
		end
		error(path .. " is missing")
	end
	if type(value) == "number" then
		value = tostring(value)
	end
	if type(value) ~= "string" then
		error(path .. " must be a string")
	end
	if #value > MAX_TEXT_BYTES then
		error(path .. " exceeds 1024 bytes")
	end
	return value
end

local function require_object(value, path)
	if type(value) ~= "table" or value == json.null or json.is_array(value) then
		error(path .. " must be a JSON object")
	end
	return value
end

local function parse_integer(value)
	if type(value) ~= "string" or not value:match "^%d+$" then
		return nil
	end
	local number = tonumber(value)
	if not number or number < 0 or number > math.maxinteger then
		return nil
	end
	return math.floor(number)
end

function M.exponential_delay(failures, minimum, maximum)
	local delay = minimum
	for _ = 2, failures do
		if delay >= maximum or delay > maximum // 2 then
			return maximum
		end
		delay = delay * 2
	end
	return math.min(delay, maximum)
end

function M.failure_delay(headers, failures, config, now)
	local delay = M.exponential_delay(
		failures,
		config.retry_min_ms,
		config.retry_max_ms)
	local retry_after = parse_integer(headers and headers.retry_after)
	if retry_after then
		delay = math.max(delay, retry_after * 1000)
	end
	if headers and headers.x_ratelimit_remaining == "0" then
		local reset = parse_integer(headers.x_ratelimit_reset)
		if reset and reset > now then
			delay = math.max(delay, (reset - now) * 1000)
		end
	end
	return math.min(delay, MAX_METADATA_DELAY_MS)
end

function M.success_delay(headers, interval_ms)
	local poll_interval = parse_integer(headers and headers.x_poll_interval)
	if poll_interval then
		interval_ms = math.max(interval_ms, poll_interval * 1000)
	end
	return math.min(interval_ms, MAX_METADATA_DELAY_MS)
end

function M.failure_patch(message, failures, last_success_at, delay_ms, now)
	if type(message) ~= "string" then
		message = tostring(message)
	end
	if #message > MAX_TEXT_BYTES then
		message = message:sub(1, MAX_TEXT_BYTES)
	end
	return {
		error = message,
		failures = failures,
		last_attempt_at = now,
		refresh_in_ms = delay_ms,
		stale = last_success_at > 0,
	}
end

function M.success_metadata(delay_ms, now)
	return {
		available = true,
		error = "",
		failures = 0,
		last_attempt_at = now,
		last_success_at = now,
		refresh_in_ms = delay_ms,
		stale = false,
	}
end

function M.parse_weather(body)
	local value = require_object(json.decode(body), "weather response")
	return {
		condition = bounded_text(value.cond, "weather response.cond"),
		feels_like = bounded_text(
			value.temp_like,
			"weather response.temp_like"),
		location = bounded_text(value.loc, "weather response.loc"),
		precipitation = bounded_text(
			value.precip,
			"weather response.precip"),
		pressure = bounded_text(value.pressure, "weather response.pressure"),
		temperature = bounded_text(value.temp, "weather response.temp"),
		wind = bounded_text(value.wind, "weather response.wind"),
	}
end

local function project_notification(value, index)
	value = require_object(value, ("GitHub notification %d"):format(index))
	local subject = require_object(
		value.subject,
		("GitHub notification %d.subject"):format(index))
	local repository = require_object(
		value.repository,
		("GitHub notification %d.repository"):format(index))
	return {
		id = bounded_text(
			value.id,
			("GitHub notification %d.id"):format(index)),
		reason = bounded_text(
			value.reason,
			("GitHub notification %d.reason"):format(index),
			true),
		repository = {
			full_name = bounded_text(
				repository.full_name,
				("GitHub notification %d.repository.full_name"):format(
					index)),
			html_url = bounded_text(
				repository.html_url,
				("GitHub notification %d.repository.html_url"):format(
					index),
				true),
		},
		subject = {
			latest_comment_url = bounded_text(
				subject.latest_comment_url,
				("GitHub notification %d.subject.latest_comment_url"):format(
					index),
				true),
			title = bounded_text(
				subject.title,
				("GitHub notification %d.subject.title"):format(index)),
			type = bounded_text(
				subject.type,
				("GitHub notification %d.subject.type"):format(index)),
			url = bounded_text(
				subject.url,
				("GitHub notification %d.subject.url"):format(index),
				true),
		},
		unread = value.unread == true,
		updated_at = bounded_text(
			value.updated_at,
			("GitHub notification %d.updated_at"):format(index),
			true),
	}
end

function M.parse_github(body, maximum)
	local value = json.decode(body)
	if type(value) ~= "table" or not json.is_array(value) then
		error "GitHub response must be a JSON array"
	end
	local notifications = json.array()
	for index = 1, math.min(#value, maximum) do
		notifications[index] = project_notification(value[index], index)
	end
	return notifications
end

return M
