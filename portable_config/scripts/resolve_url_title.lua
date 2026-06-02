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

local function resolve_title(url)
    if resolving then return end
    resolving = true

    -- We use curl to fetch just 1 byte to get the headers
    local args = {
        "curl.exe",
        "-s",        -- silent
        "-D", "-",   -- dump headers to stdout
        "-o", "NUL", -- discard output
        "-r", "0-0", -- only 1 byte
        "-L",        -- follow redirects
        url
    }

    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = false
    }, function(success, result, error)
        resolving = false
        if not success or not result.stdout then
            return
        end

        local filename = extract_filename(result.stdout)
        if filename then
            set_title(filename)
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
