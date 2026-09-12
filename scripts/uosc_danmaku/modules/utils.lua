local msg = require("mp.msg")
local utils = require("mp.utils")
local unpack = unpack or table.unpack

function get_str_width(text, font_size)
    local w = 0
    for i = 1, #text do
        local b = text:byte(i)
        if b < 0x80 then
            w = w + 1
        elseif b >= 0xC0 then
            w = w + 2
        end
    end
    return w * font_size / 2
end

function unicode_to_utf8(unicode)
    if unicode < 0x80 then
        return string.char(unicode)
    end
    local byte_count
    if unicode < 0x800 then
        byte_count = 2
    elseif unicode < 0x10000 then
        byte_count = 3
    elseif unicode < 0x110000 then
        byte_count = 4
    else
        return
    end

    local res = {}
    local shift = 2 ^ 6
    local after_shift = unicode
    for _ = byte_count, 2, -1 do
        local before_shift = after_shift
        after_shift = math.floor(before_shift / shift)
        table.insert(res, 1, before_shift - after_shift * shift + 0x80)
    end
    shift = 2 ^ (8 - byte_count)
    table.insert(res, 1, after_shift + math.floor(0xFF / shift) * shift)
    ---@diagnostic disable-next-line: deprecated
    return string.char(unpack(res))
end

function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

function itable_index_of(itable, value)
    for index = 1, #itable do
        if itable[index] == value then
            return index
        end
    end
end

function shallow_copy(original)
    if type(original) ~= "table" then
        return original
    end
    local copy = {}
    for k, v in pairs(original) do
        copy[k] = v
    end
    return copy
end

function remove_query(url)
    local qpos = string.find(url, "?", 1, true)
    if qpos then
        return string.sub(url, 1, qpos - 1)
    end
    return url
end

function file_exists(path)
    if path then
        local meta = utils.file_info(path)
        return meta and meta.is_file
    end
    return false
end

function read_file(file_path)
    local file = io.open(file_path, "r")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

function write_json_file(file_path, data)
    local file = io.open(file_path, "w")
    if not file then
        msg.error("无法写入文件: " .. file_path)
        return
    end
    local ok, err = file:write(utils.format_json(data))
    if not ok then msg.error("写入失败: " .. tostring(err)) end
    file:close()
end

function binary_search(tbl, target, key)
    if not tbl or #tbl == 0 then return 1 end
    key = key or function(x) return x end
    local lo, hi = 1, #tbl
    local res = #tbl + 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local v = tbl[mid]
        local val = key(v)
        if val >= target then
            res = mid
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    return res
end

function new_min_heap()
    local h = {}
    local function swap(i, j) h[i], h[j] = h[j], h[i] end
    local function up(i)
        while i > 1 do
            local p = math.floor(i / 2)
            if h[p].time <= h[i].time then break end
            swap(p, i)
            i = p
        end
    end
    local function down(i)
        local n = #h
        while true do
            local l = i * 2
            local r = l + 1
            local smallest = i
            if l <= n and h[l].time < h[smallest].time then smallest = l end
            if r <= n and h[r].time < h[smallest].time then smallest = r end
            if smallest == i then break end
            swap(i, smallest)
            i = smallest
        end
    end
    return {
        push = function(node)
            h[#h + 1] = node
            up(#h)
        end,
        pop = function()
            if #h == 0 then return nil end
            local root = h[1]
            if #h == 1 then h[1] = nil; return root end
            h[1] = h[#h]
            h[#h] = nil
            down(1)
            return root
        end,
        size = function() return #h end,
    }
end

function normalize(path)
    local success, result = pcall(mp.command_native, {"expand-path", path})
    if success and result then
        return result
    end
    return path
end

function get_parent_directory(path)
    if path and not is_protocol(path) then
        path = normalize(path)
        return utils.split_path(path)
    end
    return nil
end