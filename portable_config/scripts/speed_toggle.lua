-- Speed toggle — state and logic managed by persistent_prefs.lua
-- This script only provides the key binding for input.conf compatibility.
local mp = require "mp"

mp.add_key_binding(nil, "speed-toggle", function()
    mp.commandv("script-message", "toggle-speed")
end)
