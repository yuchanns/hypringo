#include "mpris.h"

#include <lauxlib.h>
#include <systemd/sd-bus.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define MPRIS_BUS_PREFIX "org.mpris.MediaPlayer2."
#define MPRIS_OBJECT_PATH "/org/mpris/MediaPlayer2"
#define MPRIS_PLAYER_INTERFACE "org.mpris.MediaPlayer2.Player"
#define MPRIS_ROOT_INTERFACE "org.mpris.MediaPlayer2"

struct mpris_source {
	sd_bus *bus;
	sd_bus_slot *name_slot;
	sd_bus_slot *properties_slot;
	char *selected_name;
	bool can_go_next;
	bool can_go_previous;
	bool can_pause;
	bool can_play;
	bool can_control;
	bool dirty;
};

struct player_snapshot {
	char *bus_name;
	char *identity;
	char *status;
	char *title;
	char *album;
	char *artist;
	char *art;
	bool can_go_next;
	bool can_go_previous;
	bool can_pause;
	bool can_play;
	bool can_control;
};

static int
set_cloexec(int fd) {
	int flags = fcntl(fd, F_GETFD, 0);
	if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
		return -1;
	}
	return 0;
}

static struct mpris_source *
check_source(lua_State *L, int index) {
	return luaL_checkudata(L, index, "hypringo.mpris.source");
}

static void
free_player(struct player_snapshot *player) {
	free(player->bus_name);
	free(player->identity);
	free(player->status);
	free(player->title);
	free(player->album);
	free(player->artist);
	free(player->art);
	*player = (struct player_snapshot) { 0 };
}

static void
close_source(struct mpris_source *source) {
	source->properties_slot = sd_bus_slot_unref(source->properties_slot);
	source->name_slot = sd_bus_slot_unref(source->name_slot);
	source->bus = sd_bus_unref(source->bus);
	free(source->selected_name);
	source->selected_name = NULL;
	source->can_go_next = false;
	source->can_go_previous = false;
	source->can_pause = false;
	source->can_play = false;
	source->can_control = false;
	source->dirty = false;
}

static int
lsource_close(lua_State *L) {
	close_source(check_source(L, 1));
	return 0;
}

static int
lsource_gc(lua_State *L) {
	close_source(check_source(L, 1));
	return 0;
}

static bool
is_mpris_name(const char *name) {
	return strncmp(name, MPRIS_BUS_PREFIX, strlen(MPRIS_BUS_PREFIX)) == 0;
}

static bool
is_relevant_property(const char *property) {
	return strcmp(property, "Metadata") == 0 ||
	       strcmp(property, "PlaybackStatus") == 0 ||
	       strcmp(property, "CanControl") == 0 ||
	       strcmp(property, "CanGoNext") == 0 ||
	       strcmp(property, "CanGoPrevious") == 0 ||
	       strcmp(property, "CanPause") == 0 ||
	       strcmp(property, "CanPlay") == 0;
}

static int
name_owner_changed(sd_bus_message *message,
		   void *userdata,
		   sd_bus_error *ret_error) {
	(void)ret_error;
	struct mpris_source *source = userdata;
	const char *name;
	const char *old_owner;
	const char *new_owner;
	int result = sd_bus_message_read(
		message, "sss", &name, &old_owner, &new_owner);
	(void)old_owner;
	(void)new_owner;
	if (result >= 0 && is_mpris_name(name)) {
		source->dirty = true;
	}
	return 0;
}

static int
properties_changed(sd_bus_message *message,
		   void *userdata,
		   sd_bus_error *ret_error) {
	(void)ret_error;
	struct mpris_source *source = userdata;
	const char *interface;
	int result = sd_bus_message_read(message, "s", &interface);
	if (result < 0 || strcmp(interface, MPRIS_PLAYER_INTERFACE) != 0) {
		return 0;
	}

	bool relevant = false;
	result = sd_bus_message_enter_container(message, 'a', "{sv}");
	while (result > 0) {
		result = sd_bus_message_enter_container(message, 'e', "sv");
		if (result <= 0) {
			break;
		}
		const char *property;
		result = sd_bus_message_read(message, "s", &property);
		if (result < 0) {
			break;
		}
		if (is_relevant_property(property)) {
			relevant = true;
		}
		result = sd_bus_message_skip(message, "v");
		if (result < 0) {
			break;
		}
		result = sd_bus_message_exit_container(message);
	}
	if (result == 0) {
		result = sd_bus_message_exit_container(message);
	}
	if (result >= 0) {
		result = sd_bus_message_enter_container(message, 'a', "s");
	}
	while (result > 0) {
		const char *property;
		result = sd_bus_message_read(message, "s", &property);
		if (result <= 0) {
			break;
		}
		if (is_relevant_property(property)) {
			relevant = true;
		}
	}
	if (result == 0) {
		result = sd_bus_message_exit_container(message);
	}
	source->dirty = source->dirty || relevant || result < 0;
	return 0;
}

static char *
duplicate_or_empty(const char *value) {
	return strdup(value == NULL ? "" : value);
}

static int
read_string_property(sd_bus *bus,
		     const char *destination,
		     const char *interface,
		     const char *property,
		     char **result) {
	sd_bus_error error = SD_BUS_ERROR_NULL;
	char *value = NULL;
	int status = sd_bus_get_property_string(
		bus,
		destination,
		MPRIS_OBJECT_PATH,
		interface,
		property,
		&error,
		&value);
	sd_bus_error_free(&error);
	if (status < 0) {
		free(value);
		return status;
	}
	*result = value;
	return 0;
}

static void
read_bool_property(sd_bus *bus,
		   const char *destination,
		   const char *property,
		   bool *value) {
	sd_bus_error error = SD_BUS_ERROR_NULL;
	int result = 0;
	int status = sd_bus_get_property_trivial(
		bus,
		destination,
		MPRIS_OBJECT_PATH,
		MPRIS_PLAYER_INTERFACE,
		property,
		&error,
		'b',
		&result);
	sd_bus_error_free(&error);
	*value = status >= 0 && result != 0;
}

static int
append_artist(char **artist, const char *value) {
	size_t previous = *artist == NULL ? 0 : strlen(*artist);
	size_t addition = strlen(value);
	size_t separator = previous == 0 ? 0 : 2;
	char *joined = realloc(*artist, previous + separator + addition + 1);
	if (joined == NULL) {
		return -ENOMEM;
	}
	if (separator > 0) {
		memcpy(joined + previous, ", ", separator);
	}
	memcpy(joined + previous + separator, value, addition + 1);
	*artist = joined;
	return 0;
}

static int
read_artist(sd_bus_message *message, char **artist) {
	int result = sd_bus_message_enter_container(message, 'a', "s");
	if (result < 0) {
		return result;
	}
	for (;;) {
		const char *value;
		result = sd_bus_message_read(message, "s", &value);
		if (result <= 0) {
			break;
		}
		result = append_artist(artist, value);
		if (result < 0) {
			return result;
		}
	}
	int exit_result = sd_bus_message_exit_container(message);
	if (result < 0) {
		return result;
	}
	return exit_result;
}

static int
read_metadata_value(sd_bus_message *message,
		    const char *key,
		    struct player_snapshot *player) {
	char type;
	const char *contents;
	int result = sd_bus_message_peek_type(message, &type, &contents);
	if (result <= 0) {
		return result == 0 ? -EBADMSG : result;
	}
	if ((strcmp(key, "xesam:title") == 0 ||
	     strcmp(key, "xesam:album") == 0 ||
	     strcmp(key, "mpris:artUrl") == 0) &&
	    type == 's') {
		const char *value;
		result = sd_bus_message_read(message, "s", &value);
		if (result < 0) {
			return result;
		}
		char **target = strcmp(key, "xesam:title") == 0
				       ? &player->title
				       : strcmp(key, "xesam:album") == 0
						 ? &player->album
						 : &player->art;
		free(*target);
		*target = duplicate_or_empty(value);
		return *target == NULL ? -ENOMEM : 0;
	}
	if (strcmp(key, "xesam:artist") == 0 && type == 'a' &&
	    contents != NULL && strcmp(contents, "s") == 0) {
		free(player->artist);
		player->artist = NULL;
		return read_artist(message, &player->artist);
	}
	char signature[260];
	switch (type) {
	case 'a':
		if (contents == NULL ||
		    snprintf(signature, sizeof(signature), "a%s", contents) >=
			    (int)sizeof(signature)) {
			return -EBADMSG;
		}
		break;
	case 'r':
		if (contents == NULL ||
		    snprintf(signature, sizeof(signature), "(%s)", contents) >=
			    (int)sizeof(signature)) {
			return -EBADMSG;
		}
		break;
	case 'e':
		if (contents == NULL ||
		    snprintf(signature, sizeof(signature), "{%s}", contents) >=
			    (int)sizeof(signature)) {
			return -EBADMSG;
		}
		break;
	default:
		signature[0] = type;
		signature[1] = '\0';
		break;
	}
	return sd_bus_message_skip(message, signature);
}

static int
read_metadata(sd_bus *bus,
	      const char *destination,
	      struct player_snapshot *player) {
	sd_bus_error error = SD_BUS_ERROR_NULL;
	sd_bus_message *reply = NULL;
	int result = sd_bus_get_property(
		bus,
		destination,
		MPRIS_OBJECT_PATH,
		MPRIS_PLAYER_INTERFACE,
		"Metadata",
		&error,
		&reply,
		"a{sv}");
	sd_bus_error_free(&error);
	if (result < 0) {
		sd_bus_message_unref(reply);
		return result;
	}

	result = sd_bus_message_enter_container(reply, 'a', "{sv}");
	if (result < 0) {
		sd_bus_message_unref(reply);
		return result;
	}
	for (;;) {
		result = sd_bus_message_enter_container(reply, 'e', "sv");
		if (result <= 0) {
			break;
		}
		const char *key;
		result = sd_bus_message_read(reply, "s", &key);
		if (result < 0) {
			break;
		}
		result = sd_bus_message_enter_container(reply, 'v', NULL);
		if (result < 0) {
			break;
		}
		result = read_metadata_value(reply, key, player);
		if (result < 0) {
			break;
		}
		result = sd_bus_message_exit_container(reply);
		if (result < 0) {
			break;
		}
		result = sd_bus_message_exit_container(reply);
		if (result < 0) {
			break;
		}
	}
	if (result == 0) {
		result = sd_bus_message_exit_container(reply);
	}
	sd_bus_message_unref(reply);
	return result;
}

static int
read_player(sd_bus *bus,
	    const char *name,
	    struct player_snapshot *player) {
	int result = read_string_property(
		bus,
		name,
		MPRIS_PLAYER_INTERFACE,
		"PlaybackStatus",
		&player->status);
	if (result < 0) {
		return result;
	}
	result = read_string_property(
		bus,
		name,
		MPRIS_ROOT_INTERFACE,
		"Identity",
		&player->identity);
	if (result < 0) {
		player->identity = duplicate_or_empty(name + strlen(MPRIS_BUS_PREFIX));
		if (player->identity == NULL) {
			return -ENOMEM;
		}
	}
	result = read_metadata(bus, name, player);
	(void)result;
	read_bool_property(bus, name, "CanControl", &player->can_control);
	read_bool_property(bus, name, "CanGoNext", &player->can_go_next);
	read_bool_property(
		bus,
		name,
		"CanGoPrevious",
		&player->can_go_previous);
	read_bool_property(bus, name, "CanPause", &player->can_pause);
	read_bool_property(bus, name, "CanPlay", &player->can_play);
	player->bus_name = strdup(name);
	if (player->bus_name == NULL) {
		return -ENOMEM;
	}
	if (player->title == NULL) {
		player->title = duplicate_or_empty(NULL);
	}
	if (player->album == NULL) {
		player->album = duplicate_or_empty(NULL);
	}
	if (player->artist == NULL) {
		player->artist = duplicate_or_empty(NULL);
	}
	if (player->art == NULL) {
		player->art = duplicate_or_empty(NULL);
	}
	if (player->title == NULL || player->album == NULL ||
	    player->artist == NULL || player->art == NULL) {
		return -ENOMEM;
	}
	return 0;
}

static int
player_rank(const struct player_snapshot *player) {
	if (strcasecmp(player->status, "Playing") == 0) {
		return 2;
	}
	if (strcasecmp(player->status, "Paused") == 0) {
		return 1;
	}
	return 0;
}

static const char *
canonical_status(const char *status) {
	if (strcasecmp(status, "Playing") == 0) {
		return "playing";
	}
	if (strcasecmp(status, "Paused") == 0) {
		return "paused";
	}
	return "stopped";
}

static bool
prefer_player(const struct player_snapshot *candidate,
	      const struct player_snapshot *selected) {
	if (selected->bus_name == NULL) {
		return true;
	}
	int candidate_rank = player_rank(candidate);
	int selected_rank = player_rank(selected);
	if (candidate_rank != selected_rank) {
		return candidate_rank > selected_rank;
	}
	return strcmp(candidate->bus_name, selected->bus_name) < 0;
}

static int
select_player(struct mpris_source *source,
	      struct player_snapshot *selected,
	      char **error_message) {
	sd_bus_error error = SD_BUS_ERROR_NULL;
	sd_bus_message *reply = NULL;
	int result = sd_bus_call_method(
		source->bus,
		"org.freedesktop.DBus",
		"/org/freedesktop/DBus",
		"org.freedesktop.DBus",
		"ListNames",
		&error,
		&reply,
		"");
	if (result < 0) {
		*error_message = duplicate_or_empty(error.message);
		sd_bus_error_free(&error);
		sd_bus_message_unref(reply);
		return result;
	}
	sd_bus_error_free(&error);

	result = sd_bus_message_enter_container(reply, 'a', "s");
	if (result < 0) {
		sd_bus_message_unref(reply);
		return result;
	}
	for (;;) {
		const char *name;
		result = sd_bus_message_read(reply, "s", &name);
		if (result <= 0) {
			break;
		}
		if (!is_mpris_name(name)) {
			continue;
		}
		struct player_snapshot candidate = { 0 };
		if (read_player(source->bus, name, &candidate) >= 0 &&
		    prefer_player(&candidate, selected)) {
			free_player(selected);
			*selected = candidate;
		} else {
			free_player(&candidate);
		}
	}
	if (result == 0) {
		result = sd_bus_message_exit_container(reply);
	}
	sd_bus_message_unref(reply);
	return result;
}

static void
push_unavailable(lua_State *L, const char *error) {
	lua_createtable(L, 0, 10);
	lua_pushboolean(L, false);
	lua_setfield(L, -2, "available");
	lua_pushstring(L, error == NULL ? "" : error);
	lua_setfield(L, -2, "error");
	for (const char **field = (const char *[]){
		     "album", "art", "artist", "player", "title", NULL };
	     *field != NULL;
	     field++) {
		lua_pushliteral(L, "");
		lua_setfield(L, -2, *field);
	}
	lua_pushliteral(L, "stopped");
	lua_setfield(L, -2, "status");
	lua_createtable(L, 0, 5);
	for (const char **field = (const char *[]){
		     "next", "pause", "play", "play_pause", "previous", NULL };
	     *field != NULL;
	     field++) {
		lua_pushboolean(L, false);
		lua_setfield(L, -2, *field);
	}
	lua_setfield(L, -2, "capabilities");
}

static int
lsource_snapshot(lua_State *L) {
	struct mpris_source *source = check_source(L, 1);
	if (source->bus == NULL) {
		push_unavailable(L, "MPRIS session bus is closed");
		return 1;
	}

	struct player_snapshot selected = { 0 };
	char *error_message = NULL;
	int result = select_player(source, &selected, &error_message);
	if (result < 0) {
		push_unavailable(
			L,
			error_message == NULL ? strerror(-result) : error_message);
		free(error_message);
		free_player(&selected);
		return 1;
	}
	free(error_message);

	free(source->selected_name);
	source->selected_name = selected.bus_name == NULL
				      ? NULL
				      : strdup(selected.bus_name);
	source->can_control = selected.can_control;
	source->can_go_next = selected.can_go_next;
	source->can_go_previous = selected.can_go_previous;
	source->can_pause = selected.can_pause;
	source->can_play = selected.can_play;
	if (selected.bus_name == NULL) {
		push_unavailable(L, "");
		free_player(&selected);
		return 1;
	}
	if (source->selected_name == NULL) {
		free_player(&selected);
		return luaL_error(L, "cannot allocate selected MPRIS player");
	}

	lua_createtable(L, 0, 10);
	lua_pushboolean(L, true);
	lua_setfield(L, -2, "available");
	lua_pushliteral(L, "");
	lua_setfield(L, -2, "error");
	struct {
		const char *field;
		const char *value;
	} fields[] = {
		{ "album", selected.album },
		{ "art", selected.art },
		{ "artist", selected.artist },
		{ "player", selected.identity },
		{ "status", canonical_status(selected.status) },
		{ "title", selected.title },
	};
	for (size_t index = 0; index < sizeof(fields) / sizeof(fields[0]); index++) {
		lua_pushstring(L, fields[index].value);
		lua_setfield(L, -2, fields[index].field);
	}
	lua_createtable(L, 0, 5);
	struct {
		const char *field;
		bool value;
	} capabilities[] = {
		{ "next", selected.can_control && selected.can_go_next },
		{ "pause", selected.can_control && selected.can_pause },
		{ "play", selected.can_control && selected.can_play },
		{ "play_pause",
		  selected.can_control &&
			  (selected.can_pause || selected.can_play) },
		{ "previous",
		  selected.can_control && selected.can_go_previous },
	};
	for (size_t index = 0;
	     index < sizeof(capabilities) / sizeof(capabilities[0]);
	     index++) {
		lua_pushboolean(L, capabilities[index].value);
		lua_setfield(L, -2, capabilities[index].field);
	}
	lua_setfield(L, -2, "capabilities");
	free_player(&selected);
	return 1;
}

static int
process_bus(struct mpris_source *source, char **error_message) {
	for (;;) {
		int result = sd_bus_process(source->bus, NULL);
		if (result > 0) {
			continue;
		}
		if (result < 0) {
			*error_message = strdup(strerror(-result));
		}
		return result;
	}
}

static int
poll_timeout(sd_bus *bus) {
	uint64_t timeout;
	int result = sd_bus_get_timeout(bus, &timeout);
	if (result < 0 || timeout == UINT64_MAX) {
		return -1;
	}
	struct timespec now;
	if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
		return -1;
	}
	uint64_t now_usec =
		(uint64_t)now.tv_sec * 1000000 + (uint64_t)now.tv_nsec / 1000;
	if (timeout <= now_usec) {
		return 0;
	}
	uint64_t remaining = timeout - now_usec;
	uint64_t milliseconds = (remaining + 999) / 1000;
	return milliseconds > INT32_MAX ? INT32_MAX : (int)milliseconds;
}

static int
lsource_wait(lua_State *L) {
	struct mpris_source *source = check_source(L, 1);
	if (!lua_islightuserdata(L, 2)) {
		return luaL_typeerror(L, 2, "lightuserdata");
	}
	int wake_fd = (int)(intptr_t)lua_touserdata(L, 2);
	if (source->bus == NULL) {
		return luaL_error(L, "MPRIS session bus is closed");
	}

	char *error_message = NULL;
	int processed = process_bus(source, &error_message);
	if (processed < 0) {
		lua_pushboolean(L, false);
		lua_pushboolean(L, false);
		lua_pushboolean(L, true);
		lua_pushstring(L, error_message == NULL
					   ? "MPRIS bus processing failed"
					   : error_message);
		free(error_message);
		return 4;
	}
	if (source->dirty) {
		source->dirty = false;
		lua_pushboolean(L, true);
		lua_pushboolean(L, false);
		lua_pushboolean(L, false);
		lua_pushnil(L);
		return 4;
	}

	struct pollfd descriptors[2] = {
		{
			.fd = sd_bus_get_fd(source->bus),
		},
		{ .fd = wake_fd, .events = POLLIN },
	};
	int bus_events = sd_bus_get_events(source->bus);
	if (descriptors[0].fd < 0 || bus_events < 0) {
		lua_pushboolean(L, false);
		lua_pushboolean(L, false);
		lua_pushboolean(L, true);
		lua_pushliteral(L, "MPRIS session bus is unavailable");
		return 4;
	}
	descriptors[0].events = (short)bus_events;
	int result;
	do {
		result = poll(descriptors, 2, poll_timeout(source->bus));
	} while (result < 0 && errno == EINTR);
	if (result < 0) {
		lua_pushboolean(L, false);
		lua_pushboolean(L, false);
		lua_pushboolean(L, true);
		lua_pushfstring(L, "MPRIS poll failed: %s", strerror(errno));
		return 4;
	}

	bool wake_ready =
		(descriptors[1].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)) != 0;
	error_message = NULL;
	processed = process_bus(source, &error_message);
	bool closed = processed < 0 ||
		      (descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0;
	bool changed = source->dirty;
	source->dirty = false;
	lua_pushboolean(L, changed);
	lua_pushboolean(L, wake_ready);
	lua_pushboolean(L, closed);
	if (error_message != NULL) {
		lua_pushstring(L, error_message);
	} else {
		lua_pushnil(L);
	}
	free(error_message);
	return 4;
}

static const char *
action_method(const char *action) {
	if (strcmp(action, "next") == 0) {
		return "Next";
	}
	if (strcmp(action, "pause") == 0) {
		return "Pause";
	}
	if (strcmp(action, "play") == 0) {
		return "Play";
	}
	if (strcmp(action, "play-pause") == 0) {
		return "PlayPause";
	}
	if (strcmp(action, "previous") == 0) {
		return "Previous";
	}
	return NULL;
}

static bool
action_available(const struct mpris_source *source, const char *action) {
	if (!source->can_control) {
		return false;
	}
	if (strcmp(action, "next") == 0) {
		return source->can_go_next;
	}
	if (strcmp(action, "pause") == 0) {
		return source->can_pause;
	}
	if (strcmp(action, "play") == 0) {
		return source->can_play;
	}
	if (strcmp(action, "play-pause") == 0) {
		return source->can_pause || source->can_play;
	}
	if (strcmp(action, "previous") == 0) {
		return source->can_go_previous;
	}
	return false;
}

static int
lsource_dispatch(lua_State *L) {
	struct mpris_source *source = check_source(L, 1);
	const char *action = luaL_checkstring(L, 2);
	const char *method = action_method(action);
	if (method == NULL) {
		return luaL_error(L, "unsupported MPRIS action: %s", action);
	}
	if (source->selected_name == NULL) {
		lua_pushnil(L);
		lua_pushliteral(L, "no MPRIS player is available");
		return 2;
	}
	if (!action_available(source, action)) {
		lua_pushnil(L);
		lua_pushfstring(
			L,
			"MPRIS player does not support action: %s",
			action);
		return 2;
	}

	sd_bus_error error = SD_BUS_ERROR_NULL;
	sd_bus_message *reply = NULL;
	int result = sd_bus_call_method(
		source->bus,
		source->selected_name,
		MPRIS_OBJECT_PATH,
		MPRIS_PLAYER_INTERFACE,
		method,
		&error,
		&reply,
		"");
	sd_bus_message_unref(reply);
	if (result < 0) {
		lua_pushnil(L);
		lua_pushstring(L, error.message == NULL
					  ? strerror(-result)
					  : error.message);
		sd_bus_error_free(&error);
		return 2;
	}
	sd_bus_error_free(&error);
	lua_pushboolean(L, true);
	return 1;
}

static int
lopen(lua_State *L) {
	struct mpris_source *source =
		lua_newuserdatauv(L, sizeof(*source), 0);
	*source = (struct mpris_source) { 0 };
	luaL_setmetatable(L, "hypringo.mpris.source");

	int result = sd_bus_open_user(&source->bus);
	if (result < 0) {
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushfstring(L, "cannot open session bus: %s", strerror(-result));
		return 2;
	}
	int bus_fd = sd_bus_get_fd(source->bus);
	if (bus_fd < 0 || set_cloexec(bus_fd) < 0) {
		int configure_error = bus_fd < 0 ? -bus_fd : errno;
		close_source(source);
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushfstring(
			L,
			"cannot configure session bus: %s",
			strerror(configure_error));
		return 2;
	}

	result = sd_bus_match_signal(
		source->bus,
		&source->name_slot,
		"org.freedesktop.DBus",
		"/org/freedesktop/DBus",
		"org.freedesktop.DBus",
		"NameOwnerChanged",
		name_owner_changed,
		source);
	if (result >= 0) {
		result = sd_bus_match_signal(
			source->bus,
			&source->properties_slot,
			NULL,
			MPRIS_OBJECT_PATH,
			"org.freedesktop.DBus.Properties",
			"PropertiesChanged",
			properties_changed,
			source);
	}
	if (result < 0) {
		close_source(source);
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushfstring(L, "cannot subscribe to MPRIS signals: %s",
				strerror(-result));
		return 2;
	}
	source->dirty = true;
	return 1;
}

int
luaopen_hypringo_mpris(lua_State *L) {
	static const luaL_Reg source_methods[] = {
		{ "close", lsource_close },
		{ "dispatch", lsource_dispatch },
		{ "snapshot", lsource_snapshot },
		{ "wait", lsource_wait },
		{ NULL, NULL },
	};
	static const luaL_Reg library[] = {
		{ "open", lopen },
		{ NULL, NULL },
	};

	if (luaL_newmetatable(L, "hypringo.mpris.source")) {
		lua_pushcfunction(L, lsource_gc);
		lua_setfield(L, -2, "__gc");
		lua_pushvalue(L, -1);
		lua_setfield(L, -2, "__index");
		luaL_setfuncs(L, source_methods, 0);
	}
	lua_pop(L, 1);

	luaL_newlib(L, library);
	return 1;
}
