VERSION = "2.1.0"

mp.commandv('script-message', 'uosc_danmaku-version', VERSION)

local msg = require('mp.msg')
local utils = require("mp.utils")

require("modules/options")
require("modules/utils")
require("modules/parse")
require('modules/render')
require('modules/menu')

SAVED_PROPS_PATH = mp.command_native({"expand-path", "~~/saved-props.json"})

-- ============================================================
-- saved-props.json 统一读写（带缓存）
-- ============================================================
local saved_props_cache = nil

local function read_saved_props()
    if not saved_props_cache then
        local json = read_file(SAVED_PROPS_PATH)
        saved_props_cache = json and utils.parse_json(json) or {}
    end
    return saved_props_cache
end

local function write_saved_props(data)
    saved_props_cache = data
    write_json_file(SAVED_PROPS_PATH, data)
end

-- ============================================================
-- 样式广播 + 描边映射
-- ============================================================
local STYLE_KEYS = {"fontsize", "scrolltime", "opacity", "displayarea", "bold", "fontname", "stroke_type"}

local function emit_style_update()
    for _, k in ipairs(STYLE_KEYS) do
        local val = options[k]
        if val ~= nil then
            mp.commandv("script-message-to", "uosc", "danmaku-style-update", k, tostring(val))
        end
    end
end

local function get_stroke_values(stroke_type)
    if stroke_type == 'outline' then
        return 0.3, 0
    elseif stroke_type == 'shadow' then
        return 0, 1.2
    end
    return 1.0, 0
end


-- ============================================================
-- 样式加载 / 保存
-- ============================================================
local STYLE_DEFAULTS = {
    fontsize     = 36,
    scrolltime   = 15,
    opacity      = 0.7,
    displayarea  = 0.6,
    bold         = true,
    stroke_type  = 'heavy',
    fontname     = '微软雅黑',
}

local function load_style_settings()
    local data = read_saved_props()
    local style = data.danmaku_style or {}
    local need_write = false

    for k, v in pairs(STYLE_DEFAULTS) do
        if style[k] == nil then
            style[k] = v
            need_write = true
        end
    end

    options.fontsize    = tostring(style.fontsize)
    options.scrolltime  = tostring(style.scrolltime)
    options.opacity     = tostring(style.opacity)
    options.displayarea = tostring(style.displayarea)
    options.bold        = (style.bold == true or style.bold == "true")
    options.fontname    = style.fontname
    options.stroke_type = style.stroke_type or 'heavy'

    local outline, shadow = get_stroke_values(style.stroke_type)
    options.outline = outline
    options.shadow  = shadow

    if need_write then
        data.danmaku_style = style
        write_saved_props(data)
        msg.info("弹幕样式默认配置已写入 saved-props.json")
    end

    emit_style_update()
end

local function save_style_settings()
    local current_stroke = 'heavy'
    if options.outline == 0.3 and options.shadow == 0 then
        current_stroke = 'outline'
    elseif options.outline == 0 and options.shadow == 1.2 then
        current_stroke = 'shadow'
    end

    local data = read_saved_props()
    data.danmaku_style = {
        fontsize     = tonumber(options.fontsize)    or STYLE_DEFAULTS.fontsize,
        scrolltime   = tonumber(options.scrolltime)  or STYLE_DEFAULTS.scrolltime,
        opacity      = tonumber(options.opacity)     or STYLE_DEFAULTS.opacity,
        displayarea  = tonumber(options.displayarea) or STYLE_DEFAULTS.displayarea,
        bold         = options.bold == "true" or options.bold == true,
        fontname     = options.fontname,
        stroke_type  = current_stroke,
    }
    write_saved_props(data)
end

load_style_settings()

-- ============================================================
-- 弹幕状态
-- ============================================================
HISTORY_PATH = mp.command_native({"expand-path", options.history_path})
DANMAKU = {sources = {}, count = 1}
ENABLED, COMMENTS, DELAY = false, nil, 0
DELAY_PROPERTY = string.format("user-data/%s/danmaku-delay", mp.get_script_name())
mp.set_property_native(DELAY_PROPERTY, 0)
HAS_DANMAKU = string.format("user-data/%s/has-danmaku", mp.get_script_name())
mp.set_property_bool(HAS_DANMAKU, false)

local rebuild_convert_timer = nil

local _visibility_cache = nil

function get_danmaku_visibility()
    if _visibility_cache ~= nil then return _visibility_cache end
    local data = read_saved_props()
    if data.show_danmaku == nil then
        data.show_danmaku = true
        write_saved_props(data)
    end
    _visibility_cache = data.show_danmaku == true
    return _visibility_cache
end

function set_danmaku_visibility(flag)
    flag = flag == true
    if _visibility_cache == flag then return end
    _visibility_cache = flag

    local data = read_saved_props()
    data.show_danmaku = flag
    write_saved_props(data)

    local val = flag and "on" or "off"
    mp.command(string.format("script-message-to uosc set show_danmaku %s", val))
end

function set_danmaku_enabled(flag, silent)
    flag = flag == true
    ENABLED = flag

    if flag then
        set_danmaku_visibility(true)
        if COMMENTS == nil then
            init(mp.get_property("path"))
        else
            if not silent then show_loaded() end
            show_danmaku_func()
        end
    else
        if not silent then show_message("关闭弹幕", 2) end
        hide_danmaku_func()
        set_danmaku_visibility(false)
    end
end

function show_loaded(init)
    if COMMENTS == nil then return end
    show_message("弹幕加载成功，共计" .. #COMMENTS .. "条弹幕", 3)
    if init then msg.info("弹幕加载成功，共计" .. #COMMENTS .. "条弹幕") end
end

-- ============================================================
-- 延迟分段合并
-- ============================================================
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

-- ============================================================
-- 历史记录
-- ============================================================
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

-- ============================================================
-- 延迟调整
-- ============================================================
local function set_danmaku_delay(dly, time, specific_source)
    local sources
    if specific_source then
        sources = { [specific_source] = DANMAKU.sources[specific_source] }
    else
        sources = DANMAKU.sources
    end

    for url, source in pairs(sources) do
        if source and source.data and not source.blocked then
            local segs
            if dly == 0 then
                segs = {}
            else
                segs = source.delay_segments or {}
                table.insert(segs, { start = time or 0, delay = dly })
            end
            source.delay = nil
            source.delay_segments = merge_delay_segments(segs)
            add_source_to_history(url, source)
        end
    end

    if dly == 0 then DELAY = 0 else DELAY = DELAY + dly end
    if ENABLED and COMMENTS ~= nil then render() end
    if rebuild_convert_timer then
        rebuild_convert_timer:kill()
        rebuild_convert_timer = nil
    end
    rebuild_convert_timer = mp.add_timeout(0.1, function()
        if convert_danmaku_to_ass_events then convert_danmaku_to_ass_events(true) end
        render()
        rebuild_convert_timer = nil
    end)
    show_message('设置弹幕延迟: ' .. string.format("%.1f", DELAY + 1e-10) .. ' s')
    mp.set_property_native(DELAY_PROPERTY, DELAY)
end

-- ============================================================
-- 加载本地弹幕
-- ============================================================
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
        if get_danmaku_visibility() then
            mp.command("script-message-to uosc set show_danmaku on")
        end
        convert_danmaku_to_ass_events()
        render_danmaku(from_menu, false)
    end
end

-- ============================================================
-- 自动匹配加载
-- ============================================================
function try_load_from_directory(search_dir, filename)
    search_dir = normalize(search_dir)
    msg.verbose("在目录中搜索: " .. search_dir)

    -- ① 精确匹配：同目录下 视频名.xml / 视频名.json
    for _, ext in ipairs({".xml", ".json"}) do
        local exact_path = utils.join_path(search_dir, filename .. ext)
        if file_exists(exact_path) then
            msg.info("精确匹配弹幕: " .. exact_path)
            add_danmaku_source_local(exact_path, true)
            return true
        end
    end

    -- ② 模糊匹配
    local items, err = utils.readdir(search_dir, "files")
    if not items then
        msg.verbose("无法读取目录文件列表: " .. search_dir .. "，错误: " .. tostring(err))
        return false
    end

    local candidates = {}
    local base_lower = filename:lower()
    for _, item in ipairs(items) do
        if item:sub(1, 1) ~= "." then
            local name_no_ext, ext = item:match("^(.+)%.([^%.]+)$")
            if ext then
                ext = ext:lower()
                if ext == "xml" or ext == "json" then
                    local name_lower = name_no_ext:lower()
                    local found_name = base_lower:find(name_lower, 1, true)
                    local found_base = name_lower:find(base_lower, 1, true)
                    if found_name or found_base then
                        local match_len
                        if found_name and found_base then
                            match_len = math.min(#name_lower, #base_lower)
                        elseif found_name then
                            match_len = #name_lower
                        else
                            match_len = #base_lower
                        end

                        table.insert(candidates, {
                            name = item,
                            path = utils.join_path(search_dir, item),
                            match_len = match_len,
                        })
                    end
                end
            end
        end
    end

    if #candidates > 0 then
        table.sort(candidates, function(a, b)
            if a.match_len ~= b.match_len then return a.match_len > b.match_len end
            return a.name < b.name
        end)
        local chosen = candidates[1]
        msg.info("模糊匹配弹幕文件: " .. chosen.name .. " (匹配度: " .. chosen.match_len .. ") 于目录 " .. search_dir)
        add_danmaku_source_local(chosen.path, true)
        return true
    end

    return false
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

    dir = normalize(dir)
    msg.verbose("视频目录: " .. dir)

    if try_load_from_directory(dir, filename) then
        return
    end

    -- 遍历子目录
    local subdirs, err = utils.readdir(dir, "dirs")
    if not subdirs then
        msg.verbose("无法读取子目录列表: " .. dir .. "，错误: " .. tostring(err))
        return
    end

    local filtered = {}
    for _, sub in ipairs(subdirs) do
        if not sub:match("^%.%.?$") and sub:sub(1, 1) ~= "." then
            table.insert(filtered, sub)
        end
    end

    local priority = { "danmu", "sub", "Subs", "subtitles" }
    table.sort(filtered, function(a, b)
        local pa = itable_index_of(priority, a) or 999
        local pb = itable_index_of(priority, b) or 999
        if pa ~= pb then return pa < pb end
        return a < b
    end)

    msg.verbose("将要搜索的子目录: " .. table.concat(filtered, ", "))

    for _, sub in ipairs(filtered) do
        local sub_dir = normalize(utils.join_path(dir, sub))
        msg.verbose("搜索子目录: " .. sub_dir)
        if try_load_from_directory(sub_dir, filename) then
            return
        end
    end

    msg.verbose("未在任何子目录中找到匹配的弹幕文件")
end

-- ============================================================
-- UI 同步
-- ============================================================
local function sync_ui_state()
    if get_danmaku_visibility() then
        ENABLED = true
        mp.command("script-message-to uosc set show_danmaku on")
    else
        ENABLED = false
        mp.command("script-message-to uosc set show_danmaku off")
    end
end

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    local video = mp.get_property_native("current-tracks/video")
    local fps = mp.get_property_number("container-fps", 0)
    local duration = mp.get_property_number("duration", 0)
    if not video or video["image"] or video["albumart"] or fps < 23 or duration < 60 then
        return
    end

    if not get_danmaku_visibility() then
        hide_danmaku_func()
        return
    end

    if options.autoload_local_danmaku then
        ENABLED = true
        init(path)
    end
end)

sync_ui_state()

-- ============================================================
-- 消息处理
-- ============================================================
mp.register_script_message("show_danmaku_keyboard", function()
    set_danmaku_enabled(not ENABLED)
end)

mp.register_script_message("danmaku-delay", function(delay_str, time_str, source_arg)
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

mp.register_script_message("get-style-values", function()
    emit_style_update()
end)

-- ============================================================
-- 表驱动的 setup-danmaku-style
-- ============================================================
local NUMERIC_SPECS = {
    fontsize    = { min = 10,  max = 100, floor = true },
    scrolltime  = { min = 1,   max = 60,  floor = true },
    opacity     = { min = 0,   max = 1,   eps   = 1e-9 },
    displayarea = { min = 0.1, max = 1,   eps   = 1e-9 },
}

mp.register_script_message("setup-danmaku-style", function(key, value)
    if not key then return end
    local changed = false

    if key == "stroke_type" then
        local old_stroke = options.stroke_type
        local outline, shadow = get_stroke_values(value)
        options.outline = outline
        options.shadow = shadow
        options.stroke_type = value
        changed = old_stroke ~= value

    elseif key == "bold" then
        local new_val = (value == "true" or value == true)
        if options.bold ~= new_val then
            options.bold = new_val
            changed = true
        end

    elseif key == "fontname" then
        if options.fontname ~= value then
            options.fontname = value
            changed = true
        end

    elseif NUMERIC_SPECS[key] then
        local spec = NUMERIC_SPECS[key]
        local num = tonumber(value)
        if num and num >= spec.min and num <= spec.max then
            if spec.floor then num = math.floor(num) end
            local cur = tonumber(options[key])
            local different
            if spec.eps then
                different = (cur == nil) or (math.abs(cur - num) > spec.eps)
            else
                different = (cur == nil) or (cur ~= num)
            end
            if different then
                options[key] = tostring(num)
                changed = true
            end
        end

    else
        return
    end

    if changed then
        save_style_settings()
        if ENABLED and COMMENTS then
            convert_danmaku_to_ass_events(true)
            render()
        end
        emit_style_update()
    end
end)

mp.register_script_message('load-danmaku-file', function(filepath)
    if not filepath or filepath == '' then
        msg.warn('无效的弹幕文件路径')
        return
    end
    add_danmaku_source_local(filepath, true)
end)