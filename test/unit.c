#include "json.h"
#include "fs.h"

#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>

int
main(int argc, char **argv) {
	if (argc != 2) {
		fputs("usage: unit TEST_FILE\n", stderr);
		return 2;
	}
	lua_State *L = luaL_newstate();
	if (L == NULL) {
		fputs("unit: cannot create Lua state\n", stderr);
		return 1;
	}
	luaL_openlibs(L);
	luaL_requiref(L, "hypringo.json", luaopen_hypringo_json, 0);
	lua_pop(L, 1);
	luaL_requiref(L, "hypringo.fs", luaopen_hypringo_fs, 0);
	lua_pop(L, 1);
	int status = luaL_dofile(L, argv[1]);
	if (status != LUA_OK) {
		fprintf(stderr, "unit: %s\n", lua_tostring(L, -1));
	}
	lua_close(L);
	return status == LUA_OK ? 0 : 1;
}
