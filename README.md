<div align = center>

<img src="./assets/Hypringo.png" width="300" height="300" alt="banner">
<br>
<br>

Hyprland + Apple = <strong>Hypringo</strong>

Better Utilize Hyprland in Your Asahi Linux.

</div>

## Current status

This branch provides an event-driven Hypringo runtime. A single native
executable embeds Lua 5.5, ltask, yyjson, and internal Lua services, while an
external `config.lua` remains the only user-facing configuration entry point.
The process contains a single-writer state service, a local Unix control
socket, and independently configurable Hyprland, MPRIS, PipeWire-Pulse,
system-device, weather, and GitHub sources. Workspace, media, audio, and
brightness operations all pass through validated typed dispatch; arbitrary
commands are never forwarded to a source. `doctor` provides a unified view of
source health and capabilities, while configuration reload only hot-applies
source policies and never changes the service topology implicitly.

## Build

A recent [luamake](https://github.com/actboy168/luamake), systemd, libcurl,
and the PulseAudio client development libraries are required. The audio source
uses the PulseAudio compatibility service provided by PipeWire and does not
link against a private PipeWire ABI. Initialize the three source submodules
after the first checkout, then build the release binary:

```bash
git submodule update --init --recursive
luamake -mode release
```

The resulting binary is `build/bin/hypringo`.

## Configure and run

The default configuration path follows XDG:
`$XDG_CONFIG_HOME/hypringo/config.lua`, or
`~/.config/hypringo/config.lua` when `XDG_CONFIG_HOME` is unset. A
configuration file can also be passed directly or selected with `--config`:

```bash
mkdir -p ~/.config/hypringo
cp example/config.lua ~/.config/hypringo/config.lua

build/bin/hypringo --check-config
build/bin/hypringo main.lua
build/bin/hypringo --config /path/to/config.lua
```

The configuration file must return a serializable Lua table. The runtime
currently consumes `runtime.workers`. The control socket defaults to
`$XDG_RUNTIME_DIR/hypringo.sock` and can be overridden explicitly:

```lua
return {
	runtime = {
		workers = 4,
		socket_path = "/run/user/1000/hypringo.sock",
	},
	sources = {
		audio = {
			enabled = true,
		},
		hyprland = {
			enabled = true,
		},
		mpris = {
			enabled = true,
		},
		system = {
			enabled = true,
			interval_ms = 5000,
		},
		github = {
			enabled = false,
		},
		weather = {
			enabled = false,
		},
	},
}
```

`socket_path` must be absolute. In most installations it should be omitted so
the XDG default is used. Every enabled Hyprland, MPRIS, audio, weather, and
GitHub source owns one blocking waiter or bounded HTTP request, so
`runtime.workers` must be greater than the number of enabled blocking sources.
Use at least six workers when all five are enabled. The system-device source
only uses an ltask timer for short sysfs scans and does not occupy a blocking
worker.

The Hyprland source is disabled by default. When enabled, it reads the initial
snapshot from
`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`
and listens to `.socket2.sock`. A disconnect explicitly changes the source to
`available=false`, followed by exponential reconnect backoff from 100 ms to
5 s. A successful reconnect reloads monitors, workspaces, and the active
window. Tests and specialized deployments can provide explicit socket paths:

```lua
return {
	sources = {
		hyprland = {
			enabled = true,
			command_socket = "/tmp/fake-hypr/.socket.sock",
			event_socket = "/tmp/fake-hypr/.socket2.sock",
			reconnect_min_ms = 100,
			reconnect_max_ms = 5000,
		},
	},
}
```

Monitors never need to be listed in the configuration. Hypringo refreshes the
complete output set at startup, after reconnect, and after monitor add/remove
events. Moving between computers, hot-plugging displays, and changing their
positions are all governed by the current Hyprland topology. A monitor's
stable identity is its `name`; position, focused state, and numeric `id` are
observed again on every refresh. The numeric `id` is informational and must
not be confused with Eww's positional monitor index. UI and backend consumers
should key instances by snapshot monitor name and create, update, or remove
them dynamically. Future optional configuration may provide matching and
overrides, but never a monitor inventory.

The MPRIS source discovers players and updates state through the user D-Bus
`NameOwnerChanged` and `PropertiesChanged` signals. When multiple players are
available, selection is deterministic: playing first, paused second, then bus
name. If the selected player disappears, the next available player is chosen;
when all players disappear, `media.available=false` and stale metadata is
cleared. Supported actions are `next`, `pause`, `play`, `play-pause`, and
`previous`. The selected player's `CanControl`, `CanGoNext`, `CanGoPrevious`,
`CanPause`, and `CanPlay` properties become dynamic capabilities. Unsupported
actions are rejected before a D-Bus method is called.

The audio source uses libpulse to subscribe to server and sink events and
always follows the current default sink. On a standard PipeWire desktop, this
connects to PipeWire-Pulse without starting polling commands or temporary
processes. If the default sink or audio service becomes unavailable,
`audio.available=false` and stale values are cleared.

The system-device source is enabled by default and scans Linux sysfs directly.
It does not start `light`, `brightnessctl`, the UPower CLI, or any other
polling process. Real battery devices are discovered under
`/sys/class/power_supply`, and backlight devices under
`/sys/class/backlight`. Missing hardware is a healthy state represented by
`battery.available=false` or `brightness.available=false`. When devices exist,
the source publishes their name, capacity and charging status, or brightness
percentage. The `set_brightness` capability is exposed only when the current
user can write the backlight `brightness` node. The default five-second rescan
detects device additions and removals without hard-coding `BAT0`,
`macsmc-battery`, or a backlight name. Tests can point `sysfs_root` at an
isolated fixture; production should retain the `/sys` default.

Weather and GitHub are low-frequency remote sources backed by in-process
libcurl, with no `curl`, `gh`, or other polling subprocess. Every request has
connect and total timeouts, a response-size limit, and HTTP(S)-only redirect
boundaries. Failures use exponential backoff. GitHub additionally honors
`Retry-After`, rate-limit reset, `X-Poll-Interval`, and ETag/304. A timeout in
one remote source never blocks another source or a local event source.

The weather endpoint must return a small JSON object with `cond`, `temp`,
`loc`, `wind`, `pressure`, `precip`, and `temp_like` fields. For example,
wttr.in's format API can project that schema. The URL controls the location;
the runtime does not hard-code it:

```lua
weather = {
	enabled = true,
	interval_ms = 600000,
	timeout_ms = 10000,
	url = "https://wttr.in/Shenzhen?format=%7B%22cond%22:%22%c%22,%22temp%22:%22%t%22,%22loc%22:%22%l%22,%22wind%22:%22%w%22,%22pressure%22:%22%P%22,%22precip%22:%22%p%22,%22temp_like%22:%22%f%22%7D",
}
```

The GitHub source calls the notifications API and keeps at most `max_items`
projected entries: notification ID, reason, unread and update time, repository
name and URL, and subject title, type, and URL. It never sends the complete API
payload to Eww. The token is read only from the environment variable named by
the configuration and never appears in snapshots, `doctor`, or logs:

```lua
github = {
	enabled = true,
	interval_ms = 60000,
	max_items = 50,
	token_env = "HYPRINGO_GITHUB_TOKEN",
}
```

For a systemd deployment, provide this variable through a user-service
`EnvironmentFile` override with mode `0600`. Never put the token in
`config.lua` or a unit file. If `gh auth login` already stores the token in the
system keyring, install `contrib/systemd/hypringo-github-start` and point the
unit override's `ExecStart` to that adapter. It reads the token once at service
startup and then `exec`s Hypringo; the GitHub source itself still never starts
a `gh` subprocess.

## State and Eww data flow

A running Hypringo instance maintains normalized state with a monotonic
revision. `status` reads the current snapshot once. `subscribe` first replays
the current snapshot and then emits later revisions. Every line is complete
JSON, so subscribers never have to repair a missed delta:

```bash
hypringo status
hypringo doctor
hypringo subscribe --format eww
hypringo status --socket /path/to/hypringo.sock
```

The snapshot defines seven stable domains: `runtime`, `hyprland`, `media`,
`audio`, `system`, `weather`, and `github`. An unavailable local event source
explicitly publishes `available=false` and clears stale state. After a remote
source succeeds once, a later refresh failure preserves the last displayable
data while setting `stale=true`, `error`, `failures`, `last_success_at`, and
`refresh_in_ms`. The UI can therefore mark cached data instead of clearing the
component during a transient network failure. The control socket always uses
mode `0600`. A second daemon refuses to take over a live socket, while a stale
socket left by an abnormal exit is recovered safely on the next start.

`doctor` combines the configured enabled sources with current state as
`disabled`, `ready`, or `degraded`, and reports overall `healthy`,
`config_generation`, `last_reload_error`, and each source's capabilities. An
MPRIS bus with no current player remains `ready` but
`media.available=false`. A connected audio service without an available
default sink is `degraded`, because volume actions cannot be completed.

Regular `status` and `subscribe` output uses a control envelope with
`revision`, `state`, and `type`. `subscribe --format eww` emits the complete
state object directly and is intended for one long-running Eww `deflisten`.
See `contrib/eww/hypringo.yuck`:

```yuck
(include "./hypringo.yuck")

(label :text {hypringo.hyprland.active_window.title})
```

Every new Eww listener first receives the complete current snapshot. It never
has to recover deltas or run separate polling scripts for workspaces, the
active window, or other fields. Install the lifecycle adapter so the listener
reconnects automatically after a daemon crash or restart:

```bash
install -Dm755 contrib/eww/hypringo-listen \
  ~/.local/bin/hypringo-eww-listen
install -Dm755 contrib/eww/hypringo-bars \
  ~/.local/bin/hypringo-bars
install -Dm755 contrib/eww/hypringo-eww-session \
  ~/.local/bin/hypringo-eww-session
install -Dm644 contrib/systemd/hypringo-eww.service \
  ~/.config/systemd/user/hypringo-eww.service
```

`contrib/eww/hypringo.yuck` invokes this adapter by default. The adapter does
not parse or cache JSON. After reconnecting, it relies on the daemon's complete
snapshot replay and cannot mix stale deltas into a new process state.

`hypringo-bars` consumes the same complete snapshot stream and reconciles one
Eww `bar` instance per current Hyprland monitor. Instances use monitor names as
stable identities and pass each name through the window's `monitor-name`
argument. An Eww configuration using this adapter must therefore define
`(defwindow bar [monitor-name] ...)`. `hypringo-eww-session` owns both the Eww
daemon and this monitor reconciler, so a crash of either process restarts the
complete UI session instead of leaving stale or duplicate layer surfaces.

## Typed dispatch

Client actions are normalized into a finite protocol before entering a
bounded queue with capacity 64. The daemon parses them again and routes them
only to the corresponding source. Supported actions are:

```bash
hypringo dispatch workspace switch 3
hypringo dispatch media play-pause
hypringo dispatch media next
hypringo dispatch audio set-volume 60
hypringo dispatch audio set-mute true
hypringo dispatch audio toggle-mute
hypringo dispatch brightness set 60
```

Workspace IDs must be integers. Volume and brightness values are restricted to
0 through 100. Other strings are never interpreted as Hyprland commands,
D-Bus methods, sysfs paths, or shell commands. The control socket returns
`accepted` after queueing an action; source execution errors are written to the
daemon log.

## Configuration reload

`reload` enters the same bounded control queue. The client first receives
`accepted`; observe the actual result through the generation and error fields
reported by `doctor`:

```bash
hypringo reload
hypringo doctor
```

Reload can hot-apply local reconnect and scan policies, remote endpoint,
timeout, interval, retry and response-limit policies, the GitHub token
environment-variable name, and projection limits. `runtime.workers`, the
control socket, source enabled state, Hyprland command and event sockets, and
the system source's `sysfs_root` determine process topology or access
boundaries. Changing one of them preserves the old configuration, leaves the
generation unchanged, and records `restart required` in
`last_reload_error`. Syntax and validation failures are also never applied
partially. Fixing the file and reloading successfully increments the
generation and clears the error.

## systemd user service

After installing the binary and unit, import the current Hyprland and Wayland
session environment into the user manager, then enable the service:

```bash
install -Dm755 build/bin/hypringo ~/.local/bin/hypringo
install -Dm755 contrib/eww/hypringo-listen ~/.local/bin/hypringo-eww-listen
install -Dm755 contrib/eww/hypringo-cover-listen ~/.local/bin/hypringo-cover-listen
install -Dm755 contrib/eww/hypringo-bars ~/.local/bin/hypringo-bars
install -Dm755 contrib/eww/hypringo-eww-session ~/.local/bin/hypringo-eww-session
install -Dm644 contrib/systemd/hypringo.service ~/.config/systemd/user/hypringo.service
install -Dm644 contrib/systemd/hypringo-eww.service ~/.config/systemd/user/hypringo-eww.service
systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
systemctl --user daemon-reload
systemctl --user enable --now hypringo.service hypringo-eww.service
```

Inspect logs and configuration errors with:

```bash
journalctl --user -u hypringo.service -f
systemctl --user status hypringo-eww.service
systemctl --user reload hypringo.service
hypringo doctor
```

The unit runs `--check-config` before startup, uses a bounded restart policy
after abnormal exits, and cleans up the complete process group after a stop
timeout. `ExecReload` assumes the default control socket. If a custom socket
is configured, add the matching `--socket` argument to `ExecReload` in a user
unit override. The unit is bound to `graphical-session.target` and does not
remain running as a background service outside the graphical session.

## Validation

Run the native yyjson binding, Lua reducer and configuration, and
process-level control socket tests with:

```bash
luamake -mode debug
luamake -mode debug unit mpris_mock
build/bin/unit test/unit.lua
sh test/control.sh build/bin/hypringo
sh test/reload.sh build/bin/hypringo
sh test/lifecycle.sh build/bin/hypringo
sh test/remote.sh build/bin/hypringo
sh test/hyprland.sh build/bin/hypringo
sh test/mpris.sh build/bin/hypringo build/bin/mpris_mock
sh test/audio.sh build/bin/hypringo
sh test/system.sh build/bin/hypringo
```

The Hyprland integration test uses only simulated command and event sockets in
a temporary directory. It covers dual-monitor hot-plug, focus migration,
unplug, split events, disconnect, and reconnect without connecting to or
modifying the current Hyprland, Eww, or legacy Hypringo process. The MPRIS test
runs two mock players in a private D-Bus session and covers deterministic
selection, capability signals, typed-action rejection and execution, and
player removal. The reload test covers successful generations, invalid
configuration, and restart-required boundaries. The lifecycle test begins
without a daemon, forces one crash and stale-socket recovery, and verifies that
Eww receives a complete replay from the new process without leaving listener
children behind. The audio test compares a read-only snapshot of the current
default sink without changing volume or mute state. The system test uses
temporary fake sysfs data to cover battery and backlight auto-discovery,
device priority, typed brightness writes, and hot removal without accessing
real sysfs. The remote test uses a local HTTP mock to cover timeouts,
response-size limits, ETag/304, `Retry-After`, stale-data retention,
exponential backoff, field projection, and fault isolation between the two
remote sources without contacting real weather or GitHub services.
