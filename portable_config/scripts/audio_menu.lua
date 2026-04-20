local mp = require "mp"

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
}

require "mp.options".read_options(options, "audio_menu")

local overlay = mp.create_osd_overlay("ass-events")
local menu_open = false
local selected_index = 1
local close_timer = nil
local render_menu
local last_click_targets = {}
local last_line_height = 22
local last_panel_width = 320

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
    menu_open = false
    overlay:remove()
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

local function apply_selection()
    local tracks = audio_tracks()
    local choices = audio_choices(tracks)
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
    local font_size = tonumber(options.font_size) or 16
    local body_size = math.max(12, font_size)
    local track_count_label = tostring(#tracks) .. (#tracks == 1 and " track" or " tracks")
    local active_id = current_choice_id(tracks)
    local lines = {}
    local click_targets = {}
    local function push_line(text, action)
        lines[#lines + 1] = text
        click_targets[#lines] = action
    end

    push_line(border_line())

    if #tracks == 0 then
        push_line(header_line("AUDIO", "none"))
        push_line(divider_line())
        push_line(menu_line("No audio tracks", "", false, true, false))
        push_line(divider_line())
        push_line(note_line("Esc close"))
    else
        push_line(header_line("AUDIO", track_count_label))
        push_line(divider_line())

        if first_index > 1 then
            push_line(menu_line("...", "", false, true, false))
        end

        for index = first_index, last_index do
            local choice = choices[index]
            local current = (choice.id == false and active_id == false)
                or (choice.id ~= false and tonumber(choice.id) == tonumber(active_id))
            local right = current and "[ACTIVE]" or ""
            push_line(menu_line(choice.label, right, index == selected_index, choice.muted == true, current), function()
                selected_index = index
                apply_selection()
            end)
        end

        if last_index < #choices then
            push_line(menu_line("...", "", false, true, false))
        end

        push_line(divider_line())
        push_line(note_line("Up/Down/Left/Right browse"))
        push_line(note_line("Enter apply  Click select  Esc close"))
    end

    push_line(border_line())
    last_click_targets = click_targets
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

        local left = tonumber(options.left) or 36
        local top = tonumber(options.top) or 44
        if x < left or x > left + last_panel_width or y < top then
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
    menu_open = true
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
