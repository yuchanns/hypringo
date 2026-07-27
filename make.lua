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
	"src/lualib/actions.lua",
	"src/lualib/config.lua",
	"src/lualib/doctor.lua",
	"src/lualib/hyprland.lua",
	"src/lualib/runtime.lua",
	"src/lualib/state.lua",
	"src/service/audio.lua",
	"src/service/hyprland.lua",
	"src/service/mpris.lua",
	"src/service/actions.lua",
	"src/service/main.lua",
	"src/service/state.lua",
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
		"src",
	},
	defines = {
		"LTASK_EXTERNAL_OPENLIBS=hypringo_openlibs",
	},
	flags = {
		"-include",
		"luamods.h",
	},
}

lm:source_set "yyjson_src" {
	sources = {
		"3rd/yyjson/src/yyjson.c",
	},
	includes = {
		"3rd/yyjson/src",
	},
}

lm:exe "hypringo" {
	deps = {
		"lua55_src",
		"ltask_src",
		"yyjson_src",
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
		"3rd/yyjson/src",
		"src",
	},
	gcc = {
		links = {
			"dl",
			"m",
			"pulse",
			"pthread",
			"systemd",
		},
	},
}

lm:exe "unit" {
	deps = {
		"lua55_src",
		"yyjson_src",
	},
	sources = {
		"src/json.c",
		"test/unit.c",
	},
	includes = {
		"3rd/lua",
		"3rd/yyjson/src",
		"src",
	},
	gcc = {
		links = {
			"dl",
			"m",
		},
	},
}

lm:exe "mpris_mock" {
	sources = {
		"test/mpris_mock.c",
	},
	gcc = {
		links = {
			"systemd",
		},
	},
}

lm:default "hypringo"
