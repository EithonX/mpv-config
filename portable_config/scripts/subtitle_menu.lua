local mp = require "mp"

local options = {
    font = "Consolas",
    font_size = 16,
    left = 36,
    top = 44,
    panel_chars = 44,
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
local last_click_targets = {}
local last_line_height = 22
local last_panel_width = 320
local last_line_count = 0

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
    mp.remove_key_binding("subtitle-menu-mouse-left")
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
    if track_id == false then
        mp.set_property_bool("sub-visibility", false)
        disable_secondary()
        return
    end

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

local function current_track_id(kind, tracks)
    if kind == "secondary" then
        local mode = current_mode()
        local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
        return secondary and tonumber(secondary.id) or false
    end

    if not mp.get_property_bool("sub-visibility") then
        return false
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

    choices[#choices + 1] = {
        id = false,
        label = "Off",
        muted = true,
    }

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

local function compact_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function panel_chars()
    local value = tonumber(options.panel_chars)
    if value and value >= 28 then
        return math.floor(value)
    end
    return 44
end

local function fit_panel_text(text, width)
    text = compact_text(text)
    if width <= 0 then
        return ""
    end
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function join_columns(left, right, width)
    left = compact_text(left)
    right = compact_text(right)

    if right == "" then
        left = fit_panel_text(left, width)
        return left .. string.rep(" ", width - #left)
    end

    right = fit_panel_text(right, width)
    local gap = 2
    local max_left = math.max(0, width - #right - gap)
    left = fit_panel_text(left, max_left)
    local spaces = math.max(gap, width - #left - #right)
    return left .. string.rep(" ", spaces) .. right
end

local function frame_line(content, color, bold)
    return color_text("| " .. content .. " |", color, bold)
end

local function border_line()
    return color_text("+" .. string.rep("-", panel_chars() + 2) .. "+", accent_color, false)
end

local function divider_line()
    return color_text("|" .. string.rep("-", panel_chars() + 2) .. "|", muted_color, false)
end

local function header_line(title, right)
    return frame_line(join_columns(title, right, panel_chars()), accent_color, true)
end

local function menu_line(left, right, selected, muted, bold)
    local marker = selected and "> " or "  "
    local content = marker .. join_columns(compact_text(left), right or "", panel_chars() - #marker)
    local color = muted and muted_color or text_color

    if selected then
        color = accent_color
    end

    return frame_line(content, color, bold or selected)
end

local function note_line(text)
    return frame_line(join_columns(fit_panel_text(text, panel_chars()), "", panel_chars()), muted_color, false)
end

local function choice_token(label, active, available)
    if available == false then
        return "--"
    end
    if active then
        return "[" .. string.upper(label) .. "]"
    end
    return label
end

local function mode_summary_text(mode, dual_available)
    return table.concat({
        choice_token("Primary", mode == "primary", true),
        choice_token("Dual", mode == "dual", dual_available),
        choice_token("Off", mode == "off", true),
    }, " | ")
end

local function auto_status_text(kind, primary_available, dual_available)
    if kind == "primary" then
        return "[PRIMARY]"
    end
    if kind == "dual" then
        return "[DUAL]"
    end
    if primary_available or dual_available then
        return "READY"
    end
    return "NONE"
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
    local subtitle_count_label = tostring(#tracks) .. (#tracks == 1 and " track" or " tracks")
    local dual_available = #tracks > 1 and ((mode == "dual" and secondary ~= nil) or smart.smart_dual_available == true)

    local lines = {}
    local click_targets = {}
    local function push_line(text, action)
        lines[#lines + 1] = text
        click_targets[#lines] = action
    end

    push_line(border_line())

    if #tracks == 0 then
        push_line(header_line("SUBTITLES", "none"))
        push_line(divider_line())
        push_line(menu_line("No subtitle tracks", "", false, true, false))
        push_line(divider_line())
        push_line(note_line("Esc close"))
    elseif picker_kind then
        local choices = picker_choices(picker_kind, tracks)
        local first_index, last_index = picker_window(#choices)
        local picker_title = "MANUAL SUBTITLES"
        local active_id = current_track_id(picker_kind, tracks)

        push_line(header_line(picker_title, string.upper(picker_kind)))
        push_line(divider_line())

        if picker_kind == "secondary" then
            push_line(menu_line("Primary", display_track_name(primary), false, false, true))
            push_line(divider_line())
        end

        if first_index > 1 then
            push_line(menu_line("...", "", false, true, false))
        end

        for index = first_index, last_index do
            local choice = choices[index]
            local current = (choice.id == false and active_id == false)
                or (choice.id ~= false and tonumber(choice.id) == tonumber(active_id))
            local right = current and "[ACTIVE]" or ""
            push_line(menu_line(choice.label, right, index == picker_index, choice.muted == true, current), function()
                picker_index = index
                render_menu()
            end)
        end

        if last_index < #choices then
            push_line(menu_line("...", "", false, true, false))
        end

        push_line(divider_line())
        push_line(note_line("Up/Down browse  Enter apply  Right target"))
        push_line(note_line("Click select  Enter apply  Esc close"))
    else
        local primary_value = mode == "off" and "Off" or display_track_name(primary)
        local primary_muted = mode == "off"
        local secondary_value = "Off"
        local secondary_muted = mode ~= "dual"
        if #tracks < 2 then
            secondary_value = "Need 2 tracks"
            secondary_muted = true
        elseif mode == "dual" then
            secondary_value = display_track_name(secondary)
            secondary_muted = false
        end

        push_line(header_line("SUBTITLES", subtitle_count_label))
        push_line(divider_line())
        push_line(menu_line("Mode", "[" .. string.upper(mode) .. "]", selected_row == 1, false, true), function()
            selected_row = 1
            render_menu()
        end)
        push_line(note_line(mode_summary_text(mode, dual_available)))
        push_line(menu_line(
            "Auto",
            auto_status_text(smart_kind, smart_primary_available(tracks, smart), smart_dual_available(tracks, smart)),
            selected_row == 2,
            not smart_primary_available(tracks, smart) and not smart_dual_available(tracks, smart),
            true
        ), function()
            selected_row = 2
            render_menu()
        end)
        push_line(note_line("Recommended tracks"))
        push_line(divider_line())
        push_line(menu_line("Primary", primary_value, selected_row == 3, primary_muted, true), function()
            selected_row = 3
            open_picker("primary")
            render_menu()
        end)
        push_line(menu_line("Secondary", secondary_value, selected_row == 4, secondary_muted, true), function()
            selected_row = 4
            open_picker("secondary")
            render_menu()
        end)
        push_line(divider_line())
        push_line(note_line("Left/Right cycle Mode or Auto"))
        push_line(note_line("Left/Right/Enter open manual list"))
        push_line(note_line("Click select  Enter apply  Esc close"))
    end

    push_line(border_line())
    last_click_targets = click_targets
    last_line_count = #lines
    last_line_height = math.max(18, body_size + 6)
    last_panel_width = math.floor((panel_chars() + 4) * math.max(7, body_size * 0.62))

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
        open_picker("primary")
    elseif selected_row == 4 then
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
    mp.add_forced_key_binding("MBTN_LEFT", "subtitle-menu-mouse-left", function()
        local x, y = mp.get_mouse_pos()
        if not x or not y then
            return
        end

        local left = tonumber(options.left) or 36
        local top = tonumber(options.top) or 44
        if x < left or x > left + last_panel_width or y < top then
            close_menu()
            return
        end

        local total_height = last_line_count * last_line_height
        if y > top + total_height then
            close_menu()
            return
        end

        local line_index = math.floor((y - top) / last_line_height) + 1
        local action = last_click_targets[line_index]
        if action then
            action()
        else
            close_menu()
        end
    end)
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

    mp.commandv("script-message", "audio-menu-close")
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
