local embed = require "hypringo.embed"

local function load_embedded(name, chunkname)
	local chunk = assert(load(embed.get(name), chunkname or name, "t"))
	return chunk()
end

local config_module = load_embedded("hypringo.config", "@src/lualib/config.lua")

local function usage()
	io.write [[Usage: hypringo [options] [config.lua]

Options:
  --config PATH       Load configuration from PATH.
  --check-config      Validate the configuration and exit.
  --help              Show this help.
]]
end

local function parse_arguments(args)
	local options = {
		check_config = false,
	}
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
			options.check_config = true
		elseif argument == "--help" then
			options.help = true
		elseif argument:sub(1, 1) == "-" then
			error("unknown option: " .. argument)
		elseif options.config_path then
			error "configuration path was specified more than once"
		else
			options.config_path = argument
		end
		index = index + 1
	end
	return options
end

local function build_service_loader()
	local names = {
		"logger",
		"main",
		"root",
		"timer",
	}
	local lines = {
		"local sources = {",
	}
	for _, name in ipairs(names) do
		lines[#lines + 1] = ("[%q] = %q,"):format(name, embed.get("service." .. name))
	end
	lines[#lines + 1] = "}"
	lines[#lines + 1] = [[
local name = ...
local source = sources[name]
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
	local root_config = {
		bootstrap = {
			{
				name = "timer",
				unique = true,
			},
			{
				name = "logger",
				unique = true,
			},
			{
				name = "main",
				args = {
					config_path,
					config,
				},
			},
		},
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

local options = parse_arguments(...)
if options.help then
	usage()
	return
end

local config_path = config_module.resolve_path(options.config_path)
local config = config_module.load(config_path)
if options.check_config then
	io.write(("hypringo: configuration is valid: %s\n"):format(config_path))
	return
end

start(config_path, config)
