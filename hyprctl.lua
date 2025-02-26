local unix = require("socket.unix")

local Hyprctl = {}
Hyprctl.__index = Hyprctl

--- @param bind_path string|nil
function Hyprctl.new(bind_path)
  if not bind_path then
    bind_path = os.getenv("XDG_RUNTIME_DIR") ..
        "/hypr/" .. os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
  end
  local self = setmetatable({}, Hyprctl)
  self.bind_path = bind_path
  return self
end

--- @class Event
--- @field name string
--- @field data string|nil

--- @param event_name string
--- @param callback fun(event: Event)
function Hyprctl:register(event_name, callback)
  if not self.event_callback then
    self.event_callback = {}
  end
  if not self.event_callback[event_name] then
    self.event_callback[event_name] = {}
  end
  self.event_callback[event_name][#self.event_callback[event_name] + 1] = callback
end

function Hyprctl:listen()
  local client = assert(unix.stream())
  local socket_path = self.bind_path .. "/.socket2.sock"
  local success, err = client:connect(socket_path)
  if not success then
    return nil, "connect failed: " .. err
  end

  while true do
    ::continue::
    local chunk = ""
    chunk, err = client:receive()
    if chunk then
      -- format: EVENT>>DATA\n
      -- remove \n if exists
      if chunk:sub(-1) == "\n" then
        chunk = chunk:sub(1, -2)
      end
      -- split by `>>`
      local parts = {}
      for part in chunk:gmatch("([^>>]+)") do
        table.insert(parts, part)
      end
      -- IPC events list: https://wiki.hyprland.org/hyprland-wiki/pages/IPC/
      local event = {
        name = parts[1],
      }
      if #parts > 1 then
        event.data = parts[2]
      end
      -- support wildcard callback
      local events = { event.name, "*" }
      for _, evt in ipairs(events) do
        if self.event_callback and self.event_callback[evt] then
          for _, callback in ipairs(self.event_callback[evt]) do
            callback(event)
          end
        end
      end
    end
    if err == "closed" then
      break
    end
    if err then
      print("receive failed: " .. err)
      goto continue
    end
  end
end

--- @param src string
function Hyprctl:write(src)
  local client = assert(unix.stream())
  local socket_path = self.bind_path .. "/.socket.sock"
  local success, err = client:connect(socket_path)
  if not success then
    return nil, "connect failed: " .. err
  end

  -- Write data
  assert(client:send(src))

  -- Read response
  local chunks = {}
  local data = ""
  local chunk = ""
  while true do
    chunk, err = client:receive("*a")
    if chunk then
      table.insert(chunks, chunk)
    end
    if err == "closed" then
      break
    end
    if err then
      return nil, "receive failed: " .. err
    end
  end
  data = table.concat(chunks)

  -- Close socket
  client:close()

  return data
end

return Hyprctl
