local json = require "hypringo.json"

local M = {}

local relevant_events = {
	activewindow = true,
	activewindowv2 = true,
	changefloatingmode = true,
	closewindow = true,
	configreloaded = true,
	createworkspace = true,
	createworkspacev2 = true,
	destroyworkspace = true,
	destroyworkspacev2 = true,
	focusedmon = true,
	fullscreen = true,
	monitoradded = true,
	monitoraddedv2 = true,
	monitorremoved = true,
	movewindow = true,
	movewindowv2 = true,
	moveworkspace = true,
	moveworkspacev2 = true,
	openwindow = true,
	pin = true,
	renameworkspace = true,
	urgent = true,
	windowtitle = true,
	windowtitlev2 = true,
	workspace = true,
	workspacev2 = true,
}

local function value_or(value, fallback, expected_type)
	if value == nil or value == json.null then
		return fallback
	end
	if type(value) ~= expected_type then
		return fallback
	end
	return value
end

local function number_or(value, fallback)
	return value_or(value, fallback, "number")
end

local function string_or(value, fallback)
	return value_or(value, fallback, "string")
end

local function boolean_or(value, fallback)
	return value_or(value, fallback, "boolean")
end

local function table_or_empty(value)
	if type(value) ~= "table" or value == json.null then
		return {}
	end
	return value
end

local function normalize_workspace_reference(workspace)
	workspace = table_or_empty(workspace)
	return {
		id = number_or(workspace.id, 0),
		name = string_or(workspace.name, ""),
	}
end

local function normalize_monitor(monitor)
	local active_workspace = normalize_workspace_reference(monitor.activeWorkspace)
	return {
		active_workspace = active_workspace,
		description = string_or(monitor.description, ""),
		dpms = boolean_or(monitor.dpmsStatus, true),
		focused = boolean_or(monitor.focused, false),
		height = number_or(monitor.height, 0),
		id = number_or(monitor.id, -1),
		name = string_or(monitor.name, ""),
		refresh_rate = number_or(monitor.refreshRate, 0),
		scale = number_or(monitor.scale, 1),
		transform = number_or(monitor.transform, 0),
		width = number_or(monitor.width, 0),
		x = number_or(monitor.x, 0),
		y = number_or(monitor.y, 0),
	}
end

local function normalize_workspace(workspace)
	return {
		fullscreen = boolean_or(workspace.hasfullscreen, false),
		id = number_or(workspace.id, 0),
		last_window = string_or(workspace.lastwindow, ""),
		last_window_title = string_or(workspace.lastwindowtitle, ""),
		monitor = string_or(workspace.monitor, ""),
		monitor_id = number_or(workspace.monitorID, -1),
		name = string_or(workspace.name, ""),
		persistent = boolean_or(workspace.ispersistent, false),
		windows = number_or(workspace.windows, 0),
	}
end

local function normalize_active_window(window)
	window = table_or_empty(window)
	return {
		address = string_or(window.address, ""),
		class = string_or(window.class, ""),
		floating = boolean_or(window.floating, false),
		fullscreen = number_or(window.fullscreen, 0),
		initial_class = string_or(window.initialClass, ""),
		initial_title = string_or(window.initialTitle, ""),
		pid = number_or(window.pid, 0),
		title = string_or(window.title, ""),
		workspace = normalize_workspace_reference(window.workspace),
		xwayland = boolean_or(window.xwayland, false),
	}
end

local function sorted_array(source, normalize, compare)
	local result = json.array()
	for _, item in ipairs(table_or_empty(source)) do
		if type(item) == "table" and item ~= json.null then
			result[#result + 1] = normalize(item)
		end
	end
	table.sort(result, compare)
	return result
end

local function compare_monitors(left, right)
	if left.x ~= right.x then
		return left.x < right.x
	end
	if left.y ~= right.y then
		return left.y < right.y
	end
	return left.name < right.name
end

local function compare_workspaces(left, right)
	if left.id ~= right.id then
		return left.id < right.id
	end
	return left.name < right.name
end

function M.snapshot(monitors, workspaces, active_window)
	local normalized_monitors = sorted_array(monitors, normalize_monitor, compare_monitors)
	local active_workspace = {
		id = 0,
		monitor = "",
		name = "",
	}
	for _, monitor in ipairs(normalized_monitors) do
		if monitor.focused then
			active_workspace = {
				id = monitor.active_workspace.id,
				monitor = monitor.name,
				name = monitor.active_workspace.name,
			}
			break
		end
	end

	return {
		active_window = normalize_active_window(active_window),
		active_workspace = active_workspace,
		available = true,
		error = "",
		monitors = normalized_monitors,
		workspaces = sorted_array(workspaces, normalize_workspace, compare_workspaces),
	}
end

function M.unavailable(message)
	return {
		active_window = normalize_active_window {},
		active_workspace = {
			id = 0,
			monitor = "",
			name = "",
		},
		available = false,
		error = message or "",
		monitors = json.array(),
		workspaces = json.array(),
	}
end

function M.consume_events(buffer, chunk)
	if type(buffer) ~= "string" or type(chunk) ~= "string" then
		error "event buffer and chunk must be strings"
	end
	buffer = buffer .. chunk
	if #buffer > 1024 * 1024 then
		error "Hyprland event buffer exceeds 1 MiB"
	end

	local relevant = false
	local count = 0
	local start = 1
	while true do
		local newline = buffer:find("\n", start, true)
		if not newline then
			break
		end
		local line = buffer:sub(start, newline - 1):gsub("\r$", "")
		local event_name = line:match "^([%w_]+)>>"
		if event_name and relevant_events[event_name] then
			relevant = true
			count = count + 1
		end
		start = newline + 1
	end
	return buffer:sub(start), relevant, count
end

return M
