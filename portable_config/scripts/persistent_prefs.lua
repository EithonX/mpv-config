local mp = require "mp"
local utils = require "mp.utils"

local state_path = mp.command_native({ "expand-path", "~~/script-opts/persistent_prefs.json" })
local state = {
    volume = nil,
    subtitle_mode = "dual",
}

local signs_keywords = {
    "sign", "signs", "song", "songs", "karaoke", "lyrics", "forced", "op", "ed",
}

local cc_keywords = {
    "cc", "sdh", "closed caption", "closed captions", "hearing impaired",
    "dialogue", "dialog", "full sub", "full subs", "full subtitle",
    "full subtitles", "dubtitle", "dubtitles", "dub cc",
}

local function round(value, digits)
    local power = 10 ^ (digits or 0)
    return math.floor((value * power) + 0.5) / power
end

local function has_any(text, keywords)
    for _, keyword in ipairs(keywords) do
        if text:find(keyword, 1, true) then
            return true
        end
    end
    return false
end

local function track_text(track)
    local parts = {
        tostring(track.title or ""),
        tostring(track.lang or ""),
        tostring(track.codec or ""),
        tostring(track["codec-desc"] or ""),
        tostring(track["external-filename"] or ""),
    }
    return table.concat(parts, " "):lower()
end

local function track_lang(track)
    return tostring(track.lang or ""):lower()
end

local function track_codec(track)
    return tostring(track.codec or track["codec-desc"] or ""):lower()
end

local function is_english(track)
    local lang = track_lang(track)
    local text = track_text(track)
    return lang == "en" or lang == "eng" or text:find("english", 1, true) ~= nil
end

local function is_subrip(track)
    local codec = track_codec(track)
    return codec == "srt" or codec:find("subrip", 1, true) ~= nil
end

local function is_ass(track)
    local codec = track_codec(track)
    return codec:find("ass", 1, true) ~= nil or codec:find("ssa", 1, true) ~= nil
end

local function is_signs_like(track)
    return track.forced or has_any(track_text(track), signs_keywords)
end

local function is_cc_like(track)
    return has_any(track_text(track), cc_keywords)
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

local function best_track(tracks, scorer, excluded_id)
    local best = nil
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

local function score_regular_primary(track, current_sid)
    local score = 0

    if tonumber(track.id) == tonumber(current_sid) then
        score = score + 25
    end
    if is_english(track) then
        score = score + 120
    end
    if track.default then
        score = score + 35
    end
    if is_subrip(track) then
        score = score + 20
    elseif is_ass(track) then
        score = score + 12
    end
    if is_cc_like(track) then
        score = score + 30
    end
    if is_signs_like(track) then
        score = score - 120
    end

    return score
end

local function score_signs_primary(track, current_sid)
    local score = 0

    if tonumber(track.id) == tonumber(current_sid) then
        score = score + 25
    end
    if is_english(track) then
        score = score + 70
    end
    if is_signs_like(track) then
        score = score + 170
    end
    if track.forced then
        score = score + 40
    end
    if is_ass(track) then
        score = score + 25
    end
    if is_subrip(track) then
        score = score - 80
    end
    if is_cc_like(track) then
        score = score - 140
    end

    return score
end

local function score_dialogue_secondary(track, current_secondary_sid)
    local score = 0

    if tonumber(track.id) == tonumber(current_secondary_sid) then
        score = score + 20
    end
    if is_english(track) then
        score = score + 100
    end
    if is_subrip(track) then
        score = score + 110
    elseif is_ass(track) then
        score = score + 10
    end
    if is_cc_like(track) then
        score = score + 80
    end
    if track.default then
        score = score + 10
    end
    if is_signs_like(track) then
        score = score - 180
    end

    return score
end

local function choose_anime_dual_pair()
    local subs = subtitle_tracks()
    if #subs < 2 then
        return nil, nil
    end

    local current_sid = mp.get_property_number("sid", -1)
    local current_secondary_sid = mp.get_property_number("secondary-sid", -1)

    local signs_track, signs_score = best_track(subs, function(track)
        return score_signs_primary(track, current_sid)
    end)

    if not signs_track or signs_score < 180 then
        return nil, nil
    end

    local dialogue_track, dialogue_score = best_track(subs, function(track)
        return score_dialogue_secondary(track, current_secondary_sid)
    end, signs_track.id)

    if not dialogue_track or dialogue_score < 150 then
        return nil, nil
    end

    return signs_track, dialogue_track
end

local function choose_regular_primary()
    local subs = subtitle_tracks()
    if #subs == 0 then
        return nil
    end

    local current_sid = mp.get_property_number("sid", -1)
    local primary, score = best_track(subs, function(track)
        return score_regular_primary(track, current_sid)
    end)

    if primary and score > 0 then
        return primary
    end

    return find_track_by_id(current_sid) or subs[1]
end

local function choose_primary_track()
    local anime_primary = choose_anime_dual_pair()
    if anime_primary then
        return anime_primary
    end

    return choose_regular_primary()
end

local function choose_dual_tracks()
    local anime_primary, anime_secondary = choose_anime_dual_pair()
    if anime_primary and anime_secondary then
        return anime_primary, anime_secondary
    end

    local primary = choose_regular_primary()
    return primary, nil
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

local function status_message_for(mode, primary_track, secondary_track)
    if mode == "off" then
        return "Subtitle Mode: Off"
    end

    if mode == "primary" then
        return "Subtitle Mode: Primary [" .. display_track_name(primary_track) .. "]"
    end

    if secondary_track then
        return "Subtitle Mode: Dual [" .. display_track_name(primary_track) .. " + " .. display_track_name(secondary_track) .. "]"
    end

    return "Subtitle Mode: Dual -> Primary [" .. display_track_name(primary_track) .. "]"
end

local function apply_subtitle_mode(mode, silent)
    if not valid_mode(mode) then
        mode = "dual"
    end

    local primary_track = find_track_by_id(mp.get_property_number("sid", -1))
    local secondary_track = find_track_by_id(mp.get_property_number("secondary-sid", -1))

    if mode == "off" then
        mp.set_property_bool("sub-visibility", false)
        mp.set_property("secondary-sid", "no")
        mp.set_property_bool("secondary-sub-visibility", false)
    elseif mode == "primary" then
        primary_track = choose_primary_track()
        if primary_track then
            mp.set_property_number("sid", tonumber(primary_track.id))
            mp.set_property_bool("sub-visibility", true)
        elseif mp.get_property("sid") == "no" then
            mp.set_property("sid", "auto")
            mp.set_property_bool("sub-visibility", true)
        end

        primary_track = find_track_by_id(mp.get_property_number("sid", -1)) or primary_track
        secondary_track = nil
        mp.set_property("secondary-sid", "no")
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

local function safe_cycle_subtitle_mode()
    local ok, err = pcall(cycle_subtitle_mode)
    if not ok then
        mp.osd_message("Subtitle mode error: " .. tostring(err), 2.0)
        mp.msg.error("subtitle mode error: " .. tostring(err))
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
        local ok, err = pcall(function()
            apply_subtitle_mode(state.subtitle_mode, true)
        end)
        if not ok then
            mp.msg.error("subtitle restore error: " .. tostring(err))
        end
    end)
end)

mp.register_event("shutdown", write_state)
mp.add_key_binding(nil, "subtitle-mode-cycle", safe_cycle_subtitle_mode)
mp.register_script_message("cycle-subtitle-mode", safe_cycle_subtitle_mode)
