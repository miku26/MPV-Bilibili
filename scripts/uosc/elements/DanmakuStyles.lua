-- elements/DanmakuStyles.lua
local PanelElement = require('elements/PanelElement')

-- 预设字体列表（供下拉菜单使用）
local FONT_LIST = {
    "黑体", "宋体", "新宋体", "仿宋",
    "微软雅黑", "微软雅黑 Light",
    "思源宋体", "思源黑体"
}

---@class DanmakuStyles : PanelElement
local DanmakuStyles = class(PanelElement)

function DanmakuStyles:init(id, props)
    PanelElement.init(self, id, props)

    self.tooltip = props.tooltip or '弹幕设置'
    self.font_picker_open = false
    self.font_scroll_offset = 0
    self.font_close_timer = nil
    self.font_size = 0

    --- 页面控制
    self.current_page = 'main'

    --- 获取 uosc_danmaku 的配置表
    self.danmaku_opts = _G.danmaku_options or {}
    self.values = {
        displayarea = tonumber(self.danmaku_opts.displayarea) or 0.6,
        opacity = tonumber(self.danmaku_opts.opacity) or 0.7,
        fontsize = tonumber(self.danmaku_opts.fontsize) or 38,
        scrolltime = tonumber(self.danmaku_opts.scrolltime) or 15,
        fontname = self.danmaku_opts.fontname or '微软雅黑',
        bold = self.danmaku_opts.bold == true,
    }
    --- 检测当前描边类型
    self.stroke_type = self:detect_stroke_type()

    --- 监听滑块和界面的反同步更新
    mp.register_script_message('danmaku-style-update', function(key, value)
        if key and value ~= nil then
            if key == 'displayarea' then
                self.values.displayarea = tonumber(value) or 0.6
            elseif key == 'opacity' then
                self.values.opacity = tonumber(value) or 0.7
            elseif key == 'fontsize' then
                self.values.fontsize = tonumber(value) or 38
            elseif key == 'scrolltime' then
                self.values.scrolltime = tonumber(value) or 15
            elseif key == 'fontname' then
                self.values.fontname = tostring(value)
            elseif key == 'bold' then
                self.values.bold = (value == "true" or value == true)
            end
            request_render()
        end
    end)

    self:register_disposer(function()
        mp.unregister_script_message('danmaku-style-update')
    end)

    mp.commandv('script-message-to', 'uosc_danmaku', 'get-style-values')
end

function DanmakuStyles:on_display()
    self._panel_rect = nil
    request_render()
end

--- 绘制按钮
function DanmakuStyles:draw_button(ass, visibility)
    local center_x = (self.ax + self.bx) / 2
    local center_y = (self.ay + self.by) / 2
    ass:icon(center_x, center_y, self.font_size, 'chat', {
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
    })
end

--- 面板大小
function DanmakuStyles:get_panel_rect()
    local PANEL_WIDTH = 430
    local ROW_HEIGHT = 60
    local FONT_SIZE = 24
    local PADDING_H = 30
    local LEFT_MARGIN = 12
    local RIGHT_MARGIN = 18

    local panel_height = self.current_page == 'main'
        and (5 * ROW_HEIGHT + 60)
        or  360

    local panel_x, panel_y = self:get_panel_origin(PANEL_WIDTH, panel_height)

    return {
        ax = panel_x, ay = panel_y,
        bx = panel_x + PANEL_WIDTH, by = panel_y + panel_height,
        _row_height = ROW_HEIGHT,
        _padding_h = PADDING_H,
        _font_size = FONT_SIZE,
        _total_width = PANEL_WIDTH,
        _left_margin = LEFT_MARGIN,
        _right_margin = RIGHT_MARGIN,
        _scroll_enabled = false,
    }
end

--- 面板内容
function DanmakuStyles:draw_content(ass, rect)
    if self.current_page == 'main' then
        self:draw_main_panel(ass, rect)
    else
        self:draw_advanced_panel(ass, rect)
    end
end

function DanmakuStyles:detect_stroke_type()
    local out = tonumber(self.danmaku_opts.outline) or 1.0
    local shd = tonumber(self.danmaku_opts.shadow) or 0
    if out == 0.3 and shd == 0 then return 'outline' end
    if out == 0 and shd == 1.2 then return 'shadow' end
    return 'heavy'
end

--- 主面板滑块配置
local sliders_config = {
    {
        key = 'displayarea',
        label = '显示区域',
        min = 0.25, max = 1.0, step = 0.25,
        format = function(val) return string.format('%.0f%%', val * 100) end,
        show_ticks = true,
    },
    {
        key = 'opacity',
        label = '不透明度',
        min = 0.15, max = 1, step = 0.01,
        format = function(val) return string.format('%.0f%%', val * 100) end,
        show_ticks = false,
    },
    {
        key = 'fontsize',
        label = '弹幕字号',
        min = 50, max = 170, step = 1,
        format = function(val) return string.format('%.0f%%', val) end,
        to_slider = function(raw) return clamp(50, raw / 36 * 100, 170) end,
        to_raw    = function(v)   return math.floor(v * 36 / 100) end,
        show_ticks = false,
    },
    {
        key = 'scrolltime',
        label = '弹幕速度',
        min = 5, max = 25, step = 5,
        format = function(val)
            local speed_texts = { [5]='极快', [10]='较快', [15]='适中', [20]='较慢', [25]='极慢' }
            local stepped = math.floor((val - 5) / 5 + 0.5) * 5 + 5
            return speed_texts[stepped] or tostring(val)
        end,
        show_ticks = true,
    },
}

function DanmakuStyles:draw_main_panel(ass, rect)
    local padding_h = rect._padding_h or 28
    local row_height = rect._row_height or 64
    local font_size = rect._font_size or (row_height * 0.4)
    local panel_clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')'

    ass:rect(rect.ax, rect.ay, rect.bx, rect.by,
        { color = bg, opacity = 0.85, radius = round(2 * state.scale) })

    -- 预量最大标签/数值宽度（用于布局对齐）
    local max_label_width, max_value_width = 0, 0
    for _, slider in ipairs(sliders_config) do
        local max_w = 0
        for val = slider.min, slider.max, slider.step do
            local w = text_width(slider.format(val), {size = font_size, bold = true})
            if w > max_w then max_w = w end
        end
        if max_w > max_value_width then max_value_width = max_w end
        local lw = text_width(slider.label, {size = font_size, bold = true})
        if lw > max_label_width then max_label_width = lw end
    end

    local left_margin  = rect._left_margin or 12
    local right_margin = rect._right_margin or math.floor(left_margin * 1.8)
    local slider_left  = rect.ax + padding_h + max_label_width + left_margin
    local slider_right = rect.bx - padding_h - max_value_width - right_margin

    local top_pad, bottom_pad = 16, 16

    for row, slider in ipairs(sliders_config) do
        local item_y = rect.ay + top_pad + (row - 1) * row_height
        local raw = self.values[slider.key]
        local sv = slider.to_slider and slider.to_slider(raw) or raw
        local display_text = slider.format(sv)

        ass:txt(rect.ax + padding_h, item_y + row_height / 2, 4, slider.label,
            { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
        ass:txt(rect.bx - padding_h, item_y + row_height / 2, 6, display_text,
            { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })

        local slider_opts = {
            item_y = item_y,
            row_height = row_height,
            slider_left = slider_left,
            slider_right = slider_right,
            clip = panel_clip,
            value = sv,
            -- 实时读取（拖拽 / 滚轮期间用）
            get_value = function()
                local r = self.values[slider.key]
                return slider.to_slider and slider.to_slider(r) or r
            end,
            -- 值变化时写入存储
            on_change = function(v)
                self.values[slider.key] = slider.to_raw and slider.to_raw(v) or v
                request_render()
            end,
            -- 拖拽 / 滚轮结束时持久化
            on_release = function() self:update_style_settings() end,
        }
        self:draw_slider(ass, slider, slider_opts)
        self:attach_slider(slider, slider_opts)
    end

    --- 底部“高级设置”入口
    local entry_h = row_height * 0.7
    local entry_y = rect.by - entry_h - bottom_pad
    local line_y = entry_y - 6

    ass:rect(rect.ax + padding_h, line_y, rect.bx - padding_h, line_y + 1,
        { color = fg, opacity = 0.15, clip = panel_clip })
    ass:txt(rect.ax + padding_h, entry_y + entry_h / 2, 4, '高级设置',
        { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
    ass:icon(rect.bx - padding_h, entry_y + entry_h / 2, font_size * 0.9, 'navigate_next',
        { color = bgt, opacity = 1, align = 6, clip = panel_clip })

    cursor:zone('primary_click',
        { ax = rect.ax, ay = entry_y, bx = rect.bx, by = entry_y + entry_h },
        function()
            self.current_page = 'advanced'
            self._panel_rect = nil
            request_render()
        end)
end

--- 2级面板
function DanmakuStyles:draw_advanced_panel(ass, rect)
    local font_size = rect._font_size or ((rect.by - rect.ay) * 0.35)
    local panel_clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')'

    local pad = math.max(24, round(font_size * 0.65))
    local gap = math.max(16, round(font_size * 0.4))
    local h_title = round(font_size * 1.6)
    local h_label = round(font_size * 1.0)
    local h_input = round(font_size * 1.2)

    local active_color = 'ecae00'
    local btn_radius = round(2 * state.scale)

    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, { color = bg, opacity = 0.85, radius = btn_radius })
    local y = rect.ay + gap

    ass:icon(rect.ax + pad, y + h_title/2, font_size * 0.9, 'navigate_before', { color = bgt, opacity = 1, clip = panel_clip })
    ass:txt(rect.ax + pad + font_size + 8, y + h_title/2, 4, '更多弹幕设置', { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
    cursor:zone('primary_click', { ax = rect.ax, ay = y, bx = rect.bx, by = y + h_title }, function()
        self.current_page = 'main'
        self._panel_rect = nil
        request_render()
    end)

    y = y + h_title + 10
    ass:rect(rect.ax, y, rect.bx, y + 1, { color = fg, opacity = 0.15, clip = panel_clip })
    y = y + gap

    ass:txt(rect.ax + pad, y + h_label/2, 4, '弹幕字体', { size = font_size, color = fg, bold = true, opacity = 1, clip = panel_clip })
    y = y + h_label + gap

    --- 字体选择框
    local font_text_opts = { size = font_size, bold = true }
    local cb_size = round(font_size * 0.75)
    local cb_y = y + (h_input - cb_size) / 2
    local bold_text_w = text_width('粗体', font_text_opts)
    local bold_total_w = cb_size + 8 + bold_text_w
    local bold_start_x = (rect.bx - pad) - bold_total_w

    local gap_between = round(font_size * 0.6)
    local font_box_w = bold_start_x - (rect.ax + pad) - gap_between
    font_box_w = math.max(160, font_box_w)
    local font_box_x = rect.ax + pad
    local font_box_y = y
    local font_box_h = h_input
    local font_box_rect = { ax = font_box_x, ay = font_box_y, bx = font_box_x + font_box_w, by = font_box_y + font_box_h }

    ass:rect(font_box_x, font_box_y, font_box_x + font_box_w, font_box_y + font_box_h,
        { color = fg, opacity = 0.15, border = 1, border_color = fg, radius = btn_radius, clip = panel_clip })
    ass:txt(font_box_x + 12, font_box_y + font_box_h / 2, 4, self.values.fontname,
        { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
    ass:icon(font_box_x + font_box_w - 20, font_box_y + font_box_h / 2, font_size * 0.9, 'expand_more', { color = bgt, opacity = 0.7, clip = panel_clip })

    --- 粗体复选框
    local is_bold = self.values.bold
    ass:rect(bold_start_x, cb_y, bold_start_x + cb_size, cb_y + cb_size,
        { color = is_bold and active_color or fg, opacity = is_bold and 0.9 or 0.2, radius = btn_radius, clip = panel_clip })
    if is_bold then
        ass:icon(bold_start_x + cb_size/2, cb_y + cb_size/2, cb_size * 0.8, 'check', { color = fg, opacity = 1, clip = panel_clip })
    end
    ass:txt(bold_start_x + cb_size + 8, y + h_input/2, 4, '粗体', { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
    cursor:zone('primary_click', { ax = bold_start_x, ay = y, bx = rect.bx - pad, by = y + h_input }, function()
        self.values.bold = not self.values.bold
        self:update_style_settings()
        request_render()
    end)

    --- 下拉菜单（固定显示5项，增大行距和字体，移除选中高亮）
    local menu_item_h = round(h_input * 1.3)          -- 增大行高
    local menu_w = font_box_w
    local menu_x = font_box_x
    local menu_y = font_box_y + font_box_h            -- 固定向下展开，不检查溢出
    local MAX_VISIBLE_ITEMS = 5
    local menu_max_h = MAX_VISIBLE_ITEMS * menu_item_h
    local menu_rect = { ax = menu_x, ay = menu_y, bx = menu_x + menu_w, by = menu_y + menu_max_h }

    local mouse_in_font_box = get_point_to_rectangle_proximity(cursor, font_box_rect) <= 0
    local mouse_in_menu = false
    if self.font_picker_open then
        mouse_in_menu = get_point_to_rectangle_proximity(cursor, menu_rect) <= 0
    end

    local keep_open = false
    if self.font_picker_open then
        keep_open = mouse_in_font_box or mouse_in_menu
    else
        keep_open = mouse_in_font_box
    end

    if keep_open then
        if self.font_close_timer then
            self.font_close_timer:kill()
            self.font_close_timer = nil
        end
        self.font_picker_open = true
    else
        if self.font_picker_open and not self.font_close_timer then
            self.font_close_timer = mp.add_timeout(0.1, function()
                self.font_picker_open = false
                self.font_scroll_offset = 0
                self.font_close_timer = nil
                request_render()
            end)
        end
    end

    y = y + h_input + gap

    ass:txt(rect.ax + pad, y + h_label/2, 4, '描边类型', { size = font_size, color = fg, bold = true, opacity = 1, clip = panel_clip })
    y = y + h_label + gap

    --- 描边按钮
    local stroke_opts = { { id = 'heavy', label = '重墨' }, { id = 'outline', label = '描边' }, { id = 'shadow', label = '45°投影' } }
    local btn_w = (rect.bx - rect.ax - 2 * pad - 2 * gap) / 3
    btn_w = math.max(70, math.floor(btn_w))

    for i, opt in ipairs(stroke_opts) do
        local bx = rect.ax + pad + (i-1) * (btn_w + gap)
        local is_active = self.stroke_type == opt.id

        ass:rect(bx, y, bx + btn_w, y + h_input, { color = is_active and active_color or fg, opacity = is_active and 0.9 or 0.2, radius = btn_radius, clip = panel_clip })
        ass:txt(bx + btn_w/2, y + h_input/2, 5, opt.label, { size = font_size, color = fg, bold = true, opacity = 1, clip = panel_clip })

        cursor:zone('primary_click', { ax=bx, ay=y, bx=bx+btn_w, by=y+h_input }, function() self:apply_stroke_type(opt.id) end)
    end

    y = y + h_input + gap * 2
    ass:rect(rect.ax, y, rect.bx, y + 1, { color = fg, opacity = 0.15, clip = panel_clip })
    y = y + gap + 10

    local reset_text = '恢复默认设置'
    local reset_w = (rect.bx - rect.ax) * 0.5
    local reset_x = rect.ax + pad
    local reset_h = h_input

    ass:rect(reset_x, y, reset_x + reset_w, y + reset_h, { color = fg, opacity = 0.15, border = 1, border_color = fg, radius = btn_radius, clip = panel_clip })
    ass:txt(reset_x + reset_w/2, y + reset_h/2, 5, reset_text, { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })

    cursor:zone('primary_click', { ax=reset_x, ay=y, bx=reset_x+reset_w, by=y+reset_h }, function()
        self:reset_to_defaults()
    end)

    --- 字体下拉列表绘制
    if self.font_picker_open then
        local max_visible = math.floor(menu_max_h / menu_item_h)
        local max_scroll = #FONT_LIST - max_visible
        if max_scroll < 0 then max_scroll = 0 end

        if self.font_scroll_offset > max_scroll then self.font_scroll_offset = max_scroll end

        ass:rect(menu_rect.ax, menu_rect.ay, menu_rect.bx, menu_rect.by,
            { color = '1c1c1c', opacity = 1.0, border = 1, border_color = '333333', radius = btn_radius })

        local start_i = 1 + self.font_scroll_offset
        local end_i = math.min(#FONT_LIST, max_visible + self.font_scroll_offset)

        for i = start_i, end_i do
            local font_name = FONT_LIST[i]
            local item_idx = i - self.font_scroll_offset
            local item_y = menu_rect.ay + (item_idx - 1) * menu_item_h

            local item_rect = { ax = menu_rect.ax, ay = item_y, bx = menu_rect.bx, by = item_y + menu_item_h }
            local is_hover = get_point_to_rectangle_proximity(cursor, item_rect) <= 0

            -- 仅保留悬停背景，移除选中背景
            if is_hover then
                ass:rect(menu_rect.ax, item_y, menu_rect.bx, item_y + menu_item_h,
                    { color = '4a4a4a', opacity = 1.0 })
            end

            local text_size = font_size * 1.1   -- 增大字体
            ass:txt(menu_rect.ax + 10, item_y + menu_item_h / 2, 4, font_name,
                { size = text_size, color = 'eeeeee', bold = true, opacity = 1 })

            cursor:zone('primary_click', item_rect, function()
                self.values.fontname = font_name
                self.font_picker_open = false
                self.font_scroll_offset = 0
                if self.font_close_timer then
                    self.font_close_timer:kill()
                    self.font_close_timer = nil
                end
                self:update_style_settings()
                request_render()
            end)
        end

        -- 滚动条
        local scroll_bar_x = menu_rect.bx - 8
        local scroll_bar_w = 4
        local scroll_bar_h = menu_max_h - 12
        local scroll_bar_y = menu_rect.ay + 6
        ass:rect(scroll_bar_x, scroll_bar_y, scroll_bar_x + scroll_bar_w, scroll_bar_y + scroll_bar_h,
            { color = '333333', opacity = 0.8, radius = 2 })

        if max_scroll > 0 then
            local thumb_h = math.max(24, (menu_max_h / (#FONT_LIST * menu_item_h)) * scroll_bar_h)
            local thumb_y = scroll_bar_y + (self.font_scroll_offset / max_scroll) * (scroll_bar_h - thumb_h)
            ass:rect(scroll_bar_x, thumb_y, scroll_bar_x + scroll_bar_w, thumb_y + thumb_h,
                { color = '777777', opacity = 0.9, radius = 2 })
        end

        cursor:zone('wheel_down', menu_rect, function()
            if self.font_scroll_offset < max_scroll then
                self.font_scroll_offset = self.font_scroll_offset + 1
                request_render()
            end
        end)
        cursor:zone('wheel_up', menu_rect, function()
            if self.font_scroll_offset > 0 then
                self.font_scroll_offset = self.font_scroll_offset - 1
                request_render()
            end
        end)
    end
end

function DanmakuStyles:apply_stroke_type(type_id)
    self.stroke_type = type_id
    self.danmaku_opts.stroke_type = type_id
    self.danmaku_opts.outline = (type_id == 'heavy' and 1.0) or (type_id == 'outline' and 0.3) or 0
    self.danmaku_opts.shadow = (type_id == 'shadow' and 1.2) or 0
    self:update_style_settings()
    request_render()
end

--- 恢复默认设置
function DanmakuStyles:reset_to_defaults()
    local defaults = {
        fontname = '微软雅黑', bold = true,
        outline = 1.0, shadow = 0, stroke_type = 'heavy'
    }

    self.values.fontname = defaults.fontname
    self.values.bold = defaults.bold

    self.danmaku_opts.fontname = defaults.fontname
    self.danmaku_opts.bold = defaults.bold
    self.danmaku_opts.outline = defaults.outline
    self.danmaku_opts.shadow = defaults.shadow

    self.stroke_type = defaults.stroke_type
    self.danmaku_opts.stroke_type = defaults.stroke_type

    self:update_style_settings()
    request_render()
    mp.osd_message('弹幕恢复默认设置', 2)
end

function DanmakuStyles:update_style_settings()
    local values = {
        fontname    = self.values.fontname,
        bold        = tostring(self.values.bold),
        displayarea = tostring(self.values.displayarea),
        opacity     = tostring(self.values.opacity),
        fontsize    = tostring(self.values.fontsize),
        scrolltime  = tostring(self.values.scrolltime),
    }

    for key, value in pairs(values) do
        mp.commandv("script-message-to", "uosc",         "danmaku-style-update", key, value)
        mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", key, value)
    end

    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style",
        "stroke_type", self.stroke_type)
end

return DanmakuStyles