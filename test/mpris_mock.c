#include <systemd/sd-bus.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OBJECT_PATH "/org/mpris/MediaPlayer2"
#define PLAYER_INTERFACE "org.mpris.MediaPlayer2.Player"
#define ROOT_INTERFACE "org.mpris.MediaPlayer2"

struct player {
	const char *action_log;
	const char *album;
	const char *art;
	const char *artist;
	const char *identity;
	const char *title;
	const char *status;
};

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t irrelevant_requested;
static volatile sig_atomic_t toggle_requested;

static void
handle_signal(int signal_number) {
	if (signal_number == SIGUSR1) {
		toggle_requested = 1;
	} else if (signal_number == SIGUSR2) {
		irrelevant_requested = 1;
	} else {
		running = 0;
	}
}

static int
property_volume(sd_bus *bus,
		const char *path,
		const char *interface,
		const char *property,
		sd_bus_message *reply,
		void *userdata,
		sd_bus_error *error) {
	(void)bus;
	(void)path;
	(void)interface;
	(void)property;
	(void)userdata;
	(void)error;
	return sd_bus_message_append(reply, "d", 1.0);
}

static int
property_string(sd_bus *bus,
		const char *path,
		const char *interface,
		const char *property,
		sd_bus_message *reply,
		void *userdata,
		sd_bus_error *error) {
	(void)bus;
	(void)path;
	(void)interface;
	(void)error;
	struct player *player = userdata;
	const char *value = strcmp(property, "Identity") == 0
				    ? player->identity
				    : player->status;
	return sd_bus_message_append(reply, "s", value);
}

static int
append_string_entry(sd_bus_message *reply,
		    const char *key,
		    const char *value) {
	int result = sd_bus_message_open_container(reply, 'e', "sv");
	if (result < 0) {
		return result;
	}
	result = sd_bus_message_append(reply, "s", key);
	if (result >= 0) {
		result = sd_bus_message_open_container(reply, 'v', "s");
	}
	if (result >= 0) {
		result = sd_bus_message_append(reply, "s", value);
	}
	if (result >= 0) {
		result = sd_bus_message_close_container(reply);
	}
	if (result >= 0) {
		result = sd_bus_message_close_container(reply);
	}
	return result;
}

static int
append_artist_entry(sd_bus_message *reply, const char *artist) {
	int result = sd_bus_message_open_container(reply, 'e', "sv");
	if (result < 0) {
		return result;
	}
	result = sd_bus_message_append(reply, "s", "xesam:artist");
	if (result >= 0) {
		result = sd_bus_message_open_container(reply, 'v', "as");
	}
	if (result >= 0) {
		result = sd_bus_message_open_container(reply, 'a', "s");
	}
	if (result >= 0) {
		result = sd_bus_message_append(reply, "s", artist);
	}
	if (result >= 0) {
		result = sd_bus_message_close_container(reply);
	}
	if (result >= 0) {
		result = sd_bus_message_close_container(reply);
	}
	if (result >= 0) {
		result = sd_bus_message_close_container(reply);
	}
	return result;
}

static int
property_metadata(sd_bus *bus,
		  const char *path,
		  const char *interface,
		  const char *property,
		  sd_bus_message *reply,
		  void *userdata,
		  sd_bus_error *error) {
	(void)bus;
	(void)path;
	(void)interface;
	(void)property;
	(void)error;
	struct player *player = userdata;
	int result = sd_bus_message_open_container(reply, 'a', "{sv}");
	if (result >= 0) {
		result = append_string_entry(reply, "xesam:title", player->title);
	}
	if (result >= 0) {
		result = append_string_entry(reply, "xesam:album", player->album);
	}
	if (result >= 0) {
		result = append_string_entry(reply, "mpris:artUrl", player->art);
	}
	if (result >= 0) {
		result = append_artist_entry(reply, player->artist);
	}
	if (result >= 0) {
		result = sd_bus_message_close_container(reply);
	}
	return result;
}

static int
method_action(sd_bus_message *message,
	      void *userdata,
	      sd_bus_error *error) {
	(void)error;
	struct player *player = userdata;
	const char *member = sd_bus_message_get_member(message);
	FILE *file = fopen(player->action_log, "a");
	if (file == NULL) {
		return -errno;
	}
	int result = fprintf(file, "%s\n", member) < 0 ? -EIO : 0;
	if (fclose(file) < 0 && result >= 0) {
		result = -errno;
	}
	if (result < 0) {
		return result;
	}
	return sd_bus_reply_method_return(message, "");
}

static const sd_bus_vtable root_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_PROPERTY(
		"Identity",
		"s",
		property_string,
		0,
		SD_BUS_VTABLE_PROPERTY_CONST),
	SD_BUS_VTABLE_END,
};

static const sd_bus_vtable player_vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_PROPERTY(
		"PlaybackStatus",
		"s",
		property_string,
		0,
		SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY(
		"Metadata",
		"a{sv}",
		property_metadata,
		0,
		SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_PROPERTY(
		"Volume",
		"d",
		property_volume,
		0,
		SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
	SD_BUS_METHOD("Next", "", "", method_action, 0),
	SD_BUS_METHOD("Pause", "", "", method_action, 0),
	SD_BUS_METHOD("Play", "", "", method_action, 0),
	SD_BUS_METHOD("PlayPause", "", "", method_action, 0),
	SD_BUS_METHOD("Previous", "", "", method_action, 0),
	SD_BUS_VTABLE_END,
};

static int
run(const char *name, struct player *player) {
	sd_bus *bus = NULL;
	sd_bus_slot *player_slot = NULL;
	sd_bus_slot *root_slot = NULL;
	int result = sd_bus_open_user(&bus);
	if (result < 0) {
		goto done;
	}
	result = sd_bus_add_object_vtable(
		bus,
		&root_slot,
		OBJECT_PATH,
		ROOT_INTERFACE,
		root_vtable,
		player);
	if (result < 0) {
		goto done;
	}
	result = sd_bus_add_object_vtable(
		bus,
		&player_slot,
		OBJECT_PATH,
		PLAYER_INTERFACE,
		player_vtable,
		player);
	if (result < 0) {
		goto done;
	}
	result = sd_bus_request_name(bus, name, 0);
	if (result < 0) {
		goto done;
	}

	while (running) {
		if (irrelevant_requested) {
			irrelevant_requested = 0;
			result = sd_bus_emit_properties_changed(
				bus,
				OBJECT_PATH,
				PLAYER_INTERFACE,
				"Volume",
				NULL);
			if (result < 0) {
				break;
			}
		}
		if (toggle_requested) {
			toggle_requested = 0;
			player->status = strcmp(player->status, "Playing") == 0
						 ? "Paused"
						 : "Playing";
			result = sd_bus_emit_properties_changed(
				bus,
				OBJECT_PATH,
				PLAYER_INTERFACE,
				"PlaybackStatus",
				NULL);
			if (result < 0) {
				break;
			}
		}
		do {
			result = sd_bus_process(bus, NULL);
		} while (result > 0);
		if (result < 0) {
			break;
		}
		result = sd_bus_wait(bus, 100000);
		if (result < 0 && result != -EINTR) {
			break;
		}
	}
	if (result == -EINTR) {
		result = 0;
	}

done:
	sd_bus_slot_unref(player_slot);
	sd_bus_slot_unref(root_slot);
	sd_bus_unref(bus);
	return result;
}

int
main(int argc, char **argv) {
	if (argc != 6) {
		fprintf(
			stderr,
			"usage: mpris_mock BUS_NAME IDENTITY STATUS TITLE ACTION_LOG\n");
		return 2;
	}
	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);
	signal(SIGUSR1, handle_signal);
	signal(SIGUSR2, handle_signal);
	struct player player = {
		.action_log = argv[5],
		.album = "Mock album",
		.art = "file:///mock-art.png",
		.artist = "Mock artist",
		.identity = argv[2],
		.status = argv[3],
		.title = argv[4],
	};
	int result = run(argv[1], &player);
	if (result < 0) {
		fprintf(stderr, "mpris_mock: %s\n", strerror(-result));
		return 1;
	}
	return 0;
}
