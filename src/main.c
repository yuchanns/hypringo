#include "embed.h"
#include "host.h"

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include <signal.h>
#include <stdio.h>

int luaopen_ltask_bootstrap(lua_State *L);

static int
traceback(lua_State *L) {
	const char *message = lua_tostring(L, 1);
	if (message == NULL) {
		message = "unknown error";
	}
	luaL_traceback(L, L, message, 1);
	return 1;
}

static void
preload(lua_State *L, const char *name, lua_CFunction open_function) {
	luaL_requiref(L, name, open_function, 0);
	lua_pop(L, 1);
}

static void
push_arguments(lua_State *L, int argc, char **argv) {
	lua_createtable(L, argc - 1, 0);
	for (int index = 1; index < argc; index++) {
		lua_pushstring(L, argv[index]);
		lua_rawseti(L, -2, index);
	}
}

int
main(int argc, char **argv) {
	signal(SIGPIPE, SIG_IGN);

	lua_State *L = luaL_newstate();
	if (L == NULL) {
		fputs("hypringo: cannot create Lua state\n", stderr);
		return 1;
	}

	luaL_openlibs(L);
	preload(L, "ltask.bootstrap", luaopen_ltask_bootstrap);
	preload(L, "hypringo.embed", luaopen_hypringo_embed);
	preload(L, "hypringo.host", luaopen_hypringo_host);

	lua_pushcfunction(L, traceback);
	if (hypringo_load_embedded(L, "hypringo.runtime", "@src/lualib/runtime.lua") != LUA_OK) {
		fprintf(stderr, "hypringo: %s\n", lua_tostring(L, -1));
		lua_close(L);
		return 1;
	}
	push_arguments(L, argc, argv);

	int status = lua_pcall(L, 1, 0, 1);
	if (status != LUA_OK) {
		fprintf(stderr, "hypringo: %s\n", lua_tostring(L, -1));
	}
	lua_close(L);
	return status == LUA_OK ? 0 : 1;
}
