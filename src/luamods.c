#include "luamods.h"

#include "audio.h"
#include "control.h"
#include "devices.h"
#include "http.h"
#include "ipc.h"
#include "json.h"
#include "mpris.h"

#include <lauxlib.h>
#include <lualib.h>

static void
preload(lua_State *L, const char *name, lua_CFunction open_function) {
	luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
	lua_pushcfunction(L, open_function);
	lua_setfield(L, -2, name);
	lua_pop(L, 1);
}

void
hypringo_openlibs(lua_State *L) {
	luaL_openlibs(L);
	preload(L, "hypringo.audio", luaopen_hypringo_audio);
	preload(L, "hypringo.control", luaopen_hypringo_control);
	preload(L, "hypringo.system", luaopen_hypringo_system);
	preload(L, "hypringo.http", luaopen_hypringo_http);
	preload(L, "hypringo.ipc", luaopen_hypringo_ipc);
	preload(L, "hypringo.json", luaopen_hypringo_json);
	preload(L, "hypringo.mpris", luaopen_hypringo_mpris);
}
