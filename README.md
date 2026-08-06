<div align = center>

<img src="./assets/Hypringo.png" width="300" height="300" alt="banner">
<br>
<br>

Hyprland + Apple = <strong>Hypringo</strong>

Better Utilize Hyprland in Your Asahi Linux.

</div>

## Current status

Hypringo is a local runtime for Hyprland desktops. It collects desktop state,
drives Eww, exposes safe desktop actions, and restores rebuildable application
sessions after a reboot.

The current runtime provides:

- Event-driven Hyprland, MPRIS, audio, system-device, weather, and GitHub sources.
- A local Unix control socket with `status`, `doctor`, `subscribe`, and typed actions.
- Complete Eww snapshot subscriptions and multi-monitor bar lifecycle management.
- Automatic Hyprland session capture and restore with per-window skip isolation.
- A native C/Lua runtime with no shell, `curl`, `gh`, or desktop-command polling.

## Installation

### Build

Requirements: Linux, LuaMake, libcurl, PulseAudio client development headers,
and the three initialized submodules:

```bash
git submodule update --init --recursive
luamake -mode release
```

The binary is written to `build/bin/hypringo`. Install it for the current user:

```bash
install -Dm755 build/bin/hypringo ~/.local/bin/hypringo
```

### Configuration

The default configuration path is `$XDG_CONFIG_HOME/hypringo/config.lua`, or
`~/.config/hypringo/config.lua` when `XDG_CONFIG_HOME` is unset:

```bash
mkdir -p ~/.config/hypringo
cp example/config.lua ~/.config/hypringo/config.lua
${HOME}/.local/bin/hypringo --check-config
```

Minimal Hyprland configuration:

```lua
return {
	runtime = {
		workers = 6,
	},
	session = {
		restore = true,
	},
	sources = {
		hyprland = {
			enabled = true,
		},
		system = {
			enabled = true,
		},
	},
}
```

The configuration controls runtime options and source policies. The control
socket defaults to `$XDG_RUNTIME_DIR/hypringo.sock`; custom paths must be
absolute. Each enabled Hyprland, MPRIS, audio, weather, or GitHub source may
occupy one blocking worker, so increase `runtime.workers` as sources are added.

Default source state:

| Source | Purpose | Default |
| --- | --- | --- |
| `hyprland` | Monitors, workspaces, active window, and clients | disabled |
| `mpris` | Player state and media actions | disabled |
| `audio` | Default sink, volume, and mute | disabled |
| `system` | Battery, backlight, and brightness actions | enabled |
| `weather` | Periodic weather JSON | disabled |
| `github` | GitHub notifications | disabled |

## Hyprland session

The session manager is enabled by default when `sources.hyprland` is enabled.
The snapshot is stored at:

- `$XDG_STATE_HOME/hypringo/session.json`
- or `~/.local/state/hypringo/session.json`

The parent directory uses `0700`; the snapshot and `.bak` use `0600`. Writes
use a temporary file, `fsync`, and an atomic replacement. The snapshot stores
workspace names, window placement, and automatically launchable process
arguments, but never stores PIDs, window addresses, numeric monitor IDs, or the
full environment. Credential-shaped arguments are removed and the affected
window is marked `skipped`.

After startup, the first available Hyprland snapshot is reconciled with the
previous snapshot. Hypringo launches each restorable application once and moves
the matching new window to its saved workspace. Launches use an argument vector
without a shell, and existing windows are never closed.

The current MVP does not guarantee:

- Exact Hyprland tiling-tree order or proportions.
- Application-internal tabs, documents, or application-owned session state.
- Multiple extra windows for single-instance applications.

Manual save and restore commands are available for validation and recovery:

```bash
hypringo session save
hypringo session restore
```

Before rebooting, verify that a snapshot exists:

```bash
systemctl --user restart hypringo.service
sleep 3
ls -l ~/.local/state/hypringo/session.json ~/.local/state/hypringo/session.json.bak
```

After reboot, inspect the service and restore logs:

```bash
systemctl --user status hypringo.service
journalctl --user -u hypringo.service -b --no-pager | grep -E 'session|launch|restore'
```

## Commands

All client commands use the local control socket:

| Command | Purpose |
| --- | --- |
| `hypringo status` | Read the current state snapshot |
| `hypringo doctor` | Inspect source health and capabilities |
| `hypringo subscribe --format eww` | Stream complete state snapshots as JSON lines |
| `hypringo reload` | Reload hot-applicable configuration |
| `hypringo session save` | Save the current session immediately |
| `hypringo session restore` | Launch applications from the previous snapshot |
| `hypringo dispatch workspace switch 3` | Switch workspace |
| `hypringo dispatch media play-pause` | Control the current player |
| `hypringo dispatch audio set-volume 60` | Set volume |
| `hypringo dispatch audio set-mute true` | Set mute state |
| `hypringo dispatch brightness set 60` | Set brightness |

Actions pass through a finite protocol, parameter validation, and a bounded
queue. Unknown strings are never interpreted as shell, Hyprland, D-Bus, or
sysfs commands.

## Eww

Eww consumes complete state snapshots and does not need to maintain deltas.
Install the listener, bar reconciler, and lifecycle service:

```bash
install -Dm755 contrib/eww/hypringo-listen ~/.local/bin/hypringo-eww-listen
install -Dm755 contrib/eww/hypringo-bars ~/.local/bin/hypringo-bars
install -Dm755 contrib/eww/hypringo-eww-session ~/.local/bin/hypringo-eww-session
install -Dm644 contrib/systemd/hypringo-eww.service ~/.config/systemd/user/hypringo-eww.service
```

`contrib/eww/hypringo.yuck` contains a basic binding example. `hypringo-bars`
uses monitor names as stable identities; the Eww configuration should define a
`defwindow` with a `monitor-name` argument.

## systemd user service

```bash
install -Dm644 contrib/systemd/hypringo.service ~/.config/systemd/user/hypringo.service
systemctl --user import-environment \
	WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
systemctl --user daemon-reload
systemctl --user enable --now hypringo.service hypringo-eww.service
```

The Hyprland environment must be visible to the user manager.
`contrib/hyprland/hypringo-session` can import the environment and start the
services after the Hyprland session is ready.

Useful diagnostics:

```bash
journalctl --user -u hypringo.service -f
systemctl --user status hypringo-eww.service
systemctl --user reload hypringo.service
hypringo doctor
```

The GitHub token is read only from the environment variable named by
`token_env`; it is never written to configuration, logs, or session snapshots.
Do not put a GitHub token in `config.lua` or a systemd unit file.

## Development and validation

Build and run the core test suite with:

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
sh test/eww-bars.sh
```

The Hyprland and Eww integration tests use temporary mocks and do not modify
the current desktop. Live checks are available through
`test/live-hyprland.sh` and `test/live-all.sh`; run them only when the current
Hyprland and systemd session satisfy their prerequisites.

## Repository layout

```text
src/main.c              Native entry point
src/lualib/             Embedded configuration, state, runtime, and domain logic
src/service/            ltask services
src/fs.c                Session filesystem and process primitives
contrib/                systemd, Hyprland, and Eww adapters
test/                   Unit and integration tests
```
