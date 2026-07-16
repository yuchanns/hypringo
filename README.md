<div align = center>

<img src="./assets/Hypringo.png" width="300" height="300" alt="banner">
<br>
<br>

Hyprland + Apple = <strong>Hypringo</strong>

Better Utilize Hyprland in Your Asahi Linux.

</div>

## 当前状态

当前分支提供 Hypringo 的运行时与状态底座：单个原生可执行文件内嵌 Lua 5.5、ltask 与内部 Lua service，外部 `config.lua` 作为唯一用户入口。进程内已有单写者状态服务和本地 Unix control socket；Hyprland、MPRIS 与 audio source 尚未接入。

## 构建

需要较新的 [luamake](https://github.com/actboy168/luamake)。首次检出后初始化两个源码 submodule，再构建 release 版本：

```bash
git submodule update --init
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
}
```

`socket_path` 必须是绝对路径；通常不需要配置，保留 XDG 默认值即可。

## 状态与 Eww 数据流

运行中的 Hypringo 维护带单调 revision 的规范化状态。`status` 读取一次当前 snapshot，`subscribe` 会先重放当前 snapshot，再持续输出后续 revision；每一行都是完整 JSON，订阅者无需自己修补丢失的增量：

```bash
hypringo status
hypringo subscribe --format eww
hypringo status --socket /path/to/hypringo.sock
```

当前 snapshot 已定义 `runtime`、`hyprland`、`media` 和 `audio` 四个稳定 domain。媒体不可用时会明确输出 `available=false` 以及清空后的 metadata，而不是保留上一次成功值。control socket 权限固定为 `0600`；第二个 daemon 会拒绝抢占仍活跃的 socket，进程异常退出留下的 stale socket 会在下一次启动时安全回收。

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

纯 Lua reducer/JSON/config 单元测试和 control socket 进程级测试分别运行：

```bash
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" luamake lua test/unit.lua
sh test/control.sh build/bin/hypringo
```
