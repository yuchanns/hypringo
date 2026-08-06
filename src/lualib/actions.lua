local M = {}

local media_actions = {
	next = true,
	pause = true,
	play = true,
	["play-pause"] = true,
	previous = true,
}

local session_actions = {
	restore = true,
	save = true,
}

local function parse_integer(value)
	if type(value) ~= "string" or not value:match "^%-?%d+$" then
		return nil
	end
	local number = tonumber(value)
	if math.type(number) ~= "integer" then
		return nil
	end
	return number
end

function M.from_cli(arguments)
	if arguments[1] == "session" and session_actions[arguments[2]] and
		#arguments == 2 then
		return "dispatch session " .. arguments[2]
	end
	if session_actions[arguments[1]] and #arguments == 1 then
		return "dispatch session " .. arguments[1]
	end
	if arguments[1] == "workspace" and arguments[2] == "switch" and
		#arguments == 3 then
		local workspace = parse_integer(arguments[3])
		if not workspace then
			return nil, "workspace switch requires an integer workspace id"
		end
		return ("dispatch workspace switch %d"):format(workspace)
	end
	if arguments[1] == "media" and media_actions[arguments[2]] and
		#arguments == 2 then
		return "dispatch media " .. arguments[2]
	end
	if arguments[1] == "audio" and arguments[2] == "set-volume" and
		#arguments == 3 then
		local volume = parse_integer(arguments[3])
		if not volume or volume < 0 or volume > 100 then
			return nil, "audio set-volume requires an integer from 0 to 100"
		end
		return ("dispatch audio set-volume %d"):format(volume)
	end
	if arguments[1] == "audio" and arguments[2] == "set-mute" and
		(arguments[3] == "true" or arguments[3] == "false") and
		#arguments == 3 then
		return "dispatch audio set-mute " .. arguments[3]
	end
	if arguments[1] == "audio" and arguments[2] == "toggle-mute" and
		#arguments == 2 then
		return "dispatch audio toggle-mute"
	end
	if arguments[1] == "brightness" and arguments[2] == "set" and
		#arguments == 3 then
		local percentage = parse_integer(arguments[3])
		if not percentage or percentage < 0 or percentage > 100 then
			return nil, "brightness set requires an integer from 0 to 100"
		end
		return ("dispatch brightness set %d"):format(percentage)
	end
	return nil, "unsupported dispatch action"
end

function M.parse(command)
	if type(command) ~= "string" then
		return nil, "dispatch command must be a string"
	end

	local workspace = command:match "^dispatch workspace switch (%-?%d+)$"
	if workspace then
		return {
			domain = "workspace",
			name = "switch",
			value = assert(parse_integer(workspace)),
		}
	end

	local media = command:match "^dispatch media ([%a%-]+)$"
	if media and media_actions[media] then
		return {
			domain = "media",
			name = media,
		}
	end

	local session = command:match "^dispatch session ([%a%-]+)$"
	if session and session_actions[session] then
		return {
			domain = "session",
			name = session,
		}
	end

	local volume = command:match "^dispatch audio set%-volume (%d+)$"
	if volume then
		volume = assert(parse_integer(volume))
		if volume >= 0 and volume <= 100 then
			return {
				domain = "audio",
				name = "set-volume",
				value = volume,
			}
		end
	end

	local muted = command:match "^dispatch audio set%-mute ([%a]+)$"
	if muted == "true" or muted == "false" then
		return {
			domain = "audio",
			name = "set-mute",
			value = muted == "true",
		}
	end

	if command == "dispatch audio toggle-mute" then
		return {
			domain = "audio",
			name = "toggle-mute",
		}
	end

	local brightness = command:match "^dispatch brightness set (%d+)$"
	if brightness then
		brightness = assert(parse_integer(brightness))
		if brightness >= 0 and brightness <= 100 then
			return {
				domain = "brightness",
				name = "set-brightness",
				value = brightness,
			}
		end
	end

	return nil, "unsupported dispatch action"
end

return M
