local opt = require("mp.options")

options = {
    autoload_local_danmaku = true,
    vf_fps = false,
    fps = "120/1.001",
    merge_tolerance = -1,
    chConvert = 0,
    scrolltime = 15,
    fixtime = 5,
    fontname = "微软雅黑",
    fontsize = 36,
    shadow = 0,
    bold = true,
    opacity = 0.8,
    displayarea = 0.5,
    outline = 1.0,
    max_screen_danmaku = 0,
    blacklist_path = "",
    message_anlignment = 7,
    message_x = 30,
    message_y = 30,
    history_path = "~~/danmaku_history.json",

    layout_overflow = 0.75,
}

opt.read_options(options, mp.get_script_name(), function() end)