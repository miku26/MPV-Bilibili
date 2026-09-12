local msg = require('mp.msg')

mp.register_script_message("set", function(prop, value)
    if prop ~= "show_danmaku" then return end
    if value == nil then
        msg.warn("set: value is nil, ignoring")
        return
    end
    if value ~= "on" and value ~= "off" then
        msg.warn("set: invalid value: " .. tostring(value))
        return
    end
    set_danmaku_enabled(value == "on")
end)