<div align = center>

<img src="./assets/Hypringo.png" width="300" height="300" alt="banner">
<br>
<br>

Hyprland + Apple = <strong>Hypringo</strong>

Better Utilize Hyprland in Your Asahi Linux.

</div>

## 当前状态

当前分支提供 Hypringo 的事件驱动运行时：单个原生可执行文件内嵌 Lua
5.5、ltask、yyjson 与内部 Lua service，外部 `config.lua` 作为唯一用户入口。
进程内包含单写者状态服务、本地 Unix control socket，以及可独立启用的
Hyprland、MPRIS 和 PipeWire-Pulse source。workspace、媒体和音频操作统一经过
校验后的 typed dispatch，不向 source 透传任意命令。`doctor` 提供统一的
source 健康与 capability 视图；配置 reload 仅热更新连接退避参数，不会在运行中
悄悄改变 service topology。

## 构建

需要较新的 [luamake](https://github.com/actboy168/luamake)、systemd 开发库和
PulseAudio 客户端开发库。音频 source 通过 PipeWire 的 PulseAudio 兼容服务工作，
不要求链接 PipeWire 私有 ABI。首次检出后初始化三个源码 submodule，再构建
release 版本：

```bash
git submodule update --init --recursive
luamake -mode release
```

产物位于 `build/bin/hypringo`。

## 配置与运行

默认配置路径遵循 XDG：`$XDG_CONFIG_HOME/hypringo/config.lua`；未设置 `XDG_CONFIG_HOME` 时使用 `~/.config/hypringo/config.lua`。也可以直接传入配置文件，或用 `--config` 指定：

```bash
mkdir -p ~/.config/hypringo
cp example/config.lua ~/.config/hypringo/config.lua

build/bin/hypringo --check-config
build/bin/hypringo main.lua
build/bin/hypringo --config /path/to/config.lua
```

配置文件必须返回可序列化的 Lua table。运行时当前消费 `runtime.workers`，control socket 默认位于 `$XDG_RUNTIME_DIR/hypringo.sock`，也可以显式覆盖：

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
	},
}
```

`socket_path` 必须是绝对路径；通常不需要配置，保留 XDG 默认值即可。每个启用的
source 都有一个阻塞式 event waiter，因此 `runtime.workers` 必须大于启用的 source
数量；全部启用时使用至少 4 个 worker。

Hyprland source 默认关闭，启用后会从
`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`
读取初始 snapshot，并监听 `.socket2.sock`。断线后状态会明确变为
`available=false`，随后按 100 ms 到 5 s 的指数退避重连；重连成功会重新读取
monitors、workspaces 和 active window。测试或特殊部署也可以显式指定 socket：

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

无需在配置中预先列出 monitor。Hypringo 在启动、重连和 monitor add/remove
事件后都会重新读取全部输出；换电脑、扩展屏热插拔和位置变化都由当前
Hyprland topology 决定。monitor 的稳定身份是 `name`，位置、focused 状态和数字
`id` 每次重新探测，其中数字 `id` 仅作为观测值保留，不能与 Eww 的显示器位置
索引混用。UI/backend 应以 snapshot 中的 monitor name 为 key 动态创建、更新和
移除对应实例；未来的可选配置只用于匹配与覆盖，不作为 monitor 清单。

MPRIS source 通过 user D-Bus 的 `NameOwnerChanged` 和
`PropertiesChanged` 信号发现播放器并更新状态。多个播放器同时存在时，优先选择
playing，其次 paused，最后按 bus name 排序，因而结果稳定；播放器消失后会选择
下一个可用实例，全部消失时 `media.available=false` 并清空旧元数据。支持
`next`、`pause`、`play`、`play-pause` 和 `previous`。所选播放器的
`CanControl`、`CanGoNext`、`CanGoPrevious`、`CanPause` 和 `CanPlay` 会转成
动态 capability；不受支持的 action 会在调用 D-Bus method 前被拒绝。

audio source 使用 libpulse 订阅 server/sink 事件，并始终跟随当前 default sink。
这在标准 PipeWire 桌面上连接的是 PipeWire-Pulse 服务，不启动轮询命令或临时子进程。
默认 sink 或音频服务不可用时会设置 `audio.available=false` 并清空旧值。

## 状态与 Eww 数据流

运行中的 Hypringo 维护带单调 revision 的规范化状态。`status` 读取一次当前 snapshot，`subscribe` 会先重放当前 snapshot，再持续输出后续 revision；每一行都是完整 JSON，订阅者无需自己修补丢失的增量：

```bash
hypringo status
hypringo doctor
hypringo subscribe --format eww
hypringo status --socket /path/to/hypringo.sock
```

当前 snapshot 已定义 `runtime`、`hyprland`、`media` 和 `audio` 四个稳定
domain。任一 source 不可用时会明确输出 `available=false` 以及清空后的状态，而
不是保留上一次成功值。control socket 权限固定为 `0600`；第二个 daemon 会拒绝
抢占仍活跃的 socket，进程异常退出留下的 stale socket 会在下一次启动时安全回收。

`doctor` 将配置中的 enabled source 与当前状态合并为 `disabled`、`ready` 或
`degraded`，并输出整体 `healthy`、`config_generation`、`last_reload_error`
以及每个 source 的 capability。MPRIS 总线已连接但当前没有播放器时，source
仍是 `ready`，只是 `available=false`；audio 已连接但没有可用 default sink
仍是 `degraded`，因为此时音量操作无法完成。

普通 `status`/`subscribe` 输出带 `revision/state/type` 的 control envelope；
`subscribe --format eww` 直接输出完整 state 对象，适合 Eww 的单一长连接
`deflisten`。示例位于 `contrib/eww/hypringo.yuck`：

```yuck
(include "./hypringo.yuck")

(label :text {hypringo.hyprland.active_window.title})
```

每次 Eww 重新启动监听都会先收到当前完整 snapshot，不需要恢复 delta，也不需要
为 workspace、active window 等字段分别运行轮询脚本。为让监听在 daemon
崩溃或重启后自动重连，安装生命周期适配器：

```bash
install -Dm755 contrib/eww/hypringo-listen \
  ~/.local/bin/hypringo-eww-listen
```

`contrib/eww/hypringo.yuck` 默认调用该适配器。它不解析或缓存 JSON；重连成功后
直接依赖 daemon 的完整 snapshot replay，因此不会把旧 delta 混入新进程状态。

## Typed dispatch

客户端 action 会先被规范化为有限协议，再进入容量为 64 的有界队列；daemon 内部
再次解析并只路由到对应 source。当前支持：

```bash
hypringo dispatch workspace switch 3
hypringo dispatch media play-pause
hypringo dispatch media next
hypringo dispatch audio set-volume 60
hypringo dispatch audio set-mute true
hypringo dispatch audio toggle-mute
```

workspace ID 必须是整数，volume 只允许 0–100，其他字符串不会被当作 Hyprland、
D-Bus 或 shell 命令执行。control socket 接收 action 后返回 `accepted`，实际
source 错误会进入 daemon 日志。

## 配置 reload

`reload` 进入同一个有界 control queue，客户端先收到 `accepted`，实际结果通过
`doctor` 的 generation/error 字段观察：

```bash
hypringo reload
hypringo doctor
```

当前只允许热更新三个 source 的 `reconnect_min_ms` 和
`reconnect_max_ms`。`runtime.workers`、control socket、source enabled 状态以及
Hyprland command/event socket 都决定进程拓扑或已打开资源；修改它们时 reload
会保留旧配置、保持 generation 不变，并在 `last_reload_error` 中返回
`restart required`。配置语法或校验失败也不会部分应用；修复文件并再次 reload
成功后，generation 增加且 error 清空。

## systemd user service

安装二进制和 unit 后，把当前 Hyprland/Wayland 会话环境导入 user manager，再启用服务：

```bash
install -Dm755 build/bin/hypringo ~/.local/bin/hypringo
install -Dm755 contrib/eww/hypringo-listen ~/.local/bin/hypringo-eww-listen
install -Dm644 contrib/systemd/hypringo.service ~/.config/systemd/user/hypringo.service
systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
systemctl --user daemon-reload
systemctl --user enable --now hypringo.service
```

查看日志与配置错误：

```bash
journalctl --user -u hypringo.service -f
systemctl --user reload hypringo.service
hypringo doctor
```

unit 在启动前执行 `--check-config`，异常退出使用受限 restart policy，并在 stop
超时后清理整个进程组；`ExecReload` 只适用于默认 control socket。若配置了自定义
socket，请在 user unit override 中为 `ExecReload` 同时增加对应 `--socket`。
unit 绑定到 `graphical-session.target`，不会作为脱离图形会话的后台服务常驻。

## 验证

原生 yyjson binding、Lua reducer/config 和 control socket 进程级测试分别运行：

```bash
luamake -mode debug
luamake -mode debug unit mpris_mock
build/bin/unit test/unit.lua
sh test/control.sh build/bin/hypringo
sh test/reload.sh build/bin/hypringo
sh test/lifecycle.sh build/bin/hypringo
sh test/hyprland.sh build/bin/hypringo
sh test/mpris.sh build/bin/hypringo build/bin/mpris_mock
sh test/audio.sh build/bin/hypringo
```

Hyprland 集成测试只使用临时目录下的模拟 command/event socket，覆盖双屏热插拔、
焦点迁移、拔屏、事件分包和断线重连；它不连接或修改当前 Hyprland、Eww 和旧版
Hypringo 进程。MPRIS 测试在私有 D-Bus session 中运行两个 mock player，覆盖稳定
选择、capability signal、typed action 拒绝/执行和 player removal。reload 测试
覆盖成功 generation、非法配置与 restart-required 边界；lifecycle 测试从 daemon
不存在开始监听，执行一次强制崩溃和 stale-socket 恢复，并验证 Eww 收到新进程的
完整 replay 且 listener 没有遗留子进程。audio 测试只读比较当前 default sink 的
snapshot，不修改音量或静音状态。
