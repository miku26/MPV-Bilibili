VERSION = "2.1.0"

mp.commandv('script-message', 'uosc_danmaku-version', VERSION)

local msg = require('mp.msg')
local utils = require("mp.utils")

require("modules/options")
require("modules/utils")
require("modules/parse")
require('modules/render')
require('modules/menu')

_G.danmaku_options = options

SAVED_PROPS_PATH = mp.command_native({"expand-path", "~~/saved-props.json"})

function load_style_settings()
    local data = {}
    local saved_json = read_file(SAVED_PROPS_PATH)
    if saved_json then
        data = utils.parse_json(saved_json) or {}
    end

    local style = data.danmaku_style
    local need_write = false

    -- 如果没有样式，创建默认配置
    if not style or not next(style) then
        style = {
            fontsize = tonumber(options.fontsize) or 38,
            scrolltime = tonumber(options.scrolltime) or 15,
            opacity = tonumber(options.opacity) or 0.7,
            displayarea = tonumber(options.displayarea) or 0.6,
            bold = options.bold == "true" or options.bold == true,
            stroke_type = 'heavy',
            fontname = options.fontname or '微软雅黑'
        }
        need_write = true
    else
        -- 补全可能缺失的字段（保证结构完整）
        local defaults = {
            fontsize = 38,
            scrolltime = 15,
            opacity = 0.7,
            displayarea = 0.6,
            bold = true,
            stroke_type = 'heavy',
            fontname = '微软雅黑'
        }
        for k, default_val in pairs(defaults) do
            if style[k] == nil then
                style[k] = default_val
                need_write = true
            end
        end
    end

    -- 应用样式到 options
    options.fontsize = tostring(style.fontsize)
    options.scrolltime = tostring(style.scrolltime)
    options.opacity = tostring(style.opacity)
    options.displayarea = tostring(style.displayarea)
    options.bold = (style.bold == true or style.bold == "true")
    options.fontname = style.fontname

    if style.stroke_type == 'heavy' then
        options.outline = 1.0; options.shadow = 0
    elseif style.stroke_type == 'outline' then
        options.outline = 0.3; options.shadow = 0
    elseif style.stroke_type == 'shadow' then
        options.outline = 0; options.shadow = 1.2
    else
        options.outline = 1.0; options.shadow = 0
    end

    -- 如果有更新（首次创建或补全），写回文件
    if need_write then
        data.danmaku_style = style
        write_json_file(SAVED_PROPS_PATH, data)
        msg.info("弹幕样式默认配置已写入 saved-props.json")
    end

    -- 通知 uosc 样式更新
    for _, k in ipairs({"fontsize", "scrolltime", "opacity", "displayarea", "bold", "fontname"}) do
        mp.commandv("script-message-to", "uosc", "danmaku-style-update", k, tostring(options[k]))
    end
end

function save_style_settings()
msg.info("save_style_settings called")
    local current_stroke = 'heavy'
    if options.outline == 0.3 and options.shadow == 0 then current_stroke = 'outline'
    elseif options.outline == 0 and options.shadow == 1.2 then current_stroke = 'shadow'
    end

    local style = {
        fontsize = tonumber(options.fontsize) or 38,
        scrolltime = tonumber(options.scrolltime) or 15,
        opacity = tonumber(options.opacity) or 0.7,
        displayarea = tonumber(options.displayarea) or 0.6,
        bold = options.bold == "true" or options.bold == true,
        fontname = options.fontname,
        stroke_type = current_stroke,
    }

    -- 读取现有 saved-props.json，保留其他字段，更新 danmaku_style
    local data = {}
    local saved_json = read_file(SAVED_PROPS_PATH)
    if saved_json then
        data = utils.parse_json(saved_json) or {}
    end
    data.danmaku_style = style
    write_json_file(SAVED_PROPS_PATH, data)
end

load_style_settings()

DANMAKU_PATH = os.getenv("TEMP") or "/tmp/"
HISTORY_PATH = mp.command_native({"expand-path", options.history_path})
PID = utils.getpid()
DANMAKU = {sources = {}, count = 1}
ENABLED, COMMENTS, DELAY = false, nil, 0
DELAY_PROPERTY = string.format("user-data/%s/danmaku-delay", mp.get_script_name())
mp.set_property_native(DELAY_PROPERTY, 0)
HAS_DANMAKU = string.format("user-data/%s/has-danmaku", mp.get_script_name())
mp.set_property_bool(HAS_DANMAKU, false)

PLATFORM = (function()
    local platform = mp.get_property_native("platform")
    if platform then
        if itable_index_of({ "windows", "darwin" }, platform) then
            return platform
        end
    else
        if os.getenv("windir") ~= nil then return "windows" end
        local homedir = os.getenv("HOME")
        if homedir ~= nil and string.sub(homedir, 1, 6) == "/Users" then return "darwin" end
    end
    return "linux"
end)()

local rebuild_convert_timer = nil

function get_danmaku_visibility()
    local file = io.open(SAVED_PROPS_PATH, "r")
    local data = {}
    if file then
        local content = file:read("*all")
        file:close()
        data = utils.parse_json(content) or {}
    end

    if data.show_danmaku == nil then
        data.show_danmaku = true
        local f = io.open(SAVED_PROPS_PATH, "w")
        if f then f:write(utils.format_json(data)); f:close() end
        return true
    end
    return data.show_danmaku == true
end

function set_danmaku_visibility(flag)
    local file = io.open(SAVED_PROPS_PATH, "r")
    local data = {}
    if file then
        local content = file:read("*all")
        file:close()
        data = utils.parse_json(content) or {}
    end

    data.show_danmaku = flag == true
    local f = io.open(SAVED_PROPS_PATH, "w")
    if f then f:write(utils.format_json(data)); f:close() end

    if flag then
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "on")
    else
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "off")
    end
end

function set_danmaku_button()
    if get_danmaku_visibility() then
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "on")
    end
end

function show_loaded(init)
    show_message("弹幕加载成功，共计" .. #COMMENTS .. "条弹幕", 3)
    if init then msg.info("弹幕加载成功，共计" .. #COMMENTS .. "条弹幕") end
end

function get_delay_for_time(delay_segments, time)
    if not delay_segments or #delay_segments == 0 then return 0 end
    local segs = {}
    for i = 1, #delay_segments do segs[i] = delay_segments[i] end
    table.sort(segs, function(a, b) return a.start < b.start end)
    local applied_delay = 0
    for i = 1, #segs do
        local seg = segs[i]
        local delay = tonumber(seg.delay)
        if time >= seg.start and delay then
            applied_delay = applied_delay + delay
        else
            break
        end
    end
    return applied_delay
end

local function merge_delay_segments(segments)
    if not segments or #segments == 0 then return {} end
    local NEAREST_THRESHOLD = 10
    local MERGE_THRESHOLD = 30
    local EPSILON = 1e-6
    table.sort(segments, function(a, b) return a.start < b.start end)
    local partially_merged = {}
    local i = 1
    while i <= #segments do
        local cur = segments[i]
        local next_seg = segments[i + 1]
        if next_seg and (next_seg.start - cur.start) <= NEAREST_THRESHOLD then
            local combined_delay = tonumber(cur.delay) + tonumber(next_seg.delay)
            if math.abs(combined_delay) > EPSILON then
                table.insert(partially_merged, {start = cur.start, delay = combined_delay})
            end
            i = i + 2
        else
            if math.abs(tonumber(cur.delay)) > EPSILON then
                table.insert(partially_merged, cur)
            end
            i = i + 1
        end
    end
    local merged = {}
    for _, seg in ipairs(partially_merged) do
        local merged_flag = false
        for idx, m in ipairs(merged) do
            if math.abs(seg.start - m.start) <= MERGE_THRESHOLD then
                m.delay = tonumber(m.delay) + tonumber(seg.delay)
                if math.abs(m.delay) <= EPSILON then table.remove(merged, idx) end
                merged_flag = true
                break
            end
        end
        if not merged_flag then
            if math.abs(tonumber(seg.delay)) > EPSILON then
                table.insert(merged, {start = seg.start, delay = seg.delay})
            end
        end
    end
    table.sort(merged, function(a, b) return a.start < b.start end)
    return merged
end

function parse_delay_input(text)
    if not text then return nil end
    local s = tostring(text):gsub("%s+", "")
    if s == "" then return nil end
    local m, sec = string.match(s, "^(%-?%d+)m(%d+)s$")
    if m and sec then
        m = tonumber(m); sec = tonumber(sec)
        if not m or not sec then return nil end
        if m < 0 then sec = -sec end
        return m * 60 + sec
    end
    local n = tonumber(s)
    if n ~= nil then return n end
    return nil
end

function add_source_to_history(add_url, add_source)
    local history_json = read_file(HISTORY_PATH)
    local path = mp.get_property("path")
    if is_protocol(path) then path = remove_query(path) end
    local history = {}
    if history_json then history = utils.parse_json(history_json) or {} end
    history[path] = history[path] or {}
    history[path]["sources"] = history[path]["sources"] or {}
    history[path]["sources"][add_url] = history[path]["sources"][add_url] or {}
    local record = history[path]["sources"][add_url]
    record.from = add_source.from or "user_custom"
    record.blocked = add_source.blocked or false
    local delay_segments = shallow_copy(add_source.delay_segments or {})
    if #delay_segments > 0 then
        record.delay_segments = merge_delay_segments(delay_segments)
        if #record.delay_segments == 0 then record.delay_segments = nil end
    else
        record.delay_segments = nil
    end
    record.delay = nil
    write_json_file(HISTORY_PATH, history)
end

function remove_source_from_history(rm_source)
    local history_json = read_file(HISTORY_PATH)
    local path = mp.get_property("path")
    if is_protocol(path) then path = remove_query(path) end
    if history_json then
        local history = utils.parse_json(history_json) or {}
        if history[path] ~= nil and history[path]["sources"] ~= nil then
            for source in pairs(history[path]["sources"]) do
                if source == rm_source then
                    history[path]["sources"][source] = nil
                    break
                end
            end
        end
        write_json_file(HISTORY_PATH, history)
    end
end

local function set_danmaku_delay(dly, time, specific_source)
    if specific_source then
        local source = DANMAKU.sources[specific_source]
        if source and source.data and not source.blocked then
            source.delay_segments = source.delay_segments or {}
            if dly == 0 then
                source.delay_segments = {}
            elseif time then
                table.insert(source.delay_segments, {start = time, delay = dly})
            else
                table.insert(source.delay_segments, {start = 0, delay = dly})
            end
            source.delay = nil
            source.delay_segments = merge_delay_segments(source.delay_segments)
            add_source_to_history(specific_source, source)
        end
    else
        for url, source in pairs(DANMAKU.sources) do
            if source.data and not source.blocked then
                source.delay_segments = source.delay_segments or {}
                if dly == 0 then
                    source.delay_segments = {}
                elseif time then
                    table.insert(source.delay_segments, {start = time, delay = dly})
                else
                    table.insert(source.delay_segments, {start = 0, delay = dly})
                end
                source.delay = nil
                source.delay_segments = merge_delay_segments(source.delay_segments)
                add_source_to_history(url, source)
            end
        end
    end
    if dly == 0 then DELAY = 0 else DELAY = DELAY + dly end
    if ENABLED and COMMENTS ~= nil then render() end
    if rebuild_convert_timer then rebuild_convert_timer:kill(); rebuild_convert_timer = nil end
    rebuild_convert_timer = mp.add_timeout(0.1, function()
        if convert_danmaku_to_ass_events then convert_danmaku_to_ass_events(true) end
        render()
        rebuild_convert_timer = nil
    end)
    show_message('设置弹幕延迟: ' .. string.format("%.1f", DELAY + 1e-10) .. ' s')
    mp.set_property_native(DELAY_PROPERTY, DELAY)
end

function load_danmaku(from_menu, no_osd)
    if not ENABLED then return end
    convert_danmaku_to_ass_events()
    render_danmaku(from_menu, no_osd)
end

function add_danmaku_source_local(query, from_menu)
    local path = normalize(query)
    if not file_exists(path) then
        msg.warn("无效的文件路径")
        return
    end
    if not (string.match(path, "%.xml$") or string.match(path, "%.json$")) then
        msg.warn("仅支持弹幕文件")
        return
    end
    local danmaku_list = parse_danmaku_file(path)
    if danmaku_list then
        DANMAKU.sources[query] = {from = "user_local", data = danmaku_list}
        set_danmaku_button()
        load_danmaku(from_menu)
    end
end

function init(path)
    if not path then return end
    if is_protocol(path) then
        msg.info("网络视频不支持自动加载本地弹幕")
        return
    end
    local dir = get_parent_directory(path)
    local filename = mp.get_property('filename/no-ext')
    if not dir or not filename then
        msg.verbose("无法获取目录或文件名")
        return
    end

    -- 规范化目录路径
    dir = normalize(dir)
    msg.verbose("视频目录: " .. dir)

    -- 1. 先尝试视频所在目录
    if try_load_from_directory(dir, filename) then
        return
    end

    -- 2. 扫描该目录下的所有子目录（使用 "dirs"）
    local subdirs, err = utils.readdir(dir, "dirs")
    if not subdirs then
        msg.verbose("无法读取子目录列表: " .. dir .. "，错误: " .. tostring(err))
        return
    end

    -- 过滤掉隐藏目录（以 . 开头）和系统目录，并按名称排序
    local filtered = {}
    for _, sub in ipairs(subdirs) do
        if sub ~= "." and sub ~= ".." and sub:sub(1,1) ~= "." then
            table.insert(filtered, sub)
        end
    end
    table.sort(filtered)

    -- 可选：优先处理常见弹幕文件夹，如 danmu, sub, Subs, subtitles
    local priority = { "danmu", "sub", "Subs", "subtitles" }
    table.sort(filtered, function(a, b)
        local pa = itable_index_of(priority, a) or 999
        local pb = itable_index_of(priority, b) or 999
        if pa ~= pb then return pa < pb end
        return a < b
    end)

    msg.verbose("将要搜索的子目录: " .. table.concat(filtered, ", "))

    for _, sub in ipairs(filtered) do
        local sub_dir = utils.join_path(dir, sub)
        sub_dir = normalize(sub_dir)
        msg.verbose("搜索子目录: " .. sub_dir)
        if try_load_from_directory(sub_dir, filename) then
            return
        end
    end

    msg.verbose("未在任何子目录中找到匹配的弹幕文件")
end

function try_load_from_directory(search_dir, filename)
    -- 确保目录路径规范化
    search_dir = normalize(search_dir)
    msg.verbose("在目录中搜索: " .. search_dir)

    -- 精确匹配：<视频名>.xml / .json
    local danmaku_xml = utils.join_path(search_dir, filename .. ".xml")
    if file_exists(danmaku_xml) then
        msg.info("精确匹配弹幕: " .. danmaku_xml)
        add_danmaku_source_local(danmaku_xml, true)
        return true
    end
    local danmaku_json = utils.join_path(search_dir, filename .. ".json")
    if file_exists(danmaku_json) then
        msg.info("精确匹配弹幕: " .. danmaku_json)
        add_danmaku_source_local(danmaku_json, true)
        return true
    end

    -- 模糊匹配：双向包含 + 匹配度排序
    local items, err = utils.readdir(search_dir, "files")
    if not items then
        msg.verbose("无法读取目录文件列表: " .. search_dir .. "，错误: " .. tostring(err))
        return false
    end

    local candidates = {}
    local base_lower = filename:lower()
    for _, item in ipairs(items) do
        -- 跳过隐藏文件
        if item:sub(1,1) ~= "." then
            local ext = item:match("%.([^%.]+)$")
            if ext and (ext:lower() == "xml" or ext:lower() == "json") then
                local name_no_ext = item:sub(1, #item - #ext - 1)
                local name_lower = name_no_ext:lower()
                -- 双向包含检查
                if base_lower:find(name_lower, 1, true) or name_lower:find(base_lower, 1, true) then
                    local match_len = math.min(#base_lower, #name_lower)
                    if base_lower:find(name_lower, 1, true) then
                        match_len = #name_lower
                    elseif name_lower:find(base_lower, 1, true) then
                        match_len = #base_lower
                    end
                    table.insert(candidates, {
                        name = item,
                        path = utils.join_path(search_dir, item),
                        match_len = match_len
                    })
                end
            end
        end
    end

    if #candidates > 0 then
        -- 按匹配长度降序，相同则按文件名升序
        table.sort(candidates, function(a, b)
            if a.match_len ~= b.match_len then
                return a.match_len > b.match_len
            else
                return a.name < b.name
            end
        end)
        local chosen = candidates[1]
        msg.info("模糊匹配弹幕文件: " .. chosen.name .. " (匹配度: " .. chosen.match_len .. ") 于目录 " .. search_dir)
        add_danmaku_source_local(chosen.path, true)
        return true
    end

    return false
end

-- 初始化时强制同步 UI 开关
local function sync_ui_state()
    if get_danmaku_visibility() then
        ENABLED = true
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "on")
    else
        ENABLED = false
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "off")
    end
end

-- 在加载文件时，如果状态为 false，必须彻底重置 ENABLED 和渲染
mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    local video = mp.get_property_native("current-tracks/video")
    local fps = mp.get_property_number("container-fps", 0)
    local duration = mp.get_property_number("duration", 0)
    if not video or video["image"] or video["albumart"] or fps < 23 or duration < 60 then
        return
    end

    if not get_danmaku_visibility() then
        ENABLED = false
        hide_danmaku_func()
        return
    end

    if options.autoload_local_danmaku then
        ENABLED = true
        init(path)
    end
end)

-- 立刻执行一次初始化同步
sync_ui_state()

mp.register_script_message("danmaku-delay", function(...)
    local commands = {...}
    local delay_str, time_str = commands[1], commands[2]
    local source_arg = commands[3]
    local dly = parse_delay_input(delay_str)
    local time = time_str and tonumber(time_str)
    if type(dly) ~= "number" then
        show_message("参数错误：缺少有效的延迟秒数", 3)
        return
    end
    if source_arg and source_arg ~= "nil" then
        set_danmaku_delay(dly, time, source_arg)
    else
        set_danmaku_delay(dly, time)
    end
end)

mp.register_script_message("show_danmaku_keyboard", function()
    ENABLED = not ENABLED
    if ENABLED then
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "on")
        if COMMENTS == nil then
            show_message("加载弹幕初始化...", 3)
            set_danmaku_visibility(true)
            local path = mp.get_property("path")
            init(path)
        else
            show_loaded()
            show_danmaku_func()
        end
    else
        show_message("关闭弹幕", 2)
        mp.commandv("script-message-to", "uosc", "set", "show_danmaku", "off")
        hide_danmaku_func()
        set_danmaku_visibility(false)
    end
end)

mp.register_script_message("get-style-values", function()
    for _, key in ipairs({"fontsize", "scrolltime", "opacity", "displayarea", "bold"}) do
        local val = options[key]
        if val ~= nil then
            mp.commandv("script-message-to", "uosc", "danmaku-style-update", key, tostring(val))
        end
    end
end)

mp.register_script_message("setup-danmaku-style", function(key, value)
    if not key then return end
    local changed = false

    if key == "stroke_type" then
        local old_stroke = options.stroke_type
        if value == "heavy" then
            options.outline = 1.0; options.shadow = 0
        elseif value == "outline" then
            options.outline = 0.3; options.shadow = 0
        elseif value == "shadow" then
            options.outline = 0; options.shadow = 1.2
        else
            return
        end
        options.stroke_type = value
        if old_stroke ~= value then changed = true end

    elseif key == "bold" then
        local new_val = (value == "true" or value == true)
        if options.bold ~= new_val then
            options.bold = new_val
            changed = true
        end

    elseif key == "fontsize" then
        local num = tonumber(value)
        if num and num >= 10 and num <= 100 then
            local new_val = math.floor(num)
            local cur_val = tonumber(options.fontsize)
            if cur_val == nil or cur_val ~= new_val then
                options.fontsize = tostring(new_val)
                changed = true
            end
        end

    elseif key == "scrolltime" then
        local num = tonumber(value)
        if num and num >= 1 and num <= 60 then
            local new_val = math.floor(num)
            local cur_val = tonumber(options.scrolltime)
            if cur_val == nil or cur_val ~= new_val then
                options.scrolltime = tostring(new_val)
                changed = true
            end
        end

    elseif key == "opacity" then
        local num = tonumber(value)
        if num and num >= 0 and num <= 1 then
            local new_val = num
            local cur_val = tonumber(options.opacity)
            if cur_val == nil or math.abs(cur_val - new_val) > 1e-9 then
                options.opacity = tostring(new_val)
                changed = true
            end
        end

    elseif key == "displayarea" then
        local num = tonumber(value)
        if num and num >= 0.1 and num <= 1 then
            local new_val = num
            local cur_val = tonumber(options.displayarea)
            if cur_val == nil or math.abs(cur_val - new_val) > 1e-9 then
                options.displayarea = tostring(new_val)
                changed = true
            end
        end

    elseif key == "fontname" then
        if options.fontname ~= value then
            options.fontname = value
            changed = true
        end
    else
        return
    end

msg.info("setup-danmaku-style: key=" .. key .. ", value=" .. tostring(value) .. ", changed=" .. tostring(changed))

    if changed then
        save_style_settings()
        if ENABLED and COMMENTS then
            convert_danmaku_to_ass_events(true)
            render()
        end
        for _, k in ipairs({"fontsize", "scrolltime", "opacity", "displayarea", "bold", "fontname"}) do
            mp.commandv("script-message-to", "uosc", "danmaku-style-update", k, tostring(options[k]))
        end
    end
end)

mp.register_script_message('load-danmaku-file', function(filepath)
    if not filepath or filepath == '' then
        msg.warn('无效的弹幕文件路径')
        return
    end
    add_danmaku_source_local(filepath, true)
end)