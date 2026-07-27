local embed = require "hypringo.embed"

local function load_embedded(name, chunkname)
	local chunk = assert(load(embed.get(name), chunkname or name, "t"))
	return chunk()
end

local config_module = load_embedded("hypringo.config", "@src/lualib/config.lua")
local actions_module = load_embedded("hypringo.actions", "@src/lualib/actions.lua")

local function usage()
	io.write [[Usage: hypringo [options] [config.lua]

Options:
  --config PATH       Load configuration from PATH.
  --check-config      Validate the configuration and exit.
  --socket PATH       Override the control socket for client commands.
  --help              Show this help.

Commands:
  doctor              Print source health and capabilities.
  reload              Reload reconnect policy from the active configuration.
  status              Print the current revisioned state and exit.
  subscribe           Stream revisioned state snapshots as JSON lines.
  dispatch            Send a typed workspace, media, or audio action.
]]
end

local function parse_arguments(args)
	local options = {
		action_args = {},
		check_config = false,
	}
	if args[1] == "doctor" or args[1] == "reload" or
		args[1] == "status" or args[1] == "subscribe" or
		args[1] == "dispatch" then
		options.command = args[1]
		table.remove(args, 1)
	end
	local index = 1
	while index <= #args do
		local argument = args[index]
		if argument == "--config" then
			index = index + 1
			if not args[index] then
				error "--config requires a path"
			end
			if options.config_path then
				error "configuration path was specified more than once"
			end
			options.config_path = args[index]
		elseif argument == "--check-config" then
			if options.command then
				error "--check-config cannot be used with a client command"
			end
			options.check_config = true
		elseif argument == "--socket" then
			index = index + 1
			if not args[index] then
				error "--socket requires a path"
			end
			if options.socket_path then
				error "control socket path was specified more than once"
			end
			options.socket_path = args[index]
		elseif argument == "--format" then
			index = index + 1
			if args[index] ~= "eww" then
				error "--format currently supports only eww"
			end
			options.format = args[index]
		elseif argument == "--help" then
			options.help = true
		elseif options.command == "dispatch" and
			argument:match "^%-?%d+$" then
			options.action_args[#options.action_args + 1] = argument
		elseif argument:sub(1, 1) == "-" then
			error("unknown option: " .. argument)
		elseif options.command == "dispatch" then
			options.action_args[#options.action_args + 1] = argument
		elseif options.command then
			error("unexpected argument for " .. options.command .. ": " .. argument)
		elseif options.config_path then
			error "configuration path was specified more than once"
		else
			options.config_path = argument
		end
		index = index + 1
	end
	if options.format and options.command ~= "subscribe" then
		error "--format can only be used with subscribe"
	end
	if options.socket_path and not options.command then
		error "--socket can only be used with a client command"
	end
	if options.command == "dispatch" then
		local command, action_error = actions_module.from_cli(options.action_args)
		if not command then
			error(action_error)
		end
		options.protocol_command = command
	end
	return options
end

local function build_service_loader()
	local service_names = {
		"actions",
		"audio",
		"hyprland",
		"logger",
		"main",
		"mpris",
		"root",
		"state",
		"timer",
	}
	local lines = {
		"local services = {",
	}
	for _, name in ipairs(service_names) do
		lines[#lines + 1] = ("[%q] = %q,"):format(name, embed.get("service." .. name))
	end
	lines[#lines + 1] = "}"
	lines[#lines + 1] = "local modules = {"
	for _, name in ipairs {
		"hypringo.actions",
		"hypringo.config",
		"hypringo.doctor",
		"hypringo.hyprland",
		"hypringo.state",
	} do
		lines[#lines + 1] = ("[%q] = %q,"):format(name, embed.get(name))
	end
	lines[#lines + 1] = "}"
	lines[#lines + 1] = [[
for module_name, module_source in pairs(modules) do
	package.preload[module_name] = function()
		return assert(load(module_source, "=(module:" .. module_name .. ")", "t"))()
	end
end
local name = ...
local source = services[name]
if not source then
	return nil, "unknown embedded service: " .. tostring(name)
end
return assert(load(source, "=(service:" .. name .. ")", "t"))
]]
	return table.concat(lines, "\n")
end

local function start(config_path, config)
	local boot = require "ltask.bootstrap"
	local host = require "hypringo.host"
	local bootstrap = load_embedded("ltask.bootstrap", "@3rd/ltask/lualib/bootstrap.lua")
	local service_loader = build_service_loader()
	local bootstrap_services = {
		{
			name = "timer",
			unique = true,
		},
		{
			name = "logger",
			unique = true,
		},
		{
			name = "state",
			unique = true,
			args = {
				config_path,
				config,
			},
		},
	}
	if config.sources.audio.enabled then
		bootstrap_services[#bootstrap_services + 1] = {
			name = "audio",
			unique = true,
			args = {
				config,
			},
		}
	end
	if config.sources.hyprland.enabled then
		bootstrap_services[#bootstrap_services + 1] = {
			name = "hyprland",
			unique = true,
			args = {
				config,
			},
		}
	end
	if config.sources.mpris.enabled then
		bootstrap_services[#bootstrap_services + 1] = {
			name = "mpris",
			unique = true,
			args = {
				config,
			},
		}
	end
	bootstrap_services[#bootstrap_services + 1] = {
		name = "actions",
		unique = true,
		args = {
			config,
		},
	}
	bootstrap_services[#bootstrap_services + 1] = {
		name = "main",
		args = {
			config_path,
			config,
		},
	}

	local root_config = {
		bootstrap = bootstrap_services,
		service_source = embed.get "ltask.service",
		service_chunkname = "@3rd/ltask/lualib/service.lua",
		initfunc = service_loader,
	}

	io.stdout:write(("hypringo: starting with %s\n"):format(config_path))
	io.stdout:flush()
	boot.init_socket()
	local context = bootstrap.start {
		core = {
			worker = config.runtime.workers,
		},
		root = root_config,
		root_initfunc = service_loader,
	}
	host.restore_signals()
	bootstrap.wait(context)
	io.stdout:write "hypringo: stopped\n"
	io.stdout:flush()
end

local function run_client(options)
	local control = require "hypringo.control"
	local socket_path = options.socket_path or config_module.default_socket_path()
	if socket_path:sub(1, 1) ~= "/" then
		error "control socket path must be absolute"
	end
	local command = options.protocol_command or options.command
	if options.format == "eww" then
		command = command .. " eww"
	end
	control.request(socket_path, command)
end

local options = parse_arguments(...)
if options.help then
	usage()
	return
end

if options.command then
	run_client(options)
	return
end

local config_path = config_module.resolve_path(options.config_path)
local config = config_module.load(config_path)
if options.check_config then
	io.write(("hypringo: configuration is valid: %s\n"):format(config_path))
	return
end

start(config_path, config)
