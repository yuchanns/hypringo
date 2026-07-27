#include "host.h"

#include <lauxlib.h>

#include <signal.h>

static int
lrestore_signals(lua_State *L) {
	if (signal(SIGTERM, SIG_DFL) == SIG_ERR) {
		return luaL_error(L, "cannot restore SIGTERM handling");
	}
	return 0;
}

int
luaopen_hypringo_host(lua_State *L) {
	static const luaL_Reg library[] = {
		{ "restore_signals", lrestore_signals },
		{ NULL, NULL },
	};
	luaL_newlib(L, library);
	return 1;
}
