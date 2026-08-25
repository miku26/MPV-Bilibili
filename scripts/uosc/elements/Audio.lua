-- elements/Audio.lua
local Element = require('elements/Element')

---@class Audio : Element
local Audio = class(Element)

function Audio:new(id, props)
    return Class.new(self, id, props)
end

function Audio:init(id, props)
    Element.init(self, id, props)
    self.tooltip = props.tooltip or '音轨'
    self.panel_open = false
    self.hide_timer = nil
    self.track_list = mp.get_property_native('track-list') or {}
    self.font_size = 0
    self._panel_rect = nil
    self.scroll_y = 0
    self.content_height = 0
    self.is_dragging = false
    self.drag_start_y = 0
    self.drag_start_scroll = 0

    self:observe_mp_property('track-list', 'native', function()
        self.track_list = mp.get_property_native('track-list') or {}
        self.scroll_y = 0
        self._panel_rect = nil
        request_render()
    end)
end

function Audio:on_coordinates()
    self.font_size = round((self.by - self.ay) * 0.7)
end

function Audio:on_display()
    self._panel_rect = nil
    request_render()
end

-- 获取轨道左侧显示文本（编号或标题）
function Audio:get_left_text(track)
    if track.title and track.title ~= '' then
        return track.title
    else
        return '音轨 ' .. track.id
    end
end

-- 获取轨道右侧属性字符串（不含左侧内容）
function Audio:get_right_text(track)
    local parts = {}
    if track.lang then table.insert(parts, track.lang) end
    local codec = track.codec or track['demux-codec']
    if codec then table.insert(parts, codec) end
    if track['audio-channels'] then
        table.insert(parts, track['audio-channels'] .. '声道')
    end
    if track['demux-samplerate'] then
        table.insert(parts, (track['demux-samplerate'] / 1000) .. 'kHz')
    end
    if track.default then table.insert(parts, '默认') end
    if track.forced then table.insert(parts, '强制') end
    return table.concat(parts, ', ')
end

function Audio:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    local ass = assdraw.ass_new()
    local is_hover_button = self.proximity_raw <= 0
    local center_x = (self.ax + self.bx) / 2
    local center_y = (self.ay + self.by) / 2
    local icon_size = round((self.by - self.ay) * 0.7)

    if is_hover_button then
        ass:rect(self.ax, self.ay, self.bx, self.by, {
            color = fg,
            opacity = 0.3,
            radius = state.radius
        })
    end

    ass:icon(center_x, center_y, icon_size, 'audiotrack', {
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
    })

    if is_hover_button and not self.panel_open then
        self:open_panel()
    end

    local panel_rect = nil
    if self.panel_open then
        if not self._panel_rect then
            self._panel_rect = self:get_panel_rect()
        end
        panel_rect = self._panel_rect
        local is_hover_panel = get_point_to_rectangle_proximity(cursor, panel_rect) <= 0

        if is_hover_button or is_hover_panel then
            if self.hide_timer then
                self.hide_timer:kill()
                self.hide_timer = nil
            end
        else
            if not self.hide_timer then
                self.hide_timer = mp.add_timeout(0.1, function()
                    self:close_panel()
                end)
            end
        end

        self:draw_panel(ass, panel_rect)
    end

    return ass
end

function Audio:open_panel()
    if not self.panel_open then
        self.panel_open = true
        Elements:set_min_visibility(1, {'controls'})
        if self.hide_timer then
            self.hide_timer:kill()
            self.hide_timer = nil
        end
        self._panel_rect = nil
        self.scroll_y = 0
        request_render()
    end
end

function Audio:close_panel()
    self.panel_open = false
    Elements:set_min_visibility(0, {'controls'})
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    self._panel_rect = nil
    self.is_dragging = false
    request_render()
end

function Audio:get_panel_rect()
    local button_height = self.by - self.ay

    local padding_h = 30       -- 左右内边距
    local padding_v = 15       -- 上下内边距
    local gap_between = 20     -- 左右文本之间的间距
    local row_height = math.max(38, round(button_height * 0.85))

    local max_height = display.height * 0.6
    local audio_tracks = itable_filter(self.track_list, function(t) return t.type == 'audio' end)
    local total_items = #audio_tracks + 1   -- 加“加载音轨”行
    self.content_height = total_items * row_height

    local final_height = math.min(self.content_height + padding_v * 2, max_height)
    local scroll_enabled = self.content_height > (final_height - padding_v * 2)
    local max_scroll = math.max(0, self.content_height - (final_height - padding_v * 2))
    self.scroll_y = math.max(0, math.min(self.scroll_y, max_scroll))

    local font_size = row_height * 0.7
    local icon_size = font_size
    local icon_gap = 8

    local current_audio_id = mp.get_property_native('audio')

    -- 遍历所有轨道，计算左侧最大宽度（含图标）和右侧最大宽度
    local max_left_total = 0
    local max_right_width = 0

    for _, track in ipairs(audio_tracks) do
        local left_text = self:get_left_text(track)
        local left_width = text_width(left_text, {size = font_size, bold = false})
        local is_active = (track.id == current_audio_id)
        local left_total = left_width + (is_active and (icon_size + icon_gap) or 0)
        if left_total > max_left_total then max_left_total = left_total end

        local right_text = self:get_right_text(track)
        local right_width = text_width(right_text, {size = font_size, bold = false})
        if right_width > max_right_width then max_right_width = right_width end
    end

    -- 处理“加载音轨”行（图标在右，不占左侧宽度）
    local load_left_text = '加载音轨'
    local load_left_width = text_width(load_left_text, {size = font_size, bold = false})
    local load_left_total = load_left_width  -- 图标移到右侧，不占用左侧宽度
    if load_left_total > max_left_total then max_left_total = load_left_total end

    -- 确保最小宽度
    max_left_total = math.max(max_left_total, 100)
    max_right_width = math.max(max_right_width, 0)

    -- 总宽度 = 左内边距 + 最大左总宽 + 间距 + 最大右宽 + 右内边距
    local total_width = padding_h + max_left_total + gap_between + max_right_width + padding_h

    -- 限制最大宽度（避免太宽）
    local max_total_width = display.width * 0.7
    if total_width > max_total_width then
        total_width = max_total_width
        -- 若宽度受限，则可能需要调整滚动或缩小间距，但这里简单截断
    end

    local center_x = (self.ax + self.bx) / 2
    local panel_x = center_x - total_width / 2
    local timeline_ay = Elements:v('timeline', 'ay', display.height)
	local timeline_enabled = Elements.timeline and Elements.timeline.enabled
	local panel_y
	if timeline_enabled then
		panel_y = timeline_ay - 16 - final_height
	else
		panel_y = self.ay - final_height - 8   -- 按钮上方 8px
	end
	if panel_y < 0 then panel_y = 0 end

	panel_x = math.max(8, math.min(panel_x, display.width - total_width - 8))

    return {
        ax = panel_x,
        ay = panel_y,
        bx = panel_x + total_width,
        by = panel_y + final_height,
        _row_height = row_height,
        _padding_h = padding_h,
        _padding_v = padding_v,
        _gap_between = gap_between,
        _display_count = total_items,
        _font_size = font_size,
        _icon_size = icon_size,
        _icon_gap = icon_gap,
        _scroll_enabled = scroll_enabled,
        _max_scroll = max_scroll,
        _content_height = self.content_height,
        _audio_tracks = audio_tracks,
        _max_left_total = max_left_total,
        _max_right_width = max_right_width,
        _left_origin = panel_x + padding_h,
        _right_origin = panel_x + total_width - padding_h,
    }
end

local AUDIO_EXTENSIONS = {
    'mp3', 'aac', 'mka', 'dts', 'flac', 'ogg', 'm4a', 'ac3', 'opus', 'wav', 'wv', 'eac3', 'thd',
    'ape', 'wma', 'm4b', 'mp2', 'tta', 'tak', 'dsf', 'dff'
}

function Audio:load_audio_file()
    local function handle_activate(event)
		mp.commandv('script-binding', 'uosc/menu-esc')
		self:close_panel()
		mp.add_timeout(0.05, function()
		mp.commandv('audio-add', event.value, 'cached')
		mp.commandv('set', 'audio', 'auto')
        end)
    end

    local directory = options.default_directory
    if state.path and not is_protocol(state.path) then
        local serialized = serialize_path(state.path)
        if serialized then directory = serialized.dirname end
    end

    open_file_navigation_menu(directory, handle_activate, {
        type = 'load-audio',
        title = '选择音轨文件',
        allowed_types = AUDIO_EXTENSIONS,
        keep_open = false,
    })
end

function Audio:draw_panel(ass, rect)
    local padding_h = rect._padding_h or 30
    local padding_v = rect._padding_v or 15
    local gap_between = rect._gap_between or 20
    local row_height = rect._row_height or 40
    local font_size = rect._font_size or (row_height * 0.7)
    local icon_size = rect._icon_size or font_size
    local icon_gap = rect._icon_gap or 8
    local scroll_enabled = rect._scroll_enabled or false
    local max_scroll = rect._max_scroll or 0
    local content_height = rect._content_height or 0
    local audio_tracks = rect._audio_tracks or {}
    local total_items = rect._display_count or (#audio_tracks + 1)  -- 关键修复：从rect获取总数

    local current_audio_id = mp.get_property_native('audio')
    local bili_blue = 'ecae00'

    -- 1. 绘制背景
    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
        color = '000000',
        opacity = 0.85,
        radius = round(2 * state.scale),
    })

    local panel_clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')'

    -- 滚动条绘制（与旧逻辑相同）
    if scroll_enabled then
        cursor:zone('wheel_down', rect, function()
            self.scroll_y = math.min(max_scroll, self.scroll_y + row_height * 3)
            request_render()
        end)
        cursor:zone('wheel_up', rect, function()
            self.scroll_y = math.max(0, self.scroll_y - row_height * 3)
            request_render()
        end)

        cursor:zone('primary_down', rect, function()
            self.is_dragging = true
            self.drag_start_y = cursor.y
            self.drag_start_scroll = self.scroll_y
            cursor:once('primary_up', function()
                self.is_dragging = false
            end)
        end)
        cursor:on('move', function()
            if self.is_dragging then
                local delta = (cursor.y - self.drag_start_y)
                self.scroll_y = math.max(0, math.min(max_scroll, self.drag_start_scroll - delta))
                request_render()
            end
        end)

        local bar_width = 4
        local bar_padding = 3
        local bar_ax = rect.bx - bar_padding - bar_width
        local bar_bx = rect.bx - bar_padding
        local bar_ay = rect.ay + 4
        local bar_by = rect.by - 4
        local track_height = bar_by - bar_ay
        local thumb_height = math.max(20, (rect.by - rect.ay) / content_height * track_height)
        local thumb_y = bar_ay + (self.scroll_y / max_scroll) * (track_height - thumb_height)
        ass:rect(bar_ax, thumb_y, bar_bx, thumb_y + thumb_height, {
            color = 'ffffff',
            opacity = 0.5,
            radius = 2,
            clip = panel_clip,
        })
    end

    -- 左侧文本基准x（左对齐）
    local left_base_x = rect.ax + padding_h
    -- 右侧文本右对齐基准x
    local right_base_x = rect.bx - padding_h

    -- 2. 绘制所有选项内容（文本、图标）
    for i = 1, #audio_tracks do
        local track = audio_tracks[i]
        local is_active = (track.id == current_audio_id)
        local color = is_active and bili_blue or 'ffffff'

        local item_y = rect.ay + padding_v + (i - 1) * row_height - self.scroll_y
        local item_ay = item_y
        local item_by = item_y + row_height

        if item_by <= rect.ay or item_ay >= rect.by then
            goto continue_track
        end

        local visible_ay = math.max(item_ay, rect.ay)
        local visible_by = math.min(item_by, rect.by)

        -- 鼠标悬停高亮
        local is_hover = get_point_to_rectangle_proximity(cursor, {
            ax = rect.ax,
            ay = item_ay,
            bx = rect.bx,
            by = item_by,
        }) <= 0
        if is_hover then
            ass:rect(rect.ax, visible_ay, rect.bx, visible_by, {
                color = 'ffffff',
                opacity = 0.4,
                radius = 0,
                clip = panel_clip,
            })
        end

        -- 绘制左侧文本（激活时图标在左并右移文本，非激活时文本直接左对齐）
        local text_pos_x = left_base_x
        if is_active then
            ass:icon(left_base_x + icon_size/2, item_y + row_height/2, icon_size, 'play_arrow', {
                color = color,
                opacity = 0.9,
                clip = panel_clip,
            })
            text_pos_x = left_base_x + icon_size + icon_gap
        end
        local left_text = self:get_left_text(track)
        ass:txt(text_pos_x, item_y + row_height/2, 4, left_text, {
            size = font_size,
            color = color,
            bold = is_active,
            opacity = 0.9,
            clip = panel_clip,
        })

        -- 绘制右侧属性文本（右对齐）
        local right_text = self:get_right_text(track)
        if right_text and right_text ~= '' then
            ass:txt(right_base_x, item_y + row_height/2, 6, right_text, {   -- 对齐方式6为右对齐
                size = font_size,
                color = 'ffffff',
                bold = false,
                opacity = 0.8,
                clip = panel_clip,
            })
        end

        -- 点击切换音轨
        cursor:zone('primary_click', {
            ax = rect.ax,
            ay = item_ay,
            bx = rect.bx,
            by = item_by,
        }, function()
            mp.set_property_native('audio', track.id)
            self:close_panel()
        end)

        ::continue_track::
    end

    -- 3. 绘制“加载音轨”行（文本在左，图标在右）
    local load_index = #audio_tracks + 1
    local load_y = rect.ay + padding_v + (load_index - 1) * row_height - self.scroll_y
    if load_y + row_height >= rect.ay and load_y <= rect.by then
        local is_hover_load = get_point_to_rectangle_proximity(cursor, {
            ax = rect.ax,
            ay = load_y,
            bx = rect.bx,
            by = load_y + row_height,
        }) <= 0
        if is_hover_load then
            ass:rect(rect.ax, math.max(load_y, rect.ay), rect.bx, math.min(load_y + row_height, rect.by), {
                color = 'ffffff',
                opacity = 0.4,
                radius = 0,
                clip = panel_clip,
            })
        end

        -- 文本在左
        ass:txt(left_base_x, load_y + row_height/2, 4, '加载音轨', {
            size = font_size,
            color = 'ffffff',
            bold = false,
            opacity = 0.9,
            clip = panel_clip,
        })
        -- 图标在右
        local right_icon_x = right_base_x - icon_size/2
        ass:icon(right_icon_x, load_y + row_height/2, icon_size, 'file_upload', {
            color = 'ffffff',
            opacity = 0.9,
            clip = panel_clip,
        })

        cursor:zone('primary_click', {
            ax = rect.ax,
            ay = load_y,
            bx = rect.bx,
            by = load_y + row_height,
        }, function()
            self:load_audio_file()
        end)
    end

    -- 4. 最后绘制分割细线（在所有选项内容之后，贯穿整个背景宽度）
    -- 使用从rect中获取的 total_items
    for i = 1, total_items - 1 do
        local line_y = rect.ay + padding_v + i * row_height - self.scroll_y
        if line_y >= rect.ay and line_y <= rect.by then
            ass:rect(rect.ax + padding_h, line_y, rect.bx - padding_h, line_y + 1, {
                color = 'ffffff',
                opacity = 0.15,
                clip = panel_clip,
            })
        end
    end
end

return Audio