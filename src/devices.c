#include "devices.h"

#include <lauxlib.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VALUE_CAPACITY 128

static bool
build_path(
	char path[PATH_MAX],
	const char *root,
	const char *class_name,
	const char *device,
	const char *attribute) {
	int length = snprintf(
		path,
		PATH_MAX,
		"%s/class/%s/%s/%s",
		root,
		class_name,
		device,
		attribute);
	return length >= 0 && length < PATH_MAX;
}

static bool
build_class_path(
	char path[PATH_MAX],
	const char *root,
	const char *class_name) {
	int length = snprintf(path, PATH_MAX, "%s/class/%s", root, class_name);
	return length >= 0 && length < PATH_MAX;
}

static bool
read_text(
	const char *root,
	const char *class_name,
	const char *device,
	const char *attribute,
	char value[VALUE_CAPACITY]) {
	char path[PATH_MAX];
	if (!build_path(path, root, class_name, device, attribute)) {
		return false;
	}
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		return false;
	}
	ssize_t length = read(fd, value, VALUE_CAPACITY - 1);
	int saved_errno = errno;
	close(fd);
	errno = saved_errno;
	if (length <= 0) {
		return false;
	}
	value[length] = '\0';
	while (length > 0) {
		char tail = value[length - 1];
		if (tail != '\n' && tail != '\r' && tail != ' ' && tail != '\t') {
			break;
		}
		value[--length] = '\0';
	}
	return length > 0;
}

static bool
read_long(
	const char *root,
	const char *class_name,
	const char *device,
	const char *attribute,
	long *result) {
	char value[VALUE_CAPACITY];
	if (!read_text(root, class_name, device, attribute, value)) {
		return false;
	}
	char *end;
	errno = 0;
	long parsed = strtol(value, &end, 10);
	if (errno != 0 || end == value || *end != '\0') {
		return false;
	}
	*result = parsed;
	return true;
}

static bool
device_is_present(
	const char *root,
	const char *class_name,
	const char *device) {
	long present;
	if (!read_long(root, class_name, device, "present", &present)) {
		return true;
	}
	return present != 0;
}

static bool
battery_capacity(const char *root, const char *device, int *capacity) {
	long direct;
	if (read_long(root, "power_supply", device, "capacity", &direct) &&
		direct >= 0 && direct <= 100) {
		*capacity = (int)direct;
		return true;
	}

	static const char *pairs[][2] = {
		{ "energy_now", "energy_full" },
		{ "charge_now", "charge_full" },
	};
	for (size_t index = 0; index < sizeof pairs / sizeof pairs[0]; index++) {
		long current;
		long full;
		if (!read_long(
				root,
				"power_supply",
				device,
				pairs[index][0],
				&current) ||
			!read_long(
				root,
				"power_supply",
				device,
				pairs[index][1],
				&full) ||
			current < 0 || full <= 0) {
			continue;
		}
		long double percentage =
			(long double)current * 100.0L / (long double)full;
		if (percentage < 0.0L) {
			percentage = 0.0L;
		} else if (percentage > 100.0L) {
			percentage = 100.0L;
		}
		*capacity = (int)(percentage + 0.5L);
		return true;
	}
	return false;
}

static bool
find_battery(
	const char *root,
	char selected[NAME_MAX + 1],
	int *capacity,
	char status[VALUE_CAPACITY]) {
	char class_path[PATH_MAX];
	if (!build_class_path(class_path, root, "power_supply")) {
		return false;
	}
	DIR *directory = opendir(class_path);
	if (directory == NULL) {
		return false;
	}

	struct dirent *entry;
	bool found = false;
	while ((entry = readdir(directory)) != NULL) {
		if (entry->d_name[0] == '.') {
			continue;
		}
		char type[VALUE_CAPACITY];
		int candidate_capacity;
		if (!read_text(
				root,
				"power_supply",
				entry->d_name,
				"type",
				type) ||
			strcmp(type, "Battery") != 0 ||
			!device_is_present(root, "power_supply", entry->d_name) ||
			!battery_capacity(root, entry->d_name, &candidate_capacity)) {
			continue;
		}
		if (found && strcmp(entry->d_name, selected) >= 0) {
			continue;
		}
		snprintf(selected, NAME_MAX + 1, "%s", entry->d_name);
		*capacity = candidate_capacity;
		if (!read_text(
				root,
				"power_supply",
				entry->d_name,
				"status",
				status)) {
			snprintf(status, VALUE_CAPACITY, "%s", "Unknown");
		}
		found = true;
	}
	closedir(directory);
	return found;
}

static bool
find_backlight(
	const char *root,
	char selected[NAME_MAX + 1],
	int *percentage,
	bool *writable) {
	char class_path[PATH_MAX];
	if (!build_class_path(class_path, root, "backlight")) {
		return false;
	}
	DIR *directory = opendir(class_path);
	if (directory == NULL) {
		return false;
	}

	struct dirent *entry;
	bool found = false;
	int selected_rank = -1;
	while ((entry = readdir(directory)) != NULL) {
		if (entry->d_name[0] == '.') {
			continue;
		}
		long current;
		long maximum;
		if (!read_long(
				root,
				"backlight",
				entry->d_name,
				"max_brightness",
				&maximum) ||
			maximum <= 0) {
			continue;
		}
		if (!read_long(
				root,
				"backlight",
				entry->d_name,
				"actual_brightness",
				&current) &&
			!read_long(
				root,
				"backlight",
				entry->d_name,
				"brightness",
				&current)) {
			continue;
		}
		if (current < 0) {
			continue;
		}
		char type[VALUE_CAPACITY];
		int rank = 0;
		if (read_text(
				root,
				"backlight",
				entry->d_name,
				"type",
				type)) {
			if (strcmp(type, "raw") == 0) {
				rank = 3;
			} else if (strcmp(type, "platform") == 0) {
				rank = 2;
			} else if (strcmp(type, "firmware") == 0) {
				rank = 1;
			}
		}
		if (found &&
			(rank < selected_rank ||
				(rank == selected_rank &&
					strcmp(entry->d_name, selected) >= 0))) {
			continue;
		}
		snprintf(selected, NAME_MAX + 1, "%s", entry->d_name);
		selected_rank = rank;
		long double value =
			(long double)current * 100.0L / (long double)maximum;
		if (value > 100.0L) {
			value = 100.0L;
		}
		*percentage = (int)(value + 0.5L);
		char brightness_path[PATH_MAX];
		*writable = build_path(
			brightness_path,
			root,
			"backlight",
			entry->d_name,
			"brightness") &&
			access(brightness_path, W_OK) == 0;
		found = true;
	}
	closedir(directory);
	return found;
}

static void
set_boolean(lua_State *L, const char *key, bool value) {
	lua_pushboolean(L, value);
	lua_setfield(L, -2, key);
}

static void
set_integer(lua_State *L, const char *key, lua_Integer value) {
	lua_pushinteger(L, value);
	lua_setfield(L, -2, key);
}

static void
set_string(lua_State *L, const char *key, const char *value) {
	lua_pushstring(L, value);
	lua_setfield(L, -2, key);
}

static int
lsnapshot(lua_State *L) {
	const char *root = luaL_optstring(L, 1, "/sys");

	lua_newtable(L);

	lua_newtable(L);
	char battery[NAME_MAX + 1] = "";
	char status[VALUE_CAPACITY] = "";
	int capacity = 0;
	bool battery_available =
		find_battery(root, battery, &capacity, status);
	set_boolean(L, "available", battery_available);
	set_integer(L, "capacity", capacity);
	set_string(L, "device", battery);
	set_string(L, "status", status);
	lua_setfield(L, -2, "battery");

	lua_newtable(L);
	char backlight[NAME_MAX + 1] = "";
	int percentage = 0;
	bool writable = false;
	bool brightness_available =
		find_backlight(root, backlight, &percentage, &writable);
	set_boolean(L, "available", brightness_available);
	lua_newtable(L);
	set_boolean(L, "set", brightness_available && writable);
	lua_setfield(L, -2, "capabilities");
	set_string(L, "device", backlight);
	set_integer(L, "percent", percentage);
	lua_setfield(L, -2, "brightness");

	return 1;
}

static bool
valid_device_name(const char *device) {
	return device[0] != '\0' &&
		strcmp(device, ".") != 0 &&
		strcmp(device, "..") != 0 &&
		strchr(device, '/') == NULL;
}

static int
operational_error(lua_State *L, const char *operation, int error_number) {
	lua_pushnil(L);
	lua_pushfstring(L, "%s: %s", operation, strerror(error_number));
	return 2;
}

static int
lset_brightness(lua_State *L) {
	const char *root = luaL_checkstring(L, 1);
	const char *device = luaL_checkstring(L, 2);
	lua_Integer percentage = luaL_checkinteger(L, 3);
	if (!valid_device_name(device)) {
		return luaL_argerror(L, 2, "invalid backlight device name");
	}
	if (percentage < 0 || percentage > 100) {
		return luaL_argerror(L, 3, "brightness percentage must be from 0 to 100");
	}

	long maximum;
	if (!read_long(root, "backlight", device, "max_brightness", &maximum) ||
		maximum <= 0) {
		lua_pushnil(L);
		lua_pushliteral(L, "cannot read backlight maximum");
		return 2;
	}
	long raw = (long)((long double)maximum *
		(long double)percentage / 100.0L + 0.5L);
	if (percentage > 0 && raw == 0) {
		raw = 1;
	}

	char path[PATH_MAX];
	if (!build_path(path, root, "backlight", device, "brightness")) {
		lua_pushnil(L);
		lua_pushliteral(L, "backlight path is too long");
		return 2;
	}
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		return operational_error(L, "cannot open backlight brightness", errno);
	}
	char value[VALUE_CAPACITY];
	int length = snprintf(value, sizeof value, "%ld\n", raw);
	ssize_t written = write(fd, value, (size_t)length);
	int saved_errno = errno;
	int close_result = close(fd);
	if (written != length) {
		return operational_error(
			L,
			"cannot write backlight brightness",
			written < 0 ? saved_errno : EIO);
	}
	if (close_result != 0) {
		return operational_error(L, "cannot close backlight brightness", errno);
	}
	lua_pushboolean(L, true);
	return 1;
}

int
luaopen_hypringo_system(lua_State *L) {
	static const luaL_Reg functions[] = {
		{ "set_brightness", lset_brightness },
		{ "snapshot", lsnapshot },
		{ NULL, NULL },
	};
	luaL_newlib(L, functions);
	return 1;
}
