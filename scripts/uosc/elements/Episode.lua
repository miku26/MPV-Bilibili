-- elements/Episode.lua
local Element = require('elements/Element')

---@class Episode : Element
local Episode = class(Element)

function Episode:new(id, props)
    return Class.new(self, id, props)
end

function Episode:init(id, props)
    Element.init(self, id, props)
    self.tooltip = props.tooltip or '选集'
    self.panel_open = false
    self.hide_timer = nil
    self.playlist = mp.get_property_native('playlist') or {}
    self.font_size = 0
    self._panel_rect = nil
    self.scroll_y = 0
    self.content_height = 0
    self.is_dragging = false
    self.drag_start_y = 0
    self.drag_start_scroll = 0

    self:observe_mp_property('playlist', 'native', function()
        self.playlist = mp.get_property_native('playlist') or {}
        self.scroll_y = 0
        request_render()
    end)
end

function Episode:get_display_title(index)
    return '第' .. index .. '话'
end

function Episode:on_coordinates()
    self.font_size = round((self.by - self.ay) * 0.7)
end

function Episode:on_display()
    self._panel_rect = nil
    request_render()
end

function Episode:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    local ass = assdraw.ass_new()
    local is_hover_button = self.proximity_raw <= 0
    local center_x = (self.ax + self.bx) / 2
    local center_y = (self.ay + self.by) / 2

    if is_hover_button then
        local text = '选集'
        local opts = { size = self.font_size, bold = true }
        local text_w = text_width(text, opts)
        local text_h = self.font_size * 0.93
        local height = self.by - self.ay
        local pad = (height - self.font_size) / 2
        if pad < 2 * state.scale then pad = 2 * state.scale end

        local bg_w = text_w + pad * 2
        local bg_h = text_h + pad * 2
        local ax = center_x - bg_w / 2
        local bx = center_x + bg_w / 2
        local ay = center_y - bg_h / 2
        local by = center_y + bg_h / 2

        ass:rect(ax, ay, bx, by, {
            color = fg,
            opacity = 0.3,
            radius = state.radius
        })
    end

    ass:txt(center_x, center_y, 5, '选集', {
        size = self.font_size,
        color = bgt,
        bold = true,
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

function Episode:open_panel()
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

function Episode:close_panel()
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

function Episode:get_panel_rect()
    local button_height = self.by - self.ay
    local row_height = math.max(24, round(button_height * 0.85))
    local padding_h = math.max(30, round(button_height * 0.5))   -- 左右边距
    local padding_v = math.max(20, round(button_height * 0.4))   -- 上下边距

    local max_height = display.height * 0.6
    local total_items = #self.playlist
    self.content_height = total_items * row_height   -- 纯选项总高度

    -- 面板总高度 = 选项总高度 + 上下边距，但不超过最大高度
    local final_height = math.min(self.content_height + padding_v * 2, max_height)

    -- 可滚动区域高度 = 面板高度 - 上下边距
    local scrollable_height = final_height - padding_v * 2
    local scroll_enabled = self.content_height > scrollable_height
    local max_scroll = math.max(0, self.content_height - scrollable_height)
    self.scroll_y = math.max(0, math.min(self.scroll_y, max_scroll))

    local font_size = row_height * 0.7
    local icon_size = font_size
    local icon_gap = 8

    local max_text_width = 0
    for i = 1, total_items do
        local title = self:get_display_title(i)
        local w = text_width(title, {size = font_size, bold = false})
        if w > max_text_width then max_text_width = w end
    end

    local playing_text = '正在播放'
    local playing_font_size = font_size * 0.8
    local playing_width = text_width(playing_text, {size = playing_font_size, bold = true})
    local label_padding_h = 3
    local playing_total_width = playing_width + label_padding_h * 2

    local spacing_between_text_and_label = 20
    local extra_width = 10
    local total_width = padding_h + icon_size + icon_gap + max_text_width + spacing_between_text_and_label + playing_total_width + padding_h + extra_width
    total_width = math.max(total_width, 200)

    local center_x = (self.ax + self.bx) / 2
    local panel_x = center_x - total_width / 2
    local panel_y = self.ay - final_height - 8
    if panel_y < 0 then
        panel_y = self.by + 8
        if panel_y + final_height > display.height - 8 then
            panel_y = display.height - final_height - 8
        end
    end
    panel_x = math.max(8, math.min(panel_x, display.width - total_width - 8))

    return {
        ax = panel_x,
        ay = panel_y,
        bx = panel_x + total_width,
        by = panel_y + final_height,
        _row_height = row_height,
        _padding_h = padding_h,
        _padding_v = padding_v,
        _display_count = total_items,
        _font_size = font_size,
        _icon_size = icon_size,
        _icon_gap = icon_gap,
        _scroll_enabled = scroll_enabled,
        _max_scroll = max_scroll,
        _content_height = self.content_height,   -- 用于滚动条比例
    }
end

function Episode:draw_panel(ass, rect)
    local padding_h = rect._padding_h or 16
    local padding_v = rect._padding_v or 0
    local row_height = rect._row_height or 40
    local display_count = rect._display_count or 0
    local font_size = rect._font_size or (row_height * 0.7)
    local icon_size = rect._icon_size or font_size
    local icon_gap = rect._icon_gap or 8
    local scroll_enabled = rect._scroll_enabled or false
    local max_scroll = rect._max_scroll or 0
    local content_height = rect._content_height or 0

    local current_pos = mp.get_property_native('playlist-pos-1') or 1
    local bili_blue = 'ecae00'
    local pink_bgr = '9972FB'

    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
        color = '000000',
        opacity = 0.85,
        radius = round(2 * state.scale),
    })

    local panel_clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')'

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

        -- 滚动条（仅在 content_height > 0 且 max_scroll > 0 时绘制）
        if content_height > 0 and max_scroll > 0 then
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
                clip = panel_clip
            })
        end
    end

    for i = 1, display_count do
        local is_current = (i == current_pos)
        local color = is_current and bili_blue or 'ffffff'
        local title = self:get_display_title(i)
        -- 关键：item_y 从 rect.ay + padding_v 开始，加上滚动偏移
        local item_y = rect.ay + padding_v + (i - 1) * row_height - self.scroll_y
        local item_ay = item_y
        local item_by = item_y + row_height

        if item_by <= rect.ay or item_ay >= rect.by then
            goto continue
        end

        local visible_ay = math.max(item_ay, rect.ay)
        local visible_by = math.min(item_by, rect.by)

        -- 高亮背景
        local is_hover = get_point_to_rectangle_proximity(cursor, {
            ax = rect.ax,
            ay = item_ay,
            bx = rect.bx,
            by = item_by
        }) <= 0
        if is_hover then
            ass:rect(rect.ax, visible_ay, rect.bx, visible_by, {
                color = 'ffffff',
                opacity = 0.4,
                radius = 0,
                clip = panel_clip
            })
        end

        local base_x = rect.ax + padding_h
        local text_x = base_x
        if is_current then
            text_x = base_x + icon_size + icon_gap
        end

        if is_current then
            local icon_x = base_x + icon_size / 2
            ass:icon(icon_x, item_y + row_height/2, icon_size, 'play_arrow', {
                color = color,
                opacity = 0.9,
                clip = panel_clip
            })
        end

        ass:txt(text_x, item_y + row_height/2, 4, title, {
            size = font_size,
            color = color,
            bold = is_current,
            opacity = 0.9,
            clip = panel_clip
        })

        if is_current then
            local playing_text = '正在播放'
            local playing_font_size = font_size * 0.8
            local playing_width = text_width(playing_text, {size = playing_font_size, bold = true})
            local playing_height = playing_font_size * 0.93
            local label_padding_h = 3
            local label_padding_v = 2

            local bg_ax = rect.bx - padding_h - playing_width - label_padding_h * 2
            local bg_ay = item_y + (row_height - (playing_height + label_padding_v * 2)) / 2
            local bg_bx = rect.bx - padding_h
            local bg_by = bg_ay + playing_height + label_padding_v * 2

            local visible_bg_ay = math.max(bg_ay, rect.ay)
            local visible_bg_by = math.min(bg_by, rect.by)
            if visible_bg_ay < visible_bg_by then
                ass:rect(bg_ax, visible_bg_ay, bg_bx, visible_bg_by, {
                    color = pink_bgr,
                    opacity = 0.9,
                    radius = round(state.radius * 0.5),
                    clip = panel_clip
                })
            end

            local label_text_x = (bg_ax + bg_bx) / 2
            local label_text_y = (bg_ay + bg_by) / 2
            ass:txt(label_text_x, label_text_y, 5, playing_text, {
                size = playing_font_size,
                color = fg,
                bold = true,
                opacity = 0.9,
                clip = panel_clip
            })
        end

        cursor:zone('primary_click', {
            ax = rect.ax,
            ay = item_ay,
            bx = rect.bx,
            by = item_by
        }, function()
            mp.commandv('playlist-play-index', i - 1)
            self:close_panel()
        end)

        ::continue::
    end
end

return Episode