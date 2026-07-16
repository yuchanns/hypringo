#include "embed.h"

#include "embedded_sources.h"

#include <lauxlib.h>
#include <string.h>

static const struct hypringo_embedded_source *
find_source(const char *name) {
	for (size_t index = 0; index < hypringo_embedded_source_count; index++) {
		const struct hypringo_embedded_source *source = &hypringo_embedded_sources[index];
		if (strcmp(source->name, name) == 0) {
			return source;
		}
	}
	return NULL;
}

int
hypringo_load_embedded(lua_State *L, const char *name, const char *chunkname) {
	const struct hypringo_embedded_source *source = find_source(name);
	if (source == NULL) {
		lua_pushfstring(L, "embedded source not found: %s", name);
		return LUA_ERRFILE;
	}
	return luaL_loadbufferx(L, (const char *)source->data, source->size, chunkname, "t");
}

static int
lget(lua_State *L) {
	const char *name = luaL_checkstring(L, 1);
	const struct hypringo_embedded_source *source = find_source(name);
	if (source == NULL) {
		return luaL_error(L, "embedded source not found: %s", name);
	}
	lua_pushlstring(L, (const char *)source->data, source->size);
	return 1;
}

int
luaopen_hypringo_embed(lua_State *L) {
	static const luaL_Reg library[] = {
		{ "get", lget },
		{ NULL, NULL },
	};
	luaL_newlib(L, library);
	return 1;
}
