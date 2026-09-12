local mp = require 'mp'
local utils = require 'mp.utils'
local input = require 'mp.input'

-- Options
local o = {
    key_page_1 = "1", key_page_2 = "2", key_page_3 = "3",
    key_page_4 = "4", key_page_5 = "5", key_page_0 = "0",
    key_scroll_up = "UP", key_scroll_down = "DOWN",
    key_search = "/", key_exit = "ESC", scroll_lines = 1,

    duration = 4,
    redraw_delay = 1,
    ass_formatting = true,
    persistent_overlay = false,
    filter_params_max_length = 100,
    file_tag_max_length = 128,
    file_tag_max_count = 16,
    show_frame_info = false,
    term_clip = true,
    track_info_selected_only = true,
    debug = false,

    plot_perfdata = false,
    plot_vsync_ratio = false,
    plot_vsync_jitter = false,
    plot_cache = true,
    plot_tonemapping_lut = false,
    skip_frames = 5,
    plot_bg_border_color = "0000FF",
    plot_bg_color = "262626",
    plot_color = "FFFFFF",
    plot_bg_border_width = 1.25,

    font = "", font_mono = "微软雅黑", font_size = 20,
    font_color = "", border_size = 1, border_color = "",
    shadow_x_offset = math.huge, shadow_y_offset = math.huge,
    shadow_color = "", alpha = "11", vidscale = "auto",
    custom_header = "",

    ass_nl = "\\N", ass_indent = "\\h\\h\\h\\h\\h", ass_prefix_sep = "\\h\\h",
    ass_b1 = "{\\b1}", ass_b0 = "{\\b0}", ass_it1 = "{\\i1}", ass_it0 = "{\\i0}",
    no_ass_nl = "\n", no_ass_indent = "    ", no_ass_prefix_sep = " ",
    no_ass_b1 = "\027[1m", no_ass_b0 = "\027[0m",
    no_ass_it1 = "\027[3m", no_ass_it0 = "\027[0m",

    bindlist = "no",

    -- 翻译语言（zh-cn / en / 留空按 slang 自动判断）
    language = "",
    -- CPU/GPU 刷新间隔（秒）
    refresh_interval = 1.0,
}

local update_scale
require "mp.options".read_options(o, nil, function () update_scale() end)

local format = string.format
local max = math.max
local min = math.min

-- ============================================================
-- JSON 翻译模块（读取与 main.lua 同目录的 <lang>.json）
-- ============================================================
local translations = {}
local fuzzy_keys = {}

local function load_translations()
    local lang = o.language
    if lang == "" then
        local slang = mp.get_property("slang", "")
        lang = slang:find("zh") and "zh-cn" or "en"
    end

    local dir = mp.get_script_directory and mp.get_script_directory()
    if not dir then
        mp.msg.warn("stats-i18n: 需要 mpv 0.36+ 才能获取脚本目录")
        return
    end

    local path = mp.command_native({"expand-path", dir .. "/" .. lang .. ".json"})
    local f = io.open(path, "rb")
    if not f then
        mp.msg.warn("stats-i18n: 未找到 " .. path)
        return
    end
    local content = f:read("*a")
    f:close()

    local parsed = utils.parse_json(content)
    if not (parsed and type(parsed) == "table") then
        mp.msg.error("stats-i18n: JSON 解析失败 " .. path)
        return
    end
    translations = parsed

    -- 模糊匹配键：长度 ≥ 4，按长度降序
    fuzzy_keys = {}
    for en in pairs(translations) do
        if #en >= 4 then fuzzy_keys[#fuzzy_keys + 1] = en end
    end
    table.sort(fuzzy_keys, function(a, b) return #a > #b end)
end

load_translations()

local function t(s)
    if type(s) ~= "string" then return s end
    return translations[s] or s
end

local function auto_translate_text(text)
    if type(text) ~= "string" then return text end
    local result = translations[text]
    if result then return result end
    for _, en in ipairs(fuzzy_keys) do
        if text:find(en, 1, true) then
            text = text:gsub(en, translations[en], 1)
        end
    end
    return text
end

-- ============================================================
-- 全局变量
-- ============================================================
local font_size = o.font_size
local border_size = o.border_size
local shadow_x_offset = o.shadow_x_offset
local shadow_y_offset = o.shadow_y_offset
local plot_bg_border_width = o.plot_bg_border_width
local recorder = nil
local display_timer = nil
local cache_recorder_timer
local curr_page = o.key_page_1
local pages = {}
local scroll_bound = false
local searched_text
local tm_viz_prev = nil
local ass_start = mp.get_property_osd("osd-ass-cc/0")
local ass_stop = mp.get_property_osd("osd-ass-cc/1")
local vsratio_buf, vsjitter_buf
local function init_buffers()
    vsratio_buf = {0, pos = 1, len = 50, max = 0}
    vsjitter_buf = {0, pos = 1, len = 50, max = 0}
end
local cache_ahead_buf, cache_speed_buf
local perf_buffers = {}
local process_key_binding
local property_cache = {}

local function get_property_cached(name, def)
    if property_cache[name] ~= nil then return property_cache[name] end
    return def
end

local function graph_add_value(graph, value)
    graph.pos = (graph.pos % graph.len) + 1
    graph[graph.pos] = value
    graph.max = max(graph.max, value)
end

local function no_ASS(txt)
    if not o.use_ass then return txt
    elseif not o.persistent_overlay then return ass_stop .. txt .. ass_start
    else return mp.command_native({"escape-ass", tostring(txt)}) end
end

local function bold(txt) return o.b1 .. txt .. o.b0 end
local function it(txt) return o.it1 .. txt .. o.it0 end

local function text_style()
    if not o.use_ass then return "" end
    if o.custom_header and o.custom_header ~= "" then return o.custom_header end
    local style = "{\\r\\an7\\fs" .. font_size .. "\\bord" .. border_size
    if o.font ~= "" then style = style .. "\\fn" .. o.font end
    if o.font_color ~= "" then
        style = style .. "\\1c&H" .. o.font_color .. "&\\1a&H" .. o.alpha .. "&"
    end
    if o.border_color ~= "" then
        style = style .. "\\3c&H" .. o.border_color .. "&\\3a&H" .. o.alpha .. "&"
    end
    if o.shadow_color ~= "" then
        style = style .. "\\4c&H" .. o.shadow_color .. "&\\4a&H" .. o.alpha .. "&"
    end
    if o.shadow_x_offset < math.huge then style = style .. "\\xshad" .. shadow_x_offset end
    if o.shadow_y_offset < math.huge then style = style .. "\\yshad" .. shadow_y_offset end
    return style .. "}"
end

local function has_vo_window()
    return mp.get_property_native("vo-configured") and mp.get_property_native("video-osd")
end

local function generate_graph(values, i, len, v_max, v_avg, scale, x_tics)
    if not values[i] then return "" end
    local x_max = (len - 1) * x_tics
    local y_offset = border_size
    local y_max = font_size * 0.66
    local x = 0
    if v_max > 0 then
        if v_avg and v_avg > 0 then scale = min(scale, v_max / (2 * v_avg)) end
        scale = scale * y_max / v_max
    end
    local s = {format("m 0 0 n %f %f l ", x, y_max - scale * values[i])}
    i = ((i - 2) % len) + 1
    for _ = 1, len - 1 do
        if values[i] then
            x = x - x_tics
            s[#s+1] = format("%f %f ", x, y_max - scale * values[i])
        end
        i = ((i - 2) % len) + 1
    end
    s[#s+1] = format("%f %f %f %f", x, y_max, 0, y_max)
    local bg_box = format("{\\bord%f}{\\3c&H%s&}{\\1c&H%s&}m 0 %f l %f %f %f 0 0 0",
                          plot_bg_border_width, o.plot_bg_border_color, o.plot_bg_color,
                          y_max, x_max, y_max, x_max)
    return format("%s{\\rDefault}{\\pbo%f}{\\shad0}{\\alpha&H00}{\\p1}%s{\\p0}" ..
                  "{\\bord0}{\\1c&H%s}{\\p1}%s{\\p0}%s",
                  o.prefix_sep, y_offset, bg_box, o.plot_color,
                  table.concat(s), text_style())
end

local function append(s, str, attr)
    if not str then return false end
    attr = attr or {}
    attr.prefix_sep = attr.prefix_sep or o.prefix_sep
    attr.indent = attr.indent or o.indent
    attr.nl = attr.nl or o.nl
    attr.suffix = attr.suffix or ""
    attr.prefix = attr.prefix or ""
    attr.no_prefix_markup = attr.no_prefix_markup or false
    attr.prefix = attr.no_prefix_markup and attr.prefix or bold(attr.prefix)
    local index = #s + (attr.nl == "" and 0 or 1)
    s[index] = s[index] or ""
    s[index] = s[index] .. format("%s%s%s%s%s%s", attr.nl, attr.indent,
                     attr.prefix, attr.prefix_sep, no_ASS(str), attr.suffix)
    return true
end

local function append_property(s, prop, attr, excluded, cached)
    excluded = excluded or {[""] = true}
    local ret
    if cached then ret = get_property_cached(prop)
    else ret = mp.get_property_osd(prop) end
    if not ret or excluded[ret] then
        if o.debug then print("No value for property: " .. prop) end
        return false
    end
    return append(s, ret, attr)
end

local function sorted_keys(tbl, comp_fn)
    local keys = {}
    for k,_ in pairs(tbl) do keys[#keys+1] = k end
    table.sort(keys, comp_fn)
    return keys
end

local function scroll_hint(search)
    local hint = format("(hint: scroll with %s/%s", o.key_scroll_up, o.key_scroll_down)
    if search then hint = hint .. " and search with " .. o.key_search end
    hint = hint .. ")"
    if not o.use_ass then return " " .. hint end
    return format(" {\\fs%s}%s{\\fs%s}", font_size * 0.66, hint, font_size)
end

local function append_perfdata(header, s, dedicated_page)
    local vo_p = mp.get_property_native("vo-passes")
    if not vo_p then return end
    local last_s, avg_s, peak_s = {}, {}, {}
    for frame, data in pairs(vo_p) do
        last_s[frame], avg_s[frame], peak_s[frame] = 0, 0, 0
        for _, pass in ipairs(data) do
            last_s[frame] = last_s[frame] + pass["last"]
            avg_s[frame]  = avg_s[frame]  + pass["avg"]
            peak_s[frame] = peak_s[frame] + pass["peak"]
        end
    end
    local function pp(i) return format("%5d", i / 1000) end
    local function p(n, m)
        local i = 0
        if m > 0 then i = tonumber(n) / m end
        local w = (700 * math.sqrt(i)) + 200
        if not o.use_ass then
            local str = format("%3d%%", i * 100)
            return w >= 700 and bold(str) or str
        end
        return format("{\\b%d}%3d%%{\\b0}", w, i * 100)
    end
    local font_small = o.use_ass and format("{\\fs%s}", font_size * 0.66) or ""
    local font_normal = o.use_ass and format("{\\fs%s}", font_size) or ""
    local font = o.use_ass and format("{\\fn%s}", o.font) or ""
    local font_mono = o.use_ass and format("{\\fn%s}", o.font_mono) or ""
    local indent = o.use_ass and "\\h" or " "
    local h = dedicated_page and header or s
    h[#h+1] = format("%s%s%s%s%s%s%s%s",
                     dedicated_page and "" or o.nl, dedicated_page and "" or o.indent,
                     bold(t("Frame Timings:")), o.prefix_sep, font_small,
                     t("(last/average/peak μs)"), font_normal,
                     dedicated_page and scroll_hint() or "")
    for _,frame in ipairs(sorted_keys(vo_p)) do
        local data = vo_p[frame]
        local f = "%s%s%s%s%s / %s / %s %s%s%s%s%s%s"
        if dedicated_page then
            s[#s+1] = format("%s%s%s:", o.nl, o.indent,
                             bold(t(frame:gsub("^%l", string.upper))))
            for _, pass in ipairs(data) do
                s[#s+1] = format(f, o.nl, o.indent, o.indent,
                                 font_mono, pp(pass["last"]),
                                 pp(pass["avg"]), pp(pass["peak"]),
                                 o.prefix_sep .. indent, p(pass["last"], last_s[frame]),
                                 font, o.prefix_sep, o.prefix_sep, t(pass["desc"]))
                if o.plot_perfdata and o.use_ass then
                    s[#s] = s[#s] ..
                              generate_graph(pass["samples"], pass["count"],
                                             pass["count"], pass["peak"],
                                             pass["avg"], 0.9, 0.25)
                end
            end
            s[#s+1] = format(f, o.nl, o.indent, o.indent,
                             font_mono, pp(last_s[frame]),
                             pp(avg_s[frame]), pp(peak_s[frame]),
                             o.prefix_sep, bold(t("Total")), font, "", "", "")
        else
            s[#s+1] = format(f, o.nl, o.indent, o.indent, font_mono,
                            pp(last_s[frame]), pp(avg_s[frame]), pp(peak_s[frame]),
                            "", "", font, o.prefix_sep, o.prefix_sep,
                            t(frame:gsub("^%l", string.upper)))
        end
    end
end

local cmd_prefixes = {
    osd_auto=1, no_osd=1, osd_bar=1, osd_msg=1, osd_msg_bar=1, raw=1, sync=1,
    async=1, expand_properties=1, repeatable=1, nonrepeatable=1, nonscalable=1,
    set=1, add=1, multiply=1, toggle=1, cycle=1, cycle_values=1, ["!reverse"]=1,
    change_list=1,
}
local name_prefixes = {
    define=1, delete=1, enable=1, disable=1, dump=1, write=1, drop=1, revert=1,
    ab=1, hr=1, secondary=1, current=1,
}

local function cmd_subject(cmd)
    cmd = cmd:gsub(";.*", ""):gsub("%-", "_")
    local TOKEN = '^%s*["\']?([%w_!]*)'
    local tok, sname, subw
    repeat tok, cmd = cmd:match(TOKEN .. '["\']?(.*)')
    until not cmd_prefixes[tok]
    sname = tok == "script_message_to" and cmd:match(TOKEN)
         or tok == "script_binding" and cmd:match(TOKEN .. "/")
    if sname and sname ~= "" then return "script: " .. sname end
    repeat subw, tok = tok:match("([^_]*)_?(.*)")
    until tok == "" or not name_prefixes[subw]
    return subw:len() > 1 and subw or "[unknown]"
end

local function keyname_cells(k)
    local klen = k:len()
    if klen > 1 and k:byte(klen) >= 0x80 then
        repeat klen = klen-1
        until klen == 1 or k:byte(klen) >= 0xc0
    end
    return klen
end

local function get_kbinfo_lines()
    local bindings = mp.get_property_native("input-bindings", {})
    local active = {}
    for _, bind in pairs(bindings) do
        if bind.priority >= 0 and (
               not active[bind.key] or
               (active[bind.key].is_weak and not bind.is_weak) or
               (bind.is_weak == active[bind.key].is_weak and
                bind.priority > active[bind.key].priority)
           ) and not bind.cmd:find("script-binding stats/__forced_", 1, true)
           and bind.section ~= "input_forced_console"
           and (
               searched_text == nil or
               (bind.key .. bind.cmd .. (bind.comment or "")):lower():find(searched_text, 1, true)
           )
        then active[bind.key] = bind end
    end
    local ordered = {}
    local kspaces = ""
    for _, bind in pairs(active) do
        bind.subject = cmd_subject(bind.cmd)
        if bind.subject ~= "ignore" then
            ordered[#ordered+1] = bind
            _,_, bind.mods = bind.key:find("(.*)%+.")
            _, bind.mods_count = bind.key:gsub("%+.", "")
            if bind.key:len() > kspaces:len() then
                kspaces = string.rep(" ", bind.key:len())
            end
        end
    end
    local function align_right(key)
        return kspaces:sub(keyname_cells(key)) .. key
    end
    table.sort(ordered, function(a, b)
        if a.subject ~= b.subject then return a.subject < b.subject
        elseif a.mods_count ~= b.mods_count then return a.mods_count < b.mods_count
        elseif a.mods ~= b.mods then return a.mods < b.mods
        elseif a.key:len() ~= b.key:len() then return a.key:len() < b.key:len()
        elseif a.key:lower() ~= b.key:lower() then return a.key:lower() < b.key:lower()
        else return a.key > b.key end
    end)
    local LTR = string.char(0xE2, 0x80, 0x8E)
    local term = not o.use_ass
    local kpre = term and "" or format("{\\q2\\fn%s}%s", o.font_mono, LTR)
    local kpost = term and " " or format(" {\\fn%s}", o.font)
    local spre = term and kspaces .. "   "
                       or format("{\\q2\\fn%s}%s   {\\fn%s}{\\fs%d\\u1}",
                                 o.font_mono, kspaces, o.font, 1.3*font_size)
    local spost = term and "" or format("{\\u0\\fs%d}%s", font_size, text_style())
    local info_lines = {}
    local subject = nil
    for _, bind in ipairs(ordered) do
        if bind.subject ~= subject then
            subject = bind.subject
            append(info_lines, "", {})
            append(info_lines, "", { prefix = spre .. subject .. spost })
        end
        if bind.comment then
            bind.cmd = bind.cmd .. "  # " .. bind.comment
        end
        append(info_lines, bind.cmd,
               { prefix = kpre .. no_ASS(align_right(bind.key)) .. kpost })
    end
    return info_lines
end

local function append_general_perfdata(s)
    for i, data in ipairs(mp.get_property_native("perf-info") or {}) do
        local display_name = auto_translate_text(data.name)
        append(s, data.text or data.value,
               {prefix="["..tostring(i).."] "..display_name..t(":")})
        if o.plot_perfdata and o.use_ass and data.value then
            local buf = perf_buffers[data.name]
            if not buf then
                buf = {0, pos = 1, len = 50, max = 0}
                perf_buffers[data.name] = buf
            end
            graph_add_value(buf, data.value)
            s[#s] = s[#s] .. generate_graph(buf, buf.pos, buf.len, buf.max, nil, 0.8, 1)
        end
    end
end

local function append_display_sync(s)
    if not mp.get_property_bool("display-sync-active", false) then return end
    local vspeed = append_property(s, "video-speed-correction", {prefix="DS:"})
    if vspeed then
        append_property(s, "audio-speed-correction",
                        {prefix="/", nl="", indent=" ", prefix_sep=" ", no_prefix_markup=true})
    else
        append_property(s, "audio-speed-correction",
                        {prefix="DS:" .. o.prefix_sep .. " - / ", prefix_sep=""})
    end
    append_property(s, "mistimed-frame-count",
                    {prefix="Mistimed:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "vo-delayed-frame-count",
                    {prefix="Delayed:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    if not display_timer.oneshot and (o.plot_vsync_ratio or o.plot_vsync_jitter) and o.use_ass then
        local ratio_graph = ""
        local jitter_graph = ""
        if o.plot_vsync_ratio then
            ratio_graph = generate_graph(vsratio_buf, vsratio_buf.pos,
                                         vsratio_buf.len, vsratio_buf.max, nil, 0.8, 1)
        end
        if o.plot_vsync_jitter then
            jitter_graph = generate_graph(vsjitter_buf, vsjitter_buf.pos,
                                          vsjitter_buf.len, vsjitter_buf.max, nil, 0.8, 1)
        end
        append_property(s, "vsync-ratio", {prefix="VSync Ratio:",
                                           suffix=o.prefix_sep .. ratio_graph})
        append_property(s, "vsync-jitter", {prefix="VSync Jitter:",
                                            suffix=o.prefix_sep .. jitter_graph})
    else
        local vr = append_property(s, "vsync-ratio", {prefix="VSync Ratio:"})
        append_property(s, "vsync-jitter", {prefix="VSync Jitter:",
                            nl=vr and "" or o.nl,
                            indent=vr and o.prefix_sep .. o.prefix_sep})
    end
end

local function append_filters(s, prop, prefix)
    local length = 0
    local filters = {}
    for _,f in ipairs(mp.get_property_native(prop, {})) do
        local n = f.name
        if f.enabled ~= nil and not f.enabled then n = n .. " (disabled)" end
        if f.label ~= nil then n = "@" .. f.label .. ": " .. n end
        local p = {}
        for _,key in ipairs(sorted_keys(f.params)) do
            p[#p+1] = key .. "=" .. f.params[key]
        end
        p = #p > 0 and (" [" .. table.concat(p, " ") .. "]") or ""
        length = length + n:len() + p:len()
        filters[#filters+1] = no_ASS(n) .. it(no_ASS(p))
    end
    if #filters > 0 then
        local ret
        if length < o.filter_params_max_length then
            ret = table.concat(filters, ", ")
        else
            local sep = o.nl .. o.indent .. o.indent
            ret = sep .. table.concat(filters, sep)
        end
        s[#s+1] = o.nl .. o.indent .. bold(prefix) .. o.prefix_sep .. ret
    end
end

local function add_header(s)
    s[#s+1] = text_style()
end

local function add_file(s, print_cache, print_tags)
    append(s, "", {prefix="File:", nl="", indent=""})
    append_property(s, "filename", {prefix_sep="", nl="", indent=""})
    if mp.get_property_osd("filename") ~= mp.get_property_osd("media-title") then
        append_property(s, "media-title", {prefix="Title:"})
    end
    if print_tags then
        append_property(s, "duration", {prefix="Duration:"})
        local tags = mp.get_property_native("display-tags")
        local tags_displayed = 0
        for _, tag in ipairs(tags) do
            local value = mp.get_property("metadata/by-key/" .. tag)
            if tag ~= "Title" and tags_displayed < o.file_tag_max_count
               and value and value:len() < o.file_tag_max_length then
                append(s, value, {prefix=string.gsub(tag, "_", " ") .. ":"})
                tags_displayed = tags_displayed + 1
            end
        end
    end
    local editions = mp.get_property_number("editions")
    local edition = mp.get_property_number("current-edition")
    local ed_cond = (edition and editions > 1)
    if ed_cond then
        append_property(s, "edition-list/" .. tostring(edition) .. "/title",
                       {prefix="Edition:"})
        append_property(s, "edition-list/count",
                        {prefix="(" .. tostring(edition + 1) .. "/", suffix=")",
                         nl="", indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end
    local ch_index = mp.get_property_number("chapter")
    if ch_index and ch_index >= 0 then
        append_property(s, "chapter-list/" .. tostring(ch_index) .. "/title",
                        {prefix="Chapter:", nl=ed_cond and "" or o.nl})
        append_property(s, "chapter-list/count",
                        {prefix="(" .. tostring(ch_index + 1) .. " /", suffix=")",
                         nl="", indent=" ", prefix_sep=" ", no_prefix_markup=true})
    end
    local fs = append_property(s, "file-size", {prefix="Size:"})
    append_property(s, "file-format", {prefix="Format/Protocol:",
                                       nl=fs and "" or o.nl,
                                       indent=fs and o.prefix_sep .. o.prefix_sep})
    if not print_cache then return end
    local demuxer_cache = mp.get_property_native("demuxer-cache-state", {})
    demuxer_cache = demuxer_cache["fw-bytes"] or 0
    local demuxer_secs = mp.get_property_number("demuxer-cache-duration", 0)
    if demuxer_cache + demuxer_secs > 0 then
        append(s, utils.format_bytes_humanized(demuxer_cache), {prefix="Total Cache:"})
        append(s, format("%.1f", demuxer_secs),
               {prefix="(", suffix=" sec)", nl="", no_prefix_markup=true,
                prefix_sep="", indent=o.prefix_sep})
    end
end

local function crop_noop(w, h, r)
    return r["crop-x"] == 0 and r["crop-y"] == 0 and
           r["crop-w"] == w and r["crop-h"] == h
end
local function crop_equal(r, ro)
    return r["crop-x"] == ro["crop-x"] and r["crop-y"] == ro["crop-y"] and
           r["crop-w"] == ro["crop-w"] and r["crop-h"] == ro["crop-h"]
end

local function append_resolution(s, r, prefix, w_prop, h_prop, video_res)
    if not r then return end
    w_prop = w_prop or "w"
    h_prop = h_prop or "h"
    if append(s, r[w_prop], {prefix=prefix}) then
        append(s, r[h_prop], {prefix="x", nl="", indent=" ", prefix_sep=" ",
                              no_prefix_markup=true})
        if r["aspect"] ~= nil and not video_res then
            append(s, format("%.2f:1", r["aspect"]), {prefix="", nl="", indent="",
                                                      no_prefix_markup=true})
            append(s, r["aspect-name"], {prefix="(", suffix=")", nl="", indent=" ",
                                         prefix_sep="", no_prefix_markup=true})
        end
        if r["sar"] ~= nil and video_res then
            append(s, format("%.2f:1", r["sar"]), {prefix="", nl="", indent="",
                                                   no_prefix_markup=true})
            append(s, r["sar-name"], {prefix="(", suffix=")", nl="", indent=" ",
                                      prefix_sep="", no_prefix_markup=true})
        end
        if r["s"] then
            append(s, format("%.2f", r["s"]),
                   {prefix="(", suffix="x)", nl="", indent=o.prefix_sep,
                    prefix_sep="", no_prefix_markup=true})
        end
        if r["crop-w"] and (not video_res or not crop_noop(r[w_prop], r[h_prop], r)) then
            append(s, format("[x: %d, y: %d, w: %d, h: %d]",
                             r["crop-x"], r["crop-y"], r["crop-w"], r["crop-h"]),
                   {prefix="", nl="", indent="", no_prefix_markup=true})
        end
    end
end

local function pq_eotf(x)
    if not x then return x end
    local PQ_M1 = 2610.0 / 4096 * 1.0 / 4
    local PQ_M2 = 2523.0 / 4096 * 128
    local PQ_C1 = 3424.0 / 4096
    local PQ_C2 = 2413.0 / 4096 * 32
    local PQ_C3 = 2392.0 / 4096 * 32
    x = x ^ (1.0 / PQ_M2)
    x = max(x - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * x)
    x = x ^ (1.0 / PQ_M1)
    return x * 10000.0
end

local function append_hdr(s, hdr, video_out)
    if not hdr then return end
    local function has(val, target)
        return val and math.abs(val - target) > 1e-4
    end
    local display_prefix = video_out and "Display:" or "Mastering display:"
    local indent = ""
    local has_dml = has(hdr["min-luma"], 0.203) or has(hdr["max-luma"], 203)
    local has_cll = hdr["max-cll"] and hdr["max-cll"] > 0
    local has_fall = hdr["max-fall"] and hdr["max-fall"] > 0
    if has_dml or has_cll or has_fall then
        append(s, "", {prefix=video_out and "" or "HDR10:",
                       prefix_sep=video_out and "" or nil})
        if has_dml then
            hdr["min-luma"] = hdr["min-luma"] <= 1e-6 and 0 or hdr["min-luma"]
            append(s, format("%.2g / %.0f", hdr["min-luma"], hdr["max-luma"]),
                   {prefix=display_prefix, suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_cll then
            append(s, string.format("%.0f", hdr["max-cll"]),
                   {prefix="MaxCLL:", suffix=" cd/m²", nl="", indent=indent})
            indent = o.prefix_sep .. o.prefix_sep
        end
        if has_fall then
            append(s, hdr["max-fall"],
                   {prefix="MaxFALL:", suffix=" cd/m²", nl="", indent=indent})
        end
    end
    indent = o.prefix_sep .. o.prefix_sep
    if hdr["scene-max-r"] or hdr["scene-max-g"] or
       hdr["scene-max-b"] or hdr["scene-avg"] then
        append(s, "", {prefix="HDR10+:"})
        append(s, format("%.1f / %.1f / %.1f", hdr["scene-max-r"] or 0,
                         hdr["scene-max-g"] or 0, hdr["scene-max-b"] or 0),
               {prefix="MaxRGB:", suffix=" cd/m²", nl="", indent=""})
        append(s, format("%.1f", hdr["scene-avg"] or 0),
               {prefix="Avg:", suffix=" cd/m²", nl="", indent=indent})
    end
    if hdr["max-pq-y"] and hdr["avg-pq-y"] then
        append(s, "", {prefix="PQ(Y):"})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["max-pq-y"]),
                         hdr["max-pq-y"] * 100), {prefix="Max:", nl="", indent=""})
        append(s, format("%.2f cd/m² (%.2f%% PQ)", pq_eotf(hdr["avg-pq-y"]),
                         hdr["avg-pq-y"] * 100), {prefix="Avg:", nl="", indent=indent})
    end
end

local function append_img_params(s, r, ro)
    if not r then return end
    append_resolution(s, r, "Resolution:", "w", "h", true)
    if ro and (r["w"] ~= ro["dw"] or r["h"] ~= ro["dh"]) then
        if ro["crop-w"] and (crop_noop(r["w"], r["h"], ro) or crop_equal(r, ro)) then
            ro["crop-w"] = nil
        end
        append_resolution(s, ro, "Output Resolution:", "dw", "dh")
    end
    local indent = o.prefix_sep .. o.prefix_sep
    r = ro or r
    local pixel_format = r["hw-pixelformat"] or r["pixelformat"]
    append(s, pixel_format, {prefix="Format:"})
    append(s, r["colorlevels"], {prefix="Levels:", nl="", indent=indent})
    if r["chroma-location"] and r["chroma-location"] ~= "unknown" then
        append(s, r["chroma-location"], {prefix="Chroma Loc:", nl="", indent=indent})
    end
    append(s, r["colormatrix"], {prefix="Colormatrix:"})
    if r["prim-red-x"] or r["prim-red-y"] or r["prim-green-x"] or r["prim-green-y"] or
       r["prim-blue-x"] or r["prim-blue-y"] or r["prim-white-x"] or r["prim-white-y"] then
        append(s, string.format("[%.3f %.3f, %.3f %.3f, %.3f %.3f, %.3f %.3f]",
                                r["prim-red-x"] or 0, r["prim-red-y"] or 0,
                                r["prim-green-x"] or 0, r["prim-green-y"] or 0,
                                r["prim-blue-x"] or 0, r["prim-blue-y"] or 0,
                                r["prim-white-x"] or 0, r["prim-white-y"] or 0),
               {prefix="Primaries:", nl="", indent=indent})
        append(s, r["primaries"],
               {prefix="使用：", nl="", indent=" ", prefix_sep="", no_prefix_markup=true})
    else
        append(s, r["primaries"], {prefix="Primaries:", nl="", indent=indent})
    end
    append(s, r["gamma"], {prefix="Transfer:", nl="", indent=indent})
end

local function append_fps(s, prop, eprop)
    local fps = mp.get_property_osd(prop)
    local efps = mp.get_property_osd(eprop)
    local single = eprop == "" or (fps ~= "" and efps ~= "" and fps == efps)
    local unit = prop == "display-fps" and " Hz" or " fps"
    local suffix = single and "" or " (specified)"
    local esuffix = single and "" or " (estimated)"
    local prefix = prop == "display-fps" and "Refresh Rate:" or "Frame Rate:"
    local nl = o.nl
    local indent = o.indent
    if fps ~= "" and append(s, fps, {prefix=prefix, suffix=unit .. suffix}) then
        prefix = ""; nl = ""; indent = ""
    end
    if not single and efps ~= "" then
        append(s, efps, {prefix=prefix, suffix=unit .. esuffix, nl=nl, indent=indent})
    end
end

local function add_video_out(s)
    local vo = mp.get_property_native("current-vo")
    if not vo then return end
    append(s, "", {prefix="Display:", nl=o.nl .. o.nl, indent=""})
    append(s, vo, {prefix_sep="", nl="", indent=""})
    append_property(s, "display-names",
                    {prefix_sep="", prefix="(", suffix=")",
                     no_prefix_markup=true, nl="", indent=" "}, nil, true)
    append(s, mp.get_property_native("current-gpu-context"),
           {prefix="Context:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append_property(s, "avsync", {prefix="A-V:"})
    append_fps(s, "display-fps", "estimated-display-fps")
    if append_property(s, "decoder-frame-drop-count",
                       {prefix="Dropped Frames:", suffix=" (decoder)"}) then
        append_property(s, "frame-drop-count", {suffix=" (output)", nl="", indent=""})
    end
    append_display_sync(s)
    append_perfdata(nil, s, false)
    if mp.get_property_native("deinterlace-active") then
        append_property(s, "deinterlace", {prefix="Deinterlacing:"})
    end
    local scale = nil
    if not mp.get_property_native("fullscreen") then
        scale = get_property_cached("current-window-scale")
    end
    local od = mp.get_property_native("osd-dimensions")
    local rt = mp.get_property_native("video-target-params")
    local r = rt or {}
    r["s"] = scale
    r["crop-x"] = od["ml"]; r["crop-y"] = od["mt"]
    r["crop-w"] = od["w"] - od["ml"] - od["mr"]
    r["crop-h"] = od["h"] - od["mt"] - od["mb"]
    if not rt then
        r["w"] = r["crop-w"]; r["h"] = r["crop-h"]
        append_resolution(s, r, "Resolution:", "w", "h", true)
        return
    end
    append_img_params(s, r)
    append_hdr(s, r, true)
end

local function add_video(s)
    local r = mp.get_property_native("video-params")
    local ro = mp.get_property_native("video-out-params")
    if not r then r = ro end
    if not r then return end
    local track = mp.get_property_native("current-tracks/video")
    local track_type = (track and track.image) and "Image:" or "Video:"
    append(s, "", {prefix=track_type, nl=o.nl .. o.nl, indent=""})
    if track and append(s, track["codec-desc"], {prefix_sep="", nl="", indent=""}) then
        append(s, track["codec-profile"],
               {prefix="[", nl="", indent=" ", prefix_sep="",
                no_prefix_markup=true, suffix="]"})
        if track["codec"] ~= track["decoder"] then
            append(s, track["decoder"],
                   {prefix="[", nl="", indent=" ", prefix_sep="",
                    no_prefix_markup=true, suffix="]"})
        end
        append_property(s, "hwdec-current", {prefix="HW:", nl="",
                        indent=o.prefix_sep .. o.prefix_sep,
                        no_prefix_markup=false, suffix=""}, {no=true, [""]=true}, true)
    end
    local has_prefix = false
    if o.show_frame_info then
        if append_property(s, "estimated-frame-number", {prefix="Frame:"}) then
            append_property(s, "estimated-frame-count", {indent=" / ", nl="",
                                                        prefix_sep=""})
            has_prefix = true
        end
        local frame_info = mp.get_property_native("video-frame-info")
        if frame_info and frame_info["picture-type"] then
            local attrs = has_prefix and {prefix="(", suffix=")", indent=" ", nl="",
                                          prefix_sep="", no_prefix_markup=true}
                                      or {prefix="Picture Type:"}
            append(s, frame_info["picture-type"], attrs)
            has_prefix = true
        end
        if frame_info and frame_info["interlaced"] then
            local attrs = has_prefix and {indent=" ", nl="", prefix_sep=""}
                                      or {prefix="Picture Type:"}
            append(s, "Interlaced", attrs)
        end
        local timecodes = {
            ["gop-timecode"] = "GOP",
            ["smpte-timecode"] = "SMPTE",
            ["estimated-smpte-timecode"] = "Estimated SMPTE",
        }
        for prop, name in pairs(timecodes) do
            if frame_info and frame_info[prop] then
                local attrs = has_prefix and
                    {prefix=name .. " Timecode:",
                     indent=o.prefix_sep .. o.prefix_sep, nl=""}
                    or {prefix=name .. " Timecode:"}
                append(s, frame_info[prop], attrs)
                break
            end
        end
    end
    if mp.get_property_native("current-tracks/video/image") == false then
        append_fps(s, "container-fps", "estimated-vf-fps")
    end
    append_img_params(s, r, ro)
    append_hdr(s, ro)
    append_property(s, "video-bitrate", {prefix="Bitrate:"})
    append_filters(s, "vf", "Filters:")
end

local function add_audio(s)
    local r = mp.get_property_native("audio-params")
    local ro = mp.get_property_native("audio-out-params") or r
    r = r or ro
    if not r then return end
    local merge = function(rr, rro, prop)
        local a = rr[prop] or rro[prop]
        local b = rro[prop] or rr[prop]
        return (a == b or a == nil) and a or (a .. " ➜ " .. b)
    end
    append(s, "", {prefix="Audio:", nl=o.nl .. o.nl, indent=""})
    local track = mp.get_property_native("current-tracks/audio")
    if track then
        append(s, track["codec-desc"], {prefix_sep="", nl="", indent=""})
        append(s, track["codec-profile"],
               {prefix="[", nl="", indent=" ", prefix_sep="",
                no_prefix_markup=true, suffix="]"})
        if track["codec"] ~= track["decoder"] then
            append(s, track["decoder"],
                   {prefix="[", nl="", indent=" ", prefix_sep="",
                    no_prefix_markup=true, suffix="]"})
        end
    end
    append_property(s, "current-ao", {prefix="AO:", nl="",
                                      indent=o.prefix_sep .. o.prefix_sep})
    local dev = append_property(s, "audio-device", {prefix="Device:"})
    local ao_mute = mp.get_property_native("ao-mute") and " (Muted)" or ""
    append_property(s, "ao-volume", {prefix="AO Volume:", suffix="%" .. ao_mute,
                                     nl=dev and "" or o.nl,
                                     indent=dev and o.prefix_sep .. o.prefix_sep})
    if math.abs(mp.get_property_native("audio-delay")) > 1e-6 then
        append_property(s, "audio-delay", {prefix="A-V delay:"})
    end
    local cc = append(s, merge(r, ro, "channel-count"), {prefix="Channels:"})
    append(s, merge(r, ro, "format"), {prefix="Format:", nl=cc and "" or o.nl,
                            indent=cc and o.prefix_sep .. o.prefix_sep})
    append(s, merge(r, ro, "samplerate"), {prefix="Sample Rate:", suffix=" Hz"})
    append_property(s, "audio-bitrate", {prefix="Bitrate:"})
    append_filters(s, "af", "Filters:")
end

local function eval_ass_formatting()
    o.use_ass = o.ass_formatting and has_vo_window()
    if o.use_ass then
        o.nl = o.ass_nl
        o.indent = o.ass_indent
        o.prefix_sep = o.ass_prefix_sep
        o.b1 = o.ass_b1
        o.b0 = o.ass_b0
        o.it1 = o.ass_it1
        o.it0 = o.ass_it0
    else
        o.nl = o.no_ass_nl
        o.indent = o.no_ass_indent
        o.prefix_sep = o.no_ass_prefix_sep
        o.b1 = o.no_ass_b1
        o.b0 = o.no_ass_b0
        o.it1 = o.no_ass_it1
        o.it0 = o.no_ass_it0
    end
end

local function split(str, pat, plain)
    local init = 1
    local r, i, find, sub = {}, 1, string.find, string.sub
    repeat
        local f0, f1 = find(str, pat, init, plain)
        r[i], i = sub(str, init, f0 and f0 - 1), i+1
        init = f0 and f1 + 1
    until f0 == nil
    return r
end

local function finalize_page(header, content, apply_scroll)
    local term_height = mp.get_property_native("term-size/h", 24)
    local from, to = 1, #content
    if apply_scroll then
        local max_content_lines = (o.use_ass and 40 or term_height - 2) - #header
        local max_offset = o.use_ass and #content or #content - max_content_lines + 1
        from = max(1, min((pages[curr_page].offset or 1), max_offset))
        to = min(#content, from + max_content_lines - 1)
        pages[curr_page].offset = from
    end
    local output = table.concat(header) .. table.concat(content, "", from, to)
    if not o.use_ass and o.term_clip then
        local clip = mp.get_property("term-clip-cc")
        local tt = split(output, "\n", true)
        output = clip .. table.concat(tt, "\n" .. clip)
    end
    return output, from
end

local function default_stats()
    local stats = {}
    eval_ass_formatting()
    add_header(stats)
    add_file(stats, true, false)
    add_video_out(stats)
    add_video(stats)
    add_audio(stats)
    return finalize_page({}, stats, false)
end

local function vo_stats()
    local header, content = {}, {}
    eval_ass_formatting()
    add_header(header)
    append_perfdata(header, content, true)
    header = {table.concat(header)}
    return finalize_page(header, content, true)
end

local kbinfo_lines = nil
local function keybinding_info(after_scroll, bindlist)
    local header = {}
    local page = pages[o.key_page_4]
    eval_ass_formatting()
    add_header(header)
    local prefix = bindlist and page.desc or page.desc .. ":" .. scroll_hint(true)
    append(header, "", {prefix=prefix, nl="", indent=""})
    header = {table.concat(header)}
    if not kbinfo_lines or not after_scroll then
        kbinfo_lines = get_kbinfo_lines()
    end
    return finalize_page(header, kbinfo_lines, not bindlist)
end

local function float2rational(x)
    local max_den = 100000
    local m00, m01, m10, m11 = 1, 0, 0, 1
    local a = math.floor(x)
    local frac = x - a
    while m10 * a + m11 <= max_den do
        local temp = m00 * a + m01
        m01 = m00; m00 = temp
        temp = m10 * a + m11
        m11 = m10; m10 = temp
        if frac == 0 then break end
        x = 1 / frac
        a = math.floor(x)
        frac = x - a
    end
    return m00, m10
end

local function add_track(c, tinfo, i)
    if not tinfo then return end
    local type = tinfo.image and "Image"
                 or tinfo["type"]:sub(1, 1):upper() .. tinfo["type"]:sub(2)
    append(c, "", {prefix=type .. ":", nl=o.nl .. o.nl, indent=""})
    append(c, tinfo["title"], {prefix_sep="", nl="", indent=""})
    append(c, tinfo["id"], {prefix="ID:"})
    append(c, tinfo["src-id"],
           {prefix="Demuxer ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, tinfo["program-id"],
           {prefix="Program ID:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, tinfo["ff-index"],
           {prefix="FFmpeg Index:", nl="", indent=o.prefix_sep .. o.prefix_sep})
    append(c, tinfo["external-filename"], {prefix="File:"})
    append(c, "", {prefix="Flags:"})
    local flags = {"default", "forced", "dependent", "visual-impaired",
                   "hearing-impaired", "original", "commentary", "image",
                   "albumart", "external"}
    local any = false
    for _, flag in ipairs(flags) do
        if tinfo[flag] then
            append(c, flag, {prefix=any and ", " or "", nl="", indent="",
                             prefix_sep=""})
            any = true
        end
    end
    if not any then table.remove(c) end
    if append(c, tinfo["codec-desc"], {prefix="Codec:"}) then
        append(c, tinfo["codec-profile"],
               {prefix="[", nl="", indent=" ", prefix_sep="",
                no_prefix_markup=true, suffix="]"})
        if tinfo["codec"] ~= tinfo["decoder"] then
            append(c, tinfo["decoder"],
                   {prefix="[", nl="", indent=" ", prefix_sep="",
                    no_prefix_markup=true, suffix="]"})
        end
    end
    append(c, tinfo["lang"], {prefix="Language:"})
    append(c, tinfo["demux-channel-count"], {prefix="Channels:"})
    append(c, tinfo["demux-channels"], {prefix="Channel Layout:"})
    append(c, tinfo["demux-samplerate"], {prefix="Sample Rate:", suffix=" Hz"})
    local function B(b) return b and string.format("%.2f", b / 1024) end
    local bitrate = append(c, B(tinfo["demux-bitrate"]),
                           {prefix="Bitrate:", suffix=" kbps"})
    append(c, B(tinfo["hls-bitrate"]),
           {prefix="HLS Bitrate:", suffix=" kbps", nl=bitrate and "" or o.nl,
            indent=bitrate and o.prefix_sep .. o.prefix_sep})
    append_resolution(c, {w=tinfo["demux-w"], h=tinfo["demux-h"],
                          ["crop-x"]=tinfo["demux-crop-x"],
                          ["crop-y"]=tinfo["demux-crop-y"],
                          ["crop-w"]=tinfo["demux-crop-w"],
                          ["crop-h"]=tinfo["demux-crop-h"]}, "Resolution:")
    if not tinfo["image"] and tinfo["demux-fps"] then
        append_fps(c, "track-list/" .. i .. "/demux-fps", "")
    end
    append(c, tinfo["format-name"], {prefix="Format:"})
    append(c, tinfo["demux-rotation"], {prefix="Rotation:"})
    if tinfo["demux-par"] then
        local num, den = float2rational(tinfo["demux-par"])
        append(c, string.format("%d:%d", num, den), {prefix="Pixel Aspect Ratio:"})
    end
    local track_rg = tinfo["replaygain-track-peak"] ~= nil or
                     tinfo["replaygain-track-gain"] ~= nil
    local album_rg = tinfo["replaygain-album-peak"] ~= nil or
                     tinfo["replaygain-album-gain"] ~= nil
    if track_rg or album_rg then append(c, "", {prefix="Replay Gain:"}) end
    if track_rg then
        append(c, "", {prefix="Track:", indent=o.indent .. o.prefix_sep,
                       prefix_sep=""})
        append(c, tinfo["replaygain-track-gain"],
               {prefix="Gain:", suffix=" dB", nl="", indent=o.prefix_sep})
        append(c, tinfo["replaygain-track-peak"],
               {prefix="Peak:", suffix=" dB", nl="", indent=o.prefix_sep})
    end
    if album_rg then
        append(c, "", {prefix="Album:", indent=o.indent .. o.prefix_sep,
                       prefix_sep=""})
        append(c, tinfo["replaygain-album-gain"],
               {prefix="Gain:", suffix=" dB", nl="", indent=o.prefix_sep})
        append(c, tinfo["replaygain-album-peak"],
               {prefix="Peak:", suffix=" dB", nl="", indent=o.prefix_sep})
    end
    if tinfo["dolby-vision-profile"] or tinfo["dolby-vision-level"] then
        append(c, "", {prefix="Dolby Vision:"})
        append(c, tinfo["dolby-vision-profile"],
               {prefix="Profile:", nl="", indent=""})
        append(c, tinfo["dolby-vision-level"],
               {prefix="Level:", nl="",
                indent=tinfo["dolby-vision-profile"] and
                       o.prefix_sep .. o.prefix_sep or ""})
    end
end

local function track_info()
    local h, c = {}, {}
    eval_ass_formatting()
    add_header(h)
    local desc = pages[o.key_page_5].desc
    append(h, "", {prefix=format("%s:%s", desc, scroll_hint()), nl="", indent=""})
    h = {table.concat(h)}
    table.insert(c, o.nl .. o.nl)
    add_file(c, false, true)
    for i, track in ipairs(mp.get_property_native("track-list")) do
        if track['selected'] or not o.track_info_selected_only then
            add_track(c, track, i - 1)
        end
    end
    return finalize_page(h, c, true)
end

local function perf_stats()
    local header, content = {}, {}
    eval_ass_formatting()
    add_header(header)
    local page = pages[o.key_page_0]
    append(header, "", {prefix=format("%s:%s", page.desc, scroll_hint()),
                        nl="", indent=""})
    append_general_perfdata(content)
    header = {table.concat(header)}
    return finalize_page(header, content, true)
end

local function opt_time(tm)
    if type(tm) == type(1.1) then return mp.format_time(tm) end
    return "?"
end

local function cache_stats()
    local stats = {}
    eval_ass_formatting()
    add_header(stats)
    append(stats, "", {prefix="Cache Info:", nl="", indent=""})
    local info = mp.get_property_native("demuxer-cache-state")
    if info == nil then
        append(stats, "Unavailable.", {})
        return finalize_page({}, stats, false)
    end
    local a = info["reader-pts"]
    local b = info["cache-end"]
    append(stats, opt_time(a) .. " - " .. opt_time(b), {prefix = "Packet Queue:"})
    local r = nil
    if a ~= nil and b ~= nil then r = b - a end
    local r_graph = nil
    if not display_timer.oneshot and o.use_ass and o.plot_cache then
        r_graph = generate_graph(cache_ahead_buf, cache_ahead_buf.pos,
                                 cache_ahead_buf.len, cache_ahead_buf.max,
                                 nil, 0.8, 1)
        r_graph = o.prefix_sep .. r_graph
    end
    append(stats, opt_time(r), {prefix = "Readahead:", suffix = r_graph})
    local state = "reading"
    local seek_ts = info["debug-seeking"]
    if seek_ts ~= nil then state = "seeking (to " .. mp.format_time(seek_ts) .. ")"
    elseif info["eof"] == true then state = "eof"
    elseif info["underrun"] then state = "underrun"
    elseif info["idle"] == true then state = "inactive" end
    append(stats, state, {prefix = "State:"})
    local speed = info["raw-input-rate"] or 0
    local speed_graph = nil
    if not display_timer.oneshot and o.use_ass and o.plot_cache then
        speed_graph = generate_graph(cache_speed_buf, cache_speed_buf.pos,
                                     cache_speed_buf.len, cache_speed_buf.max,
                                     nil, 0.8, 1)
        speed_graph = o.prefix_sep .. speed_graph
    end
    append(stats, utils.format_bytes_humanized(speed) .. "/s",
           {prefix="Speed:", suffix=speed_graph})
    append(stats, utils.format_bytes_humanized(info["total-bytes"]),
           {prefix = "Total RAM:"})
    append(stats, utils.format_bytes_humanized(info["fw-bytes"]),
           {prefix = "Forward RAM:"})
    local fc = info["file-cache-bytes"]
    fc = fc ~= nil and utils.format_bytes_humanized(fc) or "(disabled)"
    append(stats, fc, {prefix = "Disk Cache:"})
    append(stats, info["debug-low-level-seeks"], {prefix = "Media Seeks:"})
    append(stats, info["debug-byte-level-seeks"], {prefix = "Stream Seeks:"})
    append(stats, "", {prefix="Ranges:", nl=o.nl .. o.nl, indent=""})
    append(stats, info["bof-cached"] and "yes" or "no", {prefix = "Start Cached:"})
    append(stats, info["eof-cached"] and "yes" or "no", {prefix = "End Cached:"})
    local ranges = info["seekable-ranges"] or {}
    for n, range in ipairs(ranges) do
        append(stats, mp.format_time(range["start"]) .. " - " ..
                      mp.format_time(range["end"]),
               {prefix = "Range " .. n .. ":"})
    end
    return finalize_page({}, stats, false)
end

local function record_cache_stats()
    local info = mp.get_property_native("demuxer-cache-state")
    if info == nil then return end
    local a = info["reader-pts"]
    local b = info["cache-end"]
    if a ~= nil and b ~= nil then graph_add_value(cache_ahead_buf, b - a) end
    graph_add_value(cache_speed_buf, info["raw-input-rate"] or 0)
end

cache_recorder_timer = mp.add_periodic_timer(0.25, record_cache_stats)
cache_recorder_timer:kill()

-- 页面定义（desc 用 t() 翻译）
curr_page = o.key_page_1
pages = {
    [o.key_page_1] = { idx = 1, f = default_stats, desc = t("Default") },
    [o.key_page_2] = { idx = 2, f = vo_stats,
                       desc = t("Extended Frame Timings"), scroll = true },
    [o.key_page_3] = { idx = 3, f = cache_stats,
                       desc = t("Cache Statistics") },
    [o.key_page_4] = { idx = 4, f = keybinding_info,
                       desc = t("Active Key Bindings"), scroll = true },
    [o.key_page_5] = { idx = 5, f = track_info,
                       desc = t("Tracks Info"), scroll = true },
    [o.key_page_0] = { idx = 0, f = perf_stats,
                       desc = t("Internal Performance Info"), scroll = true },
}

local function record_data(skip)
    init_buffers()
    skip = max(skip, 0)
    local i = skip
    return function()
        if i < skip then i = i + 1; return else i = 0 end
        if o.plot_vsync_jitter then
            local r = mp.get_property_number("vsync-jitter")
            if r then
                vsjitter_buf.pos = (vsjitter_buf.pos % vsjitter_buf.len) + 1
                vsjitter_buf[vsjitter_buf.pos] = r
                vsjitter_buf.max = max(vsjitter_buf.max, r)
            end
        end
        if o.plot_vsync_ratio then
            local r = mp.get_property_number("vsync-ratio")
            if r then
                vsratio_buf.pos = (vsratio_buf.pos % vsratio_buf.len) + 1
                vsratio_buf[vsratio_buf.pos] = r
                vsratio_buf.max = max(vsratio_buf.max, r)
            end
        end
    end
end

local function print_page(page, after_scroll)
    local ass_content = pages[page].f(after_scroll)
    if o.persistent_overlay then
        mp.set_osd_ass(0, 0, ass_content)
    else
        mp.osd_message((o.use_ass and ass_start or "") .. ass_content,
                       display_timer.oneshot and o.duration or o.redraw_delay + 1)
    end
end

update_scale = function ()
    local scale_with_video
    if o.vidscale == "auto" then
        scale_with_video = mp.get_property_native("osd-scale-by-window")
    else
        scale_with_video = o.vidscale == "yes"
    end
    local scale = 288 / 720
    local osd_height = mp.get_property_native("osd-height")
    if not scale_with_video and osd_height > 0 then scale = 288 / osd_height end
    font_size = o.font_size * scale
    border_size = o.border_size * scale
    shadow_x_offset = o.shadow_x_offset * scale
    shadow_y_offset = o.shadow_y_offset * scale
    plot_bg_border_width = o.plot_bg_border_width * scale
    if display_timer:is_enabled() then print_page(curr_page) end
end

local function clear_screen()
    if o.persistent_overlay then mp.set_osd_ass(0, 0, "")
    else mp.osd_message("", 0) end
end

local function scroll_delta(d)
    if display_timer.oneshot then
        display_timer:kill(); display_timer:resume()
    end
    pages[curr_page].offset = (pages[curr_page].offset or 1) + d
    print_page(curr_page, true)
end
local function scroll_up() scroll_delta(-o.scroll_lines) end
local function scroll_down() scroll_delta(o.scroll_lines) end

local function reset_scroll_offsets()
    for _, page in pairs(pages) do page.offset = nil end
end
local function bind_scroll()
    if not scroll_bound then
        mp.add_forced_key_binding(o.key_scroll_up, "__forced_" .. o.key_scroll_up,
                                  scroll_up, {repeatable=true})
        mp.add_forced_key_binding(o.key_scroll_down, "__forced_" .. o.key_scroll_down,
                                  scroll_down, {repeatable=true})
        scroll_bound = true
    end
end
local function unbind_scroll()
    if scroll_bound then
        mp.remove_key_binding("__forced_"..o.key_scroll_up)
        mp.remove_key_binding("__forced_"..o.key_scroll_down)
        scroll_bound = false
    end
end

local add_page_bindings
local remove_page_bindings

local function filter_bindings()
    input.get({
        prompt = "Filter bindings:",
        opened = function ()
            searched_text = ""
            remove_page_bindings()
            bind_scroll()
        end,
        edited = function (text)
            reset_scroll_offsets()
            searched_text = text:lower()
            print_page(curr_page)
            if display_timer.oneshot then
                display_timer:kill(); display_timer:resume()
            end
        end,
        closed = function ()
            searched_text = nil
            if display_timer:is_enabled() then
                add_page_bindings()
                print_page(curr_page)
                if display_timer.oneshot then
                    display_timer:kill(); display_timer:resume()
                end
            end
        end,
    })
end

local function bind_search()
    mp.add_forced_key_binding(o.key_search, "__forced_"..o.key_search, filter_bindings)
end
local function unbind_search()
    mp.remove_key_binding("__forced_"..o.key_search)
end

local function bind_exit()
    if not display_timer.oneshot then
        mp.add_forced_key_binding(o.key_exit, "__forced_" .. o.key_exit,
            function () process_key_binding(false) end)
    end
end
local function unbind_exit()
    mp.remove_key_binding("__forced_" .. o.key_exit)
end

local function update_scroll_bindings(k)
    if pages[k].scroll then bind_scroll() else unbind_scroll() end
    if k == o.key_page_4 then bind_search() else unbind_search() end
end

add_page_bindings = function()
    local function a(k)
        return function()
            reset_scroll_offsets()
            update_scroll_bindings(k)
            curr_page = k
            print_page(k)
            if display_timer.oneshot then
                display_timer:kill(); display_timer:resume()
            end
        end
    end
    for k, _ in pairs(pages) do
        mp.add_forced_key_binding(k, "__forced_"..k, a(k), {repeatable=true})
    end
    update_scroll_bindings(curr_page)
    bind_exit()
end

remove_page_bindings = function()
    for k, _ in pairs(pages) do
        mp.remove_key_binding("__forced_"..k)
    end
    unbind_scroll()
    unbind_search()
    unbind_exit()
end

process_key_binding = function(oneshot)
    reset_scroll_offsets()
    if display_timer:is_enabled() then
        if display_timer.oneshot and oneshot then
            display_timer:kill()
            print_page(curr_page)
            display_timer:resume()
        elseif not display_timer.oneshot and not oneshot then
            display_timer:kill()
            cache_recorder_timer:stop()
            if tm_viz_prev ~= nil then
                mp.set_property_native("tone-mapping-visualize", tm_viz_prev)
                tm_viz_prev = nil
            end
            clear_screen()
            remove_page_bindings()
            if recorder then
                mp.unobserve_property(recorder)
                recorder = nil
            end
        end
    else
        if not oneshot and (o.plot_vsync_jitter or o.plot_vsync_ratio) then
            recorder = record_data(o.skip_frames)
            mp.observe_property("vsync-jitter", "none", recorder)
        end
        if not oneshot and o.plot_tonemapping_lut then
            tm_viz_prev = mp.get_property_native("tone-mapping-visualize")
            mp.set_property_native("tone-mapping-visualize", true)
        end
        if not oneshot then
            cache_ahead_buf = {0, pos = 1, len = 50, max = 0}
            cache_speed_buf = {0, pos = 1, len = 50, max = 0}
            cache_recorder_timer:resume()
        end
        display_timer:kill()
        display_timer.oneshot = oneshot
        display_timer.timeout = oneshot and o.duration or o.redraw_delay
        add_page_bindings()
        print_page(curr_page)
        display_timer:resume()
    end
end

display_timer = mp.add_periodic_timer(o.duration, function()
    if display_timer.oneshot then
        display_timer:kill()
        clear_screen()
        remove_page_bindings()
        if searched_text then input.terminate() end
    else
        print_page(curr_page)
    end
end)
display_timer:kill()

mp.add_key_binding(nil, "display-stats",
    function() process_key_binding(true) end, {repeatable=true})
mp.add_key_binding(nil, "display-stats-toggle",
    function() process_key_binding(false) end, {repeatable=false})

for k, page in pairs(pages) do
    mp.add_key_binding(nil, "display-page-" .. page.idx, function()
        curr_page = k
        process_key_binding(true)
    end, {repeatable=true})
    mp.add_key_binding(nil, "display-page-" .. page.idx .. "-toggle", function()
        curr_page = k
        process_key_binding(false)
    end, {repeatable=false})
end

mp.register_event("video-reconfig", function()
    if display_timer:is_enabled() and not display_timer.oneshot then
        print_page(curr_page)
    end
end)

if o.bindlist ~= "no" then
    mp.set_property("msg-level", "all=no,statusline=status")
    mp.set_property("term-osd", "force")
    mp.set_property_bool("msg-module", false)
    mp.set_property_bool("msg-time", false)
    mp.add_timeout(0, function()
        if o.bindlist:sub(1, 1) == "-" then
            o.no_ass_b0 = ""
            o.no_ass_b1 = ""
        end
        o.ass_formatting = false
        o.no_ass_indent = " "
        mp.osd_message(keybinding_info(false, true))
        mp.add_timeout(0, function()
            mp.command("flush-status-line no")
            mp.command("quit")
        end)
    end)
end

mp.observe_property("osd-height", "native", update_scale)
mp.observe_property("osd-scale-by-window", "native", update_scale)

local function update_property_cache(name, value)
    property_cache[name] = value
end
mp.observe_property('current-window-scale', 'native', update_property_cache)
mp.observe_property('display-names', 'string', update_property_cache)
mp.observe_property('hwdec-current', 'string', update_property_cache)

-- ============================================================
-- 包装 append：调用 auto_translate_text
-- ============================================================
local original_append = append
append = function(s, str, attr)
    str = auto_translate_text(str)
    if attr then
        attr.prefix = auto_translate_text(attr.prefix)
        attr.suffix = auto_translate_text(attr.suffix)
    end
    return original_append(s, str, attr)
end

-- ============================================================
-- CPU/GPU 占用率模块
-- ============================================================
local cpu_usage = "N/A"
local gpu_usages = {}
local cpu_name = nil
local gpu_names = {}
local hw_detected = false
local sys_lang = nil
local nvidia_smi_usage = nil
local stats_refresh_timer = nil
local update_counter = 0

local function run_async(cmd_args, callback)
    mp.command_native_async({
        name = "subprocess",
        args = cmd_args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, res)
        if callback then
            callback(success, res and (res.stdout or "") or "",
                     res and (res.stderr or "") or "")
        end
    end)
end

local function refresh_display()
    if display_timer and display_timer:is_enabled() and curr_page then
        print_page(curr_page)
    end
end

local function detect_sys_lang(callback)
    if sys_lang then callback(sys_lang); return end
    run_async({"typeperf", "-q", "Processor"}, function(success, stdout)
        if success and stdout:match("Processor") then
            sys_lang = "en"; callback("en"); return
        end
        run_async({"typeperf", "-q", "处理器"}, function(success2, stdout2)
            if success2 and stdout2:match("处理器") then
                sys_lang = "zh"; callback("zh")
            else
                sys_lang = "en"; callback("en")
            end
        end)
    end)
end

local virtual_keywords = {
    "virtual", "remote", "hyper", "microsoft basic", "basic render",
    "standard vga", "vms3d", "vmware", "parallels", "citrix", "rdp",
    "wddm", "render only", "oray", "sunflower", "向日葵",
}
local function is_virtual_gpu(name)
    if not name then return true end
    local lower = name:lower()
    for _, kw in ipairs(virtual_keywords) do
        if lower:find(kw, 1, true) then return true end
    end
    return false
end

local function is_integrated_gpu(name)
    if not name then return false end
    local lower = name:lower()
    if lower:find("nvidia") or lower:find("geforce") or
       lower:find("rtx") or lower:find("gtx") then return false end
    if lower:find("arc") then return false end
    if lower:find("radeon") then
        if lower:find("rx ") then return false end
        return true
    end
    if lower:find("uhd") or lower:find("iris") or lower:find("hd graphics") then
        return true
    end
    return false
end

local function is_nvidia_gpu(name)
    if not name then return false end
    local lower = name:lower()
    return lower:find("nvidia") or lower:find("geforce") or
           lower:find("rtx") or lower:find("gtx")
end

local function detect_hardware()
    if hw_detected then return end
    hw_detected = true
    if mp.get_property("platform", "unknown") ~= "windows" then return end

    run_async({"powershell", "-NoProfile", "-Command",
               "(Get-CimInstance Win32_Processor).Name"}, function(success, stdout)
        if success then
            local name = stdout:match("^(.-)[\r\n]*$")
            if name and #name > 0 then
                cpu_name = name:gsub("^%s+", ""):gsub("%s+$", "")
                refresh_display()
            end
        end
    end)

    run_async({"powershell", "-NoProfile", "-Command",
               "Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name"},
              function(success, stdout)
        local found = {}
        if success then
            for name in stdout:gmatch("[^\r\n]+") do
                name = name:gsub("^%s+", ""):gsub("%s+$", "")
                if #name > 0 and not is_virtual_gpu(name) then
                    local dup = false
                    for _, n in ipairs(found) do
                        if n == name then dup = true; break end
                    end
                    if not dup then table.insert(found, name) end
                end
            end
        end
        if #found > 0 then
            gpu_names = found
            table.sort(gpu_names, function(a, b)
                if is_integrated_gpu(a) ~= is_integrated_gpu(b) then
                    return is_integrated_gpu(a)
                end
                return false
            end)
            for _, n in ipairs(gpu_names) do gpu_usages[n] = "N/A" end
            refresh_display()
        end
    end)
end

local function update_cpu_cim(callback)
    run_async({"powershell", "-NoProfile", "-Command",
               "(Get-CimInstance Win32_Processor).LoadPercentage"},
              function(success, stdout)
        if success then
            local load = stdout:match("(%d+)")
            if load and tonumber(load) and tonumber(load) <= 100 then
                callback(load); return
            end
        end
        callback(nil)
    end)
end

local function update_cpu_typeperf(callback)
    detect_sys_lang(function(lang)
        local counter = lang == "zh"
            and "\\处理器(_Total)\\%% 处理器时间"
            or "\\Processor(_Total)\\%% Processor Time"
        run_async({"typeperf", counter, "-sc", "1"}, function(success, stdout)
            if success then
                local load = stdout:match(",\"(%d+%.?%d*)\"")
                if load and tonumber(load) and tonumber(load) <= 100 then
                    callback(load); return
                end
            end
            callback(nil)
        end)
    end)
end

local cpu_probes = { update_cpu_cim, update_cpu_typeperf }
local function try_cpu_probe(i)
    if i > #cpu_probes then
        cpu_usage = "N/A"; refresh_display(); return
    end
    cpu_probes[i](function(v)
        if v then
            cpu_usage = v .. "%"; refresh_display()
        else
            try_cpu_probe(i + 1)
        end
    end)
end

local function update_cpu()
    local os_name = mp.get_property("platform", "unknown")
    if os_name == "windows" then
        try_cpu_probe(1)
    elseif os_name == "linux" then
        run_async({"sh", "-c", "top -bn1 | grep 'Cpu(s)' | awk '{print $2}'"},
                  function(success, stdout)
            if success then
                local load = stdout:match("(%d+%.?%d*)")
                cpu_usage = load and (load .. "%") or "N/A"
            else
                cpu_usage = "N/A"
            end
            refresh_display()
        end)
    elseif os_name == "darwin" then
        run_async({"ps", "-A", "-o", "%cpu"}, function(success, stdout)
            if success then
                local total = 0
                for line in stdout:gmatch("[^\r\n]+") do
                    local num = line:match("^(%d+%.?%d*)")
                    if num then total = total + tonumber(num) end
                end
                cpu_usage = total > 0 and string.format("%.1f%%", total) or "N/A"
            else
                cpu_usage = "N/A"
            end
            refresh_display()
        end)
    end
end

local function apply_gpu_usage_map(gpu_map, fmt)
    if not gpu_map then return false end
    local luid_data, luid_order = {}, {}
    for engine_name, util in pairs(gpu_map) do
        local luid = engine_name:match("luid_(0x%x+_0x%x+)") or "unknown"
        if not luid_data[luid] then
            luid_data[luid] = { max_val = 0, val_3d = 0, has_3d = false, eng_types = {} }
            luid_order[#luid_order + 1] = luid
        end
        local val = tonumber(util)
        if val and val >= 0 and val <= 100 then
            if val > luid_data[luid].max_val then luid_data[luid].max_val = val end
            local etype = engine_name:match("engtype_(.+)$")
            if etype then luid_data[luid].eng_types[etype:lower()] = true end
            if engine_name:lower():find("engtype_3d", 1, true) then
                if not luid_data[luid].has_3d or val > luid_data[luid].val_3d then
                    luid_data[luid].has_3d = true
                    luid_data[luid].val_3d = val
                end
            end
        end
    end
    local filtered = {}
    for _, luid in ipairs(luid_order) do
        local types = luid_data[luid].eng_types
        local non_3d = false
        for tp in pairs(types) do
            if tp ~= "3d" then non_3d = true; break end
        end
        if non_3d or not next(types) then filtered[#filtered + 1] = luid end
    end
    luid_order = filtered
    if #luid_order == 0 then return false end
    local luid_utils = {}
    for i, luid in ipairs(luid_order) do
        local d = luid_data[luid]
        luid_utils[i] = { util = d.has_3d and d.val_3d or d.max_val }
    end
    local nvidia_luid_idx = nil
    local nv_ref = nvidia_smi_usage
    if not nv_ref then
        for _, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) and gpu_usages[gname] then
                local prev = tonumber(gpu_usages[gname]:match("(%d+)"))
                if prev then nv_ref = prev; break end
            end
        end
    end
    if nv_ref and #luid_utils > 1 then
        local nv_val = tonumber(nv_ref)
        if nv_val then
            local best_diff = math.huge
            for i, lu in ipairs(luid_utils) do
                local diff = math.abs(lu.util - nv_val)
                if diff < best_diff then best_diff = diff; nvidia_luid_idx = i end
            end
            if best_diff > 15 then nvidia_luid_idx = nil end
        end
    end
    if not nvidia_luid_idx and #luid_utils == 1 then
        for _, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) then nvidia_luid_idx = 1; break end
        end
    end
    if not nvidia_luid_idx and #luid_utils > 1 then
        for _, gname in ipairs(gpu_names) do
            if is_nvidia_gpu(gname) then
                local max_util = -1
                for i, lu in ipairs(luid_utils) do
                    if lu.util > max_util then max_util = lu.util; nvidia_luid_idx = i end
                end
                break
            end
        end
    end
    local non_nv_names = {}
    for _, gname in ipairs(gpu_names) do
        if not is_nvidia_gpu(gname) then
            non_nv_names[#non_nv_names + 1] = gname
        end
    end
    local updated = false
    local non_nv_idx = 1
    for i, lu in ipairs(luid_utils) do
        if i ~= nvidia_luid_idx then
            if non_nv_idx <= #non_nv_names then
                local gname = non_nv_names[non_nv_idx]
                gpu_usages[gname] = fmt and string.format(fmt, lu.util)
                                   or (tostring(lu.util) .. "%")
                updated = true
                non_nv_idx = non_nv_idx + 1
            elseif #gpu_names == 0 then
                gpu_usages["__total__"] = fmt and string.format(fmt, lu.util)
                                        or (tostring(lu.util) .. "%")
                updated = true
            end
        end
    end
    return updated
end

local function update_gpu_nvidia(callback)
    run_async({"nvidia-smi", "--query-gpu=utilization.gpu",
               "--format=csv,noheader,nounits"}, function(success, stdout)
        if success then
            local load = stdout:match("(%d+)")
            if load and tonumber(load) and tonumber(load) <= 100 then
                callback(load); return
            end
        end
        callback(nil)
    end)
end

local function update_gpu_cim(callback)
    run_async({"powershell", "-NoProfile", "-Command",
               "Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine | ForEach-Object { Write-Output ($_.Name + '|' + $_.UtilizationPercentage) }"},
              function(success, stdout)
        if success then
            local engines = {}
            for line in stdout:gmatch("[^\r\n]+") do
                local name, util = line:match("^(.-)|(%d+)$")
                if name and util then
                    local val = tonumber(util)
                    if val and val >= 0 and val <= 100 then
                        name = name:gsub("^%s+", ""):gsub("%s+$", "")
                        engines[name] = val
                    end
                end
            end
            if next(engines) then callback(engines); return end
        end
        callback(nil)
    end)
end

local function update_gpu()
    local os_name = mp.get_property("platform", "unknown")
    if os_name == "windows" then
        update_gpu_nvidia(function(load)
            if load then
                nvidia_smi_usage = tonumber(load) or nil
                local found_nv = false
                for _, gname in ipairs(gpu_names) do
                    if is_nvidia_gpu(gname) then
                        gpu_usages[gname] = load .. "%"
                        found_nv = true
                    end
                end
                if not found_nv and #gpu_names == 0 then
                    gpu_usages["__total__"] = load .. "%"
                end
                refresh_display()
            else
                nvidia_smi_usage = nil
            end
            update_gpu_cim(function(result)
                if result and type(result) == "table" then
                    apply_gpu_usage_map(result, "%.0f%%")
                else
                    for _, gname in ipairs(gpu_names) do
                        if not gpu_usages[gname] or gpu_usages[gname] == "N/A" then
                            gpu_usages[gname] = "N/A"
                        end
                    end
                end
                refresh_display()
            end)
        end)
    elseif os_name == "linux" then
        run_async({"nvidia-smi", "--query-gpu=utilization.gpu",
                   "--format=csv,noheader,nounits"}, function(success, stdout)
            if success then
                local load = stdout:match("(%d+)")
                if load then
                    gpu_usages["__total__"] = load .. "%"
                    refresh_display(); return
                end
            end
            run_async({"sh", "-c",
                       "radeontop --dump - | grep 'gpu' | awk '{print $2}' | head -1"},
                      function(success2, stdout2)
                if success2 then
                    local load2 = stdout2:match("(%d+%.?%d*)")
                    if load2 then
                        gpu_usages["__total__"] =
                            string.format("%.0f%%", tonumber(load2))
                        refresh_display(); return
                    end
                end
                gpu_usages["__total__"] = "N/A"
                refresh_display()
            end)
        end)
    elseif os_name == "darwin" then
        run_async({"sh", "-c",
                   "ioreg -l | grep PerformanceStatistics | grep GPU | head -1"},
                  function(success, stdout)
            if success then
                local load = stdout:match("GPU Activity Factor = (%d+)")
                gpu_usages["__total__"] = load and (load .. "%") or "N/A"
            else
                gpu_usages["__total__"] = "N/A"
            end
            refresh_display()
        end)
    end
end

-- 包装 add_file，追加 CPU/GPU 行
local original_add_file = add_file
add_file = function(s, print_cache, print_tags)
    original_add_file(s, print_cache, print_tags)

    if not hw_detected then detect_hardware() end
    if cpu_usage == "N/A" then
        update_counter = update_counter + 1
        if update_counter % 3 == 0 then update_gpu() end
        update_cpu()
    end

    local cpu_display = cpu_usage ~= "N/A" and cpu_usage or "--%"
    local cpu_line = t("CPU:") .. " " .. string.format("%4s", cpu_display)
    if cpu_name then
        cpu_line = cpu_line .. "  " .. t("Model:") .. " " .. cpu_name
    end
    append(s, cpu_line, {nl=o.nl, prefix="", prefix_sep=""})

    if #gpu_names > 0 then
        for _, gname in ipairs(gpu_names) do
            local gutil = gpu_usages[gname] or "N/A"
            local gpu_display = gutil ~= "N/A" and gutil or "--%"
            append(s, t("GPU:") .. " " .. string.format("%4s", gpu_display)
                   .. "  " .. t("Model:") .. " " .. gname,
                   {nl=o.nl, prefix="", prefix_sep=""})
        end
    elseif gpu_usages["__total__"] then
        local gpu_display = gpu_usages["__total__"] ~= "N/A"
            and gpu_usages["__total__"] or "--%"
        append(s, t("GPU:") .. " " .. string.format("%4s", gpu_display),
               {nl=o.nl, prefix="", prefix_sep=""})
    else
        append(s, t("GPU:") .. " " .. string.format("%4s", "--%"),
               {nl=o.nl, prefix="", prefix_sep=""})
    end
end

local function refresh_stats()
    if display_timer and display_timer:is_enabled() then
        update_counter = update_counter + 1
        if update_counter % 3 == 0 then update_gpu() end
        update_cpu()
    end
end

-- 包装 process_key_binding 管理 CPU/GPU 定时器
local original_process_key_binding = process_key_binding
process_key_binding = function(oneshot)
    original_process_key_binding(oneshot)
    if display_timer and display_timer:is_enabled() then
        if not stats_refresh_timer then
            stats_refresh_timer = mp.add_periodic_timer(o.refresh_interval, refresh_stats)
            mp.add_timeout(0.1, refresh_stats)
        end
    else
        if stats_refresh_timer then
            stats_refresh_timer:stop()
            stats_refresh_timer = nil
            update_counter = 0
        end
    end
end

local original_remove_page_bindings = remove_page_bindings
remove_page_bindings = function()
    original_remove_page_bindings()
    if stats_refresh_timer then
        stats_refresh_timer:stop()
        stats_refresh_timer = nil
        update_counter = 0
    end
end

mp.register_event("file-loaded", function()
    cpu_usage = "N/A"
    for k, _ in pairs(gpu_usages) do gpu_usages[k] = "N/A" end
    update_counter = 0
end)