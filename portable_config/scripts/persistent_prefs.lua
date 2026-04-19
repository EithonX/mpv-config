local mp = require "mp"
local utils = require "mp.utils"

local state_path = mp.command_native({ "expand-path", "~~/script-opts/persistent_prefs.json" })
local state = {
    volume = nil,
    subtitle_mode = "dual",
}

local primary_keywords = {
    "sign", "songs", "song", "forced", "karaoke", "lyrics", "op", "ed",
}

local secondary_keywords = {
    "cc", "sdh", "closed caption", "closed captions", "dubtitle", "dubtitles",
    "dub cc", "dialogue", "dialog", "full sub", "full subs", "full subtitle",
    "full subtitles", "hearing impaired",
}

local function round(value, digits)
    local power = 10 ^ (digits or 0)
    return math.floor((value * power) + 0.5) / power
end

local function track_text(track)
    local parts = {
        tostring(track.title or ""),
        tostring(track.lang or ""),
    }
    return table.concat(parts, " "):lower()
end

local function has_any(text, keywords)
    for _, keyword in ipairs(keywords) do
        if text:find(keyword, 1, true) then
            return true
        end
    end
    return false
end

local function display_track_name(track)
    if not track then
        return "None"
    end

    local title = tostring(track.title or ""):gsub("%s+", " ")
    if title ~= "" then
        return title
    end

    local lang = tostring(track.lang or ""):upper()
    if lang ~= "" then
        return lang .. " #" .. tostring(track.id)
    end

    return "Track #" .. tostring(track.id)
end

local function valid_mode(mode)
    return mode == "dual" or mode == "primary" or mode == "off"
end

local function read_state()
    local file = io.open(state_path, "r")
    if not file then
        return
    end

    local content = file:read("*a")
    file:close()

    local parsed = utils.parse_json(content)
    if type(parsed) ~= "table" then
        return
    end

    if type(parsed.volume) == "number" and parsed.volume >= 0 then
        state.volume = round(parsed.volume, 0)
    end

    if valid_mode(parsed.subtitle_mode) then
        state.subtitle_mode = parsed.subtitle_mode
    end
end

local function write_state()
    local file = io.open(state_path, "w")
    if not file then
        return
    end

    file:write(utils.format_json(state))
    file:close()
end

local function subtitle_tracks()
    local subs = {}
    local tracks = mp.get_property_native("track-list") or {}
    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.id then
            subs[#subs + 1] = track
        end
    end
    return subs
end

local function find_track_by_id(id)
    if not id or id < 0 then
        return nil
    end

    for _, track in ipairs(subtitle_tracks()) do
        if tonumber(track.id) == tonumber(id) then
            return track
        end
    end
    return nil
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

local function best_track(tracks, scorer, excluded_id)
    local best
    local best_score = -math.huge

    for _, track in ipairs(tracks) do
        if tonumber(track.id) ~= tonumber(excluded_id) then
            local score = scorer(track)
            if best == nil or score > best_score then
                best = track
                best_score = score
            end
        end
    end

    return best, best_score
end

local function score_primary_track(track, current_sid)
    local text = track_text(track)
    local score = 0

    if tonumber(track.id) == tonumber(current_sid) then
        score = score + 25
    end
    if track.forced then
        score = score + 35
    end
    if has_any(text, primary_keywords) then
        score = score + 120
    end
    if has_any(text, secondary_keywords) then
        score = score - 140
    end

    return score
end

local function score_secondary_track(track, current_secondary_sid)
    local text = track_text(track)
    local score = 0

    if tonumber(track.id) == tonumber(current_secondary_sid) then
        score = score + 25
    end
    if track.default then
        score = score + 10
    end
    if has_any(text, secondary_keywords) then
        score = score + 140
    end
    if has_any(text, {"english", "eng"}) then
        score = score + 10
    end
    if has_any(text, primary_keywords) then
        score = score - 140
    end

    return score
end

local function choose_dual_tracks()
    local subs = subtitle_tracks()
    if #subs == 0 then
        return nil, nil
    end

    if #subs == 1 then
        return subs[1], nil
    end

    local current_sid = mp.get_property_number("sid", -1)
    local current_secondary_sid = mp.get_property_number("secondary-sid", -1)
    local current_primary = find_track_by_id(current_sid)

    local preferred_primary, primary_score = best_track(subs, function(track)
        return score_primary_track(track, current_sid)
    end)

    local preferred_secondary, secondary_score = best_track(subs, function(track)
        return score_secondary_track(track, current_secondary_sid)
    end, preferred_primary and preferred_primary.id or nil)

    if preferred_primary and preferred_secondary and preferred_primary.id ~= preferred_secondary.id and (primary_score > 20 or secondary_score > 20) then
        return preferred_primary, preferred_secondary
    end

    local primary = current_primary or subs[1]
    local secondary = nil
    for _, track in ipairs(subs) do
        if tonumber(track.id) ~= tonumber(primary.id) then
            if not secondary then
                secondary = track
            end
            if score_secondary_track(track, current_secondary_sid) > score_secondary_track(secondary, current_secondary_sid) then
                secondary = track
            end
        end
    end

    return primary, secondary
end

local function status_message_for(mode, primary_track, secondary_track)
    if mode == "off" then
        return "Subtitle Mode: Off"
    end

    if mode == "primary" then
        return "Subtitle Mode: Primary [" .. display_track_name(primary_track) .. "]"
    end

    if not secondary_track then
        return "Subtitle Mode: Dual (No 2nd Track)"
    end

    return "Subtitle Mode: Dual [" .. display_track_name(primary_track) .. " + " .. display_track_name(secondary_track) .. "]"
end

local function apply_subtitle_mode(mode, silent)
    if not valid_mode(mode) then
        mode = "dual"
    end

    local primary_track = find_track_by_id(mp.get_property_number("sid", -1))
    local secondary_track = find_track_by_id(mp.get_property_number("secondary-sid", -1))

    if mode == "off" then
        mp.set_property_bool("sub-visibility", false)
        mp.set_property_bool("secondary-sub-visibility", false)
    elseif mode == "primary" then
        if mp.get_property("sid") == "no" then
            mp.set_property("sid", "auto")
        end
        primary_track = find_track_by_id(mp.get_property_number("sid", -1)) or primary_track
        secondary_track = nil
        mp.set_property_bool("sub-visibility", true)
        mp.set_property_bool("secondary-sub-visibility", false)
    else
        primary_track, secondary_track = choose_dual_tracks()
        if primary_track then
            mp.set_property_number("sid", tonumber(primary_track.id))
            mp.set_property_bool("sub-visibility", true)
        elseif mp.get_property("sid") == "no" then
            mp.set_property("sid", "auto")
            mp.set_property_bool("sub-visibility", true)
        end

        if secondary_track then
            mp.set_property_number("secondary-sid", tonumber(secondary_track.id))
            mp.set_property_bool("secondary-sub-visibility", true)
        else
            mp.set_property("secondary-sid", "no")
            mp.set_property_bool("secondary-sub-visibility", false)
        end
    end

    state.subtitle_mode = mode
    write_state()

    if not silent then
        mp.osd_message(status_message_for(mode, primary_track, secondary_track), 2.0)
    end
end

local function cycle_subtitle_mode()
    local current = current_subtitle_mode()
    if current == "primary" then
        apply_subtitle_mode("dual", false)
    elseif current == "dual" then
        apply_subtitle_mode("off", false)
    else
        apply_subtitle_mode("primary", false)
    end
end

local function remember_volume(_, value)
    if type(value) ~= "number" then
        return
    end

    state.volume = round(value, 0)
    write_state()
end

read_state()

mp.observe_property("volume", "number", remember_volume)

mp.register_event("file-loaded", function()
    if state.volume then
        mp.set_property_number("volume", state.volume)
    end

    mp.add_timeout(0.05, function()
        apply_subtitle_mode(state.subtitle_mode, true)
    end)
end)

mp.register_event("shutdown", write_state)
mp.add_key_binding(nil, "subtitle-mode-cycle", cycle_subtitle_mode)
