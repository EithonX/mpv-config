local mp = require "mp"
local options = {
    font = "Verdana",
    font_size = 16,
    left = 36,
    top = 44,
    max_label_length = 44,
    timeout = 7,
    accent_color = "#FF8232",
    text_color = "#FFFFFF",
    muted_color = "#A8A8A8",
    shadow_color = "#111111",
}

require "mp.options".read_options(options, "subtitle_menu")

local overlay = mp.create_osd_overlay("ass-events")
local shared_state_path = "user-data/subtitle_auto/state"
local menu_open = false
local selected_row = 4
local close_timer = nil

local function normalize_color(color, fallback)
    color = tostring(color or "")
    if color:find("^#%x%x%x%x%x%x$") == nil then
        color = fallback
    end
    return color:sub(6, 7) .. color:sub(4, 5) .. color:sub(2, 3)
end

local accent_color = normalize_color(options.accent_color, "#FF8232")
local text_color = normalize_color(options.text_color, "#FFFFFF")
local muted_color = normalize_color(options.muted_color, "#A8A8A8")
local shadow_color = normalize_color(options.shadow_color, "#111111")

local function font_tag()
    local font = tostring(options.font or ""):gsub("[{}\\]", "")
    if font == "" then
        return ""
    end
    return "\\fn" .. font
end

local function escape_ass(text)
    text = tostring(text or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub("{", "\\{")
    text = text:gsub("}", "\\}")
    text = text:gsub("\n", " ")
    return text
end

local function truncate_text(text)
    text = tostring(text or "")
    if options.max_label_length <= 0 or #text <= options.max_label_length then
        return text
    end
    if options.max_label_length <= 3 then
        return text:sub(1, options.max_label_length)
    end
    return text:sub(1, options.max_label_length - 3) .. "..."
end

local function subtitle_tracks()
    local subs = {}
    local tracks = mp.get_property_native("track-list") or {}
    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.id then
            subs[#subs + 1] = track
        end
    end
    table.sort(subs, function(left, right)
        return tonumber(left.id) < tonumber(right.id)
    end)
    return subs
end

local function find_track_by_id(id, tracks)
    local numeric_id = tonumber(id)
    if not numeric_id or numeric_id < 0 then
        return nil
    end

    for _, track in ipairs(tracks or subtitle_tracks()) do
        if tonumber(track.id) == numeric_id then
            return track
        end
    end

    return nil
end

local function display_track_name(track)
    if not track then
        return "Off"
    end

    local title = tostring(track.title or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    if title ~= "" then
        return title .. " [#" .. tostring(track.id) .. "]"
    end

    local lang = tostring(track.lang or ""):upper()
    if lang ~= "" then
        return lang .. " [#" .. tostring(track.id) .. "]"
    end

    return "Track #" .. tostring(track.id)
end

local function current_mode()
    local sub_visible = mp.get_property_bool("sub-visibility")
    local secondary_visible = mp.get_property_bool("secondary-sub-visibility")
    local secondary_sid = mp.get_property("secondary-sid")

    if not sub_visible then
        return "off"
    end

    if secondary_visible and secondary_sid and secondary_sid ~= "no" then
        return "dual"
    end

    return "primary"
end

local function auto_state()
    local shared = mp.get_property_native(shared_state_path)
    if type(shared) ~= "table" then
        return {}
    end
    return shared
end

local function clear_close_timer()
    if close_timer then
        close_timer:kill()
        close_timer = nil
    end
end

local function close_menu()
    clear_close_timer()
    menu_open = false
    overlay:remove()
    mp.remove_key_binding("subtitle-menu-up")
    mp.remove_key_binding("subtitle-menu-down")
    mp.remove_key_binding("subtitle-menu-left")
    mp.remove_key_binding("subtitle-menu-right")
    mp.remove_key_binding("subtitle-menu-wheel-up")
    mp.remove_key_binding("subtitle-menu-wheel-down")
    mp.remove_key_binding("subtitle-menu-enter")
    mp.remove_key_binding("subtitle-menu-kp-enter")
    mp.remove_key_binding("subtitle-menu-escape")
end

local function reset_close_timer()
    clear_close_timer()
    if options.timeout <= 0 then
        return
    end
    close_timer = mp.add_timeout(options.timeout, close_menu)
end

local function first_alternate_track(tracks, excluded_id, preferred_id)
    local preferred = find_track_by_id(preferred_id, tracks)
    if preferred and tonumber(preferred.id) ~= tonumber(excluded_id) then
        return preferred
    end

    for _, track in ipairs(tracks) do
        if tonumber(track.id) ~= tonumber(excluded_id) then
            return track
        end
    end

    return nil
end

local function ensure_primary_track(tracks)
    return find_track_by_id(mp.get_property_number("sid", -1), tracks) or tracks[1]
end

local function disable_secondary()
    mp.set_property("secondary-sid", "no")
    mp.set_property_bool("secondary-sub-visibility", false)
end

local function set_primary_track(track_id)
    local tracks = subtitle_tracks()
    if #tracks == 0 then
        return
    end

    local keep_dual = current_mode() == "dual"
    local primary = find_track_by_id(track_id, tracks) or ensure_primary_track(tracks)
    local current_secondary = find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks)

    mp.set_property_number("sid", tonumber(primary.id))
    mp.set_property_bool("sub-visibility", true)

    if keep_dual then
        local secondary = first_alternate_track(tracks, primary.id, current_secondary and current_secondary.id)
        if secondary then
            mp.set_property_number("secondary-sid", tonumber(secondary.id))
            mp.set_property_bool("secondary-sub-visibility", true)
        else
            disable_secondary()
        end
    else
        disable_secondary()
    end
end

local function set_secondary_track(track_id)
    local tracks = subtitle_tracks()
    if #tracks == 0 then
        return
    end

    local primary = ensure_primary_track(tracks)
    mp.set_property_number("sid", tonumber(primary.id))
    mp.set_property_bool("sub-visibility", true)

    if not track_id then
        disable_secondary()
        return
    end

    local secondary = find_track_by_id(track_id, tracks)
    if not secondary or tonumber(secondary.id) == tonumber(primary.id) then
        secondary = first_alternate_track(tracks, primary.id)
    end

    if secondary then
        mp.set_property_number("secondary-sid", tonumber(secondary.id))
        mp.set_property_bool("secondary-sub-visibility", true)
    else
        disable_secondary()
    end
end

local function cycle_track_id(tracks, current_id, step, include_off, excluded_id)
    local choices = {}
    if include_off then
        choices[#choices + 1] = false
    end

    for _, track in ipairs(tracks) do
        if tonumber(track.id) ~= tonumber(excluded_id) then
            choices[#choices + 1] = tonumber(track.id)
        end
    end

    if #choices == 0 then
        return nil
    end

    local current_index = 1
    local target_id = tonumber(current_id)
    if include_off and not target_id then
        current_index = 1
    else
        for index, choice in ipairs(choices) do
            if choice == false and not target_id then
                current_index = index
                break
            end
            if choice ~= false and tonumber(choice) == target_id then
                current_index = index
                break
            end
        end
    end

    local next_index = ((current_index - 1 + step) % #choices) + 1
    return choices[next_index]
end

local function cycle_mode(step)
    local tracks = subtitle_tracks()
    if #tracks == 0 then
        return
    end

    local modes = { "primary" }
    local current = current_mode()
    local smart = auto_state()
    local primary = find_track_by_id(mp.get_property_number("sid", -1), tracks)
    local secondary = find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks)
    local has_manual_dual = current == "dual"
        and primary
        and secondary
        and tonumber(primary.id) ~= tonumber(secondary.id)

    if has_manual_dual or smart.smart_dual_available then
        modes[#modes + 1] = "dual"
    end

    modes[#modes + 1] = "off"
    local current_index = 1

    for index, mode in ipairs(modes) do
        if mode == current then
            current_index = index
            break
        end
    end

    local next_index = ((current_index - 1 + step) % #modes) + 1
    mp.commandv("script-message", "set-subtitle-mode", modes[next_index])
end

local function cycle_primary(step)
    local tracks = subtitle_tracks()
    if #tracks == 0 then
        return
    end

    local primary = ensure_primary_track(tracks)
    local next_id = cycle_track_id(tracks, primary and primary.id, step, false)
    if next_id then
        set_primary_track(next_id)
    end
end

local function cycle_secondary(step)
    local tracks = subtitle_tracks()
    if #tracks == 0 then
        return
    end

    local primary = ensure_primary_track(tracks)
    local mode = current_mode()
    local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
    local next_id = cycle_track_id(tracks, secondary and secondary.id, step, true, primary.id)
    set_secondary_track(next_id)
end

local function color_text(text, color, bold, size)
    local tags = "\\1c&H" .. color .. "&"
    if bold then
        tags = tags .. "\\b1"
    end
    if size then
        tags = tags .. "\\fs" .. tostring(size)
    end
    return "{" .. tags .. "}" .. escape_ass(text)
end

local function mode_token(label, active)
    if active then
        return color_text("[" .. label:upper() .. "]", accent_color, true)
    end
    return color_text(label, muted_color, false)
end

local function build_mode_line(mode, active)
    local prefix = active and color_text("> ", accent_color, true) or color_text("  ", muted_color, false)
    local label = color_text("Mode ", active and accent_color or muted_color, true)
    return prefix
        .. label
        .. mode_token("Primary", mode == "primary")
        .. color_text("  ", muted_color, false)
        .. mode_token("Dual", mode == "dual")
        .. color_text("  ", muted_color, false)
        .. mode_token("Off", mode == "off")
end

local function build_track_line(label, value, active, muted)
    local prefix = active and color_text("> ", accent_color, true) or color_text("  ", muted_color, false)
    local label_color = active and accent_color or muted_color
    local value_color = muted and muted_color or text_color
    return prefix
        .. color_text(label .. ": ", label_color, true)
        .. color_text(truncate_text(value), value_color, false)
end

local function build_action_line(label, value, active, unavailable)
    local prefix = active and color_text("> ", accent_color, true) or color_text("  ", muted_color, false)
    local label_color = active and accent_color or muted_color
    local value_color = unavailable and muted_color or text_color
    return prefix
        .. color_text(label .. ": ", label_color, true)
        .. color_text(truncate_text(value), value_color, false)
end

local function render_menu()
    if not menu_open then
        return
    end

    local tracks = subtitle_tracks()
    local mode = current_mode()
    local smart = auto_state()
    local row_count = #tracks > 0 and 5 or 1
    if selected_row > row_count then
        selected_row = row_count
    end

    local primary = #tracks > 0 and ensure_primary_track(tracks) or nil
    local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
    local font_size = tonumber(options.font_size) or 16
    local help_size = math.max(12, font_size - 2)
    local body_size = math.max(12, font_size)
    local audio_summary = tostring(smart.audio_summary or "Audio unknown")
    local smart_primary_value = tostring(smart.smart_primary_label or "Unavailable")
    local smart_dual_value = "Unavailable"
    if smart.smart_dual_available then
        smart_dual_value = tostring(smart.smart_dual_primary_label or "None")
            .. " + "
            .. tostring(smart.smart_dual_secondary_label or "None")
    end

    local lines = {
        color_text("Subtitles", accent_color, true, body_size + 2)
            .. color_text("  " .. tostring(#tracks) .. " track(s)", muted_color, false, help_size)
            .. color_text("  Audio: " .. truncate_text(audio_summary), muted_color, false, help_size),
    }

    if #tracks == 0 then
        lines[#lines + 1] = build_track_line("Status", "No subtitle tracks found", true, true)
        lines[#lines + 1] = color_text("Enter or Esc closes this menu.", muted_color, false, help_size)
    else
        lines[#lines + 1] = build_action_line("Auto Primary", smart_primary_value, selected_row == 1, not smart.smart_primary_available)
        lines[#lines + 1] = build_action_line("Auto Dual", smart_dual_value, selected_row == 2, not smart.smart_dual_available)
        lines[#lines + 1] = build_mode_line(mode, selected_row == 3)
        lines[#lines + 1] = build_track_line("Primary", display_track_name(primary), selected_row == 4, false)
        lines[#lines + 1] = build_track_line("Secondary", display_track_name(secondary), selected_row == 5, mode ~= "dual")
        lines[#lines + 1] = color_text("Up/Down select  Left/Right change  Enter applies auto  Esc closes", muted_color, false, help_size)
    end

    local ass = string.format(
        "{\\an7\\pos(%d,%d)%s\\fs%d\\bord1\\shad0\\3c&H%s&}",
        tonumber(options.left) or 36,
        tonumber(options.top) or 44,
        font_tag(),
        body_size,
        shadow_color
    )

    ass = ass .. table.concat(lines, "\\N")
    overlay.data = ass
    overlay:update()
    reset_close_timer()
end

local function move_selection(step)
    local row_count = #subtitle_tracks() > 0 and 5 or 1
    selected_row = ((selected_row - 1 + step) % row_count) + 1
    render_menu()
end

local function change_value(step)
    if selected_row == 1 then
        mp.commandv("script-message", "smart-select-subtitles", "primary")
    elseif selected_row == 2 then
        mp.commandv("script-message", "smart-select-subtitles", "dual")
    elseif selected_row == 3 then
        cycle_mode(step)
    elseif selected_row == 4 then
        cycle_primary(step)
    else
        cycle_secondary(step)
    end
    render_menu()
end

local function activate_selection()
    if selected_row == 1 then
        mp.commandv("script-message", "smart-select-subtitles", "primary")
        render_menu()
        return
    end

    if selected_row == 2 then
        mp.commandv("script-message", "smart-select-subtitles", "dual")
        render_menu()
        return
    end

    close_menu()
end

local function bind_navigation_keys()
    mp.add_forced_key_binding("UP", "subtitle-menu-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("DOWN", "subtitle-menu-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("LEFT", "subtitle-menu-left", function() change_value(-1) end, { repeatable = true })
    mp.add_forced_key_binding("RIGHT", "subtitle-menu-right", function() change_value(1) end, { repeatable = true })
    mp.add_forced_key_binding("WHEEL_UP", "subtitle-menu-wheel-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("WHEEL_DOWN", "subtitle-menu-wheel-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("ENTER", "subtitle-menu-enter", activate_selection)
    mp.add_forced_key_binding("KP_ENTER", "subtitle-menu-kp-enter", activate_selection)
    mp.add_forced_key_binding("ESC", "subtitle-menu-escape", close_menu)
end

local function open_menu()
    if menu_open then
        render_menu()
        return
    end

    menu_open = true
    selected_row = #subtitle_tracks() > 0 and 4 or 1
    bind_navigation_keys()
    render_menu()
end

local function toggle_menu()
    if menu_open then
        close_menu()
    else
        open_menu()
    end
end

mp.add_key_binding(nil, "subtitle-menu-toggle", toggle_menu)
mp.observe_property("sid", "native", function()
    render_menu()
end)
mp.observe_property("secondary-sid", "native", function()
    render_menu()
end)
mp.observe_property("sub-visibility", "bool", function()
    render_menu()
end)
mp.observe_property("secondary-sub-visibility", "bool", function()
    render_menu()
end)
mp.observe_property("track-list", "native", function()
    render_menu()
end)
mp.observe_property(shared_state_path, "native", function()
    render_menu()
end)
mp.register_event("file-loaded", close_menu)
mp.register_event("end-file", close_menu)
mp.register_event("shutdown", close_menu)
