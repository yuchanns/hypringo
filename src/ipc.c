#include "ipc.h"

#include <lauxlib.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define IPC_BUFFER_SIZE 65536
#define IPC_MAX_RESPONSE_SIZE (16 * 1024 * 1024)

struct ipc_stream {
	int fd;
};

static int
set_cloexec(int fd) {
	int flags = fcntl(fd, F_GETFD, 0);
	if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
		return -1;
	}
	return 0;
}

static int
connect_socket(const char *path) {
	if (path[0] != '/') {
		errno = EINVAL;
		return -1;
	}

	struct sockaddr_un address = { .sun_family = AF_UNIX };
	size_t path_size = strlen(path);
	if (path_size >= sizeof(address.sun_path)) {
		errno = ENAMETOOLONG;
		return -1;
	}
	memcpy(address.sun_path, path, path_size + 1);

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		return -1;
	}
	if (set_cloexec(fd) < 0 ||
		connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
		int connect_error = errno;
		close(fd);
		errno = connect_error;
		return -1;
	}
	return fd;
}

static bool
write_all(int fd, const char *data, size_t size) {
	while (size > 0) {
		ssize_t written = send(fd, data, size, MSG_NOSIGNAL);
		if (written > 0) {
			data += written;
			size -= (size_t)written;
			continue;
		}
		if (written < 0 && errno == EINTR) {
			continue;
		}
		return false;
	}
	return true;
}

static int
push_error(lua_State *L, const char *operation) {
	lua_pushnil(L);
	lua_pushfstring(L, "%s: %s", operation, strerror(errno));
	return 2;
}

static int
lrequest(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	size_t payload_size = 0;
	const char *payload = luaL_checklstring(L, 2, &payload_size);

	int fd = connect_socket(path);
	if (fd < 0) {
		return push_error(L, "connect failed");
	}
	if (!write_all(fd, payload, payload_size)) {
		int write_error = errno;
		close(fd);
		errno = write_error;
		return push_error(L, "write failed");
	}
	if (shutdown(fd, SHUT_WR) < 0 && errno != ENOTCONN) {
		int shutdown_error = errno;
		close(fd);
		errno = shutdown_error;
		return push_error(L, "shutdown failed");
	}

	luaL_Buffer buffer;
	luaL_buffinit(L, &buffer);
	size_t response_size = 0;
	for (;;) {
		char chunk[IPC_BUFFER_SIZE];
		ssize_t count = recv(fd, chunk, sizeof(chunk), 0);
		if (count > 0) {
			response_size += (size_t)count;
			if (response_size > IPC_MAX_RESPONSE_SIZE) {
				close(fd);
				return luaL_error(
					L,
					"IPC response exceeds %d bytes",
					IPC_MAX_RESPONSE_SIZE);
			}
			luaL_addlstring(&buffer, chunk, (size_t)count);
			continue;
		}
		if (count == 0) {
			break;
		}
		if (errno == EINTR) {
			continue;
		}
		int read_error = errno;
		close(fd);
		errno = read_error;
		return push_error(L, "read failed");
	}
	close(fd);
	luaL_pushresult(&buffer);
	return 1;
}

static struct ipc_stream *
check_stream(lua_State *L, int index) {
	return luaL_checkudata(L, index, "hypringo.ipc.stream");
}

static void
close_stream(struct ipc_stream *stream) {
	if (stream->fd >= 0) {
		close(stream->fd);
		stream->fd = -1;
	}
}

static int
lstream_close(lua_State *L) {
	struct ipc_stream *stream = check_stream(L, 1);
	close_stream(stream);
	return 0;
}

static int
lstream_gc(lua_State *L) {
	struct ipc_stream *stream = check_stream(L, 1);
	close_stream(stream);
	return 0;
}

static int
lstream_wait(lua_State *L) {
	struct ipc_stream *stream = check_stream(L, 1);
	if (stream->fd < 0) {
		return luaL_error(L, "IPC stream is closed");
	}
	if (!lua_islightuserdata(L, 2)) {
		return luaL_typeerror(L, 2, "lightuserdata");
	}
	int wake_fd = (int)(intptr_t)lua_touserdata(L, 2);
	int timeout = (int)luaL_optinteger(L, 3, -1);
	if (timeout < -1) {
		return luaL_argerror(L, 3, "timeout must be -1 or a non-negative number");
	}

	struct pollfd fds[2] = {
		{ .fd = stream->fd, .events = POLLIN },
		{ .fd = wake_fd, .events = POLLIN },
	};
	int result;
	do {
		result = poll(fds, 2, timeout);
	} while (result < 0 && errno == EINTR);
	if (result < 0) {
		lua_pushnil(L);
		lua_pushboolean(L, false);
		lua_pushboolean(L, false);
		lua_pushfstring(L, "poll failed: %s", strerror(errno));
		return 4;
	}

	bool wake_ready = (fds[1].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)) != 0;
	bool stream_closed = false;
	const char *error_message = NULL;
	ssize_t count = -1;
	char chunk[IPC_BUFFER_SIZE];
	if (fds[0].revents & POLLIN) {
		do {
			count = recv(stream->fd, chunk, sizeof(chunk), MSG_DONTWAIT);
		} while (count < 0 && errno == EINTR);
		if (count == 0) {
			stream_closed = true;
		} else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
			error_message = strerror(errno);
			stream_closed = true;
		}
	} else if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
		stream_closed = true;
	}

	if (count > 0) {
		lua_pushlstring(L, chunk, (size_t)count);
	} else {
		lua_pushnil(L);
	}
	lua_pushboolean(L, wake_ready);
	lua_pushboolean(L, stream_closed);
	if (error_message != NULL) {
		lua_pushfstring(L, "read failed: %s", error_message);
	} else {
		lua_pushnil(L);
	}
	return 4;
}

static int
lconnect(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	int fd = connect_socket(path);
	if (fd < 0) {
		return push_error(L, "connect failed");
	}

	struct ipc_stream *stream = lua_newuserdatauv(L, sizeof(*stream), 0);
	stream->fd = fd;
	luaL_setmetatable(L, "hypringo.ipc.stream");
	return 1;
}

static int
lwait_wakeup(lua_State *L) {
	if (!lua_islightuserdata(L, 1)) {
		return luaL_typeerror(L, 1, "lightuserdata");
	}
	int wake_fd = (int)(intptr_t)lua_touserdata(L, 1);
	int timeout = (int)luaL_checkinteger(L, 2);
	if (timeout < 0) {
		return luaL_argerror(L, 2, "timeout must be non-negative");
	}

	struct pollfd fd = {
		.fd = wake_fd,
		.events = POLLIN,
	};
	int result;
	do {
		result = poll(&fd, 1, timeout);
	} while (result < 0 && errno == EINTR);
	if (result < 0) {
		lua_pushnil(L);
		lua_pushfstring(L, "poll failed: %s", strerror(errno));
		return 2;
	}
	lua_pushboolean(L, result > 0);
	return 1;
}

int
luaopen_hypringo_ipc(lua_State *L) {
	static const luaL_Reg stream_methods[] = {
		{ "close", lstream_close },
		{ "wait", lstream_wait },
		{ NULL, NULL },
	};
	static const luaL_Reg library[] = {
		{ "connect", lconnect },
		{ "request", lrequest },
		{ "wait_wakeup", lwait_wakeup },
		{ NULL, NULL },
	};

	if (luaL_newmetatable(L, "hypringo.ipc.stream")) {
		lua_pushcfunction(L, lstream_gc);
		lua_setfield(L, -2, "__gc");
		lua_pushvalue(L, -1);
		lua_setfield(L, -2, "__index");
		luaL_setfuncs(L, stream_methods, 0);
	}
	lua_pop(L, 1);

	luaL_newlib(L, library);
	return 1;
}
