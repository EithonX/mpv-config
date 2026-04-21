local mp = require "mp"

local menu_ui = dofile(mp.command_native({ "expand-path", "~~/scripts/menu_ui.lua" }))

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
    panel_color = "#121212",
    surface_color = "#1E1E1E",
    selection_color = "#362217",
}

require "mp.options".read_options(options, "subtitle_menu")

local overlay = mp.create_osd_overlay("ass-events")
local ui = menu_ui.new(overlay, options)
local shared_state_path = "user-data/subtitle_auto/state"
local menu_open = false
local selected_row = 1
local picker_kind = nil
local picker_index = 1
local hovered_row = nil
local hovered_picker_index = nil
local close_timer = nil
local hover_open_timer = nil
local render_menu

local function compact_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
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

    local title = compact_text(track.title or "")
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

local function clear_hover_open_timer()
    if hover_open_timer then
        hover_open_timer:kill()
        hover_open_timer = nil
    end
end

local function close_picker()
    clear_hover_open_timer()
    picker_kind = nil
    picker_index = 1
    hovered_picker_index = nil
end

local function close_menu()
    clear_close_timer()
    clear_hover_open_timer()
    if menu_open then
        mp.commandv("script-message", "menu-guard-release", "subtitle-menu")
    end
    menu_open = false
    close_picker()
    hovered_row = nil
    ui:clear()
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
    mp.remove_key_binding("subtitle-menu-mouse-right")
    mp.remove_key_binding("subtitle-menu-mouse-move")
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

local function dual_mode_available(tracks, smart)
    if #tracks < 2 then
        return false
    end

    local primary = find_track_by_id(mp.get_property_number("sid", -1), tracks)
    local secondary = find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks)
    local has_manual_dual = primary
        and secondary
        and tonumber(primary.id) ~= tonumber(secondary.id)

    return has_manual_dual or smart.smart_dual_available == true
end

local function current_choice_id(kind, tracks)
    if kind == "mode" then
        return current_mode()
    end

    if kind == "secondary" then
        local secondary = current_mode() == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
        return secondary and tonumber(secondary.id) or false
    end

    if not mp.get_property_bool("sub-visibility") then
        return false
    end

    local primary = ensure_primary_track(tracks)
    return primary and tonumber(primary.id) or nil
end

local function mode_choices(tracks, smart)
    local choices = {
        {
            id = "primary",
            label = "Primary",
            value = "Single track",
        },
    }

    if dual_mode_available(tracks, smart) then
        choices[#choices + 1] = {
            id = "dual",
            label = "Dual",
            value = "Recommended pair",
        }
    end

    choices[#choices + 1] = {
        id = "off",
        label = "Off",
        value = "Hide subtitles",
        muted = true,
    }

    return choices
end

local function picker_choices(kind, tracks)
    if kind == "mode" then
        return mode_choices(tracks, auto_state())
    end

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

    local target_id = current_choice_id(picker_kind, tracks)
    picker_index = math.min(math.max(picker_index, 1), #choices)

    for index, choice in ipairs(choices) do
        if choice.id == false and target_id == false then
            picker_index = index
            return
        end
        if choice.id ~= false and tostring(choice.id) == tostring(target_id) then
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

    if kind == "mode" then
        selected_row = 1
    elseif kind == "primary" then
        selected_row = 2
    else
        selected_row = 3
    end

    clear_hover_open_timer()
    hovered_picker_index = nil
    picker_kind = kind
    picker_index = 1
    set_picker_index_for_current(tracks)
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

local function move_picker(step)
    local tracks = subtitle_tracks()
    local choices = picker_choices(picker_kind, tracks)
    if #choices == 0 then
        return
    end

    picker_index = ((picker_index - 1 + step) % #choices) + 1
    hovered_picker_index = nil
    render_menu()
end

local function apply_mode_choice(mode_id)
    if mode_id == current_mode() then
        return true
    end

    mp.commandv("script-message", "set-subtitle-mode", mode_id)
    return true
end

local function apply_picker_selection(close_after)
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

    if picker_kind == "mode" then
        apply_mode_choice(choice.id)
    elseif picker_kind == "secondary" then
        set_secondary_track(choice.id)
    else
        set_primary_track(choice.id)
    end

    if close_after then
        close_picker()
    else
        set_picker_index_for_current(subtitle_tracks())
    end

    render_menu()
end

local function subtitle_row_offset(rows, choice_index)
    local offset = 0
    for _, row in ipairs(rows or {}) do
        if row.choice_index == choice_index then
            return offset
        end
        offset = offset + ui:block_height(row)
    end
    return 0
end

local function subtitle_panel_bounds_at(index)
    return ui.panel_bounds and ui.panel_bounds[index] or nil
end

local function subtitle_point_in_rect(x, y, rect)
    return rect
        and x >= rect.x1 and x <= rect.x2
        and y >= rect.y1 and y <= rect.y2
end

local function subtitle_bridge_active(x, y)
    local root_bounds = subtitle_panel_bounds_at(1)
    local child_bounds = subtitle_panel_bounds_at(2)
    if not root_bounds or not child_bounds then
        return false
    end

    local corridor
    if child_bounds.x1 >= root_bounds.x2 then
        corridor = {
            x1 = root_bounds.x2 - 10,
            x2 = child_bounds.x1 + 22,
            y1 = math.min(root_bounds.y1, child_bounds.y1) - 14,
            y2 = math.max(root_bounds.y2, child_bounds.y2) + 14,
        }
    else
        corridor = {
            x1 = child_bounds.x2 - 22,
            x2 = root_bounds.x1 + 10,
            y1 = math.min(root_bounds.y1, child_bounds.y1) - 14,
            y2 = math.max(root_bounds.y2, child_bounds.y2) + 14,
        }
    end

    return subtitle_point_in_rect(x, y, corridor)
end

render_menu = function()
    if not menu_open then
        return
    end

    local tracks = subtitle_tracks()
    clamp_picker_index(tracks)

    local mode = current_mode()
    local smart = auto_state()
    local row_count = #tracks > 0 and 3 or 1
    if selected_row > row_count then
        selected_row = row_count
    end

    local primary = #tracks > 0 and ensure_primary_track(tracks) or nil
    local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
    local root_rows = {}
    local root_footer

    if #tracks == 0 then
        root_rows[#root_rows + 1] = {
            kind = "note",
            text = "No subtitle tracks available in this file.",
            bold = true,
        }
        root_footer = {
            "Esc closes",
        }

        ui:render_panels({
            {
                title = "Subtitles",
                badge = "none",
                rows = root_rows,
                footer = root_footer,
                left = tonumber(options.left) or 36,
                top = tonumber(options.top) or 44,
            },
        })
        reset_close_timer()
        return
    end

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
    elseif smart.smart_dual_available then
        secondary_value = "Ready when Dual is used"
    end

    root_rows[#root_rows + 1] = {
        label = "Mode",
        value = string.upper(mode),
        selected = selected_row == 1,
        hovered = hovered_row == 1 and selected_row ~= 1,
        value_color = "accent",
        choice_index = 1,
        action = function()
            selected_row = 1
            open_picker("mode")
            render_menu()
        end,
    }
    root_rows[#root_rows + 1] = {
        label = "Primary",
        value = primary_value,
        value_share = 0.72,
        selected = selected_row == 2,
        hovered = hovered_row == 2 and selected_row ~= 2,
        muted = primary_muted,
        value_color = primary_muted and "muted" or "text",
        choice_index = 2,
        action = function()
            selected_row = 2
            open_picker("primary")
            render_menu()
        end,
    }
    root_rows[#root_rows + 1] = {
        label = "Secondary",
        value = secondary_value,
        value_share = 0.72,
        selected = selected_row == 3,
        hovered = hovered_row == 3 and selected_row ~= 3,
        muted = secondary_muted,
        value_color = secondary_muted and "muted" or "text",
        choice_index = 3,
        action = function()
            selected_row = 3
            open_picker("secondary")
            render_menu()
        end,
    }

    root_footer = {
        "Hover opens the side panel | Enter or Right opens",
        "Right click goes back | Esc closes",
    }

    local root_spec = {
        title = "Subtitles",
        badge = tostring(#tracks) .. (#tracks == 1 and " track" or " tracks"),
        rows = root_rows,
        footer = root_footer,
        left = tonumber(options.left) or 36,
        top = tonumber(options.top) or 44,
    }

    local specs = { root_spec }

    if picker_kind then
        local picker_rows = {}
        local picker_footer
        local choices = picker_choices(picker_kind, tracks)
        local first_index, last_index = picker_window(#choices)
        local active_id = current_choice_id(picker_kind, tracks)

        if picker_kind == "secondary" and primary then
            picker_rows[#picker_rows + 1] = {
                kind = "section",
                text = "Primary locked",
            }
            picker_rows[#picker_rows + 1] = {
                kind = "note",
                text = display_track_name(primary),
            }
        end

        if first_index > 1 then
            picker_rows[#picker_rows + 1] = {
                kind = "note",
                text = "More choices above",
            }
        end

        for index = first_index, last_index do
            local choice = choices[index]
            local current = (choice.id == false and active_id == false)
                or (choice.id ~= false and tostring(choice.id) == tostring(active_id))

            picker_rows[#picker_rows + 1] = {
                label = choice.label,
                value = choice.value,
                selected = index == picker_index,
                hovered = index == hovered_picker_index and index ~= picker_index,
                muted = choice.muted == true,
                value_color = choice.muted == true and "muted" or nil,
                badge = current and "ACTIVE" or nil,
                choice_index = index,
                action = function()
                    picker_index = index
                    apply_picker_selection(true)
                end,
            }
        end

        if last_index < #choices then
            picker_rows[#picker_rows + 1] = {
                kind = "note",
                text = "More choices below",
            }
        end

        picker_footer = {
            "Hover highlights | Click applies",
            "Right click, Left arrow, or Esc goes back",
        }

        local root_width, _ = ui:measure_panel(root_spec)
        local picker_spec = {
            title = picker_kind == "mode"
                and "Subtitle Mode"
                or (picker_kind == "primary" and "Primary Subtitle" or "Secondary Subtitle"),
            badge = picker_kind == "mode" and string.upper(mode) or picker_kind,
            rows = picker_rows,
            footer = picker_footer,
        }
        local picker_width, picker_height = ui:measure_panel(picker_spec)
        local osd_width, osd_height = ui:get_osd_size()
        local gap = 4
        local anchor_row = picker_kind == "mode" and 1 or (picker_kind == "primary" and 2 or 3)
        local item_y = root_spec.top
            + ui.theme.padding_y
            + ui.theme.header_height
            + subtitle_row_offset(root_rows, anchor_row)
        local anchor_center_y = item_y + math.floor(ui.theme.row_height / 2)
        local preferred_left = root_spec.left + root_width + gap
        local picker_left = preferred_left
        if preferred_left + picker_width > (osd_width - 12) then
            picker_left = root_spec.left - picker_width - gap
        end
        picker_left = math.max(12, math.min(picker_left, osd_width - picker_width - 12))
        local picker_top = math.max(
            12,
            math.min(
                anchor_center_y - (ui.theme.padding_y + ui.theme.header_height + math.floor(ui.theme.row_height / 2)),
                osd_height - picker_height - 12
            )
        )

        picker_spec.left = picker_left
        picker_spec.top = picker_top
        specs[2] = picker_spec
    end

    ui:render_panels(specs)
    reset_close_timer()
end

local function move_selection(step)
    if picker_kind then
        move_picker(step)
        return
    end

    local row_count = #subtitle_tracks() > 0 and 3 or 1
    selected_row = ((selected_row - 1 + step) % row_count) + 1
    hovered_row = nil
    render_menu()
end

local function open_selected_picker()
    if #subtitle_tracks() == 0 then
        close_menu()
        return
    end

    if selected_row == 1 then
        open_picker("mode")
    elseif selected_row == 2 then
        open_picker("primary")
    else
        open_picker("secondary")
    end

    render_menu()
end

local function schedule_hover_picker(row_index)
    clear_hover_open_timer()
    if picker_kind or not row_index then
        return
    end

    local tracks = subtitle_tracks()
    if #tracks == 0 then
        return
    end
    if row_index == 3 and #tracks < 2 then
        return
    end

    hover_open_timer = mp.add_timeout(0.05, function()
        hover_open_timer = nil
        if not menu_open or picker_kind or hovered_row ~= row_index then
            return
        end

        selected_row = row_index
        open_selected_picker()
    end)
end

local function activate_selection()
    if picker_kind then
        apply_picker_selection(true)
        return
    end

    open_selected_picker()
end

local function escape_menu()
    if picker_kind then
        close_picker()
        render_menu()
        return
    end

    close_menu()
end

local function enter_submenu()
    if picker_kind then
        reset_close_timer()
        return
    end

    open_selected_picker()
end

local function leave_submenu()
    if picker_kind then
        close_picker()
        render_menu()
        return
    end

    reset_close_timer()
end

local function bind_navigation_keys()
    mp.add_forced_key_binding("UP", "subtitle-menu-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("DOWN", "subtitle-menu-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("LEFT", "subtitle-menu-left", leave_submenu, { repeatable = true })
    mp.add_forced_key_binding("RIGHT", "subtitle-menu-right", enter_submenu, { repeatable = true })
    mp.add_forced_key_binding("MBTN_LEFT", "subtitle-menu-mouse-left", function()
        local x, y = mp.get_mouse_pos()
        if not x or not y then
            return
        end

        local hit = ui:handle_click(x, y)
        if hit == "outside" then
            close_menu()
        elseif hit == "inside" then
            reset_close_timer()
        end
    end)
    mp.add_forced_key_binding("MBTN_RIGHT", "subtitle-menu-mouse-right", function()
        if picker_kind then
            close_picker()
            render_menu()
            return
        end

        close_menu()
    end)
    mp.add_forced_key_binding("mouse_move", "subtitle-menu-mouse-move", function()
        local x, y = mp.get_mouse_pos()
        if not x or not y then
            return
        end

        local hit = ui:hit_test(x, y)
        if hit.kind == "outside" then
            if subtitle_bridge_active(x, y) then
                reset_close_timer()
                return
            end
            clear_hover_open_timer()
            reset_close_timer()
            return
        end

        local panel_index = hit.panel_index or 1
        local hovered = hit.kind == "item" and hit.row_index or nil

        if panel_index == 2 then
            if hovered_picker_index ~= hovered then
                hovered_picker_index = hovered
                render_menu()
            end
            reset_close_timer()
            return
        end

        local changed = false
        if hovered_row ~= hovered then
            hovered_row = hovered
            changed = true
        end

        if hovered then
            selected_row = hovered
            local target_kind = hovered == 1 and "mode" or (hovered == 2 and "primary" or "secondary")
            if not (target_kind == "secondary" and #subtitle_tracks() < 2) then
                if picker_kind ~= target_kind then
                    open_picker(target_kind)
                    render_menu()
                    reset_close_timer()
                    return
                end
            elseif picker_kind then
                close_picker()
                render_menu()
                reset_close_timer()
                return
            end
        elseif changed then
            render_menu()
        end

        reset_close_timer()
    end, { complex = true })
    mp.add_forced_key_binding("WHEEL_UP", "subtitle-menu-wheel-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("WHEEL_DOWN", "subtitle-menu-wheel-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("ENTER", "subtitle-menu-enter", activate_selection)
    mp.add_forced_key_binding("KP_ENTER", "subtitle-menu-kp-enter", activate_selection)
    mp.add_forced_key_binding("ESC", "subtitle-menu-escape", escape_menu)
end

local function open_menu()
    if menu_open then
        render_menu()
        return
    end

    mp.commandv("script-message", "audio-menu-close")
    mp.commandv("script-message", "chapter-menu-close")
    mp.commandv("script-message", "context-menu-close")
    menu_open = true
    mp.commandv("script-message", "menu-guard-acquire", "subtitle-menu")
    close_picker()
    hovered_row = nil
    hovered_picker_index = nil
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
