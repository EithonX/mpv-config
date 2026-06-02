local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local function url_decode(str)
    if not str then return nil end
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

local function is_network_path(path)
    if not path then return false end
    path = path:gsub("^ytdl://https?://", "https://"):gsub("^ytdl://", "https://")
    local scheme = path:match("^([%w][%w+%-%.]*)://")
    if not scheme then return false end
    local net = { http = true, https = true }
    return net[scheme:lower()] == true
end

local resolving = false

local function set_title(filename)
    if not filename or filename == "" then return end
    filename = url_decode(filename)
    -- Remove surrounding quotes if present just in case
    filename = string.gsub(filename, '^"(.+)"$', "%1")
    filename = string.gsub(filename, "^'(.)'$", "%1")
    mp.set_property("force-media-title", filename)
    msg.info("Resolved title: " .. filename)
end

local function extract_filename(headers)
    local filename = nil
    for line in string.gmatch(headers, "[^\r\n]+") do
        local lower_line = string.lower(line)
        if string.match(lower_line, "^content%-disposition:") then
            -- Try UTF-8 format first
            -- e.g. filename*=UTF-8''EncodedName
            local _, _, utf8_name = string.find(line, "filename%*=[Uu][Tt][Ff]%-8''([^;%s]+)")
            if utf8_name then
                filename = utf8_name
                break
            end
            
            -- Try quoted filename
            local _, _, quoted_name = string.find(line, "filename=\"([^\"]+)\"")
            if quoted_name then
                filename = quoted_name
                break
            end
            
            -- Try unquoted filename
            local _, _, unquoted_name = string.find(line, "filename=([^;%s]+)")
            if unquoted_name then
                filename = unquoted_name
                break
            end
        end
    end
    return filename
end

local is_windows = package.config:sub(1,1) == "\\"

local function resolve_title(url)
    if resolving then return end
    resolving = true

    local function parse_and_set(output)
        local filename = extract_filename(output)
        if filename then
            set_title(filename)
        end
    end

    local function try_wget()
        mp.command_native_async({
            name = "subprocess",
            args = {"wget", "--spider", "--server-response", "-q", url},
            capture_stdout = false,
            capture_stderr = true
        }, function(success, result, error)
            resolving = false
            if success and result and result.stderr then
                -- wget outputs headers to stderr
                parse_and_set(result.stderr)
            end
        end)
    end
    
    local function try_powershell()
        -- Use .RawContent from Invoke-WebRequest to get the raw HTTP headers
        local ps_cmd = string.format([[$r = Invoke-WebRequest -Uri '%s' -Method Get -Headers @{Range='bytes=0-0'} -UseBasicParsing -ErrorAction SilentlyContinue; if ($r) { Write-Output $r.RawContent }]], url:gsub("'", "''"))
        mp.command_native_async({
            name = "subprocess",
            args = {"powershell", "-NoProfile", "-Command", ps_cmd},
            capture_stdout = true,
            capture_stderr = false
        }, function(success, result, error)
            resolving = false
            if success and result and result.stdout then
                parse_and_set(result.stdout)
            end
        end)
    end

    local curl_cmd = is_windows and "curl.exe" or "curl"
    local null_out = is_windows and "NUL" or "/dev/null"
    
    mp.command_native_async({
        name = "subprocess",
        args = {curl_cmd, "-s", "-D", "-", "-o", null_out, "-r", "0-0", "-L", url},
        capture_stdout = true,
        capture_stderr = false
    }, function(success, result, error)
        if success and result and result.status == 0 and result.stdout and result.stdout ~= "" then
            resolving = false
            parse_and_set(result.stdout)
        else
            -- fallback if curl fails or is missing
            if is_windows then
                try_powershell()
            else
                try_wget()
            end
        end
    end)
end

mp.add_hook("on_load", 50, function()
    local path = mp.get_property("path")
    if is_network_path(path) then
        resolve_title(path)
    else
        -- For offline files, ensure media-title mimics the filename
        -- to prevent messy internal MKV metadata from showing up in the OSC
        local filename = mp.get_property("filename")
        if filename then
            mp.set_property("force-media-title", filename)
        end
    end
end)
