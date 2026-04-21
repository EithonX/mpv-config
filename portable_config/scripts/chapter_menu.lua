local mp = require "mp"

local menu_ui = dofile(mp.command_native({ "expand-path", "~~/scripts/menu_ui.lua" }))

local options = {
    font = "Consolas",
    font_size = 16,
    left = 36,
    top = 44,
    panel_chars = 44,
    rows = 10,
    timeout = 10,
    accent_color = "#FF8232",
    text_color = "#FFFFFF",
    muted_color = "#A8A8A8",
    shadow_color = "#111111",
    panel_color = "#121212",
    surface_color = "#1E1E1E",
    selection_color = "#362217",
}

require "mp.options".read_options(options, "chapter_menu")

local overlay = mp.create_osd_overlay("ass-events")
local ui = menu_ui.new(overlay, options)
local menu_open = false
local selected_index = 1
local hovered_index = nil
local close_timer = nil
local render_menu

local function compact_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function format_time(seconds)
    local time = tonumber(seconds) or 0
    local whole = math.max(0, math.floor(time + 0.5))
    local hours = math.floor(whole / 3600)
    local minutes = math.floor((whole % 3600) / 60)
    local secs = whole % 60

    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end

    return string.format("%02d:%02d", minutes, secs)
end

local function chapter_entries()
    local entries = {}
    local raw = mp.get_property_native("chapter-list")

    if type(raw) ~= "table" then
        return entries
    end

    for index, chapter in ipairs(raw) do
        entries[#entries + 1] = {
            index = index - 1,
            title = compact_text(chapter.title or ""),
            time = tonumber(chapter.time) or 0,
        }
    end

    return entries
end

local function display_chapter_name(chapter)
    if not chapter then
        return "No chapters"
    end

    if chapter.title ~= "" then
        return chapter.title
    end

    return "Chapter " .. tostring(chapter.index + 1)
end

local function current_chapter_index(entries)
    local current = mp.get_property_number("chapter", -1)
    if current and current >= 0 then
        return current
    end

    local pos = mp.get_property_number("time-pos", -1)
    if not pos or pos < 0 then
        return -1
    end

    local active = -1
    for _, chapter in ipairs(entries or chapter_entries()) do
        if pos + 0.001 >= chapter.time then
            active = chapter.index
        else
            break
        end
    end

    return active
end

local function sync_selected_index(entries)
    if #entries == 0 then
        selected_index = 1
        return
    end

    local current = current_chapter_index(entries)
    selected_index = math.min(math.max(selected_index, 1), #entries)

    for index, chapter in ipairs(entries) do
        if chapter.index == current then
            selected_index = index
            return
        end
    end

    if current < 0 then
        selected_index = 1
    end
end

local function clamp_selected_index(entries)
    if #entries == 0 then
        selected_index = 1
        return
    end

    selected_index = math.min(math.max(selected_index, 1), #entries)
end

local function picker_window(entry_count)
    local max_rows = math.max(4, tonumber(options.rows) or 10)
    local first_index = 1
    local last_index = entry_count

    if entry_count > max_rows then
        local half_window = math.floor(max_rows / 2)
        first_index = selected_index - half_window
        last_index = first_index + max_rows - 1

        if first_index < 1 then
            first_index = 1
            last_index = max_rows
        elseif last_index > entry_count then
            last_index = entry_count
            first_index = entry_count - max_rows + 1
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
        mp.commandv("script-message", "menu-guard-release", "chapter-menu")
    end
    menu_open = false
    hovered_index = nil
    ui:clear()
    mp.remove_key_binding("chapter-menu-up")
    mp.remove_key_binding("chapter-menu-down")
    mp.remove_key_binding("chapter-menu-left")
    mp.remove_key_binding("chapter-menu-right")
    mp.remove_key_binding("chapter-menu-wheel-up")
    mp.remove_key_binding("chapter-menu-wheel-down")
    mp.remove_key_binding("chapter-menu-enter")
    mp.remove_key_binding("chapter-menu-kp-enter")
    mp.remove_key_binding("chapter-menu-escape")
    mp.remove_key_binding("chapter-menu-mouse-left")
    mp.remove_key_binding("chapter-menu-mouse-right")
    mp.remove_key_binding("chapter-menu-mouse-move")
end

local function reset_close_timer()
    clear_close_timer()
    if options.timeout <= 0 then
        return
    end

    close_timer = mp.add_timeout(options.timeout, close_menu)
end

local function move_selection(step)
    local entries = chapter_entries()
    if #entries == 0 then
        return
    end

    selected_index = ((selected_index - 1 + step) % #entries) + 1
    hovered_index = nil
    render_menu()
end

local function apply_selection(index)
    local entries = chapter_entries()
    if #entries == 0 then
        close_menu()
        return
    end

    if index then
        selected_index = index
    end

    local chapter = entries[selected_index]
    if not chapter then
        close_menu()
        return
    end

    mp.set_property_number("chapter", chapter.index)
    mp.osd_message("Chapter: " .. display_chapter_name(chapter), 1.2)
    close_menu()
end

render_menu = function()
    if not menu_open then
        return
    end

    local entries = chapter_entries()
    clamp_selected_index(entries)

    local rows = {}
    local footer

    if #entries == 0 then
        rows[#rows + 1] = {
            kind = "note",
            text = "No chapters available in this file.",
            bold = true,
        }
        footer = {
            "Esc closes",
        }
    else
        local first_index, last_index = picker_window(#entries)
        local current = current_chapter_index(entries)

        if first_index > 1 then
            rows[#rows + 1] = {
                kind = "note",
                text = "More chapters above",
            }
        end

        for index = first_index, last_index do
            local chapter = entries[index]
            local is_current = chapter.index == current

            rows[#rows + 1] = {
                label = display_chapter_name(chapter),
                value = format_time(chapter.time),
                selected = index == selected_index,
                hovered = index == hovered_index and index ~= selected_index,
                value_color = is_current and "accent" or "muted",
                badge = is_current and "NOW" or nil,
                choice_index = index,
                action = function()
                    apply_selection(index)
                end,
            }
        end

        if last_index < #entries then
            rows[#rows + 1] = {
                kind = "note",
                text = "More chapters below",
            }
        end

        footer = {
            "Hover, Arrows, or Wheel moves",
            "Click jumps | Right click or Esc closes",
        }
    end

    ui:render({
        title = "Chapters",
        badge = #entries == 0 and "none" or (tostring(#entries) .. (#entries == 1 and " chapter" or " chapters")),
        rows = rows,
        footer = footer,
    })
    reset_close_timer()
end

local function bind_navigation_keys()
    mp.add_forced_key_binding("UP", "chapter-menu-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("DOWN", "chapter-menu-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("LEFT", "chapter-menu-left", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("RIGHT", "chapter-menu-right", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("MBTN_LEFT", "chapter-menu-mouse-left", function()
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
    mp.add_forced_key_binding("MBTN_RIGHT", "chapter-menu-mouse-right", close_menu)
    mp.add_forced_key_binding("mouse_move", "chapter-menu-mouse-move", function()
        local x, y = mp.get_mouse_pos()
        if not x or not y then
            return
        end

        local hit = ui:hit_test(x, y)
        local hovered = hit.kind == "item" and hit.row_index or nil
        if hovered_index ~= hovered then
            hovered_index = hovered
            render_menu()
        end

        if hit.kind ~= "outside" then
            reset_close_timer()
        end
    end, { complex = true })
    mp.add_forced_key_binding("WHEEL_UP", "chapter-menu-wheel-up", function() move_selection(-1) end, { repeatable = true })
    mp.add_forced_key_binding("WHEEL_DOWN", "chapter-menu-wheel-down", function() move_selection(1) end, { repeatable = true })
    mp.add_forced_key_binding("ENTER", "chapter-menu-enter", apply_selection)
    mp.add_forced_key_binding("KP_ENTER", "chapter-menu-kp-enter", apply_selection)
    mp.add_forced_key_binding("ESC", "chapter-menu-escape", close_menu)
end

local function open_menu()
    if menu_open then
        render_menu()
        return
    end

    mp.commandv("script-message", "context-menu-close")
    mp.commandv("script-message", "audio-menu-close")
    mp.commandv("script-message", "subtitle-menu-close")
    menu_open = true
    hovered_index = nil
    mp.commandv("script-message", "menu-guard-acquire", "chapter-menu")
    sync_selected_index(chapter_entries())
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

mp.add_key_binding(nil, "chapter-menu-toggle", toggle_menu)
mp.register_script_message("chapter-menu-open", open_menu)
mp.register_script_message("chapter-menu-close", close_menu)
mp.observe_property("chapter", "native", function()
    render_menu()
end)
mp.observe_property("chapter-list", "native", function()
    render_menu()
end)
mp.register_event("file-loaded", close_menu)
mp.register_event("end-file", close_menu)
mp.register_event("shutdown", close_menu)
