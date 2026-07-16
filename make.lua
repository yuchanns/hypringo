local lm = require "luamake"

lm:required_version "1.11"

lm.basedir = lm:path "."

lm:conf {
	c = "c11",
	warnings = "on",
	flags = {
		lm.mode ~= "debug" and "-O2",
	},
	defines = {
		lm.mode == "debug" and "DEBUGTHREADNAME",
	},
	gcc = {
		defines = {
			"_GNU_SOURCE",
			"_XOPEN_SOURCE=600",
		},
	},
}

local embedded_sources = {
	"3rd/ltask/lualib/bootstrap.lua",
	"3rd/ltask/lualib/service.lua",
	"3rd/ltask/service/logger.lua",
	"3rd/ltask/service/root.lua",
	"3rd/ltask/service/timer.lua",
	"src/lualib/config.lua",
	"src/lualib/runtime.lua",
	"src/service/main.lua",
}

local generated_header = lm.basedir / lm.builddir / "embedded_sources.h"

lm:runlua "embedded_sources" {
	script = "scripts/embed.lua",
	inputs = embedded_sources,
	outputs = generated_header,
	args = {
		"$out",
	},
}

lm:source_set "lua55_src" {
	sources = {
		"3rd/lua/onelua.c",
	},
	defines = {
		"MAKE_LIB",
		"LUA_USE_LINUX",
	},
}

lm:source_set "ltask_src" {
	sources = {
		"3rd/ltask/src/*.c",
	},
	includes = {
		"3rd/lua",
		"3rd/ltask/src",
	},
}

lm:exe "hypringo" {
	deps = {
		"lua55_src",
		"ltask_src",
	},
	objdeps = {
		"embedded_sources",
	},
	sources = {
		"src/*.c",
	},
	includes = {
		"build",
		"3rd/lua",
		"3rd/ltask/src",
		"src",
	},
	gcc = {
		links = {
			"dl",
			"m",
			"pthread",
		},
	},
}

lm:default "hypringo"
