-- elements/Subtitle.lua
local Element = require('elements/Element')

---@class Subtitle : Element
local Subtitle = class(Element)

function Subtitle:new(id, props)
    return Class.new(self, id, props)
end

function Subtitle:init(id, props)
    Element.init(self, id, props)
    self.tooltip = props.tooltip or '字幕'
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

function Subtitle:on_coordinates()
    self.font_size = round((self.by - self.ay) * 0.7)
end

function Subtitle:on_display()
    self._panel_rect = nil
    request_render()
end

-- 构建单个选项的左侧文本和右侧属性文本
function Subtitle:build_item_texts(track)
    local left_text = track.title and track.title ~= '' and track.title or ('字幕 ' .. track.id)
    local right_parts = {}
    if track.lang then table.insert(right_parts, track.lang) end
    if track.codec then table.insert(right_parts, track.codec) end
    if track.default then table.insert(right_parts, '默认') end
    if track.forced then table.insert(right_parts, '强制') end
    if track.external then table.insert(right_parts, '外部') end
    local right_text = table.concat(right_parts, ' ')
    return left_text, right_text
end

function Subtitle:get_panel_rect()
    local button_height = self.by - self.ay
    local padding_v = 15
    local row_height = math.max(38, round(button_height * 0.85))
    local max_height = display.height * 0.6

    local sub_tracks = itable_filter(self.track_list, function(t) return t.type == 'sub' end)
    local total_items = #sub_tracks + 1  -- 包括“加载字幕”

    -- 预计算每个选项的文本和宽度
    local items = {}
    local max_left_total = 0
    local max_right_width = 0
    local font_size = row_height * 0.7
    local icon_size = font_size
    local icon_gap = 8

    -- 处理所有字幕轨道
    for _, track in ipairs(sub_tracks) do
        local left_text, right_text = self:build_item_texts(track)
        local left_width = text_width(left_text, {size = font_size, bold = false})
        local right_width = text_width(right_text, {size = font_size, bold = false})
        local left_total = icon_size + icon_gap + left_width
        if left_total > max_left_total then max_left_total = left_total end
        if right_width > max_right_width then max_right_width = right_width end
        table.insert(items, {
            left_text = left_text,
            right_text = right_text,
            left_width = left_width,
            right_width = right_width,
            track = track,
        })
    end

    -- 处理“加载字幕”项
    local load_left = '加载字幕'
    local load_left_width = text_width(load_left, {size = font_size, bold = false})
    local load_left_total = icon_size + icon_gap + load_left_width
    if load_left_total > max_left_total then max_left_total = load_left_total end
    -- 加载项没有右侧文本
    table.insert(items, {
        left_text = load_left,
        right_text = '',
        left_width = load_left_width,
        right_width = 0,
        track = nil,
        is_load = true,
    })

    self.content_height = total_items * row_height
    local final_height = math.min(self.content_height + padding_v * 2, max_height)
    local scroll_enabled = self.content_height > (final_height - padding_v * 2)
    local max_scroll = math.max(0, self.content_height - (final_height - padding_v * 2))
    self.scroll_y = math.max(0, math.min(self.scroll_y, max_scroll))

    -- 边距和间距
    local gap = 20  -- 左右内容间距
    local padding_h = math.max(30, round(icon_size + icon_gap))
    local scroll_area = 7  -- 滚动条宽度(4) + 右边距(3)
    local total_width = padding_h * 2 + max_left_total + gap + max_right_width + scroll_area
    total_width = math.max(total_width, 200)

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
        _font_size = font_size,
        _icon_size = icon_size,
        _icon_gap = icon_gap,
        _scroll_enabled = scroll_enabled,
        _max_scroll = max_scroll,
        _content_height = self.content_height,
        _gap = gap,
        _scroll_area = scroll_area,
        _items = items,
        _sub_tracks = sub_tracks,
        _load_index = #sub_tracks + 1,
    }
end

function Subtitle:draw_panel(ass, rect)
    local padding_h = rect._padding_h
    local padding_v = rect._padding_v
    local row_height = rect._row_height
    local font_size = rect._font_size
    local icon_size = rect._icon_size
    local icon_gap = rect._icon_gap
    local scroll_enabled = rect._scroll_enabled
    local max_scroll = rect._max_scroll
    local gap = rect._gap
    local scroll_area = rect._scroll_area
    local items = rect._items
    local sub_tracks = rect._sub_tracks

    local current_sub_id = mp.get_property_native('sub')
    local bili_blue = 'ecae00'

    -- 背景
    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
        color = '000000',
        opacity = 0.85,
        radius = round(2 * state.scale),
    })

    local panel_clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')'

    -- 内容区域的左右边界
    local content_left = rect.ax + padding_h
    local content_right = rect.bx - padding_h - (scroll_enabled and scroll_area or 0)
    local line_left = content_left
    local line_right = content_right

    -- 滚动条（如果启用）
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
        local thumb_height = math.max(20, (rect.by - rect.ay) / rect._content_height * track_height)
        local thumb_y = bar_ay + (self.scroll_y / max_scroll) * (track_height - thumb_height)
        ass:rect(bar_ax, thumb_y, bar_bx, thumb_y + thumb_height, {
            color = 'ffffff',
            opacity = 0.5,
            radius = 2,
            clip = panel_clip,
        })
    end

    -- 循环绘制每个选项
    local item_count = #items
    for i, item in ipairs(items) do
        local is_load = item.is_load or false
        local track = item.track
        local left_text = item.left_text
        local right_text = item.right_text
        local right_width = item.right_width

        -- 计算垂直位置
        local item_y = rect.ay + padding_v + (i - 1) * row_height - self.scroll_y
        local item_ay = item_y
        local item_by = item_y + row_height
        if item_by <= rect.ay or item_ay >= rect.by then
            goto continue_item
        end

        local visible_ay = math.max(item_ay, rect.ay)
        local visible_by = math.min(item_by, rect.by)

        -- 悬停高亮
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

        -- 检查是否为当前激活的字幕（仅对轨道有效）
        local is_active = (not is_load) and (track.id == current_sub_id)

        -- 左侧部分：图标 + 左文本
        local left_x = content_left
        local icon_x = left_x + icon_size / 2
        local text_x = left_x + icon_size + icon_gap

        -- 绘制图标和文本（根据是否加载项调整布局）
        if is_load then
            -- 加载项：文本在左，图标在右
            ass:txt(content_left, item_y + row_height / 2, 4, left_text, {
                size = font_size,
                color = 'ffffff',
                bold = true,
                opacity = 0.9,
                clip = panel_clip,
            })
            local icon_x_right = content_right - icon_size / 2
            ass:icon(icon_x_right, item_y + row_height / 2, icon_size, 'file_upload', {
                color = 'ffffff',
                opacity = 0.9,
                clip = panel_clip,
            })
        else
            -- 普通项：激活时显示图标并右移文本；非激活时文本直接左对齐
            local text_pos_x = content_left
            if is_active then
                ass:icon(icon_x, item_y + row_height / 2, icon_size, 'play_arrow', {
                    color = bili_blue,
                    opacity = 0.9,
                    clip = panel_clip,
                })
                text_pos_x = text_x
            end
            ass:txt(text_pos_x, item_y + row_height / 2, 4, left_text, {
                size = font_size,
                color = is_active and bili_blue or 'ffffff',
                bold = is_active,
                opacity = 0.9,
                clip = panel_clip,
            })
        end

        -- 右文本（右对齐）
        if right_text ~= '' and right_width > 0 then
            local right_x = content_right - right_width
            ass:txt(right_x, item_y + row_height / 2, 4, right_text, {
                size = font_size,
                color = is_active and bili_blue or 'ffffff',
                bold = is_active,
                opacity = 0.9,
                clip = panel_clip,
            })
        end

        -- 点击事件（切换字幕或加载）
        cursor:zone('primary_click', {
            ax = rect.ax,
            ay = item_ay,
            bx = rect.bx,
            by = item_by,
        }, function()
            if is_load then
				local function handle_activate(event)
					mp.commandv('script-binding', 'uosc/menu-esc')
					-- 2. 关闭字幕面板
					self:close_panel()
					-- 3. 延迟加载字幕，确保菜单已关闭
					mp.add_timeout(0.05, function()
					load_track('sub', event.value)
				end)
                end
                local start_dir = options.default_directory
                if state.path and not is_protocol(state.path) then
                    local serialized = serialize_path(state.path)
                    if serialized and serialized.dirname then
                        start_dir = serialized.dirname
                    end
                end
                open_file_navigation_menu(start_dir, handle_activate, {
                    type = 'load-subtitle',
                    title = '选择字幕文件',
                    allowed_types = {'srt', 'ass', 'ssa', 'sub', 'idx'},
                })
            else
                mp.set_property_native('sub', track.id)
                self:close_panel()
            end
        end)

        ::continue_item::
    end

    -- 绘制分隔细线（在所有选项绘制完成后，在选项之间画线）
    -- 只画在可见范围内，且不覆盖背景边距，只覆盖内容区域
    local line_y_start = rect.ay + padding_v - self.scroll_y
    for i = 1, item_count - 1 do
        local line_y = line_y_start + i * row_height
        if line_y >= rect.ay and line_y <= rect.by then
            ass:rect(line_left, line_y, line_right, line_y + 1, {
                color = 'ffffff',
                opacity = 0.15,
                clip = panel_clip,
            })
        end
    end
end

function Subtitle:open_panel()
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

function Subtitle:close_panel()
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

function Subtitle:render()
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

	ass:icon(center_x, center_y, self.font_size, 'closed_caption', {
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

return Subtitle