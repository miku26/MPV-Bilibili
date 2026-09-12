local msg   = require 'mp.msg'
local utils = require 'mp.utils'

-- 简繁字库延迟加载：默认 chConvert=0 时不 require 上万行的 dicts
local s2t, t2s = nil, nil
local function ensure_dicts()
    if s2t then return end
    s2t = require("dicts/s2t_chars")
    t2s = require("dicts/t2s_chars")
end

local function ass_escape(text)
    return text:gsub("\\", "\\\\")
               :gsub("{", "\\{")
               :gsub("}", "\\}")
               :gsub("\n", "\\N")
end

local function decode_html_entities(text)
    text = text:gsub("&quot;", "\"")
               :gsub("&apos;", "'")
               :gsub("&gt;", ">")
               :gsub("&lt;", "<")
               :gsub("&#x([%x]+);", function(hex)
                   return unicode_to_utf8(tonumber(hex, 16))
               end)
               :gsub("&#(%d+);", function(dec)
                   return unicode_to_utf8(tonumber(dec, 10))
               end)
    return text:gsub("&amp;", "&")
end

local function parse_csv_params(str)
    local params, i = {}, 1
    for val in str:gmatch("([^,]+)") do
        params[i] = tonumber(val)
        i = i + 1
    end
    return params
end

local function load_blacklist_patterns(filepath)
    local patterns = {}
    if not file_exists(filepath) then
        return patterns
    end
    local content = read_file(filepath)
    if not content then
        msg.error("无法读取黑名单文件: " .. filepath)
        return patterns
    end

    if string.match(filepath, "%.xml$") then
        for line in content:gmatch("[^\n]+") do
            local pattern = line:match('<item%s+enabled="true">t=(.-)</item>')
            if pattern then
                table.insert(patterns, pattern)
            end
        end
    elseif string.match(filepath, "%.json$") then
        local json = utils.parse_json(content)
        if json and type(json) == "table" then
            for _, entry in ipairs(json) do
                if entry.opened and entry.filter and entry.type == 0 then
                    table.insert(patterns, entry.filter)
                end
            end
        end
    elseif string.match(filepath, "%.txt$") then
        for line in content:gmatch("[^\n]+") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then
                table.insert(patterns, line)
            end
        end
    end

    return patterns
end

local blacklist_file = mp.command_native({ "expand-path", options.blacklist_path })
local black_patterns = load_blacklist_patterns(blacklist_file)

function is_blacklisted(str, patterns)
    for _, pattern in ipairs(patterns) do
        local ok, result = pcall(function()
            return str:match(pattern)
        end)
        if ok and result then
            return true, pattern
        end
    end
    return false
end

-- 简繁转换
local function convert(text, dict)
    return text:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return dict[c] or c
    end)
end

local function ch_convert(str)
    if options.chConvert == 1 then
        ensure_dicts()
        return convert(str, t2s)
    elseif options.chConvert == 2 then
        ensure_dicts()
        return convert(str, s2t)
    end
    return str
end

local ch_convert_cache = {}
local ch_cache_keys = {}
local ch_cache_max = 5000

local function ch_convert_cached(text)
    if type(text) ~= "string" or text == "" then return text end
    local cached = ch_convert_cache[text]
    if cached ~= nil then return cached end

    local converted = ch_convert(text)
    ch_convert_cache[text] = converted
    ch_cache_keys[#ch_cache_keys + 1] = text

    if #ch_cache_keys > ch_cache_max then
        local remove_count = math.floor(ch_cache_max / 2)
        for i = 1, remove_count do
            local k = table.remove(ch_cache_keys, 1)
            ch_convert_cache[k] = nil
        end
    end

    return converted
end

-- 合并重复弹幕
local function merge_duplicate_danmaku(danmakus, threshold)
    if not threshold or tonumber(threshold) < 0 then return danmakus end

    local groups = {}
    for _, d in ipairs(danmakus) do
        local key = string.format("%s\0%s\0%s",
            tostring(d.type or ""), tostring(d.color or ""), d.text or "")
        groups[key] = groups[key] or {}
        table.insert(groups[key], d)
    end

    local merged = {}
    local abs = math.abs
    for _, group in pairs(groups) do
        table.sort(group, function(a, b) return a.time < b.time end)
        local i = 1
        while i <= #group do
            local base = group[i]
            local times = { base.time }
            local count = 1
            local j = i + 1
            while j <= #group and abs(group[j].time - base.time) <= threshold do
                times[#times + 1] = group[j].time
                count = count + 1
                j = j + 1
            end
            local same_time = true
            for k = 2, #times do
                if times[k] ~= times[1] then
                    same_time = false
                    break
                end
            end
            local danmaku = {
                time = base.time,
                type = base.type,
                size = base.size,
                color = base.color,
                text = base.text,
                source = base.source,
                orig_time = base.orig_time,
            }
            if count > 2 or not same_time then
                danmaku.text = danmaku.text .. string.format("x%d", count)
            end
            table.insert(merged, danmaku)
            i = j
        end
    end
    table.sort(merged, function(a, b) return a.time < b.time end)
    return merged
end

-- 限制每屏弹幕条数
local function limit_danmaku(danmakus, limit)
    if not limit or limit <= 0 then
        return danmakus
    end
    local window = {}
    for _, d in ipairs(danmakus) do
        for i = #window, 1, -1 do
            if window[i].end_time <= d.start_time then
                table.remove(window, i)
            end
        end
        if #window < limit then
            table.insert(window, d)
        else
            local max_idx = 1
            for i = 2, #window do
                if window[i].end_time > window[max_idx].end_time then
                    max_idx = i
                end
            end
            if window[max_idx].end_time > d.end_time then
                window[max_idx].drop = true
                window[max_idx] = d
            else
                d.drop = true
            end
        end
    end
    local result = {}
    for _, d in ipairs(danmakus) do
        if not d.drop then
            table.insert(result, d)
        end
    end
    return result
end

-- 解析 XML 弹幕
local function parse_xml_danmaku(xml_string)
    local danmakus = {}
    for p_attr, text in xml_string:gmatch('<d%s+[^>]*%f[^%s]p="([^"]+)"[^>]*>([^<]+)</d>') do
        local params = parse_csv_params(p_attr)
        if params[1] and params[2] and params[3] and params[4] then
            table.insert(danmakus, {
                time = params[1],
                type = params[2] or 1,
                size = params[3] or 25,
                color = params[4] or 0xFFFFFF,
                text = decode_html_entities(text)
            })
        end
    end
    table.sort(danmakus, function(a, b) return a.time < b.time end)
    return danmakus
end

-- 解析 JSON 弹幕
local function parse_json_danmaku(json_string)
    local danmakus = {}
    if json_string:sub(1, 3) == "\239\187\191" then
        json_string = json_string:sub(4)
    end
    local json = utils.parse_json(json_string)
    if not json or type(json) ~= "table" then
        msg.info("JSON 解析失败")
        return danmakus
    end
    for _, entry in ipairs(json) do
        local c = entry.c
        local text = entry.m or ""
        if type(c) == "string" then
            local params = parse_csv_params(c)
            if params[1] and params[2] and params[3] and params[4] then
                table.insert(danmakus, {
                    time  = params[1],
                    type  = params[2] or 1,
                    size  = params[3] or 25,
                    color = params[4] or 0xFFFFFF,
                    text  = decode_html_entities(text),
                })
            end
        end
    end
    table.sort(danmakus, function(a, b) return a.time < b.time end)
    return danmakus
end

-- 解析弹幕文件
function parse_danmaku_file(danmaku_input)
    local content = read_file(danmaku_input)
    if not content then
        msg.info("文件不存在或无法读取: " .. danmaku_input)
        return nil
    end

    local danmakus
    if danmaku_input:match("%.xml$") then
        danmakus = parse_xml_danmaku(content)
    elseif danmaku_input:match("%.json$") then
        danmakus = parse_json_danmaku(content)
    else
        msg.info("不支持的文件格式: " .. danmaku_input)
        return nil
    end

    if #danmakus == 0 then
        msg.info("未能解析任何弹幕")
        return nil
    end
    return danmakus
end

-- 弹幕数组与布局算法
local DanmakuArray = {}
DanmakuArray.__index = DanmakuArray

function DanmakuArray:new(res_x, res_y, font_size)
    local obj = {
        rows = math.floor(res_y / font_size),
        time_length_array = {}
    }
    for i = 1, obj.rows do
        obj.time_length_array[i] = { time = 0, length = 0, empty = true }
    end
    setmetatable(obj, self)
    return obj
end

function DanmakuArray:set_time_length(row, time, length)
    if row > 0 and row <= self.rows then
        self.time_length_array[row] = { time = time, length = length, empty = false }
    end
end

function DanmakuArray:get_time(row)
    if row > 0 and row <= self.rows then
        return self.time_length_array[row].time
    end
    return -1
end

function DanmakuArray:get_length(row)
    if row > 0 and row <= self.rows then
        return self.time_length_array[row].length
    end
    return 0
end

function DanmakuArray:is_empty(row)
    if row > 0 and row <= self.rows then
        return self.time_length_array[row].empty
    end
    return false
end

-- 滚动弹幕 Y 坐标算法
function get_position_y(font_size, appear_time, text_length, resolution_x, roll_time, array)
    local velocity = (text_length + resolution_x) / roll_time
    for i = 1, array.rows do
        local previous_appear_time = array:get_time(i)
        if array:is_empty(i) then
            array:set_time_length(i, appear_time, text_length)
            return 1 + (i - 1) * font_size
        end
        local previous_length = array:get_length(i)
        local previous_velocity = (previous_length + resolution_x) / roll_time
        local delta_velocity = velocity - previous_velocity
        local delta_x = (appear_time - previous_appear_time) * previous_velocity - previous_length
        if delta_x >= 0 then
            if delta_velocity <= 0 then
                array:set_time_length(i, appear_time, text_length)
                return 1 + (i - 1) * font_size
            end
            local delta_time = delta_x / delta_velocity
            if delta_time >= roll_time then
                array:set_time_length(i, appear_time, text_length)
                return 1 + (i - 1) * font_size
            end
        end
    end
    return nil
end

-- 固定弹幕 Y 坐标算法
function get_fixed_y(font_size, appear_time, fixtime, array, from_top)
    local row_start = from_top and 1 or array.rows
    local row_end   = from_top and array.rows or 1
    local row_step  = from_top and 1 or -1
    for i = row_start, row_end, row_step do
        local previous_appear_time = array:get_time(i)
        if array:is_empty(i) then
            array:set_time_length(i, appear_time, 0)
            return (i - 1) * font_size + 1
        else
            local delta_time = appear_time - previous_appear_time
            if delta_time > fixtime then
                array:set_time_length(i, appear_time, 0)
                return (i - 1) * font_size + 1
            end
        end
    end
    return nil
end

-- 将弹幕转换为 ASS 事件（核心函数）
function convert_danmaku_to_ass_events(force)
    local per_source_lists = {}
    for url, source in pairs(DANMAKU.sources) do
        if not source.blocked and source.data then
            local segments = nil
            local prefix = nil
            if source.delay_segments and #source.delay_segments > 0 then
                segments = {}
                for i, v in ipairs(source.delay_segments) do segments[i] = v end
                table.sort(segments, function(a, b) return (a.start or 0) < (b.start or 0) end)
                prefix = {}
                local s = 0
                for i, v in ipairs(segments) do
                    s = s + (v.delay or 0)
                    prefix[i] = s
                end
            end

            local function get_cached_delay(t)
                local segs = segments or {}
                local pre = prefix or {}
                if #segs == 0 then return 0 end

                -- 二分查找最后一个 start <= t 的段
                local lo, hi = 1, #segs
                local target = 0
                while lo <= hi do
                    local mid = math.floor((lo + hi) / 2)
                    local seg_start = (segs[mid] and segs[mid].start) or 0
                    if seg_start <= t then
                        target = mid
                        lo = mid + 1
                    else
                        hi = mid - 1
                    end
                end

                if target < 1 then return 0 end
                return pre[target] or 0
            end

            local list = {}
            for _, d in ipairs(source.data) do
                local base_time = d.orig_time or d.time
                if d.orig_time == nil then d.orig_time = base_time end
                local adjusted_time = base_time + get_cached_delay(base_time)
                local entry = {
                    orig_time = d.orig_time,
                    time = adjusted_time,
                    type = d.type,
                    size = d.size,
                    color = d.color,
                    text = d.text,
                    source = url,
                }
                if not is_blacklisted(d.text, black_patterns) then
                    table.insert(list, entry)
                end
            end

            if #list > 0 then
                table.sort(list, function(a, b) return a.time < b.time end)
                per_source_lists[#per_source_lists + 1] = list
            end
        end
    end

    local danmakus = {}
    local heap = new_min_heap()
    for li = 1, #per_source_lists do
        local lst = per_source_lists[li]
        if lst and #lst > 0 then
            heap.push({ time = lst[1].time, list_idx = li, pos = 1, entry = lst[1] })
        end
    end
    while true do
        local node = heap.pop()
        if not node then break end
        table.insert(danmakus, node.entry)
        local li = node.list_idx
        local next_pos = node.pos + 1
        local lst = per_source_lists[li]
        if lst and lst[next_pos] then
            heap.push({ time = lst[next_pos].time, list_idx = li, pos = next_pos, entry = lst[next_pos] })
        end
    end

    local merge_tolerance = options.merge_tolerance
    if options.max_screen_danmaku > 0 and merge_tolerance <= 0 then
        merge_tolerance = options.scrolltime
    end
    danmakus = merge_duplicate_danmaku(danmakus, merge_tolerance)

    if #danmakus == 0 then
        if not force then
            show_message("该集弹幕内容为空，结束加载", 3)
            msg.verbose("该集弹幕内容为空，结束加载")
        end
        COMMENTS = {}
        return
    end

    if not force then
        msg.info("已解析 " .. #danmakus .. " 条弹幕")
    end

    local fontsize = tonumber(options.fontsize) or 36
    local scrolltime = tonumber(options.scrolltime) or 15
    local fixtime = tonumber(options.fixtime) or 5
    local res_x = 1920
    local res_y = 1080

    local roll_array = DanmakuArray:new(res_x, res_y, fontsize)
    local top_array = DanmakuArray:new(res_x, res_y, fontsize)

    local pre_events = {}
    for _, d in ipairs(danmakus) do
        local time = d.type == 1 and math.floor(d.time + 0.5) or d.time
        local orig_time = d.type == 1 and math.floor(d.orig_time + 0.5) or d.orig_time
        local appear_time = time
        local danmaku_type = d.type
        local end_time = nil
        if danmaku_type >= 1 and danmaku_type <= 3 then
            end_time = appear_time + scrolltime
        elseif danmaku_type == 5 or danmaku_type == 4 then
            end_time = appear_time + fixtime
        end
        if end_time then
            table.insert(pre_events, {
                orig_time = orig_time,
                start_time = appear_time,
                end_time = end_time,
                danmaku = d,
            })
        end
    end

    if options.max_screen_danmaku > 0 then
        pre_events = limit_danmaku(pre_events, options.max_screen_danmaku)
    end

    local ass_events = {}
    for _, ev in ipairs(pre_events) do
        local d = ev.danmaku
        local appear_time = ev.start_time
        local danmaku_type = d.type
        local clean_text = ch_convert_cached(d.text)
        local text = ass_escape(clean_text):gsub("x(%d+)$", "{\\b1\\i1}x%1")

        local color = math.max(0, math.min(d.color or 0xFFFFFF, 0xFFFFFF))
        local color_hex = string.format("%06X", color)
        local r = string.sub(color_hex, 1, 2)
        local g = string.sub(color_hex, 3, 4)
        local b = string.sub(color_hex, 5, 6)
        local color_text = string.format("{\\c&H%s%s%s&}", b, g, r)

        local style, effect
        local pos, move = nil, nil

        if danmaku_type >= 1 and danmaku_type <= 3 then
            style = "R2L"
            local text_length = get_str_width(text, fontsize)
            local x1 = res_x + text_length / 2
            local x2 = -text_length / 2
            local y = get_position_y(fontsize, appear_time, text_length, res_x, scrolltime, roll_array)
            if y then
                effect = string.format("{\\move(%d, %d, %d, %d)}", x1, y, x2, y)
                move = {x1, y, x2, y}
            end
        elseif danmaku_type == 5 then
            style = "TOP"
            local x = res_x / 2
            local y = get_fixed_y(fontsize, appear_time, fixtime, top_array, true)
            if y then
                effect = string.format("{\\pos(%d, %d)}", x, y)
                pos = {x, y}
            end
        elseif danmaku_type == 4 then
            style = "BTM"
            local x = res_x / 2
            local y = get_fixed_y(fontsize, appear_time, fixtime, top_array, false)
            if y then
                effect = string.format("{\\pos(%d, %d)}", x, y)
                pos = {x, y}
            end
        end

        if style and effect then
            text = effect .. color_text .. text
            local event = {
                orig_time = ev.orig_time,
                start_time = ev.start_time,
                end_time = ev.end_time,
                style = style,
                text = text,
                clean_text = clean_text,
                pos = pos,
                move = move,
                source = d.source,
            }

            if move then
                event.text_no_move = text:gsub("\\move%(.-%)", "")
            end
            table.insert(ass_events, event)
        end
    end

    COMMENTS = ass_events
end

return {
    parse_danmaku_file = parse_danmaku_file,
    convert_danmaku_to_ass_events = convert_danmaku_to_ass_events,
    is_blacklisted = is_blacklisted,
}