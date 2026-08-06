local output = assert(..., "missing output path")

local sources = {
	{ "ltask.bootstrap", "3rd/ltask/lualib/bootstrap.lua" },
	{ "ltask.service", "3rd/ltask/lualib/service.lua" },
	{ "service.logger", "3rd/ltask/service/logger.lua" },
	{ "service.root", "3rd/ltask/service/root.lua" },
	{ "service.timer", "3rd/ltask/service/timer.lua" },
	{ "hypringo.actions", "src/lualib/actions.lua" },
	{ "hypringo.config", "src/lualib/config.lua" },
	{ "hypringo.doctor", "src/lualib/doctor.lua" },
	{ "hypringo.hyprland", "src/lualib/hyprland.lua" },
	{ "hypringo.remote", "src/lualib/remote.lua" },
	{ "hypringo.runtime", "src/lualib/runtime.lua" },
	{ "hypringo.session", "src/lualib/session.lua" },
	{ "hypringo.state", "src/lualib/state.lua" },
	{ "service.actions", "src/service/actions.lua" },
	{ "service.audio", "src/service/audio.lua" },
	{ "service.github", "src/service/github.lua" },
	{ "service.hyprland", "src/service/hyprland.lua" },
	{ "service.mpris", "src/service/mpris.lua" },
	{ "service.main", "src/service/main.lua" },
	{ "service.state", "src/service/state.lua" },
	{ "service.system", "src/service/system.lua" },
	{ "service.session", "src/service/session.lua" },
	{ "service.weather", "src/service/weather.lua" },
}

local function read_all(path)
	local file <close> = assert(io.open(path, "rb"))
	return file:read "a"
end

local function write_bytes(file, data)
	for index = 1, #data do
		if (index - 1) % 12 == 0 then
			file:write "\n\t"
		end
		file:write(("0x%02x,"):format(data:byte(index)))
	end
	file:write "\n"
end

local file <close> = assert(io.open(output, "wb"))
file:write [[
#ifndef HYPRINGO_EMBEDDED_SOURCES_H
#define HYPRINGO_EMBEDDED_SOURCES_H

#include <stddef.h>

struct hypringo_embedded_source {
	const char *name;
	const unsigned char *data;
	size_t size;
};
]]

for index, source in ipairs(sources) do
	local data = read_all(source[2])
	file:write(("\nstatic const unsigned char hypringo_source_%d[] = {"):format(index))
	write_bytes(file, data)
	file:write "};\n"
end

file:write [[

static const struct hypringo_embedded_source hypringo_embedded_sources[] = {
]]

for index, source in ipairs(sources) do
	file:write(("\t{ %q, hypringo_source_%d, sizeof(hypringo_source_%d) },\n"):format(source[1], index, index))
end

file:write [[
};

static const size_t hypringo_embedded_source_count =
	sizeof(hypringo_embedded_sources) / sizeof(hypringo_embedded_sources[0]);

#endif
]]
