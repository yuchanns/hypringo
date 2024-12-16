local Hyprctl = require("hyprctl")
local cjson = require("cjson")

local hyprctl = Hyprctl.new()

local execute = function(command)
  return pcall(os.execute, command)
end

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

hyprctl:register("activewindow", function(event)
  local window = event.data
  print("active window: " .. window)
  if not window then
    return
  end
  local windows = {}
  for w in string.gmatch(window, "[^,]+") do
    windows[#windows + 1] = w
  end
  window = windows[#windows]
  execute("eww update active_window='" .. window .. "'")
end)

hyprctl:register("workspace", function(event)
  local workspace = event.data
  print("active workspace: " .. workspace)
  execute("eww update active_workspace='" .. workspace .. "'")
end)

hyprctl:register("*", function(_)
  local data, err = hyprctl:write("j/workspaces")
  if err then
    print("get monitors failed: " .. err)
    return
  end
  execute("eww update workspaces='" .. data .. "'")
end)

-- Set monitors on startup
for _, monitor in ipairs(get_monitors()) do
  local name = monitor.name
  if name == "HDMI-A-1" then
    handle_external_monitor(monitor)
    goto continue
  end
  if name == "eDP-1" then
    hyprctl:write(("/keyword monitor %s,%s,%s,%d"):format(name, "preferred", "0x0", 2))
    goto continue
  end
  print("unknown monitor: " .. name)
  ::continue::
end

hyprctl:listen()
