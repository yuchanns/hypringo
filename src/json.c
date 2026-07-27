#include "json.h"

#include <lauxlib.h>
#include <yyjson.h>

#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HYPRINGO_JSON_MAX_DEPTH 256

static char null_registry_key;
static char array_registry_key;

struct encode_context {
	lua_State *L;
	yyjson_mut_doc *doc;
	int visiting;
	char error[256];
};

struct object_key {
	const char *data;
	size_t length;
};

static void
set_error(struct encode_context *context, const char *format, ...) {
	if (context->error[0] != '\0') {
		return;
	}
	va_list arguments;
	va_start(arguments, format);
	vsnprintf(context->error, sizeof(context->error), format, arguments);
	va_end(arguments);
}

static void
push_null(lua_State *L) {
	lua_rawgetp(L, LUA_REGISTRYINDEX, &null_registry_key);
}

static void
push_array_registry(lua_State *L) {
	lua_rawgetp(L, LUA_REGISTRYINDEX, &array_registry_key);
}

static bool
is_null(lua_State *L, int index) {
	index = lua_absindex(L, index);
	push_null(L);
	bool result = lua_rawequal(L, index, -1);
	lua_pop(L, 1);
	return result;
}

static bool
is_marked_array(lua_State *L, int index) {
	if (!lua_istable(L, index)) {
		return false;
	}
	index = lua_absindex(L, index);
	push_array_registry(L);
	lua_pushvalue(L, index);
	lua_rawget(L, -2);
	bool result = lua_toboolean(L, -1);
	lua_pop(L, 2);
	return result;
}

static void
mark_array(lua_State *L, int index) {
	index = lua_absindex(L, index);
	push_array_registry(L);
	lua_pushvalue(L, index);
	lua_pushboolean(L, true);
	lua_rawset(L, -3);
	lua_pop(L, 1);
}

static bool
enter_table(struct encode_context *context, int index) {
	lua_State *L = context->L;
	index = lua_absindex(L, index);
	lua_pushvalue(L, index);
	lua_rawget(L, context->visiting);
	bool circular = lua_toboolean(L, -1);
	lua_pop(L, 1);
	if (circular) {
		set_error(context, "cannot encode a circular table");
		return false;
	}
	lua_pushvalue(L, index);
	lua_pushboolean(L, true);
	lua_rawset(L, context->visiting);
	return true;
}

static void
leave_table(struct encode_context *context, int index) {
	lua_State *L = context->L;
	index = lua_absindex(L, index);
	lua_pushvalue(L, index);
	lua_pushnil(L);
	lua_rawset(L, context->visiting);
}

static bool
table_shape(struct encode_context *context,
	    int index,
	    bool *array,
	    size_t *length) {
	lua_State *L = context->L;
	index = lua_absindex(L, index);
	bool marked = is_marked_array(L, index);
	size_t count = 0;
	size_t maximum = 0;
	bool integer_keys = true;

	lua_pushnil(L);
	while (lua_next(L, index) != 0) {
		count++;
		if (!lua_isinteger(L, -2)) {
			integer_keys = false;
		} else {
			lua_Integer key = lua_tointeger(L, -2);
			if (key < 1) {
				integer_keys = false;
			} else if ((uint64_t)key > SIZE_MAX) {
				set_error(context, "JSON array index is too large");
				lua_pop(L, 2);
				return false;
			} else if ((size_t)key > maximum) {
				maximum = (size_t)key;
			}
		}
		lua_pop(L, 1);
	}

	bool dense = integer_keys && count == maximum;
	if (marked && !dense) {
		set_error(context, "JSON arrays must use dense integer keys starting at 1");
		return false;
	}
	*array = marked || (count > 0 && dense);
	*length = *array ? maximum : count;
	return true;
}

static int
compare_object_keys(const void *left_pointer, const void *right_pointer) {
	const struct object_key *left = left_pointer;
	const struct object_key *right = right_pointer;
	size_t shared = left->length < right->length ? left->length : right->length;
	int result = memcmp(left->data, right->data, shared);
	if (result != 0) {
		return result;
	}
	if (left->length < right->length) {
		return -1;
	}
	if (left->length > right->length) {
		return 1;
	}
	return 0;
}

static yyjson_mut_val *encode_value(struct encode_context *context,
				    int index,
				    unsigned int depth);

static yyjson_mut_val *
encode_array(struct encode_context *context,
	     int index,
	     size_t length,
	     unsigned int depth) {
	lua_State *L = context->L;
	index = lua_absindex(L, index);
	yyjson_mut_val *array = yyjson_mut_arr(context->doc);
	if (array == NULL) {
		set_error(context, "cannot allocate JSON array");
		return NULL;
	}
	for (size_t item = 1; item <= length; item++) {
		lua_rawgeti(L, index, (lua_Integer)item);
		yyjson_mut_val *value = encode_value(context, -1, depth + 1);
		lua_pop(L, 1);
		if (value == NULL || !yyjson_mut_arr_append(array, value)) {
			if (value != NULL) {
				set_error(context, "cannot append JSON array value");
			}
			return NULL;
		}
	}
	return array;
}

static bool
collect_object_keys(struct encode_context *context,
		    int index,
		    size_t count,
		    struct object_key **keys_pointer) {
	lua_State *L = context->L;
	index = lua_absindex(L, index);
	struct object_key *keys = NULL;
	if (count > 0) {
		keys = malloc(sizeof(*keys) * count);
		if (keys == NULL) {
			set_error(context, "cannot allocate JSON object keys");
			return false;
		}
	}

	size_t position = 0;
	lua_pushnil(L);
	while (lua_next(L, index) != 0) {
		if (lua_type(L, -2) != LUA_TSTRING) {
			set_error(context, "JSON object keys must be strings");
			lua_pop(L, 2);
			free(keys);
			return false;
		}
		keys[position].data = lua_tolstring(L, -2, &keys[position].length);
		position++;
		lua_pop(L, 1);
	}
	if (count > 1) {
		qsort(keys, count, sizeof(*keys), compare_object_keys);
	}
	*keys_pointer = keys;
	return true;
}

static yyjson_mut_val *
encode_object(struct encode_context *context,
	      int index,
	      size_t count,
	      unsigned int depth) {
	lua_State *L = context->L;
	index = lua_absindex(L, index);
	struct object_key *keys;
	if (!collect_object_keys(context, index, count, &keys)) {
		return NULL;
	}

	yyjson_mut_val *object = yyjson_mut_obj(context->doc);
	if (object == NULL) {
		set_error(context, "cannot allocate JSON object");
		free(keys);
		return NULL;
	}
	for (size_t item = 0; item < count; item++) {
		yyjson_mut_val *key = yyjson_mut_strncpy(
			context->doc, keys[item].data, keys[item].length);
		lua_pushlstring(L, keys[item].data, keys[item].length);
		lua_rawget(L, index);
		yyjson_mut_val *value = encode_value(context, -1, depth + 1);
		lua_pop(L, 1);
		if (key == NULL || value == NULL ||
		    !yyjson_mut_obj_add(object, key, value)) {
			if (context->error[0] == '\0') {
				set_error(context, "cannot append JSON object value");
			}
			free(keys);
			return NULL;
		}
	}
	free(keys);
	return object;
}

static yyjson_mut_val *
encode_table(struct encode_context *context, int index, unsigned int depth) {
	if (depth >= HYPRINGO_JSON_MAX_DEPTH) {
		set_error(context, "JSON nesting exceeds %d levels",
			  HYPRINGO_JSON_MAX_DEPTH);
		return NULL;
	}
	if (!enter_table(context, index)) {
		return NULL;
	}

	bool array;
	size_t length;
	yyjson_mut_val *value = NULL;
	if (table_shape(context, index, &array, &length)) {
		if (array) {
			value = encode_array(context, index, length, depth);
		} else {
			value = encode_object(context, index, length, depth);
		}
	}
	leave_table(context, index);
	return value;
}

static yyjson_mut_val *
encode_value(struct encode_context *context, int index, unsigned int depth) {
	lua_State *L = context->L;
	if (is_null(L, index) || lua_isnil(L, index)) {
		return yyjson_mut_null(context->doc);
	}
	switch (lua_type(L, index)) {
	case LUA_TBOOLEAN:
		return yyjson_mut_bool(context->doc, lua_toboolean(L, index));
	case LUA_TNUMBER:
		if (lua_isinteger(L, index)) {
			return yyjson_mut_sint(context->doc, lua_tointeger(L, index));
		}
		if (!isfinite(lua_tonumber(L, index))) {
			set_error(context, "cannot encode a non-finite number");
			return NULL;
		}
		return yyjson_mut_real(context->doc, lua_tonumber(L, index));
	case LUA_TSTRING: {
		size_t length;
		const char *value = lua_tolstring(L, index, &length);
		return yyjson_mut_strncpy(context->doc, value, length);
	}
	case LUA_TTABLE:
		return encode_table(context, index, depth);
	default:
		set_error(context, "cannot encode %s", luaL_typename(L, index));
		return NULL;
	}
}

static int
lencode(lua_State *L) {
	yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
	if (doc == NULL) {
		return luaL_error(L, "cannot allocate JSON document");
	}
	lua_newtable(L);
	struct encode_context context = {
		.L = L,
		.doc = doc,
		.visiting = lua_absindex(L, -1),
		.error = "",
	};
	yyjson_mut_val *root = encode_value(&context, 1, 0);
	lua_pop(L, 1);
	if (root == NULL) {
		yyjson_mut_doc_free(doc);
		return luaL_error(L, "%s", context.error[0] == '\0'
						 ? "cannot encode JSON"
						 : context.error);
	}
	yyjson_mut_doc_set_root(doc, root);

	size_t length = 0;
	yyjson_write_err error;
	char *encoded =
		yyjson_mut_write_opts(doc, YYJSON_WRITE_NOFLAG, NULL, &length, &error);
	if (encoded == NULL) {
		yyjson_mut_doc_free(doc);
		return luaL_error(L, "cannot encode JSON: %s",
				  error.msg == NULL ? "unknown error" : error.msg);
	}
	lua_pushlstring(L, encoded, length);
	free(encoded);
	yyjson_mut_doc_free(doc);
	return 1;
}

static bool
decode_value(lua_State *L, yyjson_val *value, unsigned int depth, char *error) {
	if (depth >= HYPRINGO_JSON_MAX_DEPTH) {
		snprintf(error, 256, "JSON nesting exceeds %d levels",
			 HYPRINGO_JSON_MAX_DEPTH);
		return false;
	}
	if (yyjson_is_null(value)) {
		push_null(L);
		return true;
	}
	if (yyjson_is_bool(value)) {
		lua_pushboolean(L, yyjson_get_bool(value));
		return true;
	}
	if (yyjson_is_sint(value)) {
		lua_pushinteger(L, (lua_Integer)yyjson_get_sint(value));
		return true;
	}
	if (yyjson_is_uint(value)) {
		uint64_t number = yyjson_get_uint(value);
		if (number <= (uint64_t)LUA_MAXINTEGER) {
			lua_pushinteger(L, (lua_Integer)number);
		} else {
			lua_pushnumber(L, (lua_Number)number);
		}
		return true;
	}
	if (yyjson_is_real(value)) {
		lua_pushnumber(L, (lua_Number)yyjson_get_real(value));
		return true;
	}
	if (yyjson_is_str(value)) {
		lua_pushlstring(L, yyjson_get_str(value), yyjson_get_len(value));
		return true;
	}
	if (yyjson_is_arr(value)) {
		size_t index;
		size_t count;
		yyjson_val *item;
		lua_createtable(L, (int)yyjson_arr_size(value), 0);
		mark_array(L, -1);
		yyjson_arr_foreach(value, index, count, item) {
			if (!decode_value(L, item, depth + 1, error)) {
				lua_pop(L, 1);
				return false;
			}
			lua_rawseti(L, -2, (lua_Integer)index + 1);
		}
		return true;
	}
	if (yyjson_is_obj(value)) {
		size_t index;
		size_t count;
		yyjson_val *key;
		yyjson_val *item;
		lua_createtable(L, 0, (int)yyjson_obj_size(value));
		yyjson_obj_foreach(value, index, count, key, item) {
			lua_pushlstring(L, yyjson_get_str(key), yyjson_get_len(key));
			if (!decode_value(L, item, depth + 1, error)) {
				lua_pop(L, 2);
				return false;
			}
			lua_rawset(L, -3);
		}
		return true;
	}
	snprintf(error, 256, "unsupported JSON value");
	return false;
}

static int
ldecode(lua_State *L) {
	if (lua_type(L, 1) != LUA_TSTRING) {
		return luaL_error(L, "JSON source must be a string, got %s",
				  luaL_typename(L, 1));
	}
	size_t length;
	const char *source = lua_tolstring(L, 1, &length);
	yyjson_read_err read_error;
	yyjson_doc *doc = yyjson_read_opts(
		(char *)(void *)source,
		length,
		YYJSON_READ_NOFLAG,
		NULL,
		&read_error);
	if (doc == NULL) {
		return luaL_error(L, "invalid JSON at byte %I: %s",
				  (lua_Integer)read_error.pos + 1,
				  read_error.msg == NULL ? "unknown error"
							 : read_error.msg);
	}

	char error[256] = "";
	if (!decode_value(L, yyjson_doc_get_root(doc), 0, error)) {
		yyjson_doc_free(doc);
		return luaL_error(L, "%s", error);
	}
	yyjson_doc_free(doc);
	return 1;
}

static int
larray(lua_State *L) {
	if (lua_isnoneornil(L, 1)) {
		lua_newtable(L);
	} else {
		luaL_checktype(L, 1, LUA_TTABLE);
		lua_pushvalue(L, 1);
	}
	mark_array(L, -1);
	return 1;
}

static int
lis_array(lua_State *L) {
	lua_pushboolean(L, is_marked_array(L, 1));
	return 1;
}

static void
initialize_registry(lua_State *L) {
	lua_rawgetp(L, LUA_REGISTRYINDEX, &null_registry_key);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_newtable(L);
		lua_pushliteral(L, "hypringo.json.null");
		lua_setfield(L, -2, "__metatable");
		lua_setmetatable(L, -2);
		lua_pushvalue(L, -1);
		lua_rawsetp(L, LUA_REGISTRYINDEX, &null_registry_key);
	}
	lua_pop(L, 1);

	lua_rawgetp(L, LUA_REGISTRYINDEX, &array_registry_key);
	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_newtable(L);
		lua_pushliteral(L, "k");
		lua_setfield(L, -2, "__mode");
		lua_setmetatable(L, -2);
		lua_pushvalue(L, -1);
		lua_rawsetp(L, LUA_REGISTRYINDEX, &array_registry_key);
	}
	lua_pop(L, 1);
}

int
luaopen_hypringo_json(lua_State *L) {
	static const luaL_Reg library[] = {
		{ "array", larray },
		{ "decode", ldecode },
		{ "encode", lencode },
		{ "is_array", lis_array },
		{ NULL, NULL },
	};
	initialize_registry(L);
	luaL_newlib(L, library);
	push_null(L);
	lua_setfield(L, -2, "null");
	lua_pushliteral(L, YYJSON_VERSION_STRING);
	lua_setfield(L, -2, "_VERSION");
	return 1;
}
