-- elements/PanelElement.lua
local Element = require('elements/Element')

---@class PanelElement : Element
local PanelElement = class(Element)

--- ===== 列表绘制辅助 =====

--- 该行是否落在面板可视区内
function PanelElement:is_item_visible(rect, item_y, row_height)
    return item_y + row_height > rect.ay and item_y < rect.by
end

--- 光标是否悬停在该行
function PanelElement:is_item_hovered(rect, item_y, row_height)
    return get_point_to_rectangle_proximity(cursor, {
        ax = rect.ax, ay = item_y, bx = rect.bx, by = item_y + row_height
    }) <= 0
end

--- 绘制悬停高亮
function PanelElement:draw_item_hover(ass, rect, item_y, row_height, clip)
    ass:rect(rect.ax, math.max(item_y, rect.ay), rect.bx, math.min(item_y + row_height, rect.by), {
        color = 'ffffff', opacity = 0.4, clip = clip
    })
end

--- 绘制项目之间的分割线
function PanelElement:draw_separators(ass, rect, padding_h, padding_v, row_height, scroll_y, total_items, clip)
    for i = 1, total_items - 1 do
        local line_y = rect.ay + padding_v + i * row_height - scroll_y
        if line_y >= rect.ay and line_y <= rect.by then
            ass:rect(rect.ax + padding_h, line_y, rect.bx - padding_h, line_y + 1, {
                color = 'ffffff', opacity = 0.15, clip = clip
            })
        end
    end
end

function PanelElement:init(id, props)
    Element.init(self, id, props)
    self.panel_open = false
    self.hide_timer = nil
    self._panel_rect = nil
    self.scroll_y = 0
    self.content_height = 0
    self.is_dragging = false
    self.drag_start_y = 0
    self.drag_start_scroll = 0
    self.font_size = 0
	
	self._scroll_move_handler = function() self:on_scroll_move() end
	cursor:on('move', self._scroll_move_handler)
	self:register_disposer(function()
		cursor:off('move', self._scroll_move_handler)
	end)
end

--- 默认坐标
function PanelElement:on_coordinates()
    self.font_size = round((self.by - self.ay) * 0.55)
end

--- 打开面板
function PanelElement:open_panel()
    if not self.panel_open then
        self.panel_open = true
        Elements:set_min_visibility(1, {'controls'})
        if self.hide_timer then self.hide_timer:kill(); self.hide_timer = nil end
        self._panel_rect = nil
        self.scroll_y = 0
        request_render()
    end
end

--- 关闭面板
function PanelElement:close_panel()
    self.panel_open = false
    Elements:set_min_visibility(0, {'controls'})
    if self.hide_timer then self.hide_timer:kill(); self.hide_timer = nil end
    self._panel_rect = nil
    self.is_dragging = false
    request_render()
end

--- 统一的面板计算
function PanelElement:get_panel_origin(panel_width, panel_height, fallback_offset)
    fallback_offset = fallback_offset or 8
    local center_x = (self.ax + self.bx) / 2
    local panel_x = math.max(8, math.min(center_x - panel_width / 2, display.width - panel_width - 8))

    local timeline_ay = Elements:v('timeline', 'ay', display.height)
    local timeline_enabled = Elements.timeline and Elements.timeline.enabled
    local panel_y = timeline_enabled
        and timeline_ay - 16 - panel_height
        or  self.ay - panel_height - fallback_offset
    if panel_y < 0 then panel_y = 0 end

    return panel_x, panel_y
end

--- 计算面板位置
function PanelElement:calculate_panel_rect(panel_width, panel_height, row_height, font_size, padding_h, padding_v, extra)
    local total_items = #(self.items or {}) + 1
    self.content_height = total_items * row_height
    local max_height = display.height * 0.6
    local final_height = math.min(self.content_height + padding_v * 2, max_height)
    local scroll_enabled = self.content_height > (final_height - padding_v * 2)
    local max_scroll = math.max(0, self.content_height - (final_height - padding_v * 2))
    self.scroll_y = math.max(0, math.min(self.scroll_y, max_scroll))

    local panel_x, panel_y = self:get_panel_origin(panel_width, final_height)

    local rect = {
        ax = panel_x, ay = panel_y,
        bx = panel_x + panel_width, by = panel_y + final_height,
        _row_height = row_height, _padding_h = padding_h, _padding_v = padding_v,
        _font_size = font_size, _scroll_enabled = scroll_enabled,
        _max_scroll = max_scroll, _content_height = self.content_height,
    }
    if extra then table_assign(rect, extra) end
    return rect
end

--- 滚动条拖拽的 move 处理（在 init 里注册一次，避免每次 render 泄漏）
function PanelElement:on_scroll_move()
    if not self.is_dragging then return end
    local max_scroll = (self._panel_rect and self._panel_rect._max_scroll) or 0
    if max_scroll <= 0 then return end
    local delta = cursor.y - self.drag_start_y
    self.scroll_y = math.max(0, math.min(max_scroll, self.drag_start_scroll - delta))
    request_render()
end

--- 绘制滚动条
function PanelElement:draw_scrollbar(ass, rect, content_top, content_bottom)
    content_top    = content_top    or rect.ay
    content_bottom = content_bottom or rect.by

    local row_height     = rect._row_height or 40
    local max_scroll     = rect._max_scroll
    local content_height = rect._content_height
    local panel_clip     = '\\clip('..rect.ax..','..rect.ay..','..rect.bx..','..rect.by..')'
    local interaction_rect = { ax = rect.ax, ay = content_top, bx = rect.bx, by = content_bottom }

    cursor:zone('wheel_down', interaction_rect, function()
        self.scroll_y = math.min(max_scroll, self.scroll_y + row_height * 3)
        request_render()
    end)
    cursor:zone('wheel_up', interaction_rect, function()
        self.scroll_y = math.max(0, self.scroll_y - row_height * 3)
        request_render()
    end)

    cursor:zone('primary_down', interaction_rect, function()
        self.is_dragging = true
        self.drag_start_y = cursor.y
        self.drag_start_scroll = self.scroll_y
        cursor:once('primary_up', function() self.is_dragging = false end)
    end)

    local bar_width, bar_padding = 4, 3
    local bar_ax = rect.bx - bar_padding - bar_width
    local bar_bx = rect.bx - bar_padding
    local bar_ay = content_top + 4
    local bar_by = content_bottom - 4
    local track_height   = bar_by - bar_ay
    local visible_height = content_bottom - content_top
    local thumb_height = math.max(20, visible_height / content_height * track_height)
    local thumb_y = bar_ay + (self.scroll_y / max_scroll) * (track_height - thumb_height)
    ass:rect(bar_ax, thumb_y, bar_bx, thumb_y + thumb_height, {
        color = 'ffffff', opacity = 0.5, radius = 2, clip = panel_clip
    })
end

--- 面板渲染主逻辑
function PanelElement:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    local ass = assdraw.ass_new()
    local is_hover_button = self.proximity_raw <= 0

    if is_hover_button then
        self:draw_hover_background(ass)
    end

    self:draw_button(ass, visibility)

    if is_hover_button and not self.panel_open then
        self:open_panel()
    end

    if self.panel_open then
        if not self._panel_rect then
            self._panel_rect = self:get_panel_rect()
        end
        local panel_rect = self._panel_rect

        cursor:zone('wheel_down', panel_rect, function() end)
        cursor:zone('wheel_up', panel_rect, function() end)

        local is_hover_panel = get_point_to_rectangle_proximity(cursor, panel_rect) <= 0

        if is_hover_button or is_hover_panel then
            if self.hide_timer then self.hide_timer:kill(); self.hide_timer = nil end
        else
            if not self.hide_timer then
                self.hide_timer = mp.add_timeout(0.1, function()
                    self:close_panel()
                end)
            end
        end

		if panel_rect._scroll_enabled then
            self:draw_scrollbar(ass, panel_rect, panel_rect._scroll_top, panel_rect._scroll_bottom)
        end

        self:draw_content(ass, panel_rect)
    end

    return ass
end

--- 默认的悬停背景
function PanelElement:draw_hover_background(ass)
    ass:rect(self.ax, self.ay, self.bx, self.by, {
        color = fg, opacity = 0.3, radius = state.radius
    })
end

-- ============================================================
-- 通用滑块逻辑

-- 每个滑块配置支持：
--   key            : 存储键
--   label          : 显示标签
--   min, max, step : 滑块范围值（不是存储值）
--   format(val)    : 滑块范围值 -> 显示字符串
--   to_slider(raw) : 存储值 -> 滑块范围值（默认恒等）
--   to_raw(val)    : 滑块范围值 -> 存储值（默认恒等）
--   show_ticks     : 是否绘制刻度点
-- ============================================================

--- 绘制滑块的轨道 + 填充 + 拇指 + 刻度

function PanelElement:draw_slider(ass, slider, opts)
    local track_y = opts.item_y + opts.row_height / 2
    local track_height = round(6 * state.scale)
    local thumb_radius = round(6 * state.scale)

    local t = (opts.value - slider.min) / (slider.max - slider.min)
    t = clamp(0, t, 1)
    local thumb_x = opts.slider_left + t * (opts.slider_right - opts.slider_left)
    thumb_x = math.max(opts.slider_left + thumb_radius,
                       math.min(opts.slider_right - thumb_radius, thumb_x))

    ass:rect(opts.slider_left, track_y - track_height/2, opts.slider_right, track_y + track_height/2,
        { color = fg, opacity = 0.25, radius = track_height/2, clip = opts.clip })
    ass:rect(opts.slider_left, track_y - track_height/2, thumb_x, track_y + track_height/2,
        { color = 'ecae00', opacity = 0.9, radius = track_height/2, clip = opts.clip })
    ass:circle(thumb_x, track_y, thumb_radius, { color = fg, opacity = 1, clip = opts.clip })

    if slider.show_ticks and slider.step then
        local tick_radius = round(2 * state.scale)
        local tick_span = (opts.slider_right - opts.slider_left) - 2 * tick_radius
        for val = slider.min, slider.max, slider.step do
            local tick_t = (val - slider.min) / (slider.max - slider.min)
            local tick_x = opts.slider_left + tick_radius + tick_t * tick_span
            if math.abs(tick_x - thumb_x) > thumb_radius + 2 then
                ass:circle(tick_x, track_y, tick_radius, {
                    color = 'ffffff', opacity = 1, clip = opts.clip
                })
            end
        end
    end
end

--- 为滑块注册拖拽 + 滚轮交互
function PanelElement:attach_slider(slider, opts)
    local track_rect = {
        ax = opts.slider_left, ay = opts.item_y,
        bx = opts.slider_right, by = opts.item_y + opts.row_height,
    }

    local function compute_value_from_cursor()
        local t = (cursor.x - opts.slider_left) / (opts.slider_right - opts.slider_left)
        t = clamp(0, t, 1)
        local val = slider.min + (slider.max - slider.min) * t
        if slider.step then
            val = math.floor((val - slider.min) / slider.step + 0.5) * slider.step + slider.min
        end
        return clamp(slider.min, val, slider.max)
    end

    cursor:zone('primary_down', track_rect, function()
        -- 若上一个拖拽未清理，先清理
        if self._slider_drag then
            cursor:off('move', self._slider_drag.move_handler)
            cursor:off('primary_up', self._slider_drag.up_handler)
            self._slider_drag = nil
        end

        local function move_handler()
            opts.on_change(compute_value_from_cursor())
        end
        local function up_handler()
            cursor:off('move', move_handler)
            self._slider_drag = nil
            if opts.on_release then opts.on_release() end
        end

        cursor:on('move', move_handler)
        cursor:once('primary_up', up_handler)
        self._slider_drag = { move_handler = move_handler, up_handler = up_handler }
        move_handler()
    end)

    cursor:zone('wheel_down', track_rect, function()
        local current = opts.get_value()
        local new_val = clamp(slider.min, current - (slider.step or 1), slider.max)
        opts.on_change(new_val)
        if opts.on_release then opts.on_release() end
    end)
    cursor:zone('wheel_up', track_rect, function()
        local current = opts.get_value()
        local new_val = clamp(slider.min, current + (slider.step or 1), slider.max)
        opts.on_change(new_val)
        if opts.on_release then opts.on_release() end
    end)
end

function PanelElement:draw_button(ass, visibility) end
function PanelElement:draw_content(ass, rect) end
function PanelElement:get_panel_rect() end

return PanelElement