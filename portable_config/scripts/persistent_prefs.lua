local mp = require "mp"
local utils = require "mp.utils"

local state_path = mp.command_native({ "expand-path", "~~/script-opts/persistent_prefs.json" })
local default_subtitle_mode = "primary"
local shared_state_path = "user-data/subtitle_auto/state"

local state = {
    volume = nil,
}

local signs_phrases = {
    "sign",
    "signs",
    "song",
    "songs",
    "sign song",
    "sign songs",
    "songs signs",
    "signs songs",
    "karaoke",
    "lyrics",
    "typeset",
    "typesetting",
    "on screen text",
    "onscreen text",
    "screen text",
    "title card",
    "opening",
    "ending",
    "credits",
}

local short_sign_tokens = {
    "op",
    "ed",
}

local dialogue_phrases = {
    "dialogue",
    "dialog",
    "dialogue only",
    "dialog only",
    "dialogue and songs",
    "full dialogue",
    "main dialogue",
    "full",
    "full subtitle",
    "full subtitles",
    "full sub",
    "full subs",
    "english sub",
    "english subs",
    "translation",
    "translated",
    "official",
    "retail",
    "english subtitles",
}

local forced_phrases = {
    "forced",
    "forced only",
    "foreign parts",
    "foreign dialogue",
    "foreign language",
    "foreign only",
    "non english",
    "non english only",
    "only foreign",
    "parts only",
}

local sdh_phrases = {
    "sdh",
    "closed caption",
    "closed captions",
    "hearing impaired",
    "hard of hearing",
    "dub cc",
}

local dubtitle_phrases = {
    "dubtitle",
    "dubtitles",
    "dub subtitle",
    "dub subtitles",
    "dub sub",
    "dub subs",
    "dub script",
    "dub transcript",
}

local commentary_phrases = {
    "commentary",
    "commentaries",
    "director commentary",
    "staff commentary",
    "notes",
}

local original_audio_phrases = {
    "japanese",
    "original",
    "original audio",
}

local function round(value, digits)
    local power = 10 ^ (digits or 0)
    return math.floor((value * power) + 0.5) / power
end

local function trim_text(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function normalize_text(text)
    text = tostring(text or ""):lower()
    text = text:gsub("[_%-%./\\+%[%]%(%){}:,;!?'\"&]", " ")
    text = text:gsub("[^%w%s]", " ")
    text = text:gsub("%s+", " ")
    return text:gsub("^%s*(.-)%s*$", "%1")
end

local function match_text(text)
    local normalized = normalize_text(text)
    if normalized == "" then
        return " "
    end
    return " " .. normalized .. " "
end

local function has_phrase(text, phrase)
    local normalized_phrase = normalize_text(phrase)
    if normalized_phrase == "" then
        return false
    end
    return match_text(text):find(" " .. normalized_phrase .. " ", 1, true) ~= nil
end

local function has_token(text, token)
    return has_phrase(text, token)
end

local function has_any_phrase(text, phrases)
    for _, phrase in ipairs(phrases) do
        if has_phrase(text, phrase) then
            return true
        end
    end
    return false
end

local function count_phrase_hits(text, phrases)
    local count = 0
    for _, phrase in ipairs(phrases) do
        if has_phrase(text, phrase) then
            count = count + 1
        end
    end
    return count
end

local function basename(path)
    path = tostring(path or "")
    if path == "" then
        return ""
    end
    local _, name = utils.split_path(path)
    return name or path
end

local function track_lang(track)
    return normalize_text(track and track.lang or "")
end

local function track_codec(track)
    return normalize_text(track and (track.codec or track["codec-desc"]) or "")
end

local function display_track_name(track)
    if not track then
        return "None"
    end

    local title = trim_text(track.title or "")
    if title ~= "" then
        return title
    end

    local lang = tostring(track.lang or ""):upper()
    if lang ~= "" then
        return lang .. " #" .. tostring(track.id)
    end

    return "Track #" .. tostring(track.id)
end

local function display_audio_name(track)
    if not track then
        return "No audio"
    end

    local title = trim_text(track.title or "")
    local lang = tostring(track.lang or ""):upper()

    if title ~= "" and lang ~= "" then
        return title .. " (" .. lang .. ")"
    end

    if title ~= "" then
        return title
    end

    if lang ~= "" then
        return lang .. " #" .. tostring(track.id)
    end

    return "Audio #" .. tostring(track.id)
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

local function current_audio_track()
    local selected_aid = mp.get_property_number("aid", -1)
    local tracks = mp.get_property_native("track-list") or {}

    for _, track in ipairs(tracks) do
        if track.type == "audio" and tonumber(track.id) == tonumber(selected_aid) then
            return track
        end
    end

    for _, track in ipairs(tracks) do
        if track.type == "audio" and track.selected then
            return track
        end
    end

    return nil
end

local function analyze_audio(track)
    local lang = track_lang(track)
    local title_text = normalize_text(track and track.title or "")
    local meta_text = normalize_text(table.concat({
        track and track.title or "",
        track and track.lang or "",
        basename(track and track["external-filename"] or ""),
    }, " "))

    local english = lang == "en" or lang == "eng" or has_phrase(meta_text, "english")
    local original = lang == "ja" or lang == "jpn" or has_any_phrase(meta_text, original_audio_phrases)
    local named_language = lang ~= "" and lang ~= "und" and lang ~= "zxx"
    local commentary = has_any_phrase(title_text, commentary_phrases)

    local preference = "unknown"
    local summary = "Other audio"

    if not track then
        summary = "No audio"
    elseif commentary then
        summary = "Commentary audio"
    elseif english then
        preference = "english"
        summary = "English dub"
    elseif has_phrase(meta_text, "dub") then
        preference = "english"
        summary = "Dub audio"
    elseif original or named_language then
        preference = "original"
        summary = "Original/foreign audio"
    end

    return {
        track = track,
        name = display_audio_name(track),
        summary = summary,
        preference = preference,
        english = english,
        japanese = japanese,
        commentary = commentary,
    }
end

local function analyze_subtitle_track(track)
    local label_text = normalize_text(table.concat({
        track and track.title or "",
        basename(track and track["external-filename"] or ""),
    }, " "))

    local meta_text = normalize_text(table.concat({
        track and track.title or "",
        basename(track and track["external-filename"] or ""),
        track and track.lang or "",
        track and track.codec or "",
        track and track["codec-desc"] or "",
    }, " "))

    local lang = track_lang(track)
    local codec = track_codec(track)
    local english = lang == "en" or lang == "eng" or has_phrase(meta_text, "english")
    local signs_hits = count_phrase_hits(label_text, signs_phrases)
    local dialogue_hits = count_phrase_hits(label_text, dialogue_phrases)

    for _, token in ipairs(short_sign_tokens) do
        if has_token(label_text, token) then
            signs_hits = signs_hits + 1
        end
    end

    local forced = (track and track.forced == true) or has_any_phrase(label_text, forced_phrases)
    local hearing_impaired = (track and track["hearing-impaired"] == true) or has_any_phrase(label_text, sdh_phrases) or has_token(label_text, "cc")
    local commentary = has_any_phrase(label_text, commentary_phrases)
    local dubtitle = has_any_phrase(label_text, dubtitle_phrases)
        or has_phrase(label_text, "english dub")
        or (has_phrase(label_text, "dub") and (hearing_impaired or english))
    local signs = forced or signs_hits > 0
    local dialogue = dialogue_hits > 0
    local full = dialogue or (english and not signs and not commentary)
    local subrip = codec == "srt" or has_phrase(codec, "subrip")
    local ass = has_token(codec, "ass") or has_token(codec, "ssa")

    return {
        english = english,
        default = track and track.default == true or false,
        external = track and track.external == true or false,
        forced = forced,
        hearing_impaired = hearing_impaired,
        commentary = commentary,
        dubtitle = dubtitle,
        dialogue = dialogue,
        full = full,
        signs = signs,
        subrip = subrip,
        ass = ass,
    }
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
    local features = analyze_subtitle_track(track)
    local score = 0

    if tonumber(track.id) == tonumber(current_sid) then
        score = score + 20
    end
    if features.english then
        score = score + 120
    end
    if features.default then
        score = score + 40
    end
    if features.dialogue or features.full then
        score = score + 90
    end
    if features.hearing_impaired then
        score = score + 20
    end
    if features.external then
        score = score + 10
    end
    if features.subrip then
        score = score + 30
    elseif features.ass then
        score = score + 15
    end
    if features.dubtitle then
        score = score - 10
    end
    if features.signs then
        score = score - 160
    end
    if features.commentary then
        score = score - 220
    end

    return score
end

local function score_dubbed_primary(track, current_sid)
    local features = analyze_subtitle_track(track)
    local score = 0

    if tonumber(track.id) == tonumber(current_sid) then
        score = score + 20
    end
    if features.english then
        score = score + 60
    end
    if features.signs then
        score = score + 180
    end
    if features.forced then
        score = score + 80
    end
    if features.ass then
        score = score + 35
    elseif features.subrip then
        score = score - 20
    end
    if features.default then
        score = score + 15
    end
    if features.external then
        score = score + 10
    end
    if features.dialogue or features.full then
        score = score - 90
    end
    if features.hearing_impaired then
        score = score - 40
    end
    if features.dubtitle then
        score = score - 60
    end
    if features.commentary then
        score = score - 220
    end

    return score
end

local function score_signs_primary(track, current_sid)
    local features = analyze_subtitle_track(track)
    local score = 0

    if tonumber(track.id) == tonumber(current_sid) then
        score = score + 25
    end
    if features.english then
        score = score + 40
    end
    if features.signs then
        score = score + 170
    end
    if features.forced then
        score = score + 60
    end
    if features.ass then
        score = score + 35
    elseif features.subrip then
        score = score - 60
    end
    if features.dialogue or features.full then
        score = score - 130
    end
    if features.hearing_impaired then
        score = score - 150
    end
    if features.dubtitle then
        score = score - 180
    end
    if features.commentary then
        score = score - 220
    end

    return score
end

local function score_dialogue_secondary(track, current_secondary_sid, audio_preference)
    local features = analyze_subtitle_track(track)
    local score = 0

    if tonumber(track.id) == tonumber(current_secondary_sid) then
        score = score + 20
    end
    if features.english then
        score = score + 120
    end
    if features.dialogue or features.full then
        score = score + 90
    end
    if features.default then
        score = score + 20
    end
    if features.external then
        score = score + 15
    end
    if features.subrip then
        score = score + 35
    elseif features.ass then
        score = score + 10
    end
    if audio_preference == "english" then
        if features.hearing_impaired then
            score = score + 60
        end
        if features.dubtitle then
            score = score + 60
        end
    else
        if features.hearing_impaired then
            score = score + 20
        end
        if features.dubtitle then
            score = score + 10
        end
    end
    if features.signs or features.forced then
        score = score - 180
    end
    if features.commentary then
        score = score - 220
    end

    return score
end

local function build_selection_context(tracks)
    return {
        tracks = tracks or subtitle_tracks(),
        audio = analyze_audio(current_audio_track()),
    }
end

local function choose_regular_primary(context)
    local subs = context.tracks
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

    return find_track_by_id(current_sid, subs) or subs[1]
end

local function choose_primary_track(context)
    local subs = context.tracks
    if #subs == 0 then
        return nil
    end

    local current_sid = mp.get_property_number("sid", -1)

    if context.audio.preference == "english" then
        local dubbed_primary, dubbed_score = best_track(subs, function(track)
            return score_dubbed_primary(track, current_sid)
        end)
        if dubbed_primary and dubbed_score >= 150 then
            return dubbed_primary
        end
    end

    return choose_regular_primary(context)
end

local function choose_smart_dual_pair(context)
    local subs = context.tracks
    if #subs < 2 then
        return nil, nil
    end

    local current_sid = mp.get_property_number("sid", -1)
    local current_secondary_sid = mp.get_property_number("secondary-sid", -1)

    local signs_track, signs_score = best_track(subs, function(track)
        return score_signs_primary(track, current_sid)
    end)

    if not signs_track or signs_score < 150 then
        return nil, nil
    end

    local dialogue_track, dialogue_score = best_track(subs, function(track)
        return score_dialogue_secondary(track, current_secondary_sid, context.audio.preference)
    end, signs_track.id)

    if not dialogue_track or dialogue_score < 120 then
        return nil, nil
    end

    return signs_track, dialogue_track
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

local function current_manual_dual_pair(tracks)
    local primary_track = find_track_by_id(mp.get_property_number("sid", -1), tracks)
    local secondary_track = find_track_by_id(mp.get_property_number("secondary-sid", -1), tracks)

    if primary_track and secondary_track and tonumber(primary_track.id) ~= tonumber(secondary_track.id) then
        return primary_track, secondary_track
    end

    return nil, nil
end

local function dual_mode_available(context)
    local manual_primary, manual_secondary = current_manual_dual_pair(context.tracks)
    if manual_primary and manual_secondary then
        return true
    end

    local smart_primary, smart_secondary = choose_smart_dual_pair(context)
    return smart_primary ~= nil and smart_secondary ~= nil
end

local function status_message_for(mode, primary_track, secondary_track, detail)
    local message

    if mode == "off" then
        message = "Subtitle Mode: Off"
    elseif mode == "primary" then
        message = "Subtitle Mode: Primary [" .. display_track_name(primary_track) .. "]"
    elseif secondary_track then
        message = "Subtitle Mode: Dual [" .. display_track_name(primary_track) .. " + " .. display_track_name(secondary_track) .. "]"
    else
        message = "Subtitle Mode: Primary [" .. display_track_name(primary_track) .. "]"
    end

    if detail and detail ~= "" then
        message = message .. " (" .. detail .. ")"
    end

    return message
end

local function update_shared_state()
    local context = build_selection_context()
    local smart_primary = choose_primary_track(context)
    local smart_dual_primary, smart_dual_secondary = choose_smart_dual_pair(context)

    mp.set_property_native(shared_state_path, {
        audio_name = context.audio.name,
        audio_summary = context.audio.summary,
        audio_preference = context.audio.preference,
        track_count = #context.tracks,
        smart_primary_available = smart_primary ~= nil,
        smart_primary_label = display_track_name(smart_primary),
        smart_primary_id = smart_primary and tonumber(smart_primary.id) or nil,
        smart_dual_available = smart_dual_primary ~= nil and smart_dual_secondary ~= nil,
        smart_dual_primary_label = display_track_name(smart_dual_primary),
        smart_dual_secondary_label = display_track_name(smart_dual_secondary),
        smart_dual_primary_id = smart_dual_primary and tonumber(smart_dual_primary.id) or nil,
        smart_dual_secondary_id = smart_dual_secondary and tonumber(smart_dual_secondary.id) or nil,
    })
end

local function refresh_shared_state()
    local ok, err = pcall(update_shared_state)
    if not ok then
        mp.msg.error("subtitle state publish error: " .. tostring(err))
    end
end

local function apply_subtitle_mode(mode, silent)
    if not valid_mode(mode) then
        mode = default_subtitle_mode
    end

    local context = build_selection_context()
    local primary_track = find_track_by_id(mp.get_property_number("sid", -1), context.tracks)
    local secondary_track = find_track_by_id(mp.get_property_number("secondary-sid", -1), context.tracks)
    local detail = nil

    if mode == "off" then
        mp.set_property_bool("sub-visibility", false)
        mp.set_property("secondary-sid", "no")
        mp.set_property_bool("secondary-sub-visibility", false)
        secondary_track = nil
    elseif mode == "primary" then
        primary_track = choose_primary_track(context)
        if primary_track then
            mp.set_property_number("sid", tonumber(primary_track.id))
            mp.set_property_bool("sub-visibility", true)
        elseif mp.get_property("sid") == "no" then
            mp.set_property("sid", "auto")
            mp.set_property_bool("sub-visibility", true)
        end

        primary_track = find_track_by_id(mp.get_property_number("sid", -1), context.tracks) or primary_track
        secondary_track = nil
        mp.set_property("secondary-sid", "no")
        mp.set_property_bool("secondary-sub-visibility", false)
    else
        local manual_primary, manual_secondary = current_manual_dual_pair(context.tracks)
        local smart_primary, smart_secondary = choose_smart_dual_pair(context)

        if manual_primary and manual_secondary then
            primary_track = manual_primary
            secondary_track = manual_secondary
        elseif smart_primary and smart_secondary then
            primary_track = smart_primary
            secondary_track = smart_secondary
        else
            primary_track = choose_primary_track(context)
            secondary_track = nil
            mode = "primary"
            detail = "smart dual unavailable"
        end

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

        primary_track = find_track_by_id(mp.get_property_number("sid", -1), context.tracks) or primary_track
        secondary_track = find_track_by_id(mp.get_property_number("secondary-sid", -1), context.tracks) or secondary_track
    end

    refresh_shared_state()

    if not silent then
        mp.osd_message(status_message_for(mode, primary_track, secondary_track, detail), 2.0)
    end
end

local function cycle_subtitle_mode()
    local context = build_selection_context()
    if #context.tracks == 0 then
        mp.osd_message("Subtitle Mode: No subtitle tracks available", 2.0)
        return
    end

    local modes = { "primary" }
    if dual_mode_available(context) then
        modes[#modes + 1] = "dual"
    end
    modes[#modes + 1] = "off"

    local current = current_subtitle_mode()
    local current_index = 1

    for index, mode in ipairs(modes) do
        if mode == current then
            current_index = index
            break
        end
    end

    local next_index = (current_index % #modes) + 1
    apply_subtitle_mode(modes[next_index], false)
end

local function smart_select_subtitles(kind)
    local context = build_selection_context()
    if #context.tracks == 0 then
        mp.osd_message("Smart Select: No subtitle tracks available", 2.0)
        return
    end

    if kind == "dual" then
        local smart_primary, smart_secondary = choose_smart_dual_pair(context)
        if not smart_primary or not smart_secondary then
            refresh_shared_state()
            mp.osd_message("Smart Dual: No confident signs/dialogue pair found", 2.0)
            return
        end
        apply_subtitle_mode("dual", false)
        return
    end

    apply_subtitle_mode("primary", false)
end

local function safe_cycle_subtitle_mode()
    local ok, err = pcall(cycle_subtitle_mode)
    if not ok then
        mp.osd_message("Subtitle mode error: " .. tostring(err), 2.0)
        mp.msg.error("subtitle mode error: " .. tostring(err))
    end
end

local function safe_set_subtitle_mode(mode)
    local ok, err = pcall(function()
        apply_subtitle_mode(mode, false)
    end)
    if not ok then
        mp.osd_message("Subtitle mode error: " .. tostring(err), 2.0)
        mp.msg.error("subtitle mode error: " .. tostring(err))
    end
end

local function safe_smart_select(kind)
    local ok, err = pcall(function()
        smart_select_subtitles(kind)
    end)
    if not ok then
        mp.osd_message("Smart subtitle error: " .. tostring(err), 2.0)
        mp.msg.error("smart subtitle error: " .. tostring(err))
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
mp.observe_property("aid", "native", refresh_shared_state)
mp.observe_property("sid", "native", refresh_shared_state)
mp.observe_property("secondary-sid", "native", refresh_shared_state)
mp.observe_property("sub-visibility", "bool", refresh_shared_state)
mp.observe_property("secondary-sub-visibility", "bool", refresh_shared_state)
mp.observe_property("track-list", "native", refresh_shared_state)

mp.register_event("file-loaded", function()
    if state.volume then
        mp.set_property_number("volume", state.volume)
    end

    mp.add_timeout(0.05, function()
        local ok, err = pcall(function()
            apply_subtitle_mode(default_subtitle_mode, true)
        end)
        if not ok then
            mp.msg.error("subtitle restore error: " .. tostring(err))
        end
        refresh_shared_state()
    end)
end)

mp.register_event("shutdown", write_state)
mp.add_key_binding(nil, "subtitle-mode-cycle", safe_cycle_subtitle_mode)
mp.register_script_message("cycle-subtitle-mode", safe_cycle_subtitle_mode)
mp.register_script_message("set-subtitle-mode", safe_set_subtitle_mode)
mp.register_script_message("smart-select-subtitles", safe_smart_select)

refresh_shared_state()
