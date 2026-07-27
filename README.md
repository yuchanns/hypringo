<div align = center>

<img src="./assets/Hypringo.png" width="300" height="300" alt="banner">
<br>
<br>

Hyprland + Apple = <strong>Hypringo</strong>

Better Utilize Hyprland in Your Asahi Linux.

</div>

## 当前状态

当前分支提供 Hypringo 的运行时与状态底座：单个原生可执行文件内嵌 Lua 5.5、ltask、yyjson 与内部 Lua service，外部 `config.lua` 作为唯一用户入口。进程内已有单写者状态服务、本地 Unix control socket，以及可选的 Hyprland 事件 source；MPRIS 与 audio source 尚未接入。

## 构建

需要较新的 [luamake](https://github.com/actboy168/luamake)。首次检出后初始化三个源码 submodule，再构建 release 版本：

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
		workers = 2,
		socket_path = "/run/user/1000/hypringo.sock",
	},
	sources = {
		hyprland = {
			enabled = true,
		},
	},
}
```

`socket_path` 必须是绝对路径；通常不需要配置，保留 XDG 默认值即可。

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

## 状态与 Eww 数据流

运行中的 Hypringo 维护带单调 revision 的规范化状态。`status` 读取一次当前 snapshot，`subscribe` 会先重放当前 snapshot，再持续输出后续 revision；每一行都是完整 JSON，订阅者无需自己修补丢失的增量：

```bash
hypringo status
hypringo subscribe --format eww
hypringo status --socket /path/to/hypringo.sock
```

当前 snapshot 已定义 `runtime`、`hyprland`、`media` 和 `audio` 四个稳定 domain。媒体或 Hyprland 不可用时会明确输出 `available=false` 以及清空后的状态，而不是保留上一次成功值。control socket 权限固定为 `0600`；第二个 daemon 会拒绝抢占仍活跃的 socket，进程异常退出留下的 stale socket 会在下一次启动时安全回收。

普通 `status`/`subscribe` 输出带 `revision/state/type` 的 control envelope；
`subscribe --format eww` 直接输出完整 state 对象，适合 Eww 的单一长连接
`deflisten`。示例位于 `contrib/eww/hypringo.yuck`：

```yuck
(include "./hypringo.yuck")

(label :text {hypringo.hyprland.active_window.title})
```

每次 Eww 重新启动监听都会先收到当前完整 snapshot，不需要恢复 delta，也不需要
为 workspace、active window 等字段分别运行轮询脚本。

## systemd user service

安装二进制和 unit 后，把当前 Hyprland/Wayland 会话环境导入 user manager，再启用服务：

```bash
install -Dm755 build/bin/hypringo ~/.local/bin/hypringo
install -Dm644 contrib/systemd/hypringo.service ~/.config/systemd/user/hypringo.service
systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
systemctl --user daemon-reload
systemctl --user enable --now hypringo.service
```

查看日志与配置错误：

```bash
journalctl --user -u hypringo.service -f
```

## 验证

原生 yyjson binding、Lua reducer/config 和 control socket 进程级测试分别运行：

```bash
luamake -mode debug
luamake -mode debug unit
build/bin/unit test/unit.lua
sh test/control.sh build/bin/hypringo
sh test/hyprland.sh build/bin/hypringo
```

Hyprland 集成测试只使用临时目录下的模拟 command/event socket，覆盖双屏热插拔、
焦点迁移、拔屏、事件分包和断线重连；它不连接或修改当前 Hyprland、Eww 和旧版
Hypringo 进程。
