#include "fs.h"

#include <lauxlib.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define MAX_PROCESS_FILE_SIZE (1024 * 1024)
#define MAX_PROCESS_ARGUMENTS 4096
#define MAX_PATH_COMPONENTS 256

extern char **environ;

static int
push_error(lua_State *L, const char *operation) {
	lua_pushnil(L);
	lua_pushfstring(L, "%s: %s", operation, strerror(errno));
	return 2;
}

static bool
format_proc_path(char *path, size_t size, lua_Integer pid, const char *name) {
	int written = snprintf(path, size, "/proc/%lld/%s", (long long)pid, name);
	return written > 0 && (size_t)written < size;
}

static bool
read_file(const char *path, char **data_pointer, size_t *size_pointer) {
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		return false;
	}

	char *data = NULL;
	size_t size = 0;
	for (;;) {
		if (size == MAX_PROCESS_FILE_SIZE) {
			free(data);
			close(fd);
			errno = EFBIG;
			return false;
		}
		size_t capacity = size + 4096;
		if (capacity > MAX_PROCESS_FILE_SIZE) {
			capacity = MAX_PROCESS_FILE_SIZE;
		}
		char *resized = realloc(data, capacity + 1);
		if (resized == NULL) {
			free(data);
			close(fd);
			errno = ENOMEM;
			return false;
		}
		data = resized;
		ssize_t count = read(fd, data + size, capacity - size);
		if (count > 0) {
			size += (size_t)count;
			data[size] = '\0';
			continue;
		}
		if (count == 0) {
			break;
		}
		if (errno == EINTR) {
			continue;
		}
		int read_error = errno;
		free(data);
		close(fd);
		errno = read_error;
		return false;
	}
	close(fd);
	*data_pointer = data;
	*size_pointer = size;
	return true;
}

static bool
read_link(const char *path, char *buffer, size_t size) {
	ssize_t length = readlink(path, buffer, size - 1);
	if (length < 0) {
		return false;
	}
	if ((size_t)length >= size - 1) {
		errno = ENAMETOOLONG;
		return false;
	}
	buffer[length] = '\0';
	return true;
}

static bool
read_parent_pid(const char *path, lua_Integer *parent_pid) {
	char *data = NULL;
	size_t size = 0;
	if (!read_file(path, &data, &size)) {
		return false;
	}
	const char *marker = strstr(data, "PPid:");
	if (marker == NULL) {
		free(data);
		errno = EINVAL;
		return false;
	}
	char *end = NULL;
	long long value = strtoll(marker + 5, &end, 10);
	if (end == marker + 5 || value < 0) {
		free(data);
		errno = EINVAL;
		return false;
	}
	free(data);
	*parent_pid = (lua_Integer)value;
	return true;
}

static void
push_argv(lua_State *L, const char *data, size_t size) {
	lua_createtable(L, 8, 0);
	size_t start = 0;
	int index = 1;
	while (start < size && index <= MAX_PROCESS_ARGUMENTS) {
		size_t end = start;
		while (end < size && data[end] != '\0') {
			end++;
		}
		if (end > start) {
			lua_pushlstring(L, data + start, end - start);
			lua_rawseti(L, -2, index++);
		}
		start = end + 1;
	}
}

static int
lprocess(lua_State *L) {
	lua_Integer pid = luaL_checkinteger(L, 1);
	if (pid <= 0) {
		return luaL_argerror(L, 1, "pid must be positive");
	}

	char exe_path[64];
	char cwd_path[64];
	char cmdline_path[64];
	char status_path[64];
	if (!format_proc_path(exe_path, sizeof(exe_path), pid, "exe") ||
		!format_proc_path(cwd_path, sizeof(cwd_path), pid, "cwd") ||
		!format_proc_path(cmdline_path, sizeof(cmdline_path), pid, "cmdline") ||
		!format_proc_path(status_path, sizeof(status_path), pid, "status")) {
		errno = EINVAL;
		return push_error(L, "format process path failed");
	}

	char executable[PATH_MAX];
	if (!read_link(exe_path, executable, sizeof(executable))) {
		return push_error(L, "read process executable failed");
	}
	char cwd[PATH_MAX] = "";
	if (!read_link(cwd_path, cwd, sizeof(cwd))) {
		if (errno != ENOENT && errno != EACCES && errno != ESRCH) {
			return push_error(L, "read process cwd failed");
		}
		errno = 0;
	}
	char *cmdline = NULL;
	size_t cmdline_size = 0;
	if (!read_file(cmdline_path, &cmdline, &cmdline_size)) {
		return push_error(L, "read process command line failed");
	}
	lua_Integer parent_pid = 0;
	if (!read_parent_pid(status_path, &parent_pid)) {
		free(cmdline);
		return push_error(L, "read process parent failed");
	}

	lua_createtable(L, 0, 4);
	lua_pushstring(L, executable);
	lua_setfield(L, -2, "exe");
	lua_pushstring(L, cwd);
	lua_setfield(L, -2, "cwd");
	lua_pushinteger(L, parent_pid);
	lua_setfield(L, -2, "parent_pid");
	push_argv(L, cmdline, cmdline_size);
	lua_setfield(L, -2, "argv");
	free(cmdline);
	return 1;
}

static bool
ensure_directory(const char *path) {
	char buffer[PATH_MAX];
	size_t length = strnlen(path, sizeof(buffer));
	if (length == 0 || length >= sizeof(buffer)) {
		errno = ENAMETOOLONG;
		return false;
	}
	memcpy(buffer, path, length + 1);
	if (buffer[0] != '/') {
		errno = EINVAL;
		return false;
	}
	for (char *cursor = buffer + 1; *cursor != '\0'; cursor++) {
		if (*cursor != '/') {
			continue;
		}
		*cursor = '\0';
		if (mkdir(buffer, 0700) < 0 && errno != EEXIST) {
			return false;
		}
		struct stat status;
		if (stat(buffer, &status) < 0 || !S_ISDIR(status.st_mode)) {
			errno = ENOTDIR;
			return false;
		}
		*cursor = '/';
	}
	if (mkdir(buffer, 0700) < 0 && errno != EEXIST) {
		return false;
	}
	struct stat status;
	return stat(buffer, &status) == 0 && S_ISDIR(status.st_mode);
}

static bool
ensure_parent(const char *path) {
	char parent[PATH_MAX];
	size_t length = strnlen(path, sizeof(parent));
	if (length == 0 || length >= sizeof(parent)) {
		errno = ENAMETOOLONG;
		return false;
	}
	memcpy(parent, path, length + 1);
	char *separator = strrchr(parent, '/');
	if (separator == NULL) {
		errno = EINVAL;
		return false;
	}
	if (separator == parent) {
		return true;
	}
	*separator = '\0';
	return ensure_directory(parent);
}

static bool
sync_parent(const char *path) {
	char parent[PATH_MAX];
	size_t length = strnlen(path, sizeof(parent));
	if (length == 0 || length >= sizeof(parent)) {
		errno = ENAMETOOLONG;
		return false;
	}
	memcpy(parent, path, length + 1);
	char *separator = strrchr(parent, '/');
	if (separator == NULL) {
		errno = EINVAL;
		return false;
	}
	if (separator == parent) {
		separator[1] = '\0';
	} else {
		*separator = '\0';
	}
	int fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) {
		return false;
	}
	int result = fsync(fd);
	int sync_error = errno;
	close(fd);
	if (result < 0) {
		errno = sync_error;
		return false;
	}
	return true;
}

static int
latomic_write(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	size_t size = 0;
	const char *data = luaL_checklstring(L, 2, &size);
	if (path[0] != '/') {
		return luaL_argerror(L, 1, "path must be absolute");
	}
	if (!ensure_parent(path)) {
		return push_error(L, "create session directory failed");
	}

	char temporary[PATH_MAX];
	char backup[PATH_MAX];
	int backup_length = snprintf(backup, sizeof(backup), "%s.bak", path);
	if (backup_length <= 0 || (size_t)backup_length >= sizeof(backup)) {
		errno = ENAMETOOLONG;
		return push_error(L, "create session path failed");
	}

	int fd = -1;
	for (unsigned int attempt = 0; attempt < 16; attempt++) {
		int temporary_length = snprintf(
			temporary,
			sizeof(temporary),
			"%s.tmp.%ld.%u",
			path,
			(long)getpid(),
			attempt);
		if (temporary_length <= 0 ||
			(size_t)temporary_length >= sizeof(temporary)) {
			errno = ENAMETOOLONG;
			return push_error(L, "create session path failed");
		}
		fd = open(
			temporary,
			O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
			S_IRUSR | S_IWUSR);
		if (fd >= 0 || errno != EEXIST) {
			break;
		}
	}
	if (fd < 0) {
		return push_error(L, "create session temporary failed");
	}
	bool ok = true;
	size_t offset = 0;
	while (offset < size) {
		ssize_t written = write(fd, data + offset, size - offset);
		if (written > 0) {
			offset += (size_t)written;
			continue;
		}
		if (written < 0 && errno == EINTR) {
			continue;
		}
		ok = false;
		break;
	}
	if (ok && fsync(fd) < 0) {
		ok = false;
	}
	int write_error = errno;
	if (close(fd) < 0 && ok) {
		ok = false;
		write_error = errno;
	}
	if (!ok) {
		unlink(temporary);
		errno = write_error;
		return push_error(L, "write session temporary failed");
	}

	bool had_previous = rename(path, backup) == 0;
	if (!had_previous && errno != ENOENT) {
		int rename_error = errno;
		unlink(temporary);
		errno = rename_error;
		return push_error(L, "backup session failed");
	}
	if (rename(temporary, path) < 0) {
		int rename_error = errno;
		if (had_previous) {
			rename(backup, path);
		}
		unlink(temporary);
		errno = rename_error;
		return push_error(L, "publish session failed");
	}
	if (!sync_parent(path)) {
		return push_error(L, "sync session directory failed");
	}
	lua_pushboolean(L, true);
	return 1;
}

static int
lread(lua_State *L) {
	const char *path = luaL_checkstring(L, 1);
	char *data = NULL;
	size_t size = 0;
	if (!read_file(path, &data, &size)) {
		return push_error(L, "read session failed");
	}
	lua_pushlstring(L, data, size);
	free(data);
	return 1;
}

static int
lspawn(lua_State *L) {
	size_t executable_size = 0;
	const char *executable = luaL_checklstring(L, 1, &executable_size);
	if (memchr(executable, '\0', executable_size) != NULL) {
		return luaL_argerror(L, 1, "executable must not contain NUL bytes");
	}
	if (executable[0] != '/') {
		return luaL_argerror(L, 1, "executable must be absolute");
	}
	luaL_checktype(L, 2, LUA_TTABLE);
	lua_Integer count = (lua_Integer)luaL_len(L, 2);
	if (count <= 0 || count > MAX_PROCESS_ARGUMENTS) {
		return luaL_argerror(L, 2, "argv must contain between 1 and 4096 items");
	}
	size_t cwd_size = 0;
	const char *cwd = luaL_optlstring(L, 3, "", &cwd_size);
	if (memchr(cwd, '\0', cwd_size) != NULL) {
		return luaL_argerror(L, 3, "cwd must not contain NUL bytes");
	}
	if (cwd[0] != '\0' && cwd[0] != '/') {
		return luaL_argerror(L, 3, "cwd must be absolute");
	}

	char **argv = calloc((size_t)count + 1, sizeof(*argv));
	if (argv == NULL) {
		return luaL_error(L, "cannot allocate process arguments");
	}
	for (lua_Integer index = 1; index <= count; index++) {
		lua_rawgeti(L, 2, index);
		size_t argument_size = 0;
		const char *argument = luaL_checklstring(L, -1, &argument_size);
		if (memchr(argument, '\0', argument_size) != NULL) {
			lua_pop(L, 1);
			for (lua_Integer item = 1; item < index; item++) {
				free(argv[item - 1]);
			}
			free(argv);
			return luaL_argerror(L, 2, "argv must not contain NUL bytes");
		}
		argv[index - 1] = malloc(argument_size + 1);
		if (argv[index - 1] != NULL) {
			memcpy(argv[index - 1], argument, argument_size);
			argv[index - 1][argument_size] = '\0';
		}
		lua_pop(L, 1);
		if (argv[index - 1] == NULL) {
			for (lua_Integer item = 1; item < index; item++) {
				free(argv[item - 1]);
			}
			free(argv);
			return luaL_error(L, "cannot allocate process argument");
		}
	}

	posix_spawn_file_actions_t actions;
	int action_result = posix_spawn_file_actions_init(&actions);
	if (action_result != 0) {
		for (lua_Integer index = 1; index <= count; index++) {
			free(argv[index - 1]);
		}
		free(argv);
		errno = action_result;
		return push_error(L, "initialize process actions failed");
	}
	if (cwd[0] != '\0') {
		action_result = posix_spawn_file_actions_addchdir_np(&actions, cwd);
		if (action_result != 0) {
			posix_spawn_file_actions_destroy(&actions);
			for (lua_Integer index = 1; index <= count; index++) {
				free(argv[index - 1]);
			}
			free(argv);
			errno = action_result;
			return push_error(L, "set process working directory failed");
		}
	}

	pid_t pid = 0;
	int spawn_result = posix_spawn(
		&pid,
		executable,
		&actions,
		NULL,
		argv,
		environ);
	posix_spawn_file_actions_destroy(&actions);
	for (lua_Integer index = 1; index <= count; index++) {
		free(argv[index - 1]);
	}
	free(argv);
	if (spawn_result != 0) {
		errno = spawn_result;
		return push_error(L, "spawn process failed");
	}
	lua_pushinteger(L, (lua_Integer)pid);
	return 1;
}

int
luaopen_hypringo_fs(lua_State *L) {
	static const luaL_Reg library[] = {
		{ "atomic_write", latomic_write },
		{ "process", lprocess },
		{ "read", lread },
		{ "spawn", lspawn },
		{ NULL, NULL },
	};
	luaL_newlib(L, library);
	return 1;
}
