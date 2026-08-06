local fs = require "hypringo.fs"
local json = require "hypringo.json"
local ltask = require "ltask"
local session = require "hypringo.session"

local config = ...
local session_config = config.session
local last_snapshot
local last_saved_at = 0
local last_error = ""
local pending_generation = 0
local pending_moves = {}
local restore_started = false
local stopping = false

local function read_snapshot(path)
	local encoded, read_error = fs.read(path)
	if not encoded then
		return nil, read_error
	end
	local ok, decoded = pcall(json.decode, encoded)
	if not ok then
		return nil, "session JSON is invalid: " .. tostring(decoded)
	end
	if not session.valid(decoded) then
		return nil, "session JSON has an unsupported format or version"
	end
	return decoded
end

local function load_previous()
	local snapshot, read_error = read_snapshot(session_config.path)
	if snapshot then
		return snapshot
	end
	local backup, backup_error = read_snapshot(session_config.path .. ".bak")
	if backup then
		ltask.log.info("restoring session from backup", session_config.path)
		return backup
	end
	if read_error and not read_error:match "No such file" and
		backup_error and not backup_error:match "No such file" then
		ltask.log.error("cannot load previous Hyprland session", read_error)
	end
	return nil
end

local function capture(snapshot)
	local ok, captured, capture_error = pcall(session.capture, snapshot)
	if not ok then
		return nil, captured
	end
	if not captured then
		return nil, capture_error
	end
	return captured
end

local function save_snapshot(snapshot)
	local captured, capture_error = capture(snapshot)
	if not captured then
		last_error = capture_error or "cannot capture Hyprland session"
		ltask.log.error("Hyprland session capture failed", last_error)
		return false, last_error
	end
	local encoded
	local encoded_ok, encoded_result = pcall(json.encode, captured)
	if not encoded_ok then
		last_error = encoded_result
		ltask.log.error("Hyprland session encoding failed", last_error)
		return false, last_error
	end
	encoded = encoded_result
	local written, write_error = fs.atomic_write(session_config.path, encoded)
	if not written then
		last_error = write_error or "cannot write Hyprland session"
		ltask.log.error("Hyprland session write failed", last_error)
		return false, last_error
	end
	last_saved_at = captured.captured_at
	last_error = ""
	return true
end

local function same_class(left, right)
	local left_window = left.window or left
	local right_window = right.window or right
	for _, left_class in ipairs {
		left_window.class,
		left_window.initial_class,
	} do
		if type(left_class) == "string" and left_class ~= "" then
			for _, right_class in ipairs {
				right_window.class,
				right_window.initial_class,
			} do
				if left_class == right_class then
					return true
				end
			end
		end
	end
	return false
end

local function apply_pending_moves(snapshot)
	if #pending_moves == 0 then
		return
	end
	local hyprland_service = ltask.queryservice "hyprland"
	local used_addresses = {}
	for _, client in ipairs(snapshot.clients or {}) do
		for index = #pending_moves, 1, -1 do
			local pending = pending_moves[index]
			if not pending.address and not used_addresses[client.address] and
				same_class(pending.window, client) then
				local workspace = pending.window.workspace.name
				if workspace ~= "" then
					local called, moved, move_error = pcall(
						ltask.call,
						hyprland_service,
						"move_window",
						client.address,
						workspace)
					if called and moved then
						pending.address = client.address
						used_addresses[client.address] = true
						table.remove(pending_moves, index)
					elseif not called then
						ltask.log.error("restored window move failed", moved)
					elseif move_error then
						ltask.log.error("restored window move failed", move_error)
					end
				end
			end
		end
	end
end

local function restore_snapshot(previous, current)
	local current_capture, capture_error = capture(current)
	if not current_capture then
		ltask.log.error("cannot prepare Hyprland session restore", capture_error)
		return false
	end
	local plan, plan_error = session.plan_restore(previous, current_capture)
	if not plan then
		ltask.log.error("cannot build Hyprland session restore plan", plan_error)
		return false
	end
	for _, application in ipairs(plan.applications) do
		local _, spawn_error = fs.spawn(
			application.executable,
			application.argv,
			application.cwd)
		if spawn_error then
			ltask.log.error(
				"Hyprland session application launch failed",
				application.executable,
				spawn_error)
		else
			local window = application.windows[1]
			if window then
				pending_moves[#pending_moves + 1] = {
					window = window,
				}
			end
		end
	end
	if #plan.applications > 0 then
		ltask.log.info(
			"Hyprland session restore launched applications",
			#plan.applications)
	end
	return true
end

local function schedule_save(snapshot, delay_ms)
	pending_generation = pending_generation + 1
	local generation = pending_generation
	delay_ms = delay_ms or session_config.debounce_ms
	ltask.fork(function()
		ltask.sleep(math.max(1, (delay_ms + 9) // 10))
		if not stopping and generation == pending_generation then
			save_snapshot(snapshot)
		end
	end)
end

local S = {}

function S.observe(snapshot)
	if type(snapshot) ~= "table" or not snapshot.available then
		return false
	end
	last_snapshot = snapshot
	if not restore_started then
		restore_started = true
		local previous = session_config.restore and load_previous() or nil
		if previous then
			restore_snapshot(previous, snapshot)
			schedule_save(snapshot, math.max(session_config.debounce_ms, 2000))
		else
			schedule_save(snapshot)
		end
	else
		apply_pending_moves(snapshot)
		schedule_save(snapshot)
	end
	return true
end

function S.dispatch(name)
	if name ~= "save" and name ~= "restore" then
		return false, "unsupported session action"
	end
	if not last_snapshot or not last_snapshot.available then
		return false, "Hyprland snapshot is unavailable"
	end
	if name == "save" then
		return save_snapshot(last_snapshot)
	end
	local previous = load_previous()
	if not previous then
		return false, "no previous Hyprland session snapshot"
	end
	return restore_snapshot(previous, last_snapshot)
end

function S.status()
	return {
		last_error = last_error,
		last_saved_at = last_saved_at,
		path = session_config.path,
		restore_started = restore_started,
	}
end

function S.reload(new_config)
	session_config = new_config.session
	return true
end

function S.quit()
	stopping = true
	if last_snapshot and last_snapshot.available then
		save_snapshot(last_snapshot)
	end
	ltask.quit()
end

return S
