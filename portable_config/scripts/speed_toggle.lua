-- Toggle speed between 1.0x and the last custom speed.
local mp = require "mp"

local state_path = mp.command_native({ "expand-path", "~~/script-opts/speed_toggle_state.txt" })
local saved_speed = 1.0

local function round_speed(speed)
    return tonumber(string.format("%.2f", speed or 1.0)) or 1.0
end

local function load_saved_speed()
    local file = io.open(state_path, "r")
    if not file then
        return
    end

    local value = file:read("*a")
    file:close()

    local parsed = tonumber(value)
    if parsed and parsed > 0 then
        saved_speed = round_speed(parsed)
    end
end

local function persist_saved_speed()
    local file = io.open(state_path, "w")
    if not file then
        return
    end

    file:write(string.format("%.2f", saved_speed))
    file:close()
end

local function remember_speed(_, value)
    if not value then
        return
    end

    local rounded = round_speed(value)
    if math.abs(rounded - 1.0) >= 0.01 then
        saved_speed = rounded
        persist_saved_speed()
    end
end

local function toggle_speed()
    local current_speed = mp.get_property_number("speed")

    if math.abs(current_speed - 1.0) < 0.01 then
        if math.abs(saved_speed - 1.0) > 0.01 then
            mp.set_property("speed", saved_speed)
            mp.osd_message("Speed: " .. saved_speed .. "x")
        else
            mp.osd_message("Speed: 1.0x (No previous speed saved)")
        end
    else
        saved_speed = round_speed(current_speed)
        persist_saved_speed()
        mp.set_property("speed", 1.0)
        mp.osd_message("Speed: 1.0x (Saved " .. saved_speed .. "x)")
    end
end

load_saved_speed()
mp.observe_property("speed", "number", remember_speed)
mp.add_key_binding(nil, "speed-toggle", toggle_speed)
