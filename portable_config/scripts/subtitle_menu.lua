local mp = require "mp"

local options = {
    font = "Verdana",
    font_size = 16,
    left = 36,
    top = 44,
    max_label_length = 44,
    picker_rows = 8,
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
local selected_row = 1
local picker_kind = nil
local picker_index = 1
local close_timer = nil
local render_menu

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

local function close_picker()
    picker_kind = nil
    picker_index = 1
end

local function close_menu()
    clear_close_timer()
    menu_open = false
    close_picker()
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
    if #tracks < 2 then
        disable_secondary()
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
    if #tracks < 2 then
        return
    end

    local primary = ensure_primary_track(tracks)
    local mode = current_mode()
    local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
    local next_id = cycle_track_id(tracks, secondary and secondary.id, step, true, primary.id)
    set_secondary_track(next_id)
end

local function current_track_id(kind, tracks)
    if kind == "secondary" then
        local mode = current_mode()
        local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
        return secondary and tonumber(secondary.id) or false
    end

    local primary = ensure_primary_track(tracks)
    return primary and tonumber(primary.id) or nil
end

local function picker_choices(kind, tracks)
    local choices = {}

    if kind == "secondary" then
        choices[#choices + 1] = {
            id = false,
            label = "Off",
            muted = true,
        }

        local primary = ensure_primary_track(tracks)
        local primary_id = primary and tonumber(primary.id) or nil

        for _, track in ipairs(tracks) do
            if tonumber(track.id) ~= primary_id then
                choices[#choices + 1] = {
                    id = tonumber(track.id),
                    label = display_track_name(track),
                }
            end
        end

        return choices
    end

    for _, track in ipairs(tracks) do
        choices[#choices + 1] = {
            id = tonumber(track.id),
            label = display_track_name(track),
        }
    end

    return choices
end

local function set_picker_index_for_current(tracks)
    if not picker_kind then
        return
    end

    local choices = picker_choices(picker_kind, tracks)
    if #choices == 0 then
        close_picker()
        return
    end

    local target_id = current_track_id(picker_kind, tracks)
    picker_index = math.min(math.max(picker_index, 1), #choices)

    for index, choice in ipairs(choices) do
        if choice.id == false and target_id == false then
            picker_index = index
            return
        end
        if choice.id ~= false and tonumber(choice.id) == tonumber(target_id) then
            picker_index = index
            return
        end
    end
end

local function clamp_picker_index(tracks)
    if not picker_kind then
        return
    end

    local choices = picker_choices(picker_kind, tracks)
    if #choices == 0 then
        close_picker()
        return
    end

    picker_index = math.min(math.max(picker_index, 1), #choices)
end

local function open_picker(kind)
    local tracks = subtitle_tracks()
    if #tracks == 0 then
        return
    end

    if kind == "secondary" and #tracks < 2 then
        mp.osd_message("Secondary subtitle needs at least 2 tracks", 1.2)
        return
    end

    selected_row = kind == "secondary" and 4 or 3
    picker_kind = kind
    picker_index = 1
    set_picker_index_for_current(tracks)
end

local function move_picker(step)
    local tracks = subtitle_tracks()
    local choices = picker_choices(picker_kind, tracks)
    if #choices == 0 then
        return
    end

    picker_index = ((picker_index - 1 + step) % #choices) + 1
    render_menu()
end

local function apply_picker_selection()
    local tracks = subtitle_tracks()
    local choices = picker_choices(picker_kind, tracks)
    if #choices == 0 then
        close_picker()
        render_menu()
        return
    end

    local choice = choices[picker_index]
    if not choice then
        return
    end

    if picker_kind == "secondary" then
        set_secondary_track(choice.id)
    else
        set_primary_track(choice.id)
    end

    set_picker_index_for_current(subtitle_tracks())
    render_menu()
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

local function smart_token(label, active, available)
    if not available then
        return color_text(label, muted_color, false)
    end
    if active then
        return color_text("[" .. label:upper() .. "]", accent_color, true)
    end
    return color_text(label, text_color, false)
end

local function current_smart_kind(mode, primary, secondary, smart)
    if smart.smart_dual_available
        and mode == "dual"
        and primary
        and secondary
        and tonumber(primary.id) == tonumber(smart.smart_dual_primary_id)
        and tonumber(secondary.id) == tonumber(smart.smart_dual_secondary_id) then
        return "dual"
    end

    if smart.smart_primary_available
        and mode == "primary"
        and primary
        and tonumber(primary.id) == tonumber(smart.smart_primary_id) then
        return "primary"
    end

    return nil
end

local function build_smart_line(active, smart_kind, primary_available, dual_available)
    local prefix = active and color_text("> ", accent_color, true) or color_text("  ", muted_color, false)
    local label = color_text("Smart ", active and accent_color or muted_color, true)
    return prefix
        .. label
        .. smart_token("Primary", smart_kind == "primary", primary_available)
        .. color_text("  ", muted_color, false)
        .. smart_token("Dual", smart_kind == "dual", dual_available)
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

local function build_section_line(label, size)
    return color_text(label, muted_color, true, size)
end

local function build_picker_line(label, active, current, muted)
    local prefix = active and color_text("> ", accent_color, true) or color_text("  ", muted_color, false)
    local value_color = muted and muted_color or text_color
    local value_bold = active or current
    local suffix = current and color_text("  active", active and accent_color or muted_color, false) or ""

    if active then
        value_color = accent_color
    elseif current then
        value_color = text_color
    end

    return prefix
        .. color_text(truncate_text(label), value_color, value_bold)
        .. suffix
end

local function picker_target_token(label, active)
    if active then
        return color_text("[" .. label:upper() .. "]", accent_color, true)
    end
    return color_text(label, muted_color, false)
end

local function build_picker_target_line()
    local prefix = color_text("  ", muted_color, false)
    local label = color_text("Target ", muted_color, true)
    return prefix
        .. label
        .. picker_target_token("Primary", picker_kind == "primary")
        .. color_text("  ", muted_color, false)
        .. picker_target_token("Secondary", picker_kind == "secondary")
end

local function build_meta_summary(track_count, smart)
    if track_count <= 0 then
        return "No subtitle tracks"
    end

    local parts = {
        tostring(track_count) .. (track_count == 1 and " track" or " tracks"),
    }

    local audio_summary = tostring(smart.audio_summary or "")
    if audio_summary ~= "" then
        parts[#parts + 1] = audio_summary
    end

    if track_count == 1 then
        parts[#parts + 1] = "primary/off only"
    elseif smart.smart_dual_available then
        parts[#parts + 1] = "smart dual ready"
    end

    return truncate_text(table.concat(parts, " | "))
end

local function smart_primary_available(tracks, smart)
    return #tracks > 0 and smart.smart_primary_available == true
end

local function smart_dual_available(tracks, smart)
    return #tracks > 1 and smart.smart_dual_available == true
end

local function picker_window(choice_count)
    local max_rows = math.max(3, tonumber(options.picker_rows) or 8)
    local first_index = 1
    local last_index = choice_count

    if choice_count > max_rows then
        local half_window = math.floor(max_rows / 2)
        first_index = picker_index - half_window
        last_index = first_index + max_rows - 1

        if first_index < 1 then
            first_index = 1
            last_index = max_rows
        elseif last_index > choice_count then
            last_index = choice_count
            first_index = choice_count - max_rows + 1
        end
    end

    return first_index, last_index
end

local function apply_auto_selection(kind)
    local tracks = subtitle_tracks()
    local smart = auto_state()

    if kind == "dual" then
        if #tracks < 2 then
            mp.osd_message("Auto Dual needs at least 2 subtitle tracks", 1.2)
            return false
        end
        if not smart_dual_available(tracks, smart) then
            mp.osd_message("Auto Dual: no clean signs/dialogue pair found", 1.2)
            return false
        end
    else
        if not smart_primary_available(tracks, smart) then
            mp.osd_message("Auto Primary unavailable", 1.2)
            return false
        end
    end

    mp.commandv("script-message", "smart-select-subtitles", kind)
    return true
end

local function cycle_smart(step)
    local tracks = subtitle_tracks()
    local smart = auto_state()
    local choices = {}

    if smart_primary_available(tracks, smart) then
        choices[#choices + 1] = "primary"
    end
    if smart_dual_available(tracks, smart) then
        choices[#choices + 1] = "dual"
    end

    if #choices == 0 then
        mp.osd_message("No smart subtitle choice available", 1.2)
        return
    end

    local mode = current_mode()
    local primary = ensure_primary_track(tracks)
    local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
    local current_kind = current_smart_kind(mode, primary, secondary, smart)
    local current_index = nil

    for index, choice in ipairs(choices) do
        if choice == current_kind then
            current_index = index
            break
        end
    end

    local next_index
    if current_index then
        next_index = ((current_index - 1 + step) % #choices) + 1
    elseif step >= 0 then
        next_index = 1
    else
        next_index = #choices
    end

    apply_auto_selection(choices[next_index])
end

render_menu = function()
    if not menu_open then
        return
    end

    local tracks = subtitle_tracks()
    clamp_picker_index(tracks)

    local mode = current_mode()
    local smart = auto_state()
    local row_count = #tracks > 0 and 4 or 1
    if selected_row > row_count then
        selected_row = row_count
    end

    local primary = #tracks > 0 and ensure_primary_track(tracks) or nil
    local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
    local smart_kind = current_smart_kind(mode, primary, secondary, smart)
    local font_size = tonumber(options.font_size) or 16
    local help_size = math.max(12, font_size - 2)
    local body_size = math.max(12, font_size)

    local lines = {
        color_text("Subtitles", accent_color, true, body_size + 2)
            .. color_text("  " .. build_meta_summary(#tracks, smart), muted_color, false, help_size),
    }

    if #tracks == 0 then
        lines[#lines + 1] = build_track_line("Status", "No subtitle tracks found", true, true)
        lines[#lines + 1] = color_text("Enter or Esc closes this menu.", muted_color, false, help_size)
    elseif picker_kind then
        local choices = picker_choices(picker_kind, tracks)
        local first_index, last_index = picker_window(#choices)
        local picker_title = "Manual Subtitle Tracks"
        local active_id = current_track_id(picker_kind, tracks)

        lines[#lines + 1] = color_text(picker_title, accent_color, true, body_size)
        lines[#lines + 1] = build_picker_target_line()

        if picker_kind == "secondary" then
            lines[#lines + 1] = build_track_line("Primary", display_track_name(primary), false, false)
        end

        lines[#lines + 1] = color_text("Up/Down browse  Enter applies  Right switches target  Left summary  Esc closes", muted_color, false, help_size)

        if first_index > 1 then
            lines[#lines + 1] = color_text("  ...", muted_color, false, help_size)
        end

        for index = first_index, last_index do
            local choice = choices[index]
            local current = (choice.id == false and active_id == false)
                or (choice.id ~= false and tonumber(choice.id) == tonumber(active_id))
            lines[#lines + 1] = build_picker_line(choice.label, index == picker_index, current, choice.muted == true)
        end

        if last_index < #choices then
            lines[#lines + 1] = color_text("  ...", muted_color, false, help_size)
        end
    else
        local secondary_value = "Off"
        local secondary_muted = mode ~= "dual"
        if #tracks < 2 then
            secondary_value = "Need 2 tracks"
            secondary_muted = true
        elseif mode == "dual" then
            secondary_value = display_track_name(secondary)
            secondary_muted = false
        end

        lines[#lines + 1] = build_section_line("Quick", help_size)
        lines[#lines + 1] = build_mode_line(mode, selected_row == 1)
        lines[#lines + 1] = build_smart_line(selected_row == 2, smart_kind, smart_primary_available(tracks, smart), smart_dual_available(tracks, smart))
        lines[#lines + 1] = build_section_line("Manual", help_size)
        lines[#lines + 1] = build_track_line("Primary", display_track_name(primary), selected_row == 3, false)
        lines[#lines + 1] = build_track_line("Secondary", secondary_value, selected_row == 4, secondary_muted)
        lines[#lines + 1] = color_text("Left/Right quick change Mode/Smart  Enter opens manual list  Esc closes", muted_color, false, help_size)
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
    if picker_kind then
        move_picker(step)
        return
    end

    local row_count = #subtitle_tracks() > 0 and 4 or 1
    selected_row = ((selected_row - 1 + step) % row_count) + 1
    render_menu()
end

local function change_value(step)
    if picker_kind then
        if step < 0 then
            close_picker()
        elseif #subtitle_tracks() > 1 then
            if picker_kind == "primary" then
                open_picker("secondary")
            else
                open_picker("primary")
            end
        else
            mp.osd_message("Only one subtitle track available", 1.2)
            return
        end
        render_menu()
        return
    end

    if selected_row == 1 then
        cycle_mode(step)
    elseif selected_row == 2 then
        cycle_smart(step)
    elseif selected_row == 3 then
        if step > 0 then
            open_picker("primary")
        end
    elseif step > 0 then
        open_picker("secondary")
    end
    render_menu()
end

local function activate_selection()
    if picker_kind then
        apply_picker_selection()
        return
    end

    if #subtitle_tracks() == 0 then
        close_menu()
        return
    end

    if selected_row == 1 then
        cycle_mode(1)
        render_menu()
        return
    end

    if selected_row == 2 then
        cycle_smart(1)
        render_menu()
        return
    end

    if selected_row == 3 then
        open_picker("primary")
        render_menu()
        return
    end

    if selected_row == 4 then
        open_picker("secondary")
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
    close_picker()
    selected_row = 1
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
mp.register_script_message("subtitle-menu-close", close_menu)
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
