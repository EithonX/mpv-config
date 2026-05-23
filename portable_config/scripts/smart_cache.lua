-- smart_cache.lua — Adaptive demuxer cache for network streams
--
-- Dynamically adjusts demuxer-max-bytes, demuxer-max-back-bytes,
-- and cache-secs based on detected bitrate (file_size / duration).
-- Automatically switches to disk-backed cache for very large files
-- to avoid exhausting RAM on memory-constrained systems.
--
-- Place in scripts/ and configure via script-opts/smart_cache.conf

local msg = require "mp.msg"
local opt = require "mp.options"

-- ── User options (overridable via smart_cache.conf) ─────────────────────
local opts = {
    enabled              = true,

    -- scope
    network_only         = true,    -- skip local files entirely

    -- target seconds of forward buffer per bitrate tier
    target_secs_low      = 120,     -- ≤ 2 Mbps
    target_secs_mid      = 90,      -- 2–10 Mbps
    target_secs_high     = 60,      -- 10–30 Mbps
    target_secs_vhigh    = 45,      -- 30–80 Mbps
    target_secs_extreme  = 30,      -- ≥ 80 Mbps

    -- hard limits (MiB)
    min_forward_mib      = 32,
    max_forward_mib      = 512,
    min_back_mib         = 16,
    max_back_mib         = 256,

    -- back buffer ratio relative to forward
    back_ratio           = 0.5,

    -- cache-secs limits
    min_cache_secs       = 30,
    max_cache_secs       = 300,

    -- re-adjust after N seconds using observed bitrate (0 = disabled)
    readjust_after_secs  = 30,

    -- disk cache: auto-enable when forward cache would exceed this (MiB)
    -- set to 0 to never use disk cache
    disk_cache_threshold_mib = 384,

    -- disk cache directory (mpv expand-path syntax)
    disk_cache_dir       = "~~cache/smart_cache",

    -- verbose logging to console
    verbose              = true,
}
opt.read_options(opts, "smart_cache")

-- ── Constants ───────────────────────────────────────────────────────────
local MiB              = 1024 * 1024
local Mbps_to_Bps      = 1000 * 1000 / 8   -- 1 Mbps in bytes/sec

-- ── State ───────────────────────────────────────────────────────────────
local state = {
    applied        = false,    -- have we set cache for this file?
    readjust_timer = nil,      -- one-shot timer for mid-playback re-adjust
    disk_cache_on  = false,    -- did we enable disk cache for this file?
    initial_bitrate = nil,     -- bitrate we computed on file-load
}

-- ── Defaults to restore between files ───────────────────────────────────
-- We capture mpv's defaults on script init so we can reset cleanly.
local defaults = {
    demuxer_max_bytes      = mp.get_property_number("demuxer-max-bytes"),
    demuxer_max_back_bytes = mp.get_property_number("demuxer-max-back-bytes"),
    cache_secs             = mp.get_property_number("cache-secs"),
    cache_on_disk          = mp.get_property("cache-on-disk"),
}

-- ── Helpers ─────────────────────────────────────────────────────────────
local function clamp(val, lo, hi)
    if val < lo then return lo end
    if val > hi then return hi end
    return val
end

local function fmt_bytes(bytes)
    if bytes >= MiB then
        return string.format("%.0f MiB", bytes / MiB)
    elseif bytes >= 1024 then
        return string.format("%.0f KiB", bytes / 1024)
    else
        return string.format("%.0f B", bytes)
    end
end

local function fmt_mbps(bps)
    return string.format("%.1f Mbps", bps * 8 / 1000000)
end

local function log(...)
    if opts.verbose then msg.info(...) end
end

local function is_network_path(path)
    if not path then return false end
    -- normalize ytdl:// prefix
    path = path:gsub("^ytdl://https?://", "https://"):gsub("^ytdl://", "https://")
    local scheme = path:match("^([%w][%w+%-%.]*)://")
    if not scheme then return false end
    local net = {
        http=true, https=true,
        ftp=true, ftps=true,
        rtmp=true, rtmps=true,
        rtsp=true, rtsps=true,
        mms=true, mmsh=true, mmst=true,
    }
    return net[scheme:lower()] == true
end

local function is_image_file()
    local t = mp.get_property_native("current-tracks/video")
    return t ~= nil and t.image == true and t.albumart ~= true
end

local function has_video_track()
    local tracks = mp.get_property_native("track-list", {})
    for _, t in ipairs(tracks) do
        if t.type == "video" and not t.image and not t.albumart then
            return true
        end
    end
    return false
end

-- ── Bitrate tier → target seconds ───────────────────────────────────────
local function get_target_secs(bitrate_bps)
    local mbps = bitrate_bps * 8 / 1000000
    if     mbps <= 2  then return opts.target_secs_low
    elseif mbps <= 10 then return opts.target_secs_mid
    elseif mbps <= 30 then return opts.target_secs_high
    elseif mbps <= 80 then return opts.target_secs_vhigh
    else                    return opts.target_secs_extreme
    end
end

-- ── Apply cache settings ────────────────────────────────────────────────
local function apply_cache(bitrate_bps, duration, source_label)
    if bitrate_bps <= 0 then
        log("[smart_cache] Bitrate is zero or negative, skipping.")
        return
    end

    local target_secs = get_target_secs(bitrate_bps)

    -- for very short files, don't try to buffer more than half the total
    if duration and duration > 0 and duration < 120 then
        target_secs = math.min(target_secs, duration * 0.5)
        target_secs = math.max(target_secs, 10) -- absolute floor
    end

    -- calculate ideal forward cache in bytes
    local ideal_forward = bitrate_bps * target_secs

    -- clamp to hard limits
    local forward_bytes = clamp(ideal_forward,
        opts.min_forward_mib * MiB,
        opts.max_forward_mib * MiB)

    -- back buffer
    local back_bytes = clamp(forward_bytes * opts.back_ratio,
        opts.min_back_mib * MiB,
        opts.max_back_mib * MiB)

    -- actual cache-secs we'll get with the clamped forward bytes
    local actual_secs = forward_bytes / bitrate_bps
    actual_secs = clamp(actual_secs, opts.min_cache_secs, opts.max_cache_secs)

    -- ── Disk cache decision ─────────────────────────────────────────────
    -- If ideal forward cache exceeds the disk threshold AND we have a
    -- disk cache dir configured, switch to disk-backed cache for this file.
    -- This lets us buffer much more without RAM pressure.
    local use_disk = false
    if opts.disk_cache_threshold_mib > 0
        and ideal_forward > opts.disk_cache_threshold_mib * MiB then
        use_disk = true
        -- with disk cache we can afford a larger forward buffer
        forward_bytes = clamp(ideal_forward,
            opts.min_forward_mib * MiB,
            1024 * MiB) -- up to 1 GiB on disk
        actual_secs = clamp(forward_bytes / bitrate_bps,
            opts.min_cache_secs, 600)
    end

    -- ── Apply ───────────────────────────────────────────────────────────
    mp.set_property_number("demuxer-max-bytes", forward_bytes)
    mp.set_property_number("demuxer-max-back-bytes", back_bytes)
    mp.set_property_number("cache-secs", actual_secs)

    if use_disk and not state.disk_cache_on then
        -- ensure cache directory exists
        local dir = mp.command_native({"expand-path", opts.disk_cache_dir})
        if dir then
            mp.command_native({"subprocess", args={"cmd", "/c", "mkdir", dir}, capture_stdout=true, capture_stderr=true})
        end
        mp.set_property("cache-on-disk", "yes")
        mp.set_property("demuxer-cache-dir", dir or "")
        state.disk_cache_on = true
    elseif not use_disk and state.disk_cache_on then
        mp.set_property("cache-on-disk", defaults.cache_on_disk or "no")
        state.disk_cache_on = false
    end

    state.applied = true
    state.initial_bitrate = bitrate_bps

    log(string.format(
        "[smart_cache] %s | bitrate=%s | forward=%s | back=%s | secs=%.0f | disk=%s",
        source_label,
        fmt_mbps(bitrate_bps),
        fmt_bytes(forward_bytes),
        fmt_bytes(back_bytes),
        actual_secs,
        use_disk and "yes" or "no"
    ))
end

-- ── Reset to defaults ───────────────────────────────────────────────────
local function reset_cache()
    if not state.applied then return end

    mp.set_property_number("demuxer-max-bytes", defaults.demuxer_max_bytes or 512 * MiB)
    mp.set_property_number("demuxer-max-back-bytes", defaults.demuxer_max_back_bytes or 512 * MiB)
    mp.set_property_number("cache-secs", defaults.cache_secs or 10)

    if state.disk_cache_on then
        mp.set_property("cache-on-disk", defaults.cache_on_disk or "no")
        state.disk_cache_on = false
    end

    state.applied = false
    state.initial_bitrate = nil
    log("[smart_cache] Reset to defaults.")
end

-- ── Mid-playback re-adjustment (gentle) ─────────────────────────────────
-- Uses observed demuxer bitrate. Only adjusts UPWARD to avoid disrupting
-- playback — we never shrink an active buffer.
local function readjust()
    if not state.applied then return end

    local cache_state = mp.get_property_native("demuxer-cache-state")
    if not cache_state then return end

    -- raw-input-rate is bytes/sec as observed by the demuxer
    local observed_bps = cache_state["raw-input-rate"]
    if not observed_bps or observed_bps <= 0 then return end

    local duration = mp.get_property_number("duration")

    -- only adjust upward — never shrink mid-playback (causes stutter)
    if state.initial_bitrate and observed_bps <= state.initial_bitrate * 1.2 then
        log(string.format(
            "[smart_cache] Re-check: observed=%s ≈ initial, no change needed.",
            fmt_mbps(observed_bps)
        ))
        return
    end

    log(string.format(
        "[smart_cache] Re-adjusting: observed=%s (was %s)",
        fmt_mbps(observed_bps),
        state.initial_bitrate and fmt_mbps(state.initial_bitrate) or "unknown"
    ))
    apply_cache(observed_bps, duration, "re-adjust (observed)")
end

-- ── Main entry: called on file-loaded ───────────────────────────────────
local function on_file_loaded()
    if not opts.enabled then return end

    -- cancel any pending re-adjust timer from previous file
    if state.readjust_timer then
        state.readjust_timer:kill()
        state.readjust_timer = nil
    end

    local path = mp.get_property("path")

    -- skip local files if configured
    if opts.network_only and not is_network_path(path) then
        log("[smart_cache] Local file detected, skipping.")
        reset_cache()
        return
    end

    -- skip image files
    if is_image_file() then
        log("[smart_cache] Image file detected, skipping.")
        reset_cache()
        return
    end

    local duration = mp.get_property_number("duration")
    local file_size = mp.get_property_number("file-size", 0)

    -- ── Audio-only: minimal cache ───────────────────────────────────────
    if not has_video_track() then
        log("[smart_cache] Audio-only stream, using minimal cache.")
        mp.set_property_number("demuxer-max-bytes", opts.min_forward_mib * MiB)
        mp.set_property_number("demuxer-max-back-bytes", opts.min_back_mib * MiB)
        mp.set_property_number("cache-secs", opts.max_cache_secs)
        state.applied = true
        return
    end

    -- ── Live/infinite streams: conservative defaults ────────────────────
    if not duration or duration <= 0 then
        log("[smart_cache] Live/unknown duration stream, using conservative cache.")
        local conservative_forward = 150 * MiB
        mp.set_property_number("demuxer-max-bytes", conservative_forward)
        mp.set_property_number("demuxer-max-back-bytes", 32 * MiB) -- minimal back for live
        mp.set_property_number("cache-secs", 60)
        state.applied = true

        -- schedule a re-adjust to use observed bitrate once we have data
        if opts.readjust_after_secs > 0 then
            state.readjust_timer = mp.add_timeout(opts.readjust_after_secs, readjust)
        end
        return
    end

    -- ── Known size + duration: calculate bitrate ────────────────────────
    if file_size > 0 and duration > 0 then
        local bitrate = file_size / duration
        log(string.format(
            "[smart_cache] File: %s, Duration: %.0fs, Bitrate: %s",
            fmt_bytes(file_size), duration, fmt_mbps(bitrate)
        ))
        apply_cache(bitrate, duration, "file-size/duration")

        -- schedule a gentle re-adjust to refine with observed data
        if opts.readjust_after_secs > 0 then
            state.readjust_timer = mp.add_timeout(opts.readjust_after_secs, readjust)
        end
        return
    end

    -- ── Unknown file size but known duration ────────────────────────────
    -- Use a moderate estimate, then re-adjust with observed bitrate
    log("[smart_cache] Unknown file size, using moderate defaults + deferred re-adjust.")
    local moderate_forward = 200 * MiB
    mp.set_property_number("demuxer-max-bytes", moderate_forward)
    mp.set_property_number("demuxer-max-back-bytes", 100 * MiB)
    mp.set_property_number("cache-secs", 90)
    state.applied = true

    -- definitely re-adjust once we have observed data
    if opts.readjust_after_secs > 0 then
        state.readjust_timer = mp.add_timeout(math.min(opts.readjust_after_secs, 15), readjust)
    end
end

-- ── Event handlers ──────────────────────────────────────────────────────
mp.register_event("file-loaded", on_file_loaded)

mp.register_event("end-file", function()
    if state.readjust_timer then
        state.readjust_timer:kill()
        state.readjust_timer = nil
    end
    reset_cache()
end)

msg.info("[smart_cache] Loaded. Network-adaptive demuxer cache is " ..
    (opts.enabled and "enabled" or "disabled") .. ".")
