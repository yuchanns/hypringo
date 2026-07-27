#include "audio.h"

#include <lauxlib.h>
#include <pulse/pulseaudio.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define AUDIO_NAME_CAPACITY 256
#define AUDIO_ERROR_CAPACITY 256

struct audio_source {
	pa_context *context;
	pa_threaded_mainloop *mainloop;
	int notify_fds[2];
	char error[AUDIO_ERROR_CAPACITY];
	char sink[AUDIO_NAME_CAPACITY];
	pa_cvolume volume;
	bool available;
	bool connected;
	bool dirty;
	bool mainloop_started;
	bool muted;
};

static struct audio_source *
check_source(lua_State *L, int index) {
	return luaL_checkudata(L, index, "hypringo.audio.source");
}

static void
set_error(struct audio_source *source, const char *message) {
	snprintf(
		source->error,
		sizeof(source->error),
		"%s",
		message == NULL ? "" : message);
}

static void
set_context_error(struct audio_source *source, const char *prefix) {
	const char *message =
		source->context == NULL
			? "PulseAudio context is unavailable"
			: pa_strerror(pa_context_errno(source->context));
	snprintf(
		source->error,
		sizeof(source->error),
		"%s: %s",
		prefix,
		message);
}

static void
reset_snapshot(struct audio_source *source) {
	source->available = false;
	source->muted = false;
	source->sink[0] = '\0';
	pa_cvolume_set(&source->volume, 2, PA_VOLUME_MUTED);
}

static void
notify(struct audio_source *source) {
	source->dirty = true;
	if (source->notify_fds[1] < 0) {
		return;
	}
	char byte = 1;
	ssize_t result;
	do {
		result = write(source->notify_fds[1], &byte, sizeof(byte));
	} while (result < 0 && errno == EINTR);
}

static void request_server_info(struct audio_source *source);

static void
sink_info(
	pa_context *context,
	const pa_sink_info *info,
	int eol,
	void *userdata) {
	(void)context;
	struct audio_source *source = userdata;
	if (eol < 0) {
		reset_snapshot(source);
		set_context_error(source, "cannot read default sink");
		notify(source);
		return;
	}
	if (eol > 0 || info == NULL) {
		return;
	}
	snprintf(source->sink, sizeof(source->sink), "%s", info->name);
	source->volume = info->volume;
	source->muted = info->mute != 0;
	source->available = true;
	set_error(source, "");
	notify(source);
}

static void
request_sink_info(struct audio_source *source) {
	if (source->sink[0] == '\0') {
		reset_snapshot(source);
		set_error(source, "no default audio sink is available");
		notify(source);
		return;
	}
	pa_operation *operation = pa_context_get_sink_info_by_name(
		source->context,
		source->sink,
		sink_info,
		source);
	if (operation == NULL) {
		reset_snapshot(source);
		set_context_error(source, "cannot request default sink");
		notify(source);
		return;
	}
	pa_operation_unref(operation);
}

static void
server_info(
	pa_context *context,
	const pa_server_info *info,
	void *userdata) {
	(void)context;
	struct audio_source *source = userdata;
	if (info == NULL || info->default_sink_name == NULL) {
		reset_snapshot(source);
		set_error(source, "no default audio sink is available");
		notify(source);
		return;
	}
	snprintf(
		source->sink,
		sizeof(source->sink),
		"%s",
		info->default_sink_name);
	request_sink_info(source);
}

static void
request_server_info(struct audio_source *source) {
	pa_operation *operation =
		pa_context_get_server_info(source->context, server_info, source);
	if (operation == NULL) {
		reset_snapshot(source);
		set_context_error(source, "cannot request audio server");
		notify(source);
		return;
	}
	pa_operation_unref(operation);
}

static void
subscribe_event(
	pa_context *context,
	pa_subscription_event_type_t event_type,
	uint32_t index,
	void *userdata) {
	(void)context;
	(void)index;
	struct audio_source *source = userdata;
	pa_subscription_event_type_t facility =
		event_type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
	if (facility == PA_SUBSCRIPTION_EVENT_SERVER ||
	    facility == PA_SUBSCRIPTION_EVENT_SINK) {
		request_server_info(source);
	}
}

static void
subscribe_complete(
	pa_context *context,
	int success,
	void *userdata) {
	struct audio_source *source = userdata;
	if (!success) {
		set_context_error(source, "cannot subscribe to audio events");
		notify(source);
	}
	pa_threaded_mainloop_signal(source->mainloop, 0);
	(void)context;
}

static void
context_state_changed(pa_context *context, void *userdata) {
	struct audio_source *source = userdata;
	pa_context_state_t state = pa_context_get_state(context);
	switch (state) {
	case PA_CONTEXT_READY: {
		source->connected = true;
		set_error(source, "");
		pa_context_set_subscribe_callback(
			context,
			subscribe_event,
			source);
		pa_operation *operation = pa_context_subscribe(
			context,
			PA_SUBSCRIPTION_MASK_SERVER |
				PA_SUBSCRIPTION_MASK_SINK,
			subscribe_complete,
			source);
		if (operation == NULL) {
			set_context_error(source, "cannot subscribe to audio events");
			notify(source);
		} else {
			pa_operation_unref(operation);
		}
		request_server_info(source);
		break;
	}
	case PA_CONTEXT_FAILED:
		reset_snapshot(source);
		source->connected = false;
		set_context_error(source, "audio server connection failed");
		notify(source);
		break;
	case PA_CONTEXT_TERMINATED:
		reset_snapshot(source);
		source->connected = false;
		set_error(source, "audio server connection terminated");
		notify(source);
		break;
	default:
		break;
	}
	pa_threaded_mainloop_signal(source->mainloop, 0);
}

static void
close_source(struct audio_source *source) {
	if (source->mainloop != NULL) {
		if (source->context != NULL) {
			if (source->mainloop_started) {
				pa_threaded_mainloop_lock(source->mainloop);
			}
			pa_context_set_state_callback(source->context, NULL, NULL);
			pa_context_set_subscribe_callback(source->context, NULL, NULL);
			pa_context_disconnect(source->context);
			if (source->mainloop_started) {
				pa_threaded_mainloop_unlock(source->mainloop);
			}
		}
		if (source->mainloop_started) {
			pa_threaded_mainloop_stop(source->mainloop);
			source->mainloop_started = false;
		}
	}
	if (source->context != NULL) {
		pa_context_unref(source->context);
		source->context = NULL;
	}
	if (source->mainloop != NULL) {
		pa_threaded_mainloop_free(source->mainloop);
		source->mainloop = NULL;
	}
	for (size_t index = 0; index < 2; index++) {
		if (source->notify_fds[index] >= 0) {
			close(source->notify_fds[index]);
			source->notify_fds[index] = -1;
		}
	}
	source->available = false;
	source->connected = false;
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

static int
lsource_snapshot(lua_State *L) {
	struct audio_source *source = check_source(L, 1);
	if (source->mainloop == NULL) {
		return luaL_error(L, "audio source is closed");
	}
	pa_threaded_mainloop_lock(source->mainloop);
	bool available = source->available;
	bool connected = source->connected;
	bool muted = source->muted;
	uint32_t volume = available
				  ? pa_cvolume_avg(&source->volume)
				  : PA_VOLUME_MUTED;
	char error[AUDIO_ERROR_CAPACITY];
	char sink[AUDIO_NAME_CAPACITY];
	snprintf(error, sizeof(error), "%s", source->error);
	snprintf(sink, sizeof(sink), "%s", source->sink);
	source->dirty = false;
	pa_threaded_mainloop_unlock(source->mainloop);

	unsigned int percent = (unsigned int)(
		((uint64_t)volume * 100 + PA_VOLUME_NORM / 2) /
		PA_VOLUME_NORM);
	lua_createtable(L, 0, 6);
	lua_pushboolean(L, available);
	lua_setfield(L, -2, "available");
	lua_pushboolean(L, connected);
	lua_setfield(L, -2, "connected");
	lua_pushstring(L, error);
	lua_setfield(L, -2, "error");
	lua_pushboolean(L, muted);
	lua_setfield(L, -2, "muted");
	lua_pushstring(L, sink);
	lua_setfield(L, -2, "sink");
	lua_pushinteger(L, percent);
	lua_setfield(L, -2, "volume");
	return 1;
}

static void
drain_notifications(int fd) {
	char buffer[64];
	for (;;) {
		ssize_t result = read(fd, buffer, sizeof(buffer));
		if (result > 0) {
			continue;
		}
		if (result < 0 && errno == EINTR) {
			continue;
		}
		break;
	}
}

static int
lsource_wait(lua_State *L) {
	struct audio_source *source = check_source(L, 1);
	if (!lua_islightuserdata(L, 2)) {
		return luaL_typeerror(L, 2, "lightuserdata");
	}
	int wake_fd = (int)(intptr_t)lua_touserdata(L, 2);
	if (source->mainloop == NULL) {
		return luaL_error(L, "audio source is closed");
	}
	struct pollfd descriptors[2] = {
		{ .fd = source->notify_fds[0], .events = POLLIN },
		{ .fd = wake_fd, .events = POLLIN },
	};
	int result;
	do {
		result = poll(descriptors, 2, -1);
	} while (result < 0 && errno == EINTR);
	if (result < 0) {
		return luaL_error(L, "audio poll failed: %s", strerror(errno));
	}
	bool changed =
		(descriptors[0].revents &
		 (POLLIN | POLLERR | POLLHUP | POLLNVAL)) != 0;
	bool wake_ready =
		(descriptors[1].revents &
		 (POLLIN | POLLERR | POLLHUP | POLLNVAL)) != 0;
	if (changed) {
		drain_notifications(source->notify_fds[0]);
	}
	pa_threaded_mainloop_lock(source->mainloop);
	bool closed = !source->connected &&
		      (pa_context_get_state(source->context) ==
			       PA_CONTEXT_FAILED ||
		       pa_context_get_state(source->context) ==
			       PA_CONTEXT_TERMINATED);
	char error[AUDIO_ERROR_CAPACITY];
	snprintf(error, sizeof(error), "%s", source->error);
	pa_threaded_mainloop_unlock(source->mainloop);
	lua_pushboolean(L, changed);
	lua_pushboolean(L, wake_ready);
	lua_pushboolean(L, closed);
	if (error[0] == '\0') {
		lua_pushnil(L);
	} else {
		lua_pushstring(L, error);
	}
	return 4;
}

static int
lsource_dispatch(lua_State *L) {
	struct audio_source *source = check_source(L, 1);
	const char *action = luaL_checkstring(L, 2);
	lua_Integer requested_volume = 0;
	bool requested_mute = false;
	enum {
		AUDIO_ACTION_VOLUME,
		AUDIO_ACTION_MUTE,
	} action_type;
	if (strcmp(action, "set-volume") == 0) {
		requested_volume = luaL_checkinteger(L, 3);
		if (requested_volume < 0 || requested_volume > 100) {
			return luaL_error(
				L,
				"audio volume must be between 0 and 100");
		}
		action_type = AUDIO_ACTION_VOLUME;
	} else if (strcmp(action, "set-mute") == 0) {
		luaL_checktype(L, 3, LUA_TBOOLEAN);
		requested_mute = lua_toboolean(L, 3);
		action_type = AUDIO_ACTION_MUTE;
	} else if (strcmp(action, "toggle-mute") == 0) {
		action_type = AUDIO_ACTION_MUTE;
	} else {
		return luaL_error(L, "unsupported audio action: %s", action);
	}
	if (source->mainloop == NULL) {
		lua_pushnil(L);
		lua_pushliteral(L, "audio source is closed");
		return 2;
	}

	pa_threaded_mainloop_lock(source->mainloop);
	if (!source->available || source->sink[0] == '\0') {
		pa_threaded_mainloop_unlock(source->mainloop);
		lua_pushnil(L);
		lua_pushliteral(L, "no default audio sink is available");
		return 2;
	}
	pa_operation *operation = NULL;
	if (action_type == AUDIO_ACTION_VOLUME) {
		pa_cvolume volume;
		pa_cvolume_set(
			&volume,
			source->volume.channels == 0
				? 2
				: source->volume.channels,
			(pa_volume_t)(
				(uint64_t)requested_volume *
				PA_VOLUME_NORM /
				100));
		operation = pa_context_set_sink_volume_by_name(
			source->context,
			source->sink,
			&volume,
			NULL,
			NULL);
	} else {
		bool muted = strcmp(action, "toggle-mute") == 0
				     ? !source->muted
				     : requested_mute;
		operation = pa_context_set_sink_mute_by_name(
			source->context,
			source->sink,
			muted,
			NULL,
			NULL);
	}
	if (operation != NULL) {
		pa_operation_unref(operation);
	}
	if (operation == NULL) {
		set_context_error(source, "cannot dispatch audio action");
	}
	char error[AUDIO_ERROR_CAPACITY];
	snprintf(error, sizeof(error), "%s", source->error);
	pa_threaded_mainloop_unlock(source->mainloop);
	if (operation == NULL) {
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	lua_pushboolean(L, true);
	return 1;
}

static int
lopen(lua_State *L) {
	struct audio_source *source =
		lua_newuserdatauv(L, sizeof(*source), 0);
	*source = (struct audio_source) {
		.notify_fds = { -1, -1 },
	};
	luaL_setmetatable(L, "hypringo.audio.source");

	if (pipe2(source->notify_fds, O_CLOEXEC | O_NONBLOCK) < 0) {
		int pipe_error = errno;
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushfstring(
			L,
			"cannot create audio notification pipe: %s",
			strerror(pipe_error));
		return 2;
	}
	source->mainloop = pa_threaded_mainloop_new();
	if (source->mainloop == NULL) {
		close_source(source);
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushliteral(L, "cannot create PulseAudio mainloop");
		return 2;
	}
	pa_mainloop_api *api =
		pa_threaded_mainloop_get_api(source->mainloop);
	source->context = pa_context_new(api, "hypringo");
	if (source->context == NULL) {
		close_source(source);
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushliteral(L, "cannot create PulseAudio context");
		return 2;
	}
	pa_context_set_state_callback(
		source->context,
		context_state_changed,
		source);
	if (pa_context_connect(
		    source->context,
		    NULL,
		    PA_CONTEXT_NOAUTOSPAWN,
		    NULL) < 0) {
		set_context_error(source, "cannot connect to audio server");
		char error[AUDIO_ERROR_CAPACITY];
		snprintf(error, sizeof(error), "%s", source->error);
		close_source(source);
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	if (pa_threaded_mainloop_start(source->mainloop) < 0) {
		close_source(source);
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushliteral(L, "cannot start PulseAudio mainloop");
		return 2;
	}
	source->mainloop_started = true;

	pa_threaded_mainloop_lock(source->mainloop);
	for (;;) {
		pa_context_state_t state =
			pa_context_get_state(source->context);
		if (state == PA_CONTEXT_READY) {
			break;
		}
		if (!PA_CONTEXT_IS_GOOD(state)) {
			char error[AUDIO_ERROR_CAPACITY];
			set_context_error(source, "cannot connect to audio server");
			snprintf(error, sizeof(error), "%s", source->error);
			pa_threaded_mainloop_unlock(source->mainloop);
			close_source(source);
			lua_pop(L, 1);
			lua_pushnil(L);
			lua_pushstring(L, error);
			return 2;
		}
		pa_threaded_mainloop_wait(source->mainloop);
	}
	pa_threaded_mainloop_unlock(source->mainloop);
	return 1;
}

int
luaopen_hypringo_audio(lua_State *L) {
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

	if (luaL_newmetatable(L, "hypringo.audio.source")) {
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
