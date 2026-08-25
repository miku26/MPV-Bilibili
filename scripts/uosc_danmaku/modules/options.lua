local opt = require("mp.options")

-- 选项
options = {
    auto_load = true,
    autoload_local_danmaku = true,
    autoload_for_url = true,
    save_danmaku = false,
    vf_fps = true,
    -- 设置要使用的 fps 滤镜参数
    fps = "120/1.001",
    -- 指定合并重复弹幕的时间间隔的容差值，单位为秒。默认值: -1，表示禁用
    merge_tolerance = -1,
    -- 指定弹幕关联历史记录文件的路径，支持绝对路径和相对路径
    --show_danmaku_keyboard_key = "d",
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
    --指定弹幕屏蔽词文件路径(black.txt)，支持绝对路径和相对路径。文件内容以换行分隔
    --支持 lua 的正则表达式写法
    blacklist_path = "",
    --指定脚本相关消息显示的消息的对齐方式
    message_anlignment = 7,
    --指定脚本相关消息显示的消息的x轴坐标
    message_x = 30,
    --指定脚本相关消息显示的消息的y轴坐标
    message_y = 30,
    -- 自定义标题解析中的额外替换规则，内容格式为 JSON 字符串，替换模式为 lua 的 string.gsub 函数
    --! 注意：由于 mpv 的 lua 版本限制，自定义规则只支持形如 %n 的捕获组写法，即示例用法，不支持直接替换字符的写法
    title_replace = [[
       [{ 
           "rules": [{ "^〔(.-)〕": "%1"},{ "^.*《(.-)》": "%1" }],
       }]
    ]],
    -- 指定哈希匹配中需忽略的共享盘（挂载盘）的路径/目录。支持绝对路径和相对路径，多个路径用逗号分隔
    -- 示例：["X:", "Z:", "F:/Download/", "Download"]
    excluded_path = [[
        []
    ]],
}

opt.read_options(options, mp.get_script_name(), function() end)
