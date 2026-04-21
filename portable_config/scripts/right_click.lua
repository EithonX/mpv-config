local mp = require "mp"
local timer = nil
local delay = 0.30
local suppress_single_until = 0

local function clear_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

local function open_menu()
    mp.commandv("script-message", "subtitle-menu-close")
    mp.commandv("script-message", "audio-menu-close")
    mp.commandv("script-message", "chapter-menu-close")
    mp.commandv("script-message", "context-menu-toggle")
end

local function right_click_single()
    if mp.get_time() < suppress_single_until then
        return
    end
    if timer then
        return
    end
    timer = mp.add_timeout(delay, function()
        timer = nil
        open_menu()
    end)
end

local function right_click_double()
    clear_timer()
    suppress_single_until = mp.get_time() + 0.35
    mp.commandv("script-message", "context-menu-close")
    mp.commandv("script-message", "chapter-menu-close")
    mp.commandv("script-message", "subtitle-menu-close")
    mp.commandv("script-message", "audio-menu-close")
    mp.commandv("cycle", "fullscreen")
    local is_fullscreen = mp.get_property_bool("fullscreen")
    mp.osd_message(is_fullscreen and "Fullscreen On" or "Fullscreen Off", 0.5)
end

local function register_bindings()
    mp.add_forced_key_binding("MBTN_RIGHT", "right_click_single", right_click_single)
    mp.add_forced_key_binding("MBTN_RIGHT_DBL", "right_click_double", right_click_double)
end

local function shutdown()
    clear_timer()
    suppress_single_until = 0
end

register_bindings()
mp.add_timeout(0.25, register_bindings)
mp.register_event("file-loaded", function()
    mp.add_timeout(0.10, register_bindings)
end)
mp.register_event("shutdown", shutdown)
