local mp = require "mp"

local menu_ui = dofile(mp.command_native({ "expand-path", "~~/scripts/menu_ui.lua" }))

local options = {
    font = "Consolas",
    font_size = 16,
    left = 36,
    top = 44,
    panel_chars = 44,
    rows = 8,
    timeout = 7,
    accent_color = "#FF8232",
    text_color = "#FFFFFF",
    muted_color = "#A8A8A8",
    shadow_color = "#111111",
    panel_color = "#121212",
    surface_color = "#1E1E1E",
    selection_color = "#362217",
}

require "mp.options".read_options(options, "audio_menu")

local overlay = mp.create_osd_overlay("ass-events")
local ui = menu_ui.new(overlay, options)
local menu_open = false
local selected_index = 1
local close_timer = nil
local render_menu

local function compact_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function audio_tracks()
    local audios = {}
    local tracks = mp.get_property_native("track-list") or {}

    for _, track in ipairs(tracks) do
        if track.type == "audio" and track.id then
            audios[#audios + 1] = track
        end
    end

    table.sort(audios, function(left, right)
        return tonumber(left.id) < tonumber(right.id)
    end)

    return audios
end

local function display_audio_name(track)
    if not track then
        return "Off"
    end

    local title = compact_text(track.title or "")
    local lang = tostring(track.lang or ""):upper()

    if title ~= "" and lang ~= "" then
        return title .. " (" .. lang .. ")"
    end

    if title ~= "" then
        return title
    end

    if lang ~= "" then
        return lang .. " [#" .. tostring(track.id) .. "]"
    end

    return "Audio [#" .. tostring(track.id) .. "]"
end

local function current_audio_track(tracks)
    local selected_aid = mp.get_property_number("aid", -1)

    for _, track in ipairs(tracks or audio_tracks()) do
        if tonumber(track.id) == tonumber(selected_aid) then
            return track
        end
    end

    for _, track in ipairs(tracks or audio_tracks()) do
        if track.selected then
            return track
        end
    end

    return nil
end

local function current_choice_id(tracks)
    if mp.get_property("aid") == "no" then
        return false
    end

    local current = current_audio_track(tracks)
    return current and tonumber(current.id) or false
end

local function audio_choices(tracks)
    local choices = {
        {
            id = false,
            label = "Off",
            muted = true,
        },
    }

    for _, track in ipairs(tracks) do
        choices[#choices + 1] = {
            id = tonumber(track.id),
            label = display_audio_name(track),
        }
    end

    return choices
end

local function sync_selected_index(tracks)
    local choices = audio_choices(tracks)
    if #choices == 0 then
        selected_index = 1
        return
    end

    local active_id = current_choice_id(tracks)
    selected_index = math.min(math.max(selected_index, 1), #choices)

    for index, choice in ipairs(choices) do
        if choice.id == false and active_id == false then
            selected_index = index
            return
        end
        if choice.id ~= false and tonumber(choice.id) == tonumber(active_id) then
            selected_index = index
            return
        end
    end
end

local function clamp_selected_index(tracks)
    local choices = audio_choices(tracks)
    if #choices == 0 then
        selected_index = 1
        return
    end

    selected_index = math.min(math.max(selected_index, 1), #choices)
end

local function picker_window(choice_count)
    local max_rows = math.max(3, tonumber(options.rows) or 8)
    local first_index = 1
    local last_index = choice_count

    if choice_count > max_rows then
        local half_window = math.floor(max_rows / 2)
        first_index = selected_index - half_window
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

local function clear_close_timer()
    if close_timer then
        close_timer:kill()
        close_timer = nil
    end
end

local function close_menu()
    clear_close_timer()
    if menu_open then
        mp.commandv("script-message", "menu-guard-release", "audio-menu")
    end
    menu_open = false
    ui:clear()
    mp.remove_key_binding("audio-menu-up")
    mp.remove_key_binding("audio-menu-down")
    mp.remove_key_binding("audio-menu-left")
    mp.remove_key_binding("audio-menu-right")
    mp.remove_key_binding("audio-menu-wheel-up")
    mp.remove_key_binding("audio-menu-wheel-down")
    mp.remove_key_binding("audio-menu-enter")
    mp.remove_key_binding("audio-menu-kp-enter")
    mp.remove_key_binding("audio-menu-escape")
    mp.remove_key_binding("audio-menu-mouse-left")
end

local function reset_close_timer()
    clear_close_timer()
    if options.timeout <= 0 then
        return
    end
    close_timer = mp.add_timeout(options.timeout, close_menu)
end

local function move_selection(step)
    local choices = audio_choices(audio_tracks())
    if #choices == 0 then
        return
    end

    selected_index = ((selected_index - 1 + step) % #choices) + 1
    render_menu()
end

local function apply_selection(index)
    local tracks = audio_tracks()
    local choices = audio_choices(tracks)

    if index then
        selected_index = index
    end

    local choice = choices[selected_index]
    if not choice then
        close_menu()
        return
    end

    if choice.id == false then
        mp.set_property("aid", "no")
        mp.osd_message("Audio: Off", 1.2)
    else
        mp.set_property_number("aid", tonumber(choice.id))
        mp.osd_message("Audio: " .. choice.label, 1.2)
    end

    close_menu()
end

render_menu = function()
    if not menu_open then
        return
    end

    local tracks = audio_tracks()
    clamp_selected_index(tracks)

    local choices = audio_choices(tracks)
    local first_index, last_index = picker_window(#choices)
    local active_id = current_choice_id(tracks)
    local rows = {}
    local footer

    if #tracks == 0 then
        rows[#rows + 1] = {
            kind = "note",
            text = "No audio tracks available in this file.",
            bold = true,
        }
        footer = {
            "Esc closes",
        }
    else
        if first_index > 1 then
            rows[#rows + 1] = {
                kind = "note",
                text = "More choices above",
            }
        end

        for index = first_index, last_index do
            local choice = choices[index]
            local current = (choice.id == false and active_id == false)
                or (choice.id ~= false and tonumber(choice.id) == tonumber(active_id))

            rows[#rows + 1] = {
                label = choice.label,
                selected = index == selected_index,
                muted = choice.muted == true,
                badge = current and "ACTIVE" or nil,
                action = function()
                    apply_selection(index)
                end,
            }
        end

        if last_index < #choices then
            rows[#rows + 1] = {
                kind = "note",
                text = "More choices below",
            }
        end

        footer = {
            "Arrows or Wheel move the cursor",
            "Enter or Click applies | Esc closes",
        }
    end

    ui:render({
        title = "Audio",
        badge = #tracks == 0 and "none" or (tostring(#tracks) .. (#tracks == 1 and " track" or " tracks")),
        rows = rows,
        footer = footer,
    })
    reset_close_timer()
end

local function bind_navigation_keys()
    mp.add_forced_key_binding("UP", "audio-menu-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("DOWN", "audio-menu-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("LEFT", "audio-menu-left", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("RIGHT", "audio-menu-right", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("MBTN_LEFT", "audio-menu-mouse-left", function()
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
    mp.add_forced_key_binding("WHEEL_UP", "audio-menu-wheel-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("WHEEL_DOWN", "audio-menu-wheel-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("ENTER", "audio-menu-enter", apply_selection)
    mp.add_forced_key_binding("KP_ENTER", "audio-menu-kp-enter", apply_selection)
    mp.add_forced_key_binding("ESC", "audio-menu-escape", close_menu)
end

local function open_menu()
    if menu_open then
        render_menu()
        return
    end

    mp.commandv("script-message", "subtitle-menu-close")
    mp.commandv("script-message", "chapter-menu-close")
    mp.commandv("script-message", "context-menu-close")
    menu_open = true
    mp.commandv("script-message", "menu-guard-acquire", "audio-menu")
    sync_selected_index(audio_tracks())
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

mp.add_key_binding(nil, "audio-menu-toggle", toggle_menu)
mp.register_script_message("audio-menu-close", close_menu)
mp.observe_property("aid", "native", function()
    render_menu()
end)
mp.observe_property("track-list", "native", function()
    render_menu()
end)
mp.register_event("file-loaded", close_menu)
mp.register_event("end-file", close_menu)
mp.register_event("shutdown", close_menu)
