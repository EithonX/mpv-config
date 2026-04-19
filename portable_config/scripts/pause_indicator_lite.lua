--[[

   A simple script that shows a pause indicator, on pause
   https://github.com/Samillion/ModernZ/tree/main/extras/pause-indicator-lite

--]]

local options = {
    indicator_icon = "pause",
    indicator_stay = true,
    indicator_timeout = 0.6,

    keybind_allow = false,
    keybind_set = "mbtn_left",
    keybind_mode = "onpause",
    keybind_eof_disable = true,

    icon_color = "#FFFFFF",
    icon_border_color = "#111111",
    icon_border_width = 1.5,
    icon_opacity = 28,

    rectangles_width = 22,
    rectangles_height = 56,
    rectangles_spacing = 14,

    triangle_width = 56,
    triangle_height = 56,

    flash_play_icon = true,
    flash_icon_timeout = 0.3,

    fluent_icons = false,
    fluent_icon_size = 80,

    mute_indicator = false,
    mute_indicator_pos = "middle_right",
}

local msg = require "mp.msg"
require "mp.options".read_options(options, "pause_indicator_lite")

local function convert_color(color)
    if color:find("^#%x%x%x%x%x%x$") == nil then
        msg.warn("'" .. color .. "' is not a valid color, using default '#FFFFFF'")
        return "FFFFFF"
    end
    return color:sub(6, 7) .. color:sub(4, 5) .. color:sub(2, 3)
end

local function convert_opacity(value)
    value = math.max(0, math.min(100, value))
    return string.format("%02X", (255 - (value * 2.55)))
end

local icon_color = convert_color(options.icon_color)
local icon_border_color = convert_color(options.icon_border_color)
local icon_opacity = convert_opacity(options.icon_opacity)
local icon_font = "fluent-system-icons"

local function draw_rectangles()
    if options.fluent_icons then
        local pause_icon = "\238\163\140"
        return string.format([[{\\rDefault\\an5\\alpha&H%s\\bord%s\\1c&H%s&\\3c&H%s&\\fs%s\\fn%s}%s]],
            icon_opacity, options.icon_border_width, icon_color, icon_border_color, options.fluent_icon_size, icon_font, pause_icon)
    end

    return string.format([[{\\rDefault\\p1\\an5\\alpha&H%s\\bord%s\\1c&H%s&\\3c&H%s&}m 0 0 l %d 0 l %d %d l 0 %d m %d 0 l %d 0 l %d %d l %d %d{\\p0}]],
        icon_opacity, options.icon_border_width, icon_color, icon_border_color, options.rectangles_width, options.rectangles_width,
        options.rectangles_height, options.rectangles_height, options.rectangles_width + options.rectangles_spacing,
        options.rectangles_width * 2 + options.rectangles_spacing, options.rectangles_width * 2 + options.rectangles_spacing,
        options.rectangles_height, options.rectangles_width + options.rectangles_spacing, options.rectangles_height)
end

local function draw_triangle()
    if options.fluent_icons then
        local play_icon = "\238\166\143"
        return string.format([[{\\rDefault\\an5\\alpha&H%s\\bord%s\\1c&H%s&\\3c&H%s&\\fs%s\\fn%s}%s]],
            icon_opacity, options.icon_border_width, icon_color, icon_border_color, options.fluent_icon_size, icon_font, play_icon)
    end

    return string.format([[{\\rDefault\\p1\\an5\\alpha&H%s\\bord%s\\1c&H%s&\\3c&H%s&}m 0 0 l %d %d l 0 %d{\\p0}]],
        icon_opacity, options.icon_border_width, icon_color, icon_border_color, options.triangle_width, options.triangle_height / 2, options.triangle_height)
end

local function draw_mute()
    if not options.fluent_icons then return end

    local mute_icon = "\238\173\138"
    local mute_pos_list = {
        ["top_left"] = 7,
        ["top_center"] = 8,
        ["top_right"] = 9,
        ["middle_left"] = 4,
        ["middle_center"] = 5,
        ["middle_right"] = 6,
        ["bottom_left"] = 1,
        ["bottom_center"] = 2,
        ["bottom_right"] = 3,
    }
    local mute_pos = mute_pos_list[options.mute_indicator_pos:lower()] or 6
    return string.format([[{\\rDefault\\an%s\\alpha&H%s\\bord%s\\1c&H%s&\\3c&H%s&\\fs%s\\fn%s}%s]],
        mute_pos, icon_opacity, options.icon_border_width, icon_color, icon_border_color, options.fluent_icon_size, icon_font, mute_icon)
end

local indicator = mp.create_osd_overlay("ass-events")
local flash = mp.create_osd_overlay("ass-events")
local mute = mp.create_osd_overlay("ass-events")

local toggled, eof

local function update_indicator()
    local _, _, display_aspect = mp.get_osd_size()
    if display_aspect == 0 or (indicator.visible and not toggled) then return end

    indicator.data = options.indicator_icon == "play" and draw_triangle() or draw_rectangles()
    indicator:update()

    if not options.indicator_stay then
        mp.add_timeout(options.indicator_timeout, function() indicator:remove() end)
    end
end

local function flash_icon()
    if not options.flash_play_icon then return flash:remove() end
    flash.data = draw_triangle()
    flash:update()
    mp.add_timeout(options.flash_icon_timeout, function() flash:remove() end)
end

local function mute_icon()
    mute.data = draw_mute()
    mute:update()
end

local function is_video()
    local track = mp.get_property_native("current-tracks/video")
    return track and not (track.image or track.albumart) and true or false
end

local function shutdown()
    if flash then flash:remove() end
    if indicator then indicator:remove() end
    mp.unobserve_property("pause")
end

if options.keybind_eof_disable then
    mp.observe_property("eof-reached", "bool", function(_, val)
        eof = val
    end)
end

mp.observe_property("pause", "bool", function(_, paused)
    if not is_video() then return shutdown() end
    if paused then
        update_indicator()
        toggled = true
        if options.flash_play_icon then flash:remove() end
    else
        indicator:remove()
        if toggled then
            flash_icon()
            toggled = false
        end
    end

    if options.keybind_allow == true then
        mp.set_key_bindings({
            {options.keybind_set, function() mp.commandv("cycle", "pause") end}
        }, "pause-indicator", "force")

        if options.keybind_mode == "always" or (options.keybind_mode == "onpause" and paused) then
            if not eof then mp.enable_key_bindings("pause-indicator") end
        else
            mp.disable_key_bindings("pause-indicator")
        end
    end
end)

mp.observe_property("osd-dimensions", "native", function()
    if indicator and indicator.visible then
        update_indicator()
    end
end)

if options.mute_indicator and options.fluent_icons then
    mp.observe_property("mute", "bool", function(_, val)
        if val and not mute.visible then mute_icon() else mute:remove() end
    end)
else
    mute:remove()
end
