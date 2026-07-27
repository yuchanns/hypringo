#include "control.h"

#include <lauxlib.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define CONTROL_MAX_CLIENTS 64
#define CONTROL_COMMAND_SIZE 128

struct control_client {
	int fd;
	bool subscribed;
	bool eww_format;
	char command[CONTROL_COMMAND_SIZE];
	size_t command_size;
};

struct control_server {
	pthread_mutex_t mutex;
	pthread_t thread;
	bool running;
	bool stopping;
	int listener;
	int wake_read;
	int wake_write;
	char *path;
	char *snapshot;
	size_t snapshot_size;
	char *eww_snapshot;
	size_t eww_snapshot_size;
};

static struct control_server server = {
	.mutex = PTHREAD_MUTEX_INITIALIZER,
	.listener = -1,
	.wake_read = -1,
	.wake_write = -1,
};

static void
close_fd(int *fd) {
	if (*fd >= 0) {
		close(*fd);
		*fd = -1;
	}
}

static int
set_nonblocking(int fd) {
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
		return -1;
	}
	return 0;
}

static int
set_cloexec(int fd) {
	int flags = fcntl(fd, F_GETFD, 0);
	if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
		return -1;
	}
	return 0;
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

static char *
copy_snapshot(bool eww_format, size_t *size) {
	pthread_mutex_lock(&server.mutex);
	const char *snapshot = eww_format ? server.eww_snapshot : server.snapshot;
	*size = eww_format ? server.eww_snapshot_size : server.snapshot_size;
	char *result = malloc(*size);
	if (result != NULL && *size > 0) {
		memcpy(result, snapshot, *size);
	}
	pthread_mutex_unlock(&server.mutex);
	return result;
}

static bool
send_snapshot(int fd, bool eww_format) {
	size_t size = 0;
	char *snapshot = copy_snapshot(eww_format, &size);
	if (snapshot == NULL && size > 0) {
		return false;
	}
	if (size == 0) {
		if (eww_format) {
			static const char empty_eww_snapshot[] = "{}\n";
			return write_all(
				fd,
				empty_eww_snapshot,
				sizeof(empty_eww_snapshot) - 1);
		}
		static const char empty_snapshot[] =
			"{\"revision\":0,\"state\":{},\"type\":\"snapshot\"}\n";
		return write_all(fd, empty_snapshot, sizeof(empty_snapshot) - 1);
	}
	bool ok = write_all(fd, snapshot, size);
	free(snapshot);
	return ok;
}

static void
remove_client(struct control_client *clients, size_t *count, size_t index) {
	close_fd(&clients[index].fd);
	clients[index] = clients[*count - 1];
	(*count)--;
}

static void
broadcast_snapshot(struct control_client *clients, size_t *count) {
	for (size_t index = 0; index < *count;) {
		if (!clients[index].subscribed ||
			send_snapshot(clients[index].fd, clients[index].eww_format)) {
			index++;
		} else {
			remove_client(clients, count, index);
		}
	}
}

static void
handle_command(struct control_client *client, bool *close_client) {
	client->command[client->command_size] = '\0';
	char *newline = strchr(client->command, '\n');
	if (newline == NULL) {
		return;
	}
	*newline = '\0';
	bool status = strcmp(client->command, "status") == 0;
	bool subscribe = strcmp(client->command, "subscribe") == 0;
	bool eww_status = strcmp(client->command, "status eww") == 0;
	bool eww_subscribe = strcmp(client->command, "subscribe eww") == 0;
	if (status || eww_status) {
		client->eww_format = eww_status;
		send_snapshot(client->fd, client->eww_format);
		*close_client = true;
		return;
	}
	if (subscribe || eww_subscribe) {
		client->eww_format = eww_subscribe;
		client->subscribed = true;
		if (!send_snapshot(client->fd, client->eww_format)) {
			*close_client = true;
		}
		return;
	}
	static const char error[] =
		"{\"type\":\"error\",\"error\":\"unknown command\"}\n";
	write_all(client->fd, error, sizeof(error) - 1);
	*close_client = true;
}

static bool
read_command(struct control_client *client) {
	while (!client->subscribed) {
		if (client->command_size >= sizeof(client->command) - 1) {
			return false;
		}
		ssize_t count = recv(
			client->fd,
			client->command + client->command_size,
			sizeof(client->command) - 1 - client->command_size,
			0);
		if (count > 0) {
			client->command_size += (size_t)count;
			bool close_client = false;
			handle_command(client, &close_client);
			if (close_client) {
				return false;
			}
			if (client->subscribed) {
				return true;
			}
			continue;
		}
		if (count == 0) {
			return false;
		}
		if (errno == EINTR) {
			continue;
		}
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			return true;
		}
		return false;
	}
	return true;
}

static void
accept_clients(struct control_client *clients, size_t *count) {
	for (;;) {
		int fd = accept(server.listener, NULL, NULL);
		if (fd < 0) {
			if (errno == EINTR) {
				continue;
			}
			return;
		}
		if (set_nonblocking(fd) < 0 || set_cloexec(fd) < 0 ||
			*count >= CONTROL_MAX_CLIENTS) {
			close(fd);
			continue;
		}
		clients[*count] = (struct control_client) {
			.fd = fd,
		};
		(*count)++;
	}
}

static bool
is_stopping(void) {
	pthread_mutex_lock(&server.mutex);
	bool stopping = server.stopping;
	pthread_mutex_unlock(&server.mutex);
	return stopping;
}

static void
drain_wake_pipe(void) {
	char buffer[64];
	while (read(server.wake_read, buffer, sizeof(buffer)) > 0) {
	}
}

static void *
control_thread(void *unused) {
	(void)unused;
	struct control_client clients[CONTROL_MAX_CLIENTS] = { 0 };
	size_t client_count = 0;

	while (!is_stopping()) {
		size_t polled_client_count = client_count;
		struct pollfd pollfds[2 + CONTROL_MAX_CLIENTS] = {
			{ .fd = server.listener, .events = POLLIN },
			{ .fd = server.wake_read, .events = POLLIN },
		};
		for (size_t index = 0; index < polled_client_count; index++) {
			pollfds[index + 2] = (struct pollfd) {
				.fd = clients[index].fd,
				.events = clients[index].subscribed ? 0 : POLLIN,
			};
		}

		int result = poll(pollfds, (nfds_t)(2 + polled_client_count), -1);
		if (result < 0) {
			if (errno == EINTR) {
				continue;
			}
			break;
		}
		bool should_broadcast = false;
		if (pollfds[1].revents & POLLIN) {
			drain_wake_pipe();
			should_broadcast = !is_stopping();
		}
		for (size_t index = polled_client_count; index > 0; index--) {
			size_t client_index = index - 1;
			short events = pollfds[client_index + 2].revents;
			if (events & (POLLERR | POLLHUP | POLLNVAL)) {
				remove_client(clients, &client_count, client_index);
			} else if ((events & POLLIN) &&
				!read_command(&clients[client_index])) {
				remove_client(clients, &client_count, client_index);
			}
		}
		if (pollfds[0].revents & POLLIN) {
			accept_clients(clients, &client_count);
		}
		if (should_broadcast) {
			broadcast_snapshot(clients, &client_count);
		}
	}

	while (client_count > 0) {
		remove_client(clients, &client_count, client_count - 1);
	}
	return NULL;
}

static int
connect_socket(const char *path) {
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		return -1;
	}
	if (set_cloexec(fd) < 0) {
		int configure_error = errno;
		close(fd);
		errno = configure_error;
		return -1;
	}
	struct sockaddr_un address = { .sun_family = AF_UNIX };
	if (strlen(path) >= sizeof(address.sun_path)) {
		close(fd);
		errno = ENAMETOOLONG;
		return -1;
	}
	strcpy(address.sun_path, path);
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
		int connect_error = errno;
		close(fd);
		errno = connect_error;
		return -1;
	}
	return fd;
}

static int
prepare_socket(lua_State *L, const char *path) {
	struct stat stat_buffer;
	if (lstat(path, &stat_buffer) == 0) {
		if (!S_ISSOCK(stat_buffer.st_mode)) {
			return luaL_error(L, "control socket path exists and is not a socket: %s", path);
		}
		int existing = connect_socket(path);
		if (existing >= 0) {
			close(existing);
			return luaL_error(L, "another Hypringo instance is listening on %s", path);
		}
		int connect_error = errno;
		if (connect_error != ECONNREFUSED && connect_error != ENOENT) {
			return luaL_error(
				L,
				"cannot verify existing control socket %s: %s",
				path,
				strerror(connect_error));
		}
		if (unlink(path) < 0) {
			return luaL_error(L, "cannot remove stale control socket %s: %s", path, strerror(errno));
		}
	} else if (errno != ENOENT) {
		return luaL_error(L, "cannot inspect control socket %s: %s", path, strerror(errno));
	}

	int listener = socket(AF_UNIX, SOCK_STREAM, 0);
	if (listener < 0) {
		return luaL_error(L, "cannot create control socket: %s", strerror(errno));
	}
	if (set_nonblocking(listener) < 0 || set_cloexec(listener) < 0) {
		close(listener);
		return luaL_error(L, "cannot configure control socket: %s", strerror(errno));
	}
	struct sockaddr_un address = { .sun_family = AF_UNIX };
	if (strlen(path) >= sizeof(address.sun_path)) {
		close(listener);
		return luaL_error(L, "control socket path is too long: %s", path);
	}
	strcpy(address.sun_path, path);
	if (bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0) {
		int bind_error = errno;
		close(listener);
		return luaL_error(L, "cannot bind control socket %s: %s", path, strerror(bind_error));
	}
	if (chmod(path, S_IRUSR | S_IWUSR) < 0 || listen(listener, 32) < 0) {
		int listen_error = errno;
		close(listener);
		unlink(path);
		return luaL_error(L, "cannot listen on control socket %s: %s", path, strerror(listen_error));
	}
	return listener;
}

static int
lstart(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	pthread_mutex_lock(&server.mutex);
	bool running = server.running;
	pthread_mutex_unlock(&server.mutex);
	if (running) {
		return luaL_error(L, "control server is already running");
	}

	int listener = prepare_socket(L, path);
	int wake_pipe[2];
	if (pipe(wake_pipe) < 0) {
		close(listener);
		unlink(path);
		return luaL_error(L, "cannot create control wake pipe: %s", strerror(errno));
	}
	if (set_nonblocking(wake_pipe[0]) < 0 || set_nonblocking(wake_pipe[1]) < 0 ||
		set_cloexec(wake_pipe[0]) < 0 || set_cloexec(wake_pipe[1]) < 0) {
		close(listener);
		close(wake_pipe[0]);
		close(wake_pipe[1]);
		unlink(path);
		return luaL_error(L, "cannot configure control wake pipe: %s", strerror(errno));
	}

	pthread_mutex_lock(&server.mutex);
	server.listener = listener;
	server.wake_read = wake_pipe[0];
	server.wake_write = wake_pipe[1];
	server.path = strdup(path);
	server.stopping = false;
	server.running = true;
	pthread_mutex_unlock(&server.mutex);

	if (server.path == NULL || pthread_create(&server.thread, NULL, control_thread, NULL) != 0) {
		pthread_mutex_lock(&server.mutex);
		server.running = false;
		server.stopping = true;
		free(server.path);
		server.path = NULL;
		pthread_mutex_unlock(&server.mutex);
		close_fd(&server.listener);
		close_fd(&server.wake_read);
		close_fd(&server.wake_write);
		unlink(path);
		return luaL_error(L, "cannot start control server thread");
	}
	return 0;
}

static int
lpublish(lua_State *L) {
	size_t snapshot_size = 0;
	size_t eww_snapshot_size = 0;
	const char *snapshot = luaL_checklstring(L, 1, &snapshot_size);
	const char *eww_snapshot = luaL_checklstring(L, 2, &eww_snapshot_size);
	char *snapshot_copy = malloc(snapshot_size);
	char *eww_snapshot_copy = malloc(eww_snapshot_size);
	if (snapshot_copy == NULL || eww_snapshot_copy == NULL) {
		free(snapshot_copy);
		free(eww_snapshot_copy);
		return luaL_error(L, "cannot allocate control snapshot");
	}
	memcpy(snapshot_copy, snapshot, snapshot_size);
	memcpy(eww_snapshot_copy, eww_snapshot, eww_snapshot_size);

	pthread_mutex_lock(&server.mutex);
	if (!server.running || server.stopping) {
		pthread_mutex_unlock(&server.mutex);
		free(snapshot_copy);
		free(eww_snapshot_copy);
		return luaL_error(L, "control server is not running");
	}
	free(server.snapshot);
	free(server.eww_snapshot);
	server.snapshot = snapshot_copy;
	server.snapshot_size = snapshot_size;
	server.eww_snapshot = eww_snapshot_copy;
	server.eww_snapshot_size = eww_snapshot_size;
	int wake_write = server.wake_write;
	pthread_mutex_unlock(&server.mutex);

	char byte = 1;
	ssize_t ignored = write(wake_write, &byte, 1);
	(void)ignored;
	return 0;
}

static int
lstop(lua_State *L) {
	(void)L;
	pthread_mutex_lock(&server.mutex);
	if (!server.running) {
		pthread_mutex_unlock(&server.mutex);
		return 0;
	}
	server.stopping = true;
	int wake_write = server.wake_write;
	pthread_mutex_unlock(&server.mutex);

	char byte = 1;
	ssize_t ignored = write(wake_write, &byte, 1);
	(void)ignored;
	pthread_join(server.thread, NULL);

	pthread_mutex_lock(&server.mutex);
	char *path = server.path;
	server.path = NULL;
	server.running = false;
	free(server.snapshot);
	server.snapshot = NULL;
	server.snapshot_size = 0;
	free(server.eww_snapshot);
	server.eww_snapshot = NULL;
	server.eww_snapshot_size = 0;
	close_fd(&server.listener);
	close_fd(&server.wake_read);
	close_fd(&server.wake_write);
	pthread_mutex_unlock(&server.mutex);
	if (path != NULL) {
		unlink(path);
		free(path);
	}
	return 0;
}

static int
lrequest(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	const char *command = luaL_checkstring(L, 2);
	if (strcmp(command, "status") != 0 &&
		strcmp(command, "subscribe") != 0 &&
		strcmp(command, "status eww") != 0 &&
		strcmp(command, "subscribe eww") != 0) {
		return luaL_error(L, "unsupported control command: %s", command);
	}
	int fd = connect_socket(path);
	if (fd < 0) {
		return luaL_error(L, "cannot connect to control socket %s: %s", path, strerror(errno));
	}
	if (!write_all(fd, command, strlen(command)) || !write_all(fd, "\n", 1)) {
		int write_error = errno;
		close(fd);
		return luaL_error(L, "cannot write control command: %s", strerror(write_error));
	}

	char buffer[4096];
	for (;;) {
		ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
		if (count > 0) {
			size_t offset = 0;
			while (offset < (size_t)count) {
				ssize_t written = write(STDOUT_FILENO, buffer + offset, (size_t)count - offset);
				if (written > 0) {
					offset += (size_t)written;
				} else if (written < 0 && errno == EINTR) {
					continue;
				} else {
					close(fd);
					return luaL_error(L, "cannot write control response: %s", strerror(errno));
				}
			}
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
		return luaL_error(L, "cannot read control response: %s", strerror(read_error));
	}
	close(fd);
	return 0;
}

int
luaopen_hypringo_control(lua_State *L) {
	static const luaL_Reg library[] = {
		{ "publish", lpublish },
		{ "request", lrequest },
		{ "start", lstart },
		{ "stop", lstop },
		{ NULL, NULL },
	};
	luaL_newlib(L, library);
	return 1;
}
