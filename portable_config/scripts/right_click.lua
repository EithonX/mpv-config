local mp = require "mp"
local timer = nil
local delay = 0.3

local function right_click_handler()
    if timer then
        timer:kill()
        timer = nil
        mp.command("cycle fullscreen")
        local is_fullscreen = mp.get_property_bool("fullscreen")
        mp.osd_message(is_fullscreen and "Fullscreen On" or "Fullscreen Off", 0.5)
    else
        timer = mp.add_timeout(delay, function()
            timer = nil
            mp.command("script-binding select/menu")
        end)
    end
end

mp.add_forced_key_binding("MBTN_RIGHT", "right_click_smart", right_click_handler)
