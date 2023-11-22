local Hyprctl = require("hyprctl")
local cjson = require("cjson")

local hyprctl = Hyprctl.new(os.getenv("XDG_RUNTIME_DIR") ..
  "/hypr/" .. os.getenv("HYPRLAND_INSTANCE_SIGNATURE"))

hyprctl:register("monitoradded", function(event)
  local monitor_name = event.data
  print("monitor added: " .. monitor_name)
  local data, err = hyprctl:write("j/monitors")
  if err then
    print("get monitors failed: " .. err)
    return
  end
  local monitors = cjson.decode(data)
  for _, monitor in ipairs(monitors) do
    if monitor.name == monitor_name then
      print("monitor found: " .. monitor_name)
      local resolution = ("%dx%d"):format(monitor.width, monitor.height)
      if resolution == "1920x1080" then
        print()
        hyprctl:write(("/keyword monitor %s,%s,%s,%d"):format(monitor_name, "preferred", "0x-1080", 1))
      elseif resolution == "3840x2160" then
        hyprctl:write(("/keyword monitor %s,%s,%s,%d"):format(monitor_name, "preferred", "0x-1080", 2))
      end
      return
    end
  end
  print("monitor not found: " .. monitor_name)
end)

hyprctl:listen()
