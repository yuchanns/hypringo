#ifndef HYPRINGO_EMBED_H
#define HYPRINGO_EMBED_H

#include <lua.h>

int hypringo_load_embedded(lua_State *L, const char *name, const char *chunkname);
int luaopen_hypringo_embed(lua_State *L);

#endif
