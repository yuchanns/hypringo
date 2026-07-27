#include "http.h"

#include <lauxlib.h>

#include <curl/curl.h>

#include <ctype.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define HTTP_ERROR_SIZE CURL_ERROR_SIZE
#define HTTP_MAX_HEADER_COUNT 64
#define HTTP_MAX_HEADER_VALUE_SIZE 8192

struct response_buffer {
	char *data;
	size_t size;
	size_t capacity;
	size_t maximum;
	bool exceeded;
};

struct response_headers {
	struct response_buffer *body;
	char *etag;
	char *last_modified;
	char *retry_after;
	char *x_poll_interval;
	char *x_ratelimit_remaining;
	char *x_ratelimit_reset;
	bool exceeded;
};

static pthread_once_t curl_init_once = PTHREAD_ONCE_INIT;
static CURLcode curl_init_result = CURLE_FAILED_INIT;

static void
initialize_curl(void) {
	curl_init_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static bool
reserve_buffer(struct response_buffer *buffer, size_t required) {
	if (required <= buffer->capacity) {
		return true;
	}
	size_t capacity = buffer->capacity == 0 ? 4096 : buffer->capacity;
	while (capacity < required) {
		if (capacity > buffer->maximum / 2) {
			capacity = buffer->maximum;
			break;
		}
		capacity *= 2;
	}
	if (capacity < required) {
		return false;
	}
	char *data = realloc(buffer->data, capacity);
	if (data == NULL) {
		return false;
	}
	buffer->data = data;
	buffer->capacity = capacity;
	return true;
}

static size_t
write_response(char *data, size_t size, size_t count, void *userdata) {
	struct response_buffer *buffer = userdata;
	if (size != 0 && count > SIZE_MAX / size) {
		buffer->exceeded = true;
		return 0;
	}
	size_t bytes = size * count;
	if (bytes > buffer->maximum - buffer->size) {
		buffer->exceeded = true;
		return 0;
	}
	if (!reserve_buffer(buffer, buffer->size + bytes)) {
		return 0;
	}
	memcpy(buffer->data + buffer->size, data, bytes);
	buffer->size += bytes;
	return bytes;
}

static bool
header_name_equal(const char *line, size_t name_length, const char *expected) {
	size_t expected_length = strlen(expected);
	if (name_length != expected_length) {
		return false;
	}
	for (size_t index = 0; index < name_length; index++) {
		if (tolower((unsigned char)line[index]) !=
		    tolower((unsigned char)expected[index])) {
			return false;
		}
	}
	return true;
}

static void
replace_header(char **target, const char *value, size_t length) {
	while (length > 0 &&
	       (value[length - 1] == '\r' || value[length - 1] == '\n' ||
		isspace((unsigned char)value[length - 1]))) {
		length--;
	}
	while (length > 0 && isspace((unsigned char)*value)) {
		value++;
		length--;
	}
	char *copy = malloc(length + 1);
	if (copy == NULL) {
		return;
	}
	memcpy(copy, value, length);
	copy[length] = '\0';
	free(*target);
	*target = copy;
}

static void
clear_response_headers(struct response_headers *headers) {
	free(headers->etag);
	free(headers->last_modified);
	free(headers->retry_after);
	free(headers->x_poll_interval);
	free(headers->x_ratelimit_remaining);
	free(headers->x_ratelimit_reset);
	headers->etag = NULL;
	headers->last_modified = NULL;
	headers->retry_after = NULL;
	headers->x_poll_interval = NULL;
	headers->x_ratelimit_remaining = NULL;
	headers->x_ratelimit_reset = NULL;
	headers->exceeded = false;
}

static size_t
read_response_header(char *data, size_t size, size_t count, void *userdata) {
	struct response_headers *headers = userdata;
	if (size != 0 && count > SIZE_MAX / size) {
		return 0;
	}
	size_t bytes = size * count;
	if (bytes >= 5 &&
	    tolower((unsigned char)data[0]) == 'h' &&
	    tolower((unsigned char)data[1]) == 't' &&
	    tolower((unsigned char)data[2]) == 't' &&
	    tolower((unsigned char)data[3]) == 'p' &&
	    data[4] == '/') {
		clear_response_headers(headers);
		headers->body->size = 0;
		headers->body->exceeded = false;
		return bytes;
	}
	const char *separator = memchr(data, ':', bytes);
	if (separator == NULL) {
		return bytes;
	}
	size_t name_length = (size_t)(separator - data);
	const char *value = separator + 1;
	size_t value_length = bytes - name_length - 1;
	char **target = NULL;
	if (header_name_equal(data, name_length, "etag")) {
		target = &headers->etag;
	} else if (header_name_equal(data, name_length, "last-modified")) {
		target = &headers->last_modified;
	} else if (header_name_equal(data, name_length, "retry-after")) {
		target = &headers->retry_after;
	} else if (header_name_equal(data, name_length, "x-poll-interval")) {
		target = &headers->x_poll_interval;
	} else if (header_name_equal(data, name_length, "x-ratelimit-remaining")) {
		target = &headers->x_ratelimit_remaining;
	} else if (header_name_equal(data, name_length, "x-ratelimit-reset")) {
		target = &headers->x_ratelimit_reset;
	}
	if (target != NULL) {
		if (value_length > HTTP_MAX_HEADER_VALUE_SIZE) {
			headers->exceeded = true;
			return 0;
		}
		replace_header(target, value, value_length);
	}
	return bytes;
}
static bool
valid_request_header(const char *header, size_t length) {
	if (length == 0 || memchr(header, '\r', length) != NULL ||
	    memchr(header, '\n', length) != NULL) {
		return false;
	}
	return memchr(header, ':', length) != NULL;
}

static struct curl_slist *
read_request_headers(lua_State *L, int index) {
	struct curl_slist *headers = NULL;
	if (lua_isnoneornil(L, index)) {
		return headers;
	}
	luaL_checktype(L, index, LUA_TTABLE);
	size_t count = lua_rawlen(L, index);
	if (count > HTTP_MAX_HEADER_COUNT) {
		luaL_error(L, "HTTP request has too many headers");
	}
	for (size_t item = 1; item <= count; item++) {
		lua_rawgeti(L, index, (lua_Integer)item);
		if (lua_type(L, -1) != LUA_TSTRING) {
			lua_pop(L, 1);
			curl_slist_free_all(headers);
			luaL_error(L, "HTTP request headers must be strings");
		}
		size_t length;
		const char *header = lua_tolstring(L, -1, &length);
		if (!valid_request_header(header, length)) {
			curl_slist_free_all(headers);
			luaL_error(L, "HTTP request header must be a single name:value line");
		}
		struct curl_slist *next = curl_slist_append(headers, header);
		lua_pop(L, 1);
		if (next == NULL) {
			curl_slist_free_all(headers);
			luaL_error(L, "cannot allocate HTTP request headers");
		}
		headers = next;
	}
	return headers;
}

static void
set_string_field(lua_State *L, const char *name, const char *value) {
	if (value == NULL) {
		return;
	}
	lua_pushstring(L, value);
	lua_setfield(L, -2, name);
}

static int
push_request_error(lua_State *L,
		   const char *message,
		   struct response_buffer *buffer,
		   struct response_headers *headers,
		   struct curl_slist *request_headers,
		   CURL *curl) {
	free(buffer->data);
	clear_response_headers(headers);
	curl_slist_free_all(request_headers);
	curl_easy_cleanup(curl);
	lua_pushnil(L);
	lua_pushstring(L, message);
	return 2;
}

static int
lrequest(lua_State *L) {
	luaL_checktype(L, 1, LUA_TTABLE);
	lua_getfield(L, 1, "url");
	const char *url = luaL_checkstring(L, -1);
	lua_getfield(L, 1, "timeout_ms");
	lua_Integer timeout_ms = luaL_checkinteger(L, -1);
	lua_getfield(L, 1, "max_bytes");
	lua_Integer max_bytes = luaL_checkinteger(L, -1);
	lua_getfield(L, 1, "headers");
	int headers_index = lua_gettop(L);
	if (timeout_ms < 10 || timeout_ms > 600000) {
		return luaL_error(L, "HTTP timeout_ms must be between 10 and 600000");
	}
	if (max_bytes < 1 || max_bytes > 16 * 1024 * 1024) {
		return luaL_error(L, "HTTP max_bytes must be between 1 and 16777216");
	}

	pthread_once(&curl_init_once, initialize_curl);
	if (curl_init_result != CURLE_OK) {
		return luaL_error(L, "cannot initialize libcurl: %s",
				  curl_easy_strerror(curl_init_result));
	}
	struct curl_slist *request_headers = read_request_headers(L, headers_index);
	CURL *curl = curl_easy_init();
	if (curl == NULL) {
		curl_slist_free_all(request_headers);
		return luaL_error(L, "cannot create HTTP request");
	}
	struct response_buffer buffer = {
		.maximum = (size_t)max_bytes,
	};
	struct response_headers response_headers = {
		.body = &buffer,
	};
	char error[HTTP_ERROR_SIZE] = { 0 };

#define SETOPT(option, value)                                                   \
	do {                                                                      \
		CURLcode option_result = curl_easy_setopt(curl, option, value);     \
		if (option_result != CURLE_OK) {                                    \
			return push_request_error(L,                                \
						  curl_easy_strerror(option_result),  \
						  &buffer,                            \
						  &response_headers,                  \
						  request_headers,                    \
						  curl);                              \
		}                                                                 \
	} while (0)

	SETOPT(CURLOPT_URL, url);
	SETOPT(CURLOPT_HTTPHEADER, request_headers);
	SETOPT(CURLOPT_USERAGENT, "hypringo/0.1");
	SETOPT(CURLOPT_ACCEPT_ENCODING, "");
	SETOPT(CURLOPT_NOSIGNAL, 1L);
	SETOPT(CURLOPT_CONNECTTIMEOUT_MS, (long)timeout_ms);
	SETOPT(CURLOPT_TIMEOUT_MS, (long)timeout_ms);
	SETOPT(CURLOPT_FOLLOWLOCATION, 1L);
	SETOPT(CURLOPT_MAXREDIRS, 3L);
	SETOPT(CURLOPT_PROTOCOLS_STR, "http,https");
	SETOPT(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
	SETOPT(CURLOPT_WRITEFUNCTION, write_response);
	SETOPT(CURLOPT_WRITEDATA, &buffer);
	SETOPT(CURLOPT_HEADERFUNCTION, read_response_header);
	SETOPT(CURLOPT_HEADERDATA, &response_headers);
	SETOPT(CURLOPT_ERRORBUFFER, error);

	CURLcode result = curl_easy_perform(curl);
	if (result != CURLE_OK) {
		const char *message;
		if (buffer.exceeded) {
			message = "HTTP response exceeds configured max_bytes";
		} else if (response_headers.exceeded) {
			message = "HTTP response header exceeds 8192 bytes";
		} else if (error[0] != '\0') {
			message = error;
		} else {
			message = curl_easy_strerror(result);
		}
		return push_request_error(L,
					  message,
					  &buffer,
					  &response_headers,
					  request_headers,
					  curl);
	}

	long status = 0;
	char *effective_url = NULL;
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
	curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective_url);

	lua_newtable(L);
	lua_pushinteger(L, status);
	lua_setfield(L, -2, "status");
	lua_pushlstring(L, buffer.data == NULL ? "" : buffer.data, buffer.size);
	lua_setfield(L, -2, "body");
	set_string_field(L, "url", effective_url);
	lua_newtable(L);
	set_string_field(L, "etag", response_headers.etag);
	set_string_field(L, "last_modified", response_headers.last_modified);
	set_string_field(L, "retry_after", response_headers.retry_after);
	set_string_field(L, "x_poll_interval", response_headers.x_poll_interval);
	set_string_field(
		L, "x_ratelimit_remaining", response_headers.x_ratelimit_remaining);
	set_string_field(L, "x_ratelimit_reset", response_headers.x_ratelimit_reset);
	lua_setfield(L, -2, "headers");

	free(buffer.data);
	clear_response_headers(&response_headers);
	curl_slist_free_all(request_headers);
	curl_easy_cleanup(curl);
	return 1;
#undef SETOPT
}

int
luaopen_hypringo_http(lua_State *L) {
	static const luaL_Reg library[] = {
		{ "request", lrequest },
		{ NULL, NULL },
	};
	luaL_newlib(L, library);
	return 1;
}
