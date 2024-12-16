local Hyprctl = require("hyprctl")
local cjson = require("cjson")

local hyprctl = Hyprctl.new()

--- @param monitor table
local handle_external_monitor = function(monitor)
  local name = monitor.name
  local resolution = ("%dx%d"):format(monitor.width, monitor.height)
  if resolution == "1920x1080" then
    hyprctl:write(("/keyword monitor %s,%s,%s,%d"):format(name, "preferred", "0x-1080", 1))
  elseif resolution == "3840x2160" then
    hyprctl:write(("/keyword monitor %s,%s,%s,%d"):format(name, "preferred", "0x-1080", 2))
  end
end

--- @return table
local get_monitors = function()
  local data, err = hyprctl:write("j/monitors")
  if err then
    print("get monitors failed: " .. err)
    return {}
  end
  local monitors = cjson.decode(data)
  return monitors
end

for _, monitor in ipairs(get_monitors()) do
  local name = monitor.name
  if name == "HDMI-A-1" then
    handle_external_monitor(monitor)
  end
  if name == "eDP-1" then
    hyprctl:write(("/keyword monitor %s,%s,%s,%d"):format(name, "preferred", "0x0", 2))
  end
end

hyprctl:register("monitoradded", function(event)
  local monitor_name = event.data
  print("monitor added: " .. monitor_name)
  local monitors = get_monitors()
  for _, monitor in ipairs(monitors) do
    if monitor.name == monitor_name then
      print("monitor found: " .. monitor_name)
      handle_external_monitor(monitor)
      return
    end
  end
  print("monitor not found: " .. monitor_name)
end)

local window_aliases = {
  ["wezterm"] = "wezterm",
  ["chromium"] = "Chrome",
  ["firefox"] = "Firefox",
  ["remmina"] = "Remmina",
  ["wechat"] = "Wechat",
}

hyprctl:register("activewindow", function(event)
  local window = event.data
  print("active window: " .. window)
  local windows = {}
  for w in string.gmatch(window, "[^,]+") do
    windows[#windows + 1] = w
  end
  window = windows[#windows]
  if #windows == 1 then
    for _, name in pairs(window_aliases) do
      if string.match(window, name) then
        window = name
        break
      end
    end
  end
  if not window then
    return
  end
  os.execute("eww update active_window='" .. window .. "'")
end)

hyprctl:register("workspace", function(event)
  local workspace = event.data
  print("active workspace: " .. workspace)
  os.execute("eww update active_workspace='" .. workspace .. "'")
end)

hyprctl:register("*", function(_)
  local data, err = hyprctl:write("j/workspaces")
  if err then
    print("get monitors failed: " .. err)
    return {}
  end
  os.execute("eww update workspaces='" .. data .. "'")
end)

hyprctl:listen()
