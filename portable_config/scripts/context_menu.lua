local mp = require "mp"

local menu_ui = dofile(mp.command_native({ "expand-path", "~~/scripts/menu_ui.lua" }))

local options = {
    font = "Consolas",
    font_size = 16,
    left = 36,
    top = 44,
    panel_chars = 44,
    playlist_panel_chars = 58,
    rows = 9,
    playlist_rows = 11,
    playlist_bottom_margin = 108,
    timeout = 10,
    submenu_hover_arm_delay = 0.22,
    submenu_hover_delay = 0.10,
    marquee_delay = 0.8,
    marquee_step = 0.2,
    marquee_gap = 6,
    accent_color = "#FF8232",
    text_color = "#FFFFFF",
    muted_color = "#A8A8A8",
    shadow_color = "#111111",
    panel_color = "#121212",
    surface_color = "#1E1E1E",
    selection_color = "#362217",
    hover_color = "#262626",
}

require "mp.options".read_options(options, "context_menu")

local overlay = mp.create_osd_overlay("ass-events")
local ui = menu_ui.new(overlay, options)
local shared_state_path = "user-data/subtitle_auto/state"
local open_state_path = "user-data/context_menu/open"

local menu_open = false
local close_timer = nil
local render_menu
local close_menu
local page_stack = {}
local page_state = {}
local anchor_x = nil
local anchor_y = nil
local mouse_x = nil
local mouse_y = nil
local bindings_registered = false
local playlist_marquee_timer = nil
local submenu_hover_timer = nil
local submenu_hover_target = nil
local submenu_hover_armed_at = 0
local marquee_focus_key = nil
local marquee_started_at = 0

local PAGE_ROOT = "root"
local PAGE_PLAYLIST = "playlist"
local PAGE_CHAPTERS = "chapters"
local PAGE_AUDIO = "audio"
local PAGE_SUBTITLE = "subtitle"
local PAGE_SUBTITLE_MODE = "subtitle-mode"
local PAGE_SUBTITLE_PRIMARY = "subtitle-primary"
local PAGE_SUBTITLE_SECONDARY = "subtitle-secondary"
local PAGE_PLAYBACK = "playback"
local PAGE_SPEED = "speed"
local PAGE_VIDEO = "video"
local PAGE_VIDEO_ASPECT = "video-aspect"
local PAGE_WINDOW = "window"
local PAGE_TOOLS = "tools"

local function compact_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function invoke_action(action)
    if type(action) ~= "function" then
        return true
    end

    local ok, err = xpcall(action, debug.traceback)
    if not ok then
        mp.msg.error("context menu action failed: " .. tostring(err))
        mp.osd_message("Menu action failed", 1.5)
    end
    return ok
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function is_url(path)
    return type(path) == "string" and path:match("^[%a][%w+.-]*://") ~= nil
end

local function basename(path)
    path = tostring(path or "")
    if path == "" then
        return ""
    end

    local normalized = path:gsub("\\", "/")
    local tail = normalized:match("([^/]+)$")
    return tail or normalized
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

local function format_speed(value)
    local numeric = tonumber(value) or 1
    return string.format("%.2fx", numeric)
end

local function yes_no(value)
    return value and "On" or "Off"
end

local function bool_value_color(value)
    return value and "accent" or "muted"
end

local function current_path()
    return tostring(mp.get_property("path", "") or "")
end

local function current_media_title()
    local media_title = compact_text(mp.get_property("media-title", ""))
    if media_title ~= "" then
        return media_title
    end

    return basename(current_path())
end

local function clear_close_timer()
    if close_timer then
        close_timer:kill()
        close_timer = nil
    end
end

local function stop_playlist_marquee()
    if playlist_marquee_timer then
        playlist_marquee_timer:kill()
        playlist_marquee_timer = nil
    end
    marquee_focus_key = nil
    marquee_started_at = 0
end

local function clear_submenu_hover()
    if submenu_hover_timer then
        submenu_hover_timer:kill()
        submenu_hover_timer = nil
    end
    submenu_hover_target = nil
end

local function arm_submenu_hover()
    submenu_hover_armed_at = mp.get_time() + math.max(0.04, tonumber(options.submenu_hover_arm_delay) or 0.22)
end

local function submenu_hover_ready()
    return mp.get_time() >= (submenu_hover_armed_at or 0)
end

local function reset_close_timer()
    clear_close_timer()
    if options.timeout <= 0 then
        return
    end

    close_timer = mp.add_timeout(options.timeout, close_menu)
end

close_menu = function()
    clear_close_timer()
    stop_playlist_marquee()
    clear_submenu_hover()
    submenu_hover_armed_at = 0
    marquee_focus_key = nil
    marquee_started_at = 0
    if menu_open then
        mp.commandv("script-message", "menu-guard-release", "context-menu")
    end
    menu_open = false
    bindings_registered = false
    page_stack = {}
    mp.set_property_native(open_state_path, false)
    ui:clear()
    mp.remove_key_binding("context-menu-up")
    mp.remove_key_binding("context-menu-down")
    mp.remove_key_binding("context-menu-left")
    mp.remove_key_binding("context-menu-right")
    mp.remove_key_binding("context-menu-wheel-up")
    mp.remove_key_binding("context-menu-wheel-down")
    mp.remove_key_binding("context-menu-enter")
    mp.remove_key_binding("context-menu-kp-enter")
    mp.remove_key_binding("context-menu-escape")
    mp.remove_key_binding("context-menu-mouse-left")
    mp.remove_key_binding("context-menu-mouse-right")
    mp.remove_key_binding("context-menu-mouse-move")
end

mp.set_property_native(open_state_path, false)

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

local function subtitle_tracks()
    local subtitles = {}
    local tracks = mp.get_property_native("track-list") or {}

    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.id then
            subtitles[#subtitles + 1] = track
        end
    end

    table.sort(subtitles, function(left, right)
        return tonumber(left.id) < tonumber(right.id)
    end)

    return subtitles
end

local function video_tracks()
    local videos = {}
    local tracks = mp.get_property_native("track-list") or {}

    for _, track in ipairs(tracks) do
        if track.type == "video" and track.id then
            videos[#videos + 1] = track
        end
    end

    table.sort(videos, function(left, right)
        return tonumber(left.id) < tonumber(right.id)
    end)

    return videos
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

local function playlist_entries()
    local entries = {}
    local raw = mp.get_property_native("playlist")

    if type(raw) ~= "table" then
        return entries
    end

    for index, entry in ipairs(raw) do
        entries[#entries + 1] = {
            index = index - 1,
            title = compact_text(entry.title or ""),
            filename = tostring(entry.filename or ""),
            current = entry.current == true,
            playing = entry.playing == true,
        }
    end

    return entries
end

local function find_track_by_id(id, tracks)
    local numeric_id = tonumber(id)
    if not numeric_id or numeric_id < 0 then
        return nil
    end

    for _, track in ipairs(tracks or {}) do
        if tonumber(track.id) == numeric_id then
            return track
        end
    end

    return nil
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

local function display_subtitle_name(track)
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

local function display_chapter_name(chapter)
    if not chapter then
        return "No chapters"
    end

    if chapter.title ~= "" then
        return chapter.title
    end

    return "Chapter " .. tostring(chapter.index + 1)
end

local function display_playlist_name(entry)
    if not entry then
        return "No entry"
    end

    if entry.title ~= "" then
        return entry.title
    end

    if entry.filename ~= "" then
        local file_name = basename(entry.filename)
        if file_name ~= "" then
            return file_name
        end
        return entry.filename
    end

    return "Entry " .. tostring(entry.index + 1)
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

local function current_audio_summary()
    if mp.get_property("aid") == "no" then
        return "Off"
    end

    local current = current_audio_track(audio_tracks())
    if current then
        return display_audio_name(current)
    end

    if #audio_tracks() == 0 then
        return "Unavailable"
    end

    return "Auto"
end

local function current_subtitle_mode()
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

local function ensure_primary_track(tracks)
    return find_track_by_id(mp.get_property_number("sid", -1), tracks) or tracks[1]
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

    local keep_dual = current_subtitle_mode() == "dual"
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

local function apply_subtitle_mode(mode_id)
    if mode_id == current_subtitle_mode() then
        return
    end

    mp.commandv("script-message", "set-subtitle-mode", mode_id)
end

local function current_subtitle_summary()
    local tracks = subtitle_tracks()
    local mode = current_subtitle_mode()

    if mode == "off" then
        return "Off"
    end

    if mode == "dual" then
        local primary = ensure_primary_track(tracks)
        local secondary = find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks)
        local primary_label = primary and display_subtitle_name(primary) or "Primary"
        local secondary_label = secondary and display_subtitle_name(secondary) or "Secondary"
        return primary_label .. " + " .. secondary_label
    end

    local primary = #tracks > 0 and ensure_primary_track(tracks) or nil
    if primary then
        return display_subtitle_name(primary)
    end

    return "Unavailable"
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

local function current_chapter_summary()
    local chapters = chapter_entries()
    if #chapters == 0 then
        return "Unavailable"
    end

    local current = current_chapter_index(chapters)
    if current >= 0 then
        return display_chapter_name(chapters[current + 1])
    end

    return tostring(#chapters) .. (#chapters == 1 and " chapter" or " chapters")
end

local function current_playlist_summary()
    local entries = playlist_entries()
    if #entries == 0 then
        return "Unavailable"
    end

    local current = mp.get_property_number("playlist-pos", -1)
    if current >= 0 and entries[current + 1] then
        return string.format("%d/%d", current + 1, #entries)
    end

    return tostring(#entries) .. " entries"
end

local function current_window_summary()
    local fullscreen = mp.get_property_bool("fullscreen")
    local ontop = mp.get_property_bool("ontop")
    if fullscreen then
        return ontop and "Fullscreen + On Top" or "Fullscreen"
    end

    return ontop and "Windowed + On Top" or "Windowed"
end

local function current_video_summary()
    local tracks = video_tracks()
    if #tracks == 0 then
        return "Unavailable"
    end

    return tostring(#tracks) .. (#tracks == 1 and " track" or " tracks")
end

local function current_tools_summary()
    return is_url(current_path()) and "Network" or "Local"
end

local function aspect_summary()
    local raw_value = mp.get_property("video-aspect-override", "no")
    if raw_value == "no" then
        return "Default"
    end

    local numeric = tonumber(raw_value)
    if not numeric then
        return tostring(raw_value)
    end

    if math.abs(numeric - (16 / 9)) < 0.05 then
        return "16:9"
    end
    if math.abs(numeric - (4 / 3)) < 0.05 then
        return "4:3"
    end
    if math.abs(numeric - 2.35) < 0.05 then
        return "2.35:1"
    end

    return string.format("%.2f", numeric)
end

local function ensure_page_state(key)
    local state = page_state[key]
    if not state then
        state = { selected = 1, hovered = nil }
        page_state[key] = state
    end
    return state
end

local function clear_page_hover(key)
    local state = page_state[key]
    if state then
        state.hovered = nil
    end
end

local function current_page_key()
    return page_stack[#page_stack] or PAGE_ROOT
end

local function page_key_at(depth)
    return page_stack[depth] or PAGE_ROOT
end

local function trim_page_stack(depth)
    depth = math.max(1, tonumber(depth) or 1)
    while #page_stack > depth do
        clear_page_hover(page_stack[#page_stack])
        table.remove(page_stack)
    end
end

local function picker_window(choice_count, selected_index)
    local max_rows = math.max(4, tonumber(options.rows) or 9)
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

local function picker_window_for_rows(choice_count, selected_index, row_limit)
    local max_rows = math.max(3, tonumber(row_limit) or tonumber(options.rows) or 9)
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

local function update_marquee_focus(key)
    local focus_key = tostring(key or "")
    if marquee_focus_key ~= focus_key then
        marquee_focus_key = focus_key
        marquee_started_at = mp.get_time()
    end
end

local function ensure_playlist_marquee(active)
    if not active then
        stop_playlist_marquee()
        return false
    end

    if playlist_marquee_timer then
        return true
    end

    playlist_marquee_timer = mp.add_periodic_timer(math.max(0.16, tonumber(options.marquee_step) or 0.2), function()
        if not menu_open or current_page_key() ~= PAGE_PLAYLIST then
            stop_playlist_marquee()
            return
        end

        render_menu(true)
    end)

    return true
end

local function build_page_from_choices(page_key, title, badge, choices, footer, empty_note)
    local state = ensure_page_state(page_key)
    local rows = {}
    local choice_count = #choices

    if choice_count == 0 then
        rows[#rows + 1] = {
            kind = "note",
            text = empty_note or "No items available.",
            bold = true,
        }
        return {
            title = title,
            badge = badge or "none",
            rows = rows,
            choices = choices,
            footer = footer,
            choice_count = 0,
        }
    end

    state.selected = clamp(state.selected, 1, choice_count)
    if state.hovered and (state.hovered < 1 or state.hovered > choice_count) then
        state.hovered = nil
    end
    local first_index, last_index = picker_window(choice_count, state.selected)

    if first_index > 1 then
        rows[#rows + 1] = {
            kind = "note",
            text = "More items above",
        }
    end

    for index = first_index, last_index do
        local choice = choices[index]
        rows[#rows + 1] = {
            label = choice.label,
            value = choice.value,
            value_share = choice.value_share,
            value_color = choice.value_color,
            selected = index == state.selected,
            hovered = index == state.hovered and index ~= state.selected,
            muted = choice.muted == true,
            badge = choice.badge,
            badge_fill = choice.badge_fill,
            choice_index = index,
            action = choice.action,
        }
    end

    if last_index < choice_count then
        rows[#rows + 1] = {
            kind = "note",
            text = "More items below",
        }
    end

    return {
        title = title,
        badge = badge,
        rows = rows,
        choices = choices,
        footer = footer,
        choice_count = choice_count,
    }
end

local function root_footer()
    return {
        "Hover opens submenu panels | Enter or Right opens",
        "Right click inside goes back | outside repositions",
    }
end

local function child_footer()
    return {
        "Hover opens submenu panels | Enter or Right opens or applies",
        "Right click goes back | Esc closes",
    }
end

local function playlist_footer()
    return {
        "Enter plays the file or applies the control",
        "Right click goes back | Arrows and wheel browse",
    }
end

local function playlist_label_limit(value_text, badge_text, value_share, min_value_share, panel_chars)
    local theme = ui.theme
    local row_width = ui:panel_inner_width(panel_chars)
    local label_x = 14
    local badge_width = 0
    local badge_gap = 0

    badge_text = compact_text(badge_text or "")
    if badge_text ~= "" then
        badge_width = math.ceil(ui:measure_text(badge_text, theme.section_size, true) + (theme.badge_padding_x * 2))
        badge_gap = 10
    end

    local value_right = row_width - 14 - badge_width - badge_gap
    local value_width = math.max(0, value_right - label_x - 18)
    local fitted_value = ""
    if compact_text(value_text or "") ~= "" then
        fitted_value = ui:fit_text(
            compact_text(value_text),
            math.max(0, math.floor(value_width * clamp(tonumber(value_share) or 0.24, tonumber(min_value_share) or 0.2, 0.8))),
            theme.body_size,
            false
        )
    end

    local value_measured = fitted_value ~= "" and ui:measure_text(fitted_value, theme.body_size, false) or 0
    return math.max(0, value_width - value_measured - (fitted_value ~= "" and 20 or 0))
end

local function marquee_playlist_label(text, max_width, focus_key)
    text = compact_text(text)
    if text == "" or max_width <= 0 then
        return text, false
    end

    local body_size = ui.theme.body_size
    if ui:measure_text(text, body_size, true) <= max_width then
        return text, false
    end

    update_marquee_focus(focus_key)

    local delay = math.max(0.2, tonumber(options.marquee_delay) or 0.8)
    local step_time = math.max(0.16, tonumber(options.marquee_step) or 0.2)
    local elapsed = math.max(0, mp.get_time() - marquee_started_at)
    if elapsed < delay then
        return ui:fit_text(text, max_width, body_size, true), true
    end

    local gap = " | "
    local cycle = text .. gap .. text
    local cycle_span = #text + #gap
    local offset = math.floor((elapsed - delay) / step_time) % math.max(1, cycle_span)
    local cycle_length = #cycle
    local window = ""
    local index = offset + 1
    local max_chars = math.max(#text + #gap, 12)

    while #window < max_chars do
        if index > cycle_length then
            index = 1
        end

        local candidate = window .. cycle:sub(index, index)
        if window ~= "" and ui:measure_text(candidate, body_size, true) > max_width then
            break
        end

        window = candidate
        index = index + 1
    end

    if window == "" then
        window = ui:fit_text(text, max_width, body_size, true)
    end

    return window, true
end

local function seed_playlist_selection()
    local entries = playlist_entries()
    local state = ensure_page_state(PAGE_PLAYLIST)
    if #entries == 0 then
        state.selected = 1
        return
    end

    local current_pos = mp.get_property_number("playlist-pos", -1)
    if current_pos >= 0 then
        state.selected = clamp(current_pos + 1, 1, #entries)
    else
        state.selected = clamp(state.selected or 1, 1, #entries)
    end
end

local function submenu_action(page_key)
    return function()
        clear_submenu_hover()
        local parent_key = current_page_key()
        clear_page_hover(parent_key)
        if page_key == PAGE_PLAYLIST then
            seed_playlist_selection()
        end
        ensure_page_state(page_key).hovered = nil
        page_stack[#page_stack + 1] = page_key
        render_menu()
    end
end

local function maybe_open_hovered_submenu()
    clear_submenu_hover()
    if not submenu_hover_ready() then
        return
    end

    local page_key = current_page_key()
    local page = build_page(page_key)
    local state = ensure_page_state(page_key)
    local hovered = state.hovered
    local choice = page.choices and hovered and page.choices[hovered] or nil
    local submenu_page = choice and choice.submenu_page or nil

    if not submenu_page or submenu_page == page_key then
        return
    end

    local target = page_key .. ":" .. tostring(hovered) .. ":" .. submenu_page
    submenu_hover_target = target
    submenu_hover_timer = mp.add_timeout(math.max(0.04, tonumber(options.submenu_hover_delay) or 0.10), function()
        submenu_hover_timer = nil
        if not menu_open or current_page_key() ~= page_key then
            submenu_hover_target = nil
            return
        end

        local current_state = ensure_page_state(page_key)
        if current_state.hovered ~= hovered then
            submenu_hover_target = nil
            return
        end

        current_state.selected = hovered
        if invoke_action(choice.action) then
            arm_submenu_hover()
        else
            close_menu()
        end
        submenu_hover_target = nil
    end)
end

local function close_after(action)
    return function()
        action()
        close_menu()
    end
end

local function open_root_choices()
    return {
        {
            label = "Playlist",
            value = current_playlist_summary(),
            submenu_page = PAGE_PLAYLIST,
            action = submenu_action(PAGE_PLAYLIST),
        },
        {
            label = "Chapters",
            value = current_chapter_summary(),
            muted = #chapter_entries() == 0,
            submenu_page = PAGE_CHAPTERS,
            action = submenu_action(PAGE_CHAPTERS),
        },
        {
            label = "Audio",
            value = current_audio_summary(),
            submenu_page = PAGE_AUDIO,
            action = submenu_action(PAGE_AUDIO),
        },
        {
            label = "Subtitles",
            value = current_subtitle_summary(),
            submenu_page = PAGE_SUBTITLE,
            action = submenu_action(PAGE_SUBTITLE),
        },
        {
            label = "Playback",
            value = (mp.get_property_bool("pause") and "Paused" or "Playing") .. " | " .. format_speed(mp.get_property_number("speed", 1)),
            value_share = 0.62,
            submenu_page = PAGE_PLAYBACK,
            action = submenu_action(PAGE_PLAYBACK),
        },
        {
            label = "Video",
            value = current_video_summary(),
            muted = #video_tracks() == 0,
            submenu_page = PAGE_VIDEO,
            action = submenu_action(PAGE_VIDEO),
        },
        {
            label = "Window",
            value = current_window_summary(),
            submenu_page = PAGE_WINDOW,
            action = submenu_action(PAGE_WINDOW),
        },
        {
            label = "Tools",
            value = current_tools_summary(),
            submenu_page = PAGE_TOOLS,
            action = submenu_action(PAGE_TOOLS),
        },
        {
            label = "Quit",
            value = "Close player",
            value_color = "muted",
            action = close_after(function()
                mp.commandv("quit")
            end),
        },
    }
end

local function build_root_page()
    return build_page_from_choices(
        PAGE_ROOT,
        "Menu",
        is_url(current_path()) and "network" or "local",
        open_root_choices(),
        root_footer(),
        "Nothing to show."
    )
end

local function build_playlist_page()
    local entries = playlist_entries()
    local current_pos = mp.get_property_number("playlist-pos", -1)
    local loop_playlist = mp.get_property("loop-playlist", "no")
    local state = ensure_page_state(PAGE_PLAYLIST)
    local entry_value_share = 0.12
    local entry_min_value_share = 0.08
    local playlist_panel_chars = math.max(
        tonumber(options.panel_chars) or 44,
        tonumber(options.playlist_panel_chars) or 58
    )
    local entry_choices = {}
    local marquee_active = false
    local control_choices = {
        {
            label = "Play Previous",
            value = #entries > 1 and "Previous item" or "Unavailable",
            muted = #entries < 2,
            action = #entries > 1 and close_after(function()
                mp.commandv("playlist-prev")
            end) or nil,
        },
        {
            label = "Play Next",
            value = #entries > 1 and "Next item" or "Unavailable",
            muted = #entries < 2,
            action = #entries > 1 and close_after(function()
                mp.commandv("playlist-next")
            end) or nil,
        },
        {
            label = "Loop Playlist",
            value = loop_playlist == "inf" and "On" or "Off",
            value_color = bool_value_color(loop_playlist == "inf"),
            action = function()
                mp.commandv("cycle-values", "loop-playlist", "inf", "no")
            end,
        },
        {
            label = "Shuffle Order",
            value = #entries > 1 and "Randomize queue" or "Need 2 items",
            muted = #entries < 2,
            action = #entries > 1 and function()
                mp.commandv("playlist-shuffle")
            end or nil,
        },
        {
            label = "Restore Order",
            value = #entries > 1 and "Undo shuffle" or "Need 2 items",
            muted = #entries < 2,
            action = #entries > 1 and function()
                mp.commandv("playlist-unshuffle")
            end or nil,
        },
    }

    if state.selected == nil or state.selected < 1 then
        seed_playlist_selection()
    end
    if state.hovered and (state.hovered < 1 or state.hovered > (#entries + #control_choices)) then
        state.hovered = nil
    end

    local focus_entry_index = nil
    if state.hovered and state.hovered >= 1 and state.hovered <= #entries then
        focus_entry_index = state.hovered
    elseif state.selected and state.selected >= 1 and state.selected <= #entries then
        focus_entry_index = state.selected
    end

    for _, entry in ipairs(entries) do
        local is_current = entry.index == current_pos or entry.current or entry.playing
        local value = tostring(entry.index + 1) .. "/" .. tostring(#entries)
        local badge = is_current and "NOW" or nil
        local raw_label = display_playlist_name(entry)

        local label = raw_label
        if focus_entry_index == entry.index + 1 then
            local max_width = playlist_label_limit(
                value,
                badge,
                entry_value_share,
                entry_min_value_share,
                playlist_panel_chars
            )
            local animated
            label, animated = marquee_playlist_label(
                raw_label,
                max_width,
                "playlist:" .. tostring(entry.index)
            )
            marquee_active = animated == true
        end

        entry_choices[#entry_choices + 1] = {
            label = label,
            value = tostring(entry.index + 1) .. "/" .. tostring(#entries),
            value_share = entry_value_share,
            min_value_share = entry_min_value_share,
            value_color = is_current and "accent" or "muted",
            badge = badge,
            action = close_after(function()
                mp.commandv("playlist-play-index", tostring(entry.index))
            end),
        }
    end

    local choices = {}
    for _, choice in ipairs(entry_choices) do
        choices[#choices + 1] = choice
    end
    for _, choice in ipairs(control_choices) do
        choices[#choices + 1] = choice
    end

    if #choices == 0 then
        return {
            title = "Playlist",
            badge = "none",
            panel_chars = playlist_panel_chars,
            bottom_margin = tonumber(options.playlist_bottom_margin) or 108,
            rows = {
                {
                    kind = "note",
                    text = "No playlist entries available.",
                    bold = true,
                },
            },
            choices = {},
            footer = playlist_footer(),
            choice_count = 0,
        }
    end

    state.selected = clamp(state.selected or 1, 1, #choices)

    local focus_entry = state.selected
    if focus_entry > #entry_choices then
        focus_entry = current_pos >= 0 and clamp(current_pos + 1, 1, math.max(1, #entry_choices)) or 1
    end

    local rows = {
        {
            kind = "section",
            text = "Queue",
        },
    }

    if #entry_choices == 0 then
        rows[#rows + 1] = {
            kind = "note",
            text = "No queued files yet.",
            bold = true,
        }
    else
        local visible_entry_rows = math.max(4, math.floor(tonumber(options.playlist_rows) or 11) - #control_choices)
        local first_index, last_index = picker_window_for_rows(#entry_choices, focus_entry, visible_entry_rows)

        if first_index > 1 then
            rows[#rows + 1] = {
                kind = "note",
                text = "More files above",
            }
        end

        for index = first_index, last_index do
            local choice = entry_choices[index]
            rows[#rows + 1] = {
                label = choice.label,
                value = choice.value,
                value_share = choice.value_share,
                value_color = choice.value_color,
                selected = state.selected == index,
                hovered = state.hovered == index and state.selected ~= index,
                muted = choice.muted == true,
                badge = choice.badge,
                badge_fill = choice.badge_fill,
                choice_index = index,
                action = choice.action,
            }
        end

        if last_index < #entry_choices then
            rows[#rows + 1] = {
                kind = "note",
                text = "More files below",
            }
        end
    end

    rows[#rows + 1] = {
        kind = "divider",
    }
    rows[#rows + 1] = {
        kind = "section",
        text = "Controls",
    }

    for index, choice in ipairs(control_choices) do
        local choice_index = #entry_choices + index
        rows[#rows + 1] = {
            label = choice.label,
            value = choice.value,
            value_share = choice.value_share,
            value_color = choice.value_color,
            selected = state.selected == choice_index,
            hovered = state.hovered == choice_index and state.selected ~= choice_index,
            muted = choice.muted == true,
            badge = choice.badge,
            badge_fill = choice.badge_fill,
            choice_index = choice_index,
            action = choice.action,
        }
    end

    ensure_playlist_marquee(marquee_active)

    return {
        title = "Playlist",
        badge = #entries == 0 and "none" or (tostring(#entries) .. (#entries == 1 and " entry" or " entries")),
        panel_chars = playlist_panel_chars,
        bottom_margin = tonumber(options.playlist_bottom_margin) or 108,
        rows = rows,
        choices = choices,
        footer = playlist_footer(),
        choice_count = #choices,
    }
end

local function build_chapter_page()
    local chapters = chapter_entries()
    local current = current_chapter_index(chapters)
    local choices = {
        {
            label = "Next Chapter",
            value = #chapters > 0 and "chapter +1" or "Unavailable",
            muted = #chapters == 0,
            action = #chapters > 0 and close_after(function()
                mp.commandv("add", "chapter", "1")
            end) or nil,
        },
        {
            label = "Previous Chapter",
            value = #chapters > 0 and "chapter -1" or "Unavailable",
            muted = #chapters == 0,
            action = #chapters > 0 and close_after(function()
                mp.commandv("add", "chapter", "-1")
            end) or nil,
        },
    }

    for _, chapter in ipairs(chapters) do
        local is_current = chapter.index == current
        choices[#choices + 1] = {
            label = display_chapter_name(chapter),
            value = format_time(chapter.time),
            value_color = is_current and "accent" or "muted",
            badge = is_current and "NOW" or nil,
            action = close_after(function()
                mp.set_property_number("chapter", chapter.index)
            end),
        }
    end

    return build_page_from_choices(
        PAGE_CHAPTERS,
        "Chapters",
        #chapters == 0 and "none" or (tostring(#chapters) .. (#chapters == 1 and " chapter" or " chapters")),
        choices,
        child_footer(),
        "No chapters available in this file."
    )
end

local function build_audio_page()
    local tracks = audio_tracks()
    local current = current_audio_track(tracks)
    local current_id = current and tonumber(current.id) or false
    local volume = tonumber(mp.get_property_number("volume", 0)) or 0
    local muted = mp.get_property_bool("mute")
    local audio_delay = tonumber(mp.get_property_number("audio-delay", 0)) or 0
    local choices = {
        {
            label = "Mute",
            value = yes_no(muted),
            value_color = bool_value_color(muted),
            action = function()
                mp.commandv("cycle", "mute")
            end,
        },
        {
            label = "Volume +2",
            value = string.format("%.0f%%", volume),
            action = function()
                mp.commandv("add", "volume", "2")
            end,
        },
        {
            label = "Volume -2",
            value = string.format("%.0f%%", volume),
            action = function()
                mp.commandv("add", "volume", "-2")
            end,
        },
        {
            label = "Delay +0.1s",
            value = string.format("%.1fs", audio_delay),
            action = function()
                mp.commandv("add", "audio-delay", "0.1")
            end,
        },
        {
            label = "Delay -0.1s",
            value = string.format("%.1fs", audio_delay),
            action = function()
                mp.commandv("add", "audio-delay", "-0.1")
            end,
        },
        {
            label = "Audio Off",
            value = "Disable track",
            muted = true,
            badge = current_id == false and "ACTIVE" or nil,
            action = close_after(function()
                mp.set_property("aid", "no")
            end),
        },
    }

    for _, track in ipairs(tracks) do
        local track_id = tonumber(track.id)
        choices[#choices + 1] = {
            label = display_audio_name(track),
            badge = track_id == current_id and "ACTIVE" or nil,
            action = close_after(function()
                mp.set_property_number("aid", track_id)
            end),
        }
    end

    return build_page_from_choices(
        PAGE_AUDIO,
        "Audio",
        #tracks == 0 and "none" or (tostring(#tracks) .. (#tracks == 1 and " track" or " tracks")),
        choices,
        child_footer(),
        "No audio tracks available in this file."
    )
end

local function subtitle_page_choices()
    local tracks = subtitle_tracks()
    local mode = current_subtitle_mode()
    local smart = auto_state()
    local primary = #tracks > 0 and ensure_primary_track(tracks) or nil
    local secondary = mode == "dual" and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks) or nil
    local secondary_value = "Off"
    local secondary_muted = mode ~= "dual"

    if #tracks < 2 then
        secondary_value = "Need 2 tracks"
        secondary_muted = true
    elseif mode == "dual" then
        secondary_value = secondary and display_subtitle_name(secondary) or "Off"
        secondary_muted = false
    elseif smart.smart_dual_available then
        secondary_value = "Ready when Dual is used"
    end

    return {
        {
            label = "Mode",
            value = string.upper(mode),
            value_color = "accent",
            submenu_page = PAGE_SUBTITLE_MODE,
            action = submenu_action(PAGE_SUBTITLE_MODE),
        },
        {
            label = "Primary",
            value = mode == "off" and "Off" or (primary and display_subtitle_name(primary) or "Unavailable"),
            value_share = 0.72,
            muted = mode == "off",
            value_color = mode == "off" and "muted" or "text",
            submenu_page = PAGE_SUBTITLE_PRIMARY,
            action = submenu_action(PAGE_SUBTITLE_PRIMARY),
        },
        {
            label = "Secondary",
            value = secondary_value,
            value_share = 0.72,
            muted = secondary_muted,
            value_color = secondary_muted and "muted" or "text",
            submenu_page = PAGE_SUBTITLE_SECONDARY,
            action = submenu_action(PAGE_SUBTITLE_SECONDARY),
        },
        {
            label = "Visible",
            value = yes_no(mp.get_property_bool("sub-visibility")),
            value_color = bool_value_color(mp.get_property_bool("sub-visibility")),
            action = function()
                mp.commandv("cycle", "sub-visibility")
            end,
        },
        {
            label = "Delay +0.1s",
            value = string.format("%.1fs", tonumber(mp.get_property_number("sub-delay", 0)) or 0),
            action = function()
                mp.commandv("add", "sub-delay", "0.1")
            end,
        },
        {
            label = "Delay -0.1s",
            value = string.format("%.1fs", tonumber(mp.get_property_number("sub-delay", 0)) or 0),
            action = function()
                mp.commandv("add", "sub-delay", "-0.1")
            end,
        },
        {
            label = "Scale Up",
            value = string.format("%.2f", tonumber(mp.get_property_number("sub-scale", 1)) or 1),
            action = function()
                mp.commandv("add", "sub-scale", "0.1")
            end,
        },
        {
            label = "Scale Down",
            value = string.format("%.2f", tonumber(mp.get_property_number("sub-scale", 1)) or 1),
            action = function()
                mp.commandv("add", "sub-scale", "-0.1")
            end,
        },
    }
end

local function build_subtitle_page()
    local tracks = subtitle_tracks()
    return build_page_from_choices(
        PAGE_SUBTITLE,
        "Subtitles",
        #tracks == 0 and "none" or (tostring(#tracks) .. (#tracks == 1 and " track" or " tracks")),
        subtitle_page_choices(),
        child_footer(),
        "No subtitle tracks available in this file."
    )
end

local function subtitle_mode_choices()
    local tracks = subtitle_tracks()
    local smart = auto_state()
    local mode = current_subtitle_mode()
    local choices = {
        {
            label = "Primary",
            value = "Single track",
            badge = mode == "primary" and "ACTIVE" or nil,
            action = close_after(function()
                apply_subtitle_mode("primary")
            end),
        },
    }

    if dual_mode_available(tracks, smart) then
        choices[#choices + 1] = {
            label = "Dual",
            value = "Recommended pair",
            badge = mode == "dual" and "ACTIVE" or nil,
            action = close_after(function()
                apply_subtitle_mode("dual")
            end),
        }
    end

    choices[#choices + 1] = {
        label = "Off",
        value = "Hide subtitles",
        muted = true,
        badge = mode == "off" and "ACTIVE" or nil,
        action = close_after(function()
            apply_subtitle_mode("off")
        end),
    }

    return choices
end

local function build_subtitle_mode_page()
    return build_page_from_choices(
        PAGE_SUBTITLE_MODE,
        "Subtitle Mode",
        string.upper(current_subtitle_mode()),
        subtitle_mode_choices(),
        child_footer(),
        "No subtitle modes available."
    )
end

local function build_subtitle_primary_page()
    local tracks = subtitle_tracks()
    local choices = {
        {
            label = "Off",
            value = "Hide primary track",
            muted = true,
            badge = current_subtitle_mode() == "off" and "ACTIVE" or nil,
            action = close_after(function()
                set_primary_track(false)
            end),
        },
    }

    local active_primary = mp.get_property_bool("sub-visibility") and ensure_primary_track(tracks) or nil
    local active_id = active_primary and tonumber(active_primary.id) or false

    for _, track in ipairs(tracks) do
        local track_id = tonumber(track.id)
        choices[#choices + 1] = {
            label = display_subtitle_name(track),
            badge = active_id ~= false and track_id == active_id and "ACTIVE" or nil,
            action = close_after(function()
                set_primary_track(track_id)
            end),
        }
    end

    return build_page_from_choices(
        PAGE_SUBTITLE_PRIMARY,
        "Primary Subtitle",
        #tracks == 0 and "none" or (tostring(#tracks) .. (#tracks == 1 and " track" or " tracks")),
        choices,
        child_footer(),
        "No subtitle tracks available in this file."
    )
end

local function build_subtitle_secondary_page()
    local tracks = subtitle_tracks()
    local choices = {}
    local primary = #tracks > 0 and ensure_primary_track(tracks) or nil
    local primary_id = primary and tonumber(primary.id) or nil
    local active_secondary = current_subtitle_mode() == "dual"
        and find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks)
        or nil
    local active_secondary_id = active_secondary and tonumber(active_secondary.id) or false

    choices[#choices + 1] = {
        label = "Off",
        value = "Hide secondary track",
        muted = true,
        badge = active_secondary_id == false and "ACTIVE" or nil,
        action = close_after(function()
            set_secondary_track(false)
        end),
    }

    for _, track in ipairs(tracks) do
        local track_id = tonumber(track.id)
        if track_id ~= primary_id then
            choices[#choices + 1] = {
                label = display_subtitle_name(track),
                badge = track_id == active_secondary_id and "ACTIVE" or nil,
                action = close_after(function()
                    set_secondary_track(track_id)
                end),
            }
        end
    end

    return build_page_from_choices(
        PAGE_SUBTITLE_SECONDARY,
        "Secondary Subtitle",
        #tracks < 2 and "need 2" or "dual",
        choices,
        child_footer(),
        "A secondary subtitle needs at least 2 tracks."
    )
end

local function build_playback_page()
    local loop_file = mp.get_property("loop-file", "no")
    local loop_playlist = mp.get_property("loop-playlist", "no")
    local paused = mp.get_property_bool("pause")
    local choices = {
        {
            label = paused and "Play" or "Pause",
            value = paused and "Resume playback" or "Pause playback",
            value_color = paused and "muted" or "accent",
            action = function()
                mp.commandv("cycle", "pause")
            end,
        },
        {
            label = "Speed Presets",
            value = format_speed(mp.get_property_number("speed", 1)),
            submenu_page = PAGE_SPEED,
            action = submenu_action(PAGE_SPEED),
        },
        {
            label = "Speed +0.10",
            value = format_speed(mp.get_property_number("speed", 1)),
            action = function()
                mp.commandv("add", "speed", "0.1")
            end,
        },
        {
            label = "Speed -0.10",
            value = format_speed(mp.get_property_number("speed", 1)),
            action = function()
                mp.commandv("add", "speed", "-0.1")
            end,
        },
        {
            label = "Reset Speed",
            value = "1.00x",
            action = function()
                mp.commandv("set", "speed", "1")
            end,
        },
        {
            label = "A-B Loop Points",
            value = "Set or clear",
            action = function()
                mp.commandv("ab-loop")
            end,
        },
        {
            label = "Loop File",
            value = loop_file == "inf" and "On" or "Off",
            value_color = bool_value_color(loop_file == "inf"),
            action = function()
                mp.commandv("cycle-values", "loop-file", "inf", "no")
            end,
        },
        {
            label = "Loop Playlist",
            value = loop_playlist == "inf" and "On" or "Off",
            value_color = bool_value_color(loop_playlist == "inf"),
            action = function()
                mp.commandv("cycle-values", "loop-playlist", "inf", "no")
            end,
        },
        {
            label = "Seek +10s",
            value = "Forward",
            action = close_after(function()
                mp.commandv("seek", "10")
            end),
        },
        {
            label = "Seek -10s",
            value = "Backward",
            action = close_after(function()
                mp.commandv("seek", "-10")
            end),
        },
        {
            label = "Seek +10m",
            value = "Forward",
            action = close_after(function()
                mp.commandv("seek", "600")
            end),
        },
        {
            label = "Seek -10m",
            value = "Backward",
            action = close_after(function()
                mp.commandv("seek", "-600")
            end),
        },
        {
            label = "Reload Current",
            value = current_media_title(),
            action = close_after(function()
                local time_pos = tostring(mp.get_property_number("time-pos", 0) or 0)
                mp.commandv("set", "file-local-options/start", time_pos)
                mp.commandv("playlist-play-index", "current", "yes")
            end),
        },
    }

    return build_page_from_choices(
        PAGE_PLAYBACK,
        "Playback",
        paused and "paused" or "playing",
        choices,
        child_footer(),
        "Playback controls are unavailable."
    )
end

local function build_speed_page()
    local speed = tonumber(mp.get_property_number("speed", 1)) or 1
    local presets = {
        { label = "0.25x", value = "25%", speed = 0.25 },
        { label = "0.50x", value = "50%", speed = 0.50 },
        { label = "0.75x", value = "75%", speed = 0.75 },
        { label = "1.00x", value = "100%", speed = 1.00 },
        { label = "1.25x", value = "125%", speed = 1.25 },
        { label = "1.50x", value = "150%", speed = 1.50 },
        { label = "1.75x", value = "175%", speed = 1.75 },
        { label = "2.00x", value = "200%", speed = 2.00 },
        { label = "4.00x", value = "400%", speed = 4.00 },
        { label = "8.00x", value = "800%", speed = 8.00 },
    }

    local choices = {}
    for _, preset in ipairs(presets) do
        local is_current = math.abs(speed - preset.speed) < 0.01
        choices[#choices + 1] = {
            label = preset.label,
            value = preset.value,
            badge = is_current and "ACTIVE" or nil,
            action = function()
                mp.set_property_number("speed", preset.speed)
            end,
        }
    end

    return build_page_from_choices(
        PAGE_SPEED,
        "Speed",
        format_speed(speed),
        choices,
        child_footer(),
        "No speed presets available."
    )
end

local function build_video_page()
    local has_video = #video_tracks() > 0
    local choices = {
        {
            label = "Aspect Ratio",
            value = aspect_summary(),
            muted = not has_video,
            submenu_page = has_video and PAGE_VIDEO_ASPECT or nil,
            action = has_video and submenu_action(PAGE_VIDEO_ASPECT) or nil,
        },
        {
            label = "Deband",
            value = yes_no(mp.get_property_bool("deband")),
            value_color = bool_value_color(mp.get_property_bool("deband")),
            muted = not has_video,
            action = has_video and function()
                mp.commandv("cycle", "deband")
            end or nil,
        },
        {
            label = "Deinterlace",
            value = yes_no(mp.get_property_bool("deinterlace-active")),
            value_color = bool_value_color(mp.get_property_bool("deinterlace-active")),
            muted = not has_video,
            action = has_video and function()
                mp.commandv("cycle", "deinterlace")
            end or nil,
        },
        {
            label = "Rotate Clockwise",
            value = tostring(mp.get_property_number("video-rotate", 0) or 0) .. " deg",
            muted = not has_video,
            action = has_video and function()
                mp.commandv("cycle-values", "video-rotate", "90", "180", "270", "0")
            end or nil,
        },
        {
            label = "Rotate Counterclockwise",
            value = tostring(mp.get_property_number("video-rotate", 0) or 0) .. " deg",
            muted = not has_video,
            action = has_video and function()
                mp.commandv("cycle-values", "video-rotate", "270", "180", "90", "0")
            end or nil,
        },
        {
            label = "Screenshot",
            value = "With subtitles",
            muted = not has_video,
            action = has_video and close_after(function()
                mp.commandv("screenshot")
            end) or nil,
        },
        {
            label = "Screenshot Video",
            value = "Without subtitles",
            muted = not has_video,
            action = has_video and close_after(function()
                mp.commandv("screenshot", "video")
            end) or nil,
        },
    }

    return build_page_from_choices(
        PAGE_VIDEO,
        "Video",
        has_video and "available" or "none",
        choices,
        child_footer(),
        "No video track available for this file."
    )
end

local function build_video_aspect_page()
    local current_aspect = aspect_summary()
    local aspect_choices = {
        { label = "Default", value = "No override", aspect = "no" },
        { label = "16:9", value = "Widescreen", aspect = "16:9" },
        { label = "4:3", value = "Classic", aspect = "4:3" },
        { label = "2.35:1", value = "CinemaScope", aspect = "2.35:1" },
    }

    local choices = {}
    for _, item in ipairs(aspect_choices) do
        choices[#choices + 1] = {
            label = item.label,
            value = item.value,
            badge = item.label == current_aspect and "ACTIVE" or nil,
            action = function()
                mp.commandv("set", "video-aspect-override", item.aspect)
            end,
        }
    end

    return build_page_from_choices(
        PAGE_VIDEO_ASPECT,
        "Aspect Ratio",
        current_aspect,
        choices,
        child_footer(),
        "No aspect options available."
    )
end

local function build_window_page()
    local choices = {
        {
            label = "Fullscreen",
            value = yes_no(mp.get_property_bool("fullscreen")),
            value_color = bool_value_color(mp.get_property_bool("fullscreen")),
            action = function()
                mp.commandv("cycle", "fullscreen")
            end,
        },
        {
            label = "Always On Top",
            value = yes_no(mp.get_property_bool("ontop")),
            value_color = bool_value_color(mp.get_property_bool("ontop")),
            action = function()
                mp.commandv("cycle", "ontop")
            end,
        },
        {
            label = "Border",
            value = yes_no(mp.get_property_bool("border")),
            value_color = bool_value_color(mp.get_property_bool("border")),
            action = function()
                mp.commandv("cycle", "border")
            end,
        },
        {
            label = "Title Bar",
            value = yes_no(mp.get_property_bool("title-bar")),
            value_color = bool_value_color(mp.get_property_bool("title-bar")),
            action = function()
                mp.commandv("cycle", "title-bar")
            end,
        },
    }

    return build_page_from_choices(
        PAGE_WINDOW,
        "Window",
        current_window_summary(),
        choices,
        child_footer(),
        "Window controls are unavailable."
    )
end

local function build_tools_page()
    local path = current_path()
    local subtitle_text = compact_text(mp.get_property("sub-text", ""))
    local has_subtitle_text = subtitle_text ~= ""
    local has_subtitle_track = mp.get_property("sid") ~= "no"
    local has_video = #video_tracks() > 0
    local hwdec_enabled = tostring(mp.get_property("hwdec-current", "no")) ~= "no"

    local choices = {
        {
            label = "Open Clipboard",
            value = "Load URL or path",
            action = close_after(function()
                mp.command("update-clipboard text; loadfile ${clipboard/text}; show-text '+ ${clipboard/text}'")
            end),
        },
        {
            label = is_url(path) and "Copy URL" or "Copy Path",
            value = is_url(path) and "Network source" or "Current file",
            muted = path == "",
            action = path ~= "" and function()
                mp.commandv("set", "clipboard/text", path)
                mp.osd_message((is_url(path) and "URL" or "Path") .. " copied", 1.0)
            end or nil,
        },
        {
            label = "Copy Title",
            value = current_media_title(),
            muted = current_media_title() == "",
            action = current_media_title() ~= "" and function()
                mp.commandv("set", "clipboard/text", current_media_title())
                mp.osd_message("Title copied", 1.0)
            end or nil,
        },
        {
            label = "Copy Subtitle",
            value = has_subtitle_text and "Current on-screen line" or "Unavailable",
            muted = not has_subtitle_track or not has_subtitle_text,
            action = has_subtitle_track and has_subtitle_text and function()
                mp.commandv("set", "clipboard/text", subtitle_text)
                mp.osd_message("Subtitle copied", 1.0)
            end or nil,
        },
        {
            label = "Playback Statistics",
            value = "stats page 1",
            action = close_after(function()
                mp.commandv("script-binding", "stats/display-page-1-toggle")
            end),
        },
        {
            label = "File Information",
            value = "stats page 5",
            action = close_after(function()
                mp.commandv("script-binding", "stats/display-page-5-toggle")
            end),
        },
        {
            label = "Key Bindings",
            value = "stats page 4",
            action = close_after(function()
                mp.commandv("script-binding", "stats/display-page-4-toggle")
            end),
        },
        {
            label = "Hardware Decoding",
            value = yes_no(hwdec_enabled),
            value_color = bool_value_color(hwdec_enabled),
            muted = not has_video,
            action = has_video and function()
                mp.commandv("cycle-values", "hwdec", "no", "auto")
            end or nil,
        },
    }

    return build_page_from_choices(
        PAGE_TOOLS,
        "Tools",
        current_tools_summary(),
        choices,
        child_footer(),
        "No tools available."
    )
end

local function build_page(page_key)
    if page_key == PAGE_ROOT then
        return build_root_page()
    end
    if page_key == PAGE_PLAYLIST then
        return build_playlist_page()
    end
    if page_key == PAGE_CHAPTERS then
        return build_chapter_page()
    end
    if page_key == PAGE_AUDIO then
        return build_audio_page()
    end
    if page_key == PAGE_SUBTITLE then
        return build_subtitle_page()
    end
    if page_key == PAGE_SUBTITLE_MODE then
        return build_subtitle_mode_page()
    end
    if page_key == PAGE_SUBTITLE_PRIMARY then
        return build_subtitle_primary_page()
    end
    if page_key == PAGE_SUBTITLE_SECONDARY then
        return build_subtitle_secondary_page()
    end
    if page_key == PAGE_PLAYBACK then
        return build_playback_page()
    end
    if page_key == PAGE_SPEED then
        return build_speed_page()
    end
    if page_key == PAGE_VIDEO then
        return build_video_page()
    end
    if page_key == PAGE_VIDEO_ASPECT then
        return build_video_aspect_page()
    end
    if page_key == PAGE_WINDOW then
        return build_window_page()
    end
    if page_key == PAGE_TOOLS then
        return build_tools_page()
    end

    return build_root_page()
end

local function resolve_menu_position(page)
    local default_x = tonumber(options.left) or 36
    local default_y = tonumber(options.top) or 44
    local panel_width, panel_height = ui:measure_panel({
        panel_chars = page.panel_chars,
        rows = page.rows,
        footer = page.footer,
    })
    local osd_width, osd_height = ui:get_osd_size()
    local x = anchor_x or default_x
    local y = anchor_y or default_y

    if not mouse_x or not mouse_y then
        return x, y
    end

    if (page.key or current_page_key()) == PAGE_PLAYLIST then
        if mouse_y > (osd_height * 0.75) then
            y = mouse_y - panel_height - 32
        end

        if mouse_y > (osd_height * 0.84) then
            y = math.min(y, math.max(default_y, math.floor(osd_height * 0.18)))
        end

        if mouse_x < (osd_width * 0.34) then
            x = mouse_x + 18
        elseif mouse_x > (osd_width * 0.76) then
            x = mouse_x - panel_width - 18
        else
            x = mouse_x - math.floor(panel_width * 0.18)
        end

        local bottom_margin = math.max(72, tonumber(page.bottom_margin) or 108)
        y = math.min(y, osd_height - panel_height - bottom_margin)
    else
        if mouse_y > (osd_height - panel_height - 24) then
            y = mouse_y - panel_height - 14
        end

        if mouse_x > (osd_width - panel_width - 24) then
            x = mouse_x - panel_width - 14
        end
    end

    return x, y
end

local function row_offset_for_choice(page, choice_index)
    local offset = 0
    for _, row in ipairs(page.rows or {}) do
        if row.choice_index == choice_index then
            return offset
        end
        offset = offset + ui:block_height(row)
    end
    return 0
end

local function panel_bounds_at(index)
    local bounds = ui.panel_bounds and ui.panel_bounds[index] or nil
    return bounds
end

local function point_in_rect(x, y, rect)
    return rect
        and x >= rect.x1 and x <= rect.x2
        and y >= rect.y1 and y <= rect.y2
end

local function bridge_depth_for_point(x, y)
    if type(ui.panel_bounds) ~= "table" or #ui.panel_bounds < 2 then
        return nil
    end

    for depth = 1, (#ui.panel_bounds - 1) do
        local parent_bounds = ui.panel_bounds[depth]
        local child_bounds = ui.panel_bounds[depth + 1]
        if parent_bounds and child_bounds then
            local corridor
            if child_bounds.x1 >= parent_bounds.x2 then
                corridor = {
                    x1 = parent_bounds.x2 - 10,
                    x2 = child_bounds.x1 + 22,
                    y1 = math.min(parent_bounds.y1, child_bounds.y1) - 14,
                    y2 = math.max(parent_bounds.y2, child_bounds.y2) + 14,
                }
            else
                corridor = {
                    x1 = child_bounds.x2 - 22,
                    x2 = parent_bounds.x1 + 10,
                    y1 = math.min(parent_bounds.y1, child_bounds.y1) - 14,
                    y2 = math.max(parent_bounds.y2, child_bounds.y2) + 14,
                }
            end

            if point_in_rect(x, y, corridor) then
                return depth
            end
        end
    end

    return nil
end

local function build_panel_specs()
    local specs = {}
    local pages = {}
    local root_key = page_key_at(1)
    local root_page = build_page(root_key)
    root_page.key = root_key
    pages[1] = root_page

    local root_left, root_top = resolve_menu_position(root_page)
    local osd_width, osd_height = ui:get_osd_size()
    local gap = 4
    local lefts = { root_left }
    local tops = { root_top }

    specs[1] = {
        title = root_page.title,
        badge = root_page.badge,
        panel_chars = root_page.panel_chars,
        rows = root_page.rows,
        footer = root_page.footer,
        left = root_left,
        top = root_top,
    }

    for depth = 2, #page_stack do
        local page_key = page_key_at(depth)
        local page = build_page(page_key)
        page.key = page_key
        pages[depth] = page

        local parent_page = pages[depth - 1]
        local parent_key = parent_page.key
        local parent_state = ensure_page_state(parent_key)
        local anchor_choice = parent_state.hovered or parent_state.selected or 1
        local parent_width, _ = ui:measure_panel({
            panel_chars = parent_page.panel_chars,
            rows = parent_page.rows,
            footer = parent_page.footer,
        })
        local child_width, child_height = ui:measure_panel({
            panel_chars = page.panel_chars,
            rows = page.rows,
            footer = page.footer,
        })
        local item_y = tops[depth - 1]
            + ui.theme.padding_y
            + ui.theme.header_height
            + row_offset_for_choice(parent_page, anchor_choice)
        local anchor_center_y = item_y + math.floor(ui.theme.row_height / 2)
        local preferred_left = lefts[depth - 1] + parent_width + gap
        local child_left = preferred_left
        if preferred_left + child_width > (osd_width - 12) then
            child_left = lefts[depth - 1] - child_width - gap
        end
        child_left = clamp(child_left, 12, math.max(12, osd_width - child_width - 12))
        local desired_child_top = anchor_center_y - (ui.theme.padding_y + ui.theme.header_height + math.floor(ui.theme.row_height / 2))
        local child_top = clamp(desired_child_top, 12, math.max(12, osd_height - child_height - 12))

        lefts[depth] = child_left
        tops[depth] = child_top
        specs[depth] = {
            title = page.title,
            badge = page.badge,
            panel_chars = page.panel_chars,
            rows = page.rows,
            footer = page.footer,
            left = child_left,
            top = child_top,
        }
    end

    return specs
end

local function update_anchor_from_mouse()
    local x, y = mp.get_mouse_pos()
    if x and y and x >= 0 and y >= 0 then
        mouse_x = x
        mouse_y = y
        anchor_x = x + 10
        anchor_y = y + 6
    else
        mouse_x = nil
        mouse_y = nil
        anchor_x = tonumber(options.left) or 36
        anchor_y = tonumber(options.top) or 44
    end
end

local function activate_current_choice()
    local page = build_page(current_page_key())
    if (page.choice_count or 0) <= 0 then
        return
    end

    local state = ensure_page_state(current_page_key())
    local choice = page.choices and page.choices[state.selected] or nil
    if choice and choice.action then
        choice.action()
    end
end

local function normalize_page_key(page_key)
    local target = compact_text(page_key or "")
    if target == "" then
        return PAGE_ROOT
    end
    return target
end

local function set_page_target(page_key, standalone)
    local target = normalize_page_key(page_key)

    if standalone and target ~= PAGE_ROOT then
        page_stack = { target }
        clear_page_hover(target)
    else
        page_stack = { PAGE_ROOT }
        clear_page_hover(PAGE_ROOT)
        if target ~= PAGE_ROOT then
            if target == PAGE_PLAYLIST then
                seed_playlist_selection()
            end
            clear_page_hover(target)
            page_stack[#page_stack + 1] = target
        end
    end

    return target
end

local function open_menu(page_key, standalone)
    page_key = normalize_page_key(page_key)
    local was_open = menu_open

    clear_submenu_hover()
    arm_submenu_hover()
    update_anchor_from_mouse()
    mp.commandv("script-message", "audio-menu-close")
    mp.commandv("script-message", "subtitle-menu-close")
    mp.commandv("script-message", "chapter-menu-close")

    menu_open = true
    mp.set_property_native(open_state_path, true)
    if not was_open then
        mp.commandv("script-message", "menu-guard-acquire", "context-menu")
    end
    set_page_target(page_key, standalone)

    if was_open and bindings_registered then
        render_menu()
        return
    end

    bindings_registered = true

    mp.add_forced_key_binding("UP", "context-menu-up", function()
        local page = build_page(current_page_key())
        if (page.choice_count or 0) <= 0 then
            return
        end

        local state = ensure_page_state(current_page_key())
        state.hovered = nil
        state.selected = ((state.selected - 2 + page.choice_count) % page.choice_count) + 1
        render_menu()
    end, { repeatable = true })

    mp.add_forced_key_binding("DOWN", "context-menu-down", function()
        local page = build_page(current_page_key())
        if (page.choice_count or 0) <= 0 then
            return
        end

        local state = ensure_page_state(current_page_key())
        state.hovered = nil
        state.selected = (state.selected % page.choice_count) + 1
        render_menu()
    end, { repeatable = true })

    mp.add_forced_key_binding("LEFT", "context-menu-left", function()
        clear_page_hover(current_page_key())
        if #page_stack > 1 then
            clear_submenu_hover()
            arm_submenu_hover()
            table.remove(page_stack)
            render_menu()
        else
            close_menu()
        end
    end, { repeatable = true })

    mp.add_forced_key_binding("RIGHT", "context-menu-right", function()
        clear_page_hover(current_page_key())
        activate_current_choice()
    end, { repeatable = true })

    mp.add_forced_key_binding("MBTN_LEFT", "context-menu-mouse-left", function()
        local x, y = mp.get_mouse_pos()
        if not x or not y then
            return
        end

        local hit = ui:hit_test(x, y)
        if hit.kind == "outside" then
            close_menu()
            return
        end

        if hit.kind == "inside" then
            reset_close_timer()
            return
        end

        local panel_index = hit.panel_index or #page_stack
        local page_key = page_key_at(panel_index)
        local state = ensure_page_state(page_key)
        trim_page_stack(panel_index)
        state.selected = hit.row_index
        state.hovered = hit.row_index
        if hit.action then
            invoke_action(hit.action)
        else
            render_menu()
        end
    end)

    mp.add_forced_key_binding("MBTN_RIGHT", "context-menu-mouse-right", function()
        local x, y = mp.get_mouse_pos()
        local hit = (x and y) and ui:hit_test(x, y) or { kind = "outside" }

        if hit.kind ~= "outside" then
            if (hit.panel_index or #page_stack) > 1 then
                trim_page_stack((hit.panel_index or #page_stack) - 1)
                render_menu()
            else
                close_menu()
            end
            return
        end

        update_anchor_from_mouse()
        render_menu()
    end)

    mp.add_forced_key_binding("mouse_move", "context-menu-mouse-move", function()
        local x, y = mp.get_mouse_pos()
        if not x or not y then
            return
        end

        local hit = ui:hit_test(x, y)
        if hit.kind == "outside" then
            local bridge_depth = bridge_depth_for_point(x, y)
            if bridge_depth then
                reset_close_timer()
                return
            end
            reset_close_timer()
            return
        end

        local panel_index = hit.panel_index or #page_stack
        local page_key = page_key_at(panel_index)
        local state = ensure_page_state(page_key)
        local hovered = hit.kind == "item" and hit.row_index or nil
        local panel_changed = false

        if state.hovered ~= hovered then
            state.hovered = hovered
            panel_changed = true
        end

        if hit.kind == "inside" then
            if panel_changed then
                render_menu(true)
            end
            reset_close_timer()
            return
        end

        if hovered then
            local page = build_page(page_key)
            local choice = page.choices and page.choices[hovered] or nil
            state.selected = hovered
            if choice and choice.submenu_page then
                local existing_next = page_key_at(panel_index + 1)
                if panel_index + 1 < #page_stack or existing_next ~= choice.submenu_page then
                    trim_page_stack(panel_index)
                    if choice.submenu_page == PAGE_PLAYLIST then
                        seed_playlist_selection()
                    end
                    page_stack[#page_stack + 1] = choice.submenu_page
                    clear_page_hover(choice.submenu_page)
                    panel_changed = true
                end
            elseif panel_index < #page_stack then
                trim_page_stack(panel_index)
                panel_changed = true
            end
        end

        if panel_changed then
            render_menu(true)
        end
        reset_close_timer()
    end, { complex = true })

    mp.add_forced_key_binding("WHEEL_UP", "context-menu-wheel-up", function()
        local page = build_page(current_page_key())
        if (page.choice_count or 0) <= 0 then
            return
        end

        local state = ensure_page_state(current_page_key())
        state.hovered = nil
        state.selected = ((state.selected - 2 + page.choice_count) % page.choice_count) + 1
        render_menu()
    end, { repeatable = true })

    mp.add_forced_key_binding("WHEEL_DOWN", "context-menu-wheel-down", function()
        local page = build_page(current_page_key())
        if (page.choice_count or 0) <= 0 then
            return
        end

        local state = ensure_page_state(current_page_key())
        state.hovered = nil
        state.selected = (state.selected % page.choice_count) + 1
        render_menu()
    end, { repeatable = true })

    mp.add_forced_key_binding("ENTER", "context-menu-enter", function()
        clear_page_hover(current_page_key())
        activate_current_choice()
    end)

    mp.add_forced_key_binding("KP_ENTER", "context-menu-kp-enter", function()
        clear_page_hover(current_page_key())
        activate_current_choice()
    end)

    mp.add_forced_key_binding("ESC", "context-menu-escape", close_menu)
    render_menu()
end

local function open_menu_here()
    local target = menu_open and current_page_key() or PAGE_ROOT
    if menu_open then
        clear_submenu_hover()
        arm_submenu_hover()
        update_anchor_from_mouse()
        clear_page_hover(current_page_key())
        render_menu()
        return
    end

    open_menu(target)
end

local function open_menu_target_here(page_key, standalone)
    local target = normalize_page_key(page_key)
    if menu_open then
        clear_submenu_hover()
        arm_submenu_hover()
        update_anchor_from_mouse()
        set_page_target(target, standalone)
        render_menu()
        return
    end

    open_menu(target, standalone)
end

local function toggle_menu()
    if menu_open then
        close_menu()
    else
        open_menu(PAGE_ROOT)
    end
end

render_menu = function(skip_close_reset)
    if not menu_open then
        return
    end

    local specs = build_panel_specs()
    ui:render_panels(specs)

    if current_page_key() ~= PAGE_PLAYLIST then
        stop_playlist_marquee()
    end

    if skip_close_reset ~= true then
        reset_close_timer()
    end
end

mp.register_script_message("context-menu-open", function()
    open_menu_target_here(PAGE_ROOT)
end)

mp.register_script_message("context-menu-open-here", open_menu_here)

mp.register_script_message("context-menu-open-page", function(page_key)
    open_menu_target_here(page_key)
end)

mp.register_script_message("context-menu-open-page-here", open_menu_target_here)

mp.register_script_message("context-menu-open-page-standalone-here", function(page_key)
    open_menu_target_here(page_key, true)
end)

mp.register_script_message("context-menu-toggle", toggle_menu)
mp.register_script_message("context-menu-close", close_menu)

mp.observe_property("aid", "native", render_menu)
mp.observe_property("sid", "native", render_menu)
mp.observe_property("secondary-sid", "native", render_menu)
mp.observe_property("sub-visibility", "bool", render_menu)
mp.observe_property("secondary-sub-visibility", "bool", render_menu)
mp.observe_property("volume", "native", render_menu)
mp.observe_property("mute", "bool", render_menu)
mp.observe_property("audio-delay", "native", render_menu)
mp.observe_property("sub-delay", "native", render_menu)
mp.observe_property("sub-scale", "native", render_menu)
mp.observe_property("speed", "native", render_menu)
mp.observe_property("pause", "bool", render_menu)
mp.observe_property("loop-file", "string", render_menu)
mp.observe_property("loop-playlist", "string", render_menu)
mp.observe_property("fullscreen", "bool", render_menu)
mp.observe_property("ontop", "bool", render_menu)
mp.observe_property("border", "bool", render_menu)
mp.observe_property("title-bar", "bool", render_menu)
mp.observe_property("hwdec-current", "string", render_menu)
mp.observe_property("deband", "bool", render_menu)
mp.observe_property("deinterlace-active", "bool", render_menu)
mp.observe_property("video-rotate", "native", render_menu)
mp.observe_property("video-aspect-override", "string", render_menu)
mp.observe_property("track-list", "native", render_menu)
mp.observe_property("chapter", "native", render_menu)
mp.observe_property("chapter-list", "native", render_menu)
mp.observe_property("playlist", "native", render_menu)
mp.observe_property("playlist-pos", "native", render_menu)
mp.observe_property("playlist-count", "native", render_menu)
mp.observe_property("path", "string", render_menu)
mp.observe_property("media-title", "string", render_menu)
mp.observe_property(shared_state_path, "native", render_menu)
mp.register_event("file-loaded", close_menu)
mp.register_event("end-file", close_menu)
mp.register_event("shutdown", close_menu)
