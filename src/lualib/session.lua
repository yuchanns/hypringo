local json = require "hypringo.json"

local M = {}

M.format = "hypringo-session"
M.version = 1

local wrapper_names = {
	bash = true,
	dash = true,
	env = true,
	fish = true,
	flatpak = true,
	flatpak_session_helper = true,
	sh = true,
	zsh = true,
}

local function array(value)
	return type(value) == "table" and value or json.array()
end

local function string_or(value, fallback)
	if type(value) == "string" then
		return value
	end
	return fallback
end

local function number_or(value, fallback)
	if type(value) == "number" then
		return value
	end
	return fallback
end

local function boolean_or(value, fallback)
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function basename(path)
	return (path:match "([^/]+)$" or path):lower()
end

local function copy_array(values)
	local result = json.array()
	for _, value in ipairs(array(values)) do
		result[#result + 1] = value
	end
	return result
end

local function is_wrapper(process)
	local executable = string_or(process and process.exe, "")
	return wrapper_names[basename(executable)] == true
end

local function process_reader()
	local fs = require "hypringo.fs"
	return function(pid)
		return fs.process(pid)
	end
end

local function contains_sensitive_name(value)
	return value:find("token", 1, true) ~= nil or
		value:find("secret", 1, true) ~= nil or
		value:find("password", 1, true) ~= nil or
		value:find("passwd", 1, true) ~= nil or
		value:find("api-key", 1, true) ~= nil or
		value:find("api_key", 1, true) ~= nil or
		value:find("access-key", 1, true) ~= nil or
		value:find("access_key", 1, true) ~= nil or
		value:find("auth", 1, true) ~= nil
end

local function credential_key(value)
	local lower = value:lower()
	return lower:match "^%-%-([%w_-]+)=" or lower:match "^([%w_-]+)="
end

local function safe_argument(value)
	local lower = value:lower()
	local key = credential_key(value)
	if (key and contains_sensitive_name(key)) or
		lower:match "^authorization=" or
		lower:match "^https?://[^/%s:]+:[^/%s]+@" then
		return nil, true
	end
	return value, false
end

local function is_sensitive_flag(value)
	local lower = value:lower()
	local flag = lower:match "^%-%-([%w_-]+)$" or lower:match "^([%w_-]+)$"
	return flag ~= nil and contains_sensitive_name(flag)
end

local function select_process(pid, reader)
	if math.type(pid) ~= "integer" or pid <= 0 then
		return nil, "client process id is unavailable"
	end
	local seen = {}
	local current_pid = pid
	local current
	for _ = 1, 8 do
		if seen[current_pid] then
			break
		end
		seen[current_pid] = true
		local process, process_error = reader(current_pid)
		if not process then
			if current then
				break
			end
			return nil, process_error or "process metadata is unavailable"
		end
		current = process
		if not is_wrapper(current) or
			math.type(current.parent_pid) ~= "integer" or
			current.parent_pid <= 1 then
			break
		end
		current_pid = current.parent_pid
	end
	if not current then
		return nil, "process metadata is unavailable"
	end

	local executable = string_or(current.exe, "")
	if executable == "" or executable:match "%s+%(deleted%)$" then
		return nil, "process executable is unavailable"
	end
	local source_argv = array(current.argv)
	local argv = json.array()
	local redacted = false
	local redact_next = false
	for _, argument in ipairs(source_argv) do
		if type(argument) ~= "string" or argument:find("%z", 1, true) then
			return nil, "process arguments are invalid"
		end
		if redact_next then
			redact_next = false
			redacted = true
		else
			local safe, was_redacted = safe_argument(argument)
			if is_sensitive_flag(argument) then
				redact_next = true
			end
			if was_redacted then
				redacted = true
			elseif safe then
				argv[#argv + 1] = safe
			end
		end
	end
	if #argv == 0 then
		argv[1] = executable
	end
	return {
		argv = argv,
		cwd = string_or(current.cwd, ""),
		executable = executable,
		redacted = redacted,
	}, nil
end

local function workspace_reference(client)
	local workspace = type(client.workspace) == "table" and client.workspace or {}
	return {
		monitor = string_or(client.monitor_name, ""),
		name = string_or(workspace.name, ""),
	}
end

local function window_record(client)
	return {
		class = string_or(client.class, ""),
		floating = boolean_or(client.floating, false),
		fullscreen = number_or(client.fullscreen, 0),
		height = number_or(client.height, 0),
		initial_class = string_or(client.initial_class, ""),
		initial_title = string_or(client.initial_title, ""),
		title = string_or(client.title, ""),
		width = number_or(client.width, 0),
		workspace = workspace_reference(client),
		x = number_or(client.x, 0),
		y = number_or(client.y, 0),
	}
end

local function application_key(application, window)
	return table.concat({
		string_or(application.executable, ""),
		table.concat(application.argv or {}, "\0"),
		string_or(application.initial_class, ""),
		string_or(window.initial_class, ""),
	}, "\0")
end

function M.application_key(application, window)
	return application_key(application, window)
end

local function compare_clients(left, right)
	local left_workspace = left.window.workspace.name
	local right_workspace = right.window.workspace.name
	if left_workspace ~= right_workspace then
		return left_workspace < right_workspace
	end
	local left_key = application_key(left.application, left.window)
	local right_key = application_key(right.application, right.window)
	if left_key ~= right_key then
		return left_key < right_key
	end
	return left.window.title < right.window.title
end

local function capture_monitor(monitor)
	return {
		description = string_or(monitor.description, ""),
		height = number_or(monitor.height, 0),
		name = string_or(monitor.name, ""),
		scale = number_or(monitor.scale, 1),
		transform = number_or(monitor.transform, 0),
		width = number_or(monitor.width, 0),
		x = number_or(monitor.x, 0),
		y = number_or(monitor.y, 0),
	}
end

local function capture_workspace(workspace)
	return {
		monitor = string_or(workspace.monitor, ""),
		name = string_or(workspace.name, ""),
		persistent = boolean_or(workspace.persistent, false),
	}
end

function M.capture(snapshot, reader, now)
	if type(snapshot) ~= "table" or not snapshot.available then
		return nil, "Hyprland snapshot is unavailable"
	end
	reader = reader or process_reader()
	now = now or os.time()
	local result = {
		captured_at = math.type(now) == "integer" and now or os.time(),
		clients = json.array(),
		format = M.format,
		monitors = json.array(),
		skipped = json.array(),
		version = M.version,
		workspaces = json.array(),
	}
	for _, monitor in ipairs(array(snapshot.monitors)) do
		result.monitors[#result.monitors + 1] = capture_monitor(monitor)
	end
	for _, workspace in ipairs(array(snapshot.workspaces)) do
		result.workspaces[#result.workspaces + 1] = capture_workspace(workspace)
	end
	local process_cache = {}
	for _, client in ipairs(array(snapshot.clients)) do
		local window = window_record(client)
		local pid = client.pid
		local process = process_cache[pid]
		local process_error
		if process == nil then
			process, process_error = select_process(pid, reader)
			process_cache[pid] = process or false
		elseif process == false then
			process_error = "process metadata is unavailable"
		end
		local application
		local reason
		if client.hidden or client.mapped == false then
			reason = "client is hidden or unmapped"
		elseif process then
			application = {
				argv = copy_array(process.argv),
				cwd = process.cwd,
				executable = process.executable,
				initial_class = window.initial_class,
			}
			if process.redacted then
				reason = "credential-shaped process argument was omitted"
			end
		else
			reason = process_error or "process metadata is unavailable"
		end
		local record = {
			application = application or {
				argv = json.array(),
				cwd = "",
				executable = "",
				initial_class = window.initial_class,
			},
			restore = reason and "skipped" or "automatic",
			reason = reason or "",
			window = window,
		}
		result.clients[#result.clients + 1] = record
		if reason then
			result.skipped[#result.skipped + 1] = {
				class = window.class,
				reason = reason,
				title = window.title,
			}
		end
	end
	table.sort(result.clients, compare_clients)
	return result
end

local function classes_match(saved_window, current_window)
	local saved_classes = {
		string_or(saved_window.class, ""),
		string_or(saved_window.initial_class, ""),
	}
	local current_classes = {
		string_or(current_window.class, ""),
		string_or(current_window.initial_class, ""),
	}
	for _, saved_class in ipairs(saved_classes) do
		if saved_class ~= "" then
			for _, current_class in ipairs(current_classes) do
				if saved_class == current_class then
					return true
				end
			end
		end
	end
	return false
end

local function current_window(record)
	if type(record.window) == "table" then
		return record.window
	end
	return record
end

function M.plan_restore(saved, current)
	if not M.valid(saved) then
		return nil, "session snapshot is invalid"
	end
	local current_clients = array(current and current.clients)
	local plan = {
		applications = json.array(),
		skipped = json.array(),
	}
	local grouped = {}
	for _, record in ipairs(array(saved.clients)) do
		local window = current_window(record)
		if record.restore == "automatic" and
			type(record.application) == "table" and
			type(record.application.executable) == "string" and
			record.application.executable ~= "" and
			type(record.application.argv) == "table" and
			#record.application.argv > 0 then
			local already_open = false
			for _, current_record in ipairs(current_clients) do
				local current_window_record = current_window(current_record)
				local current_application = current_record.application
				if classes_match(window, current_window_record) or
					type(current_application) == "table" and
					current_application.executable == record.application.executable then
					already_open = true
					break
				end
			end
			if not already_open then
				local key = application_key(record.application, window)
				local application = grouped[key]
				if not application then
					application = {
						argv = copy_array(record.application.argv),
						cwd = string_or(record.application.cwd, ""),
						executable = record.application.executable,
						initial_class = string_or(record.application.initial_class, ""),
						windows = json.array(),
					}
					grouped[key] = application
					plan.applications[#plan.applications + 1] = application
				else
					plan.skipped[#plan.skipped + 1] = {
						reason = "additional window for the same application is unsupported",
						title = string_or(window.title, ""),
					}
				end
				application.windows[#application.windows + 1] = window
			end
		else
			plan.skipped[#plan.skipped + 1] = {
				reason = string_or(record.reason, "session record is not automatically restorable"),
				title = string_or(window.title, ""),
			}
		end
	end
	return plan
end

function M.valid(snapshot)
	return type(snapshot) == "table" and
		snapshot.format == M.format and
		snapshot.version == M.version and
		type(snapshot.clients) == "table" and
		type(snapshot.monitors) == "table" and
		type(snapshot.workspaces) == "table"
end

return M
