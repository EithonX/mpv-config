local mp = require "mp"

mp.register_script_message("menu-guard-acquire", function(owner)
    return owner
end)

mp.register_script_message("menu-guard-release", function(owner)
    return owner
end)
