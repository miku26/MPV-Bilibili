-- elements/DanmakuStyles.lua
local Element = require('elements/Element')
-- 预设字体列表（供下拉菜单使用）
local FONT_LIST = {
    "黑体", "宋体", "新宋体", "仿宋",
    "微软雅黑", "微软雅黑 Light",
    "思源宋体", "思源黑体"
}
---@class DanmakuStyles : Element
local DanmakuStyles = class(Element)

function DanmakuStyles:new(id, props)
    return Class.new(self, id, props)
end

function DanmakuStyles:init(id, props)
    Element.init(self, id, props)
    self.tooltip = props.tooltip or '弹幕设置'
    self.panel_open = false
    self.font_picker_open = false   -- 控制下拉菜单展开/收起
    self.font_scroll_offset = 0     -- 字体下拉列表滚动偏移量
    self.font_close_timer = nil     -- 关闭下拉菜单的延迟定时器
    self.hide_timer = nil
    self.font_size = 0

    -- 页面控制
    self.current_page = 'main'

    -- 获取 uosc_danmaku 的配置表
    self.danmaku_opts = _G.danmaku_options or {}
    self.values = {
        displayarea = tonumber(self.danmaku_opts.displayarea) or 0.6,
        opacity = tonumber(self.danmaku_opts.opacity) or 0.7,
        fontsize = tonumber(self.danmaku_opts.fontsize) or 38,
        scrolltime = tonumber(self.danmaku_opts.scrolltime) or 15,
        fontname = self.danmaku_opts.fontname or '微软雅黑',
        bold = self.danmaku_opts.bold == true,
    }
    -- 检测当前描边类型
    self.stroke_type = self:detect_stroke_type()

    self._dragging = nil

    -- 监听滑块和界面的反同步更新
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

function DanmakuStyles:on_coordinates()
    self.font_size = round((self.by - self.ay) * 0.7)
end

function DanmakuStyles:on_display()
    self._panel_rect = nil
    request_render()
end

function DanmakuStyles:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    local ass = assdraw.ass_new()
    local is_hover_button = self.proximity_raw <= 0
    local center_x = (self.ax + self.bx) / 2
    local center_y = (self.ay + self.by) / 2

	if is_hover_button then
		ass:rect(self.ax, self.ay, self.bx, self.by, {
			color = fg,
			opacity = 0.3,
			radius = state.radius
		})
	end
	ass:icon(center_x, center_y, self.font_size, 'chat', {
		color = bgt,
		border = options.text_border * state.scale,
		border_color = bg,
		opacity = visibility,
	})

    if is_hover_button and not self.panel_open then
        self:open_panel()
    end

    if self.panel_open then
        if not self._panel_rect then
            self._panel_rect = self:get_panel_rect()
        end
        local panel_rect = self._panel_rect
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

        if self.current_page == 'main' then
            self:draw_main_panel(ass, panel_rect)
        else
            self:draw_advanced_panel(ass, panel_rect)
        end
    end

    return ass
end

function DanmakuStyles:open_panel()
    if not self.panel_open then
        self.panel_open = true
        self.current_page = 'main'
        Elements:set_min_visibility(1, {'controls'})
        if self.hide_timer then
            self.hide_timer:kill()
            self.hide_timer = nil
        end
        self._panel_rect = nil
        request_render()
    end
end

function DanmakuStyles:close_panel()
    self.panel_open = false
    self.font_picker_open = false
    Elements:set_min_visibility(0, {'controls'})
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    self._panel_rect = nil
    if self._dragging then
        cursor:off('move', self._dragging.move_handler)
        cursor:off('primary_up', self._dragging.up_handler)
        self._dragging = nil
    end
    request_render()
end

local sliders_config = {
    {
        key = 'displayarea',
        label = '显示区域',
        min = 0.25,
        max = 1.0,
        step = 0.25,
        get_display = function(val) return string.format('%.0f%%', val * 100) end,
        get_raw = function(val) return val end,
        show_ticks = true
    },
    {
        key = 'opacity',
        label = '不透明度',
        min = 0.15,
        max = 1,
        step = 0.01,
        get_display = function(val) return string.format('%.0f%%', val * 100) end,
        get_raw = function(val) return val end,
        show_ticks = false
    },
    {
        key = 'fontsize',
        label = '弹幕字号',
        min = 50,
        max = 170,
        step = 1,
        get_display = function(val) return string.format('%.0f%%', val) end,
        get_raw = function(val) return math.floor(val * 36 / 100) end,  -- 修正字段名
        show_ticks = false
    },
    {
        key = 'scrolltime',
        label = '弹幕速度',
        min = 5,
        max = 25,
        step = 5,
        get_display = function(val)
            local speed_texts = { [5]='极快', [10]='较快', [15]='适中', [20]='较慢', [25]='极慢' }
            local stepped = math.floor((val - 5) / 5 + 0.5) * 5 + 5
            return speed_texts[stepped] or tostring(val)
        end,
        get_raw = function(val) return val end,
        show_ticks = true
    }
}

-- ============================================================
-- 自适应面板尺寸计算
-- ============================================================
function DanmakuStyles:get_panel_rect()
    local button_height = self.by - self.ay
    local row_height = math.max(64, round(button_height * 1.2))
    local padding_h = math.max(28, round(button_height * 0.4))

    -- 提前复制测量逻辑（与 draw_main_panel 保持一致）
    local font_size = row_height * 0.42
    local max_label_width, max_value_width = 0, 0
    for _, slider in ipairs(sliders_config) do
        local lw = text_width(slider.label, {size = font_size, bold = true})
        if lw > max_label_width then max_label_width = lw end

        local max_w = 0
        for val = slider.min, slider.max, slider.step do
            local display_text = slider.get_display(val)
            local w = text_width(display_text, {size = font_size, bold = true})
            if w > max_w then max_w = w end
        end
        if max_w > max_value_width then max_value_width = max_w end
    end

    -- 控制条与文本的固定距离
    local left_margin = 12
    local right_margin = math.floor(left_margin * 1.8)

    -- 设定控制条自身的基准宽度
    local slider_width = row_height * 1.9

    -- 计算背景实际需要的总宽度
    local required_width = padding_h + max_label_width + left_margin + slider_width + right_margin + max_value_width + padding_h
    local total_width = math.max(420, required_width)

    -- 其余位置计算保持不变
    local center_x = (self.ax + self.bx) / 2
    local panel_x = center_x - total_width / 2
	
    -- 动态计算面板高度
    local panel_height
    if self.current_page == 'main' then
        panel_height = 5 * row_height
	else
        -- 高级面板：高度基于文字与间距动态拼凑
        local pad = math.max(20, round(font_size * 0.65))
        local gap = math.max(8, round(font_size * 0.4))
        local h_title = round(font_size * 1.6)
        local h_label = round(font_size * 1.0)
        local h_input = round(font_size * 1.2)

		panel_height = gap + h_title + gap + h_label + gap + h_input + gap + h_label + gap + h_input + gap*2 + h_input + pad * 1.6
    end

	local panel_y = self.ay - panel_height - 20
    if panel_y < 20 then
        panel_y = self.by + 20
        if panel_y + panel_height > display.height - 20 then
            panel_y = 20
        end
    end
    panel_x = math.max(20, math.min(panel_x, display.width - total_width - 20))

	return {
        ax = panel_x, ay = panel_y,
        bx = panel_x + total_width, by = panel_y + panel_height,
        _row_height = row_height, _padding_h = padding_h,
        _font_size = font_size, _total_width = total_width,
    }
end

function DanmakuStyles:get_panel_height(row_height)
    if self.current_page == 'main' then
        return 5 * row_height
    else
        return 6.5 * row_height
    end
end

function DanmakuStyles:detect_stroke_type()
    local out = tonumber(self.danmaku_opts.outline) or 1.0
    local shd = tonumber(self.danmaku_opts.shadow) or 0
    if out == 0.3 and shd == 0 then return 'outline' end
    if out == 0 and shd == 1.2 then return 'shadow' end
    return 'heavy'
end

-- 主面板绘制
function DanmakuStyles:draw_main_panel(ass, rect)
    local padding_h = rect._padding_h or 28
    local row_height = rect._row_height or 64
    local font_size = rect._font_size or (row_height * 0.4)
    local panel_clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')'

    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, { color = bg, opacity = 0.85, radius = round(2 * state.scale) })

    -- 预计算：固定最大宽度，防止轨道晃动
    local max_label_width, max_value_width = 0, 0
    for _, slider in ipairs(sliders_config) do
        local max_w = 0
        for val = slider.min, slider.max, slider.step do
            local display_text = slider.get_display(val)
            local w = text_width(display_text, {size = font_size, bold = true})
            if w > max_w then max_w = w end
        end
        if max_w > max_value_width then max_value_width = max_w end
        local lw = text_width(slider.label, {size = font_size, bold = true})
        if lw > max_label_width then max_label_width = lw end
    end

    local left_margin = 12
    local right_margin = math.floor(left_margin * 1.8)
    local slider_left = rect.ax + padding_h + max_label_width + left_margin
    local slider_right = rect.bx - padding_h - max_value_width - right_margin

    -- 统一顶部和底部留白比例
    local top_pad = row_height * 0.15
    local bottom_pad = row_height * 0.15

    for row, slider in ipairs(sliders_config) do
        local item_y = rect.ay + top_pad + (row - 1) * row_height
        local raw = self.values[slider.key]
        local sv = (slider.key == 'fontsize') and math.max(slider.min, math.min(slider.max, raw / 36 * 100)) or raw
        local display_text = slider.get_display(sv)

        -- 左对齐的文字标签
        ass:txt(rect.ax + padding_h, item_y + row_height / 2, 4, slider.label, { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
        -- 右对齐的百分比数值
        ass:txt(rect.bx - padding_h, item_y + row_height / 2, 6, display_text, { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })

        local track_y = item_y + row_height / 2
        local track_height = round(6 * state.scale)
        local thumb_radius = round(6 * state.scale)
        local t = (sv - slider.min) / (slider.max - slider.min)
        local thumb_x = slider_left + t * (slider_right - slider_left)
        thumb_x = math.max(slider_left + thumb_radius, math.min(slider_right - thumb_radius, thumb_x))

        ass:rect(slider_left, track_y - track_height/2, slider_right, track_y + track_height/2, { color = fg, opacity = 0.25, radius = track_height/2, clip = panel_clip })
        ass:rect(slider_left, track_y - track_height/2, thumb_x, track_y + track_height/2, { color = 'ecae00', opacity = 0.9, radius = track_height/2, clip = panel_clip })
        ass:circle(thumb_x, track_y, thumb_radius, { color = fg, opacity = 1, clip = panel_clip })

        if slider.show_ticks and slider.step then
            for val = slider.min, slider.max, slider.step do
                local tick_t = (val - slider.min) / (slider.max - slider.min)
                local tick_x = slider_left + tick_t * (slider_right - slider_left)
                if math.abs(tick_x - thumb_x) > thumb_radius + 2 then
                    ass:circle(tick_x, track_y, round(2 * state.scale), {
                        color = 'ffffff', opacity = 1, clip = panel_clip
                    })
                end
            end
        end

        local track_rect = { ax = slider_left, ay = item_y, bx = slider_right, by = item_y + row_height }
        cursor:zone('primary_down', track_rect, function() self:_start_slider_drag(slider, slider_left, slider_right, track_y, item_y) end)
        cursor:zone('wheel_down', track_rect, function() self:_adjust_slider(slider, -1) end)
        cursor:zone('wheel_up', track_rect, function() self:_adjust_slider(slider, 1) end)
    end

    -- 底部入口
    local entry_h = row_height * 0.7
    local entry_y = rect.by - entry_h - bottom_pad
    local line_y = entry_y - 2

    -- 灰线
    ass:rect(rect.ax + padding_h, line_y, rect.bx - padding_h, line_y + 1, { color = fg, opacity = 0.15, clip = panel_clip })
    -- 高级设置文本
    ass:txt(rect.ax + padding_h, entry_y + entry_h / 2, 4, '高级设置', { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
    -- 右箭头
    ass:icon(rect.bx - padding_h, entry_y + entry_h / 2, font_size * 0.9, 'navigate_next', { color = bgt, opacity = 1, align = 6, clip = panel_clip })

    cursor:zone('primary_click', { ax = rect.ax, ay = entry_y, bx = rect.bx, by = entry_y + entry_h }, function()
        self.current_page = 'advanced'
        self._panel_rect = nil
        request_render()
    end)
end

	-- 高级面板绘制
function DanmakuStyles:draw_advanced_panel(ass, rect)
    -- 读取尺寸参数
    local font_size = rect._font_size or ((rect.by - rect.ay) * 0.35)
    local panel_clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')'

    -- 内部元素间距
    local pad = math.max(20, round(font_size * 0.65))
    local gap = math.max(8, round(font_size * 0.4))
    local h_title = round(font_size * 1.6)
    local h_label = round(font_size * 1.0)
    local h_input = round(font_size * 1.2)

    -- 配色与圆角
    local active_color = 'ecae00' 
    local btn_radius = round(2 * state.scale)

    -- 1. 绘制弹窗背景
    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, { color = bg, opacity = 0.85, radius = btn_radius })
    local y = rect.ay + gap

    -- 2. 标题行：返回箭头 + 文字
    ass:icon(rect.ax + pad, y + h_title/2, font_size * 0.9, 'navigate_before', { color = bgt, opacity = 1, clip = panel_clip })
    ass:txt(rect.ax + pad + font_size + 8, y + h_title/2, 4, '更多弹幕设置', { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
    cursor:zone('primary_click', { ax = rect.ax, ay = y, bx = rect.bx, by = y + h_title }, function()
        self.current_page = 'main'
        self._panel_rect = nil
        request_render()
    end)

    y = y + h_title

    ass:rect(rect.ax, y, rect.bx, y + 1, { color = fg, opacity = 0.15, clip = panel_clip })
    y = y + gap

    -- 3. “弹幕字体”标签
    ass:txt(rect.ax + pad, y + h_label/2, 4, '弹幕字体', { size = font_size, color = fg, bold = true, opacity = 1, clip = panel_clip })
    y = y + h_label + gap

    -- ================== 字体选择框 ==================
    local font_text_opts = { size = font_size, bold = true }
    local cb_size = round(font_size * 0.75)
    local cb_y = y + (h_input - cb_size) / 2
    local bold_text_w = text_width('粗体', font_text_opts)
    local bold_total_w = cb_size + 8 + bold_text_w
    local bold_start_x = (rect.bx - pad) - bold_total_w

    -- 字体框的矩形范围
    local gap_between = round(font_size * 0.6)
    local font_box_w = bold_start_x - (rect.ax + pad) - gap_between
    font_box_w = math.max(160, font_box_w)
    local font_box_x = rect.ax + pad
    local font_box_y = y
    local font_box_h = h_input
    local font_box_rect = { ax = font_box_x, ay = font_box_y, bx = font_box_x + font_box_w, by = font_box_y + font_box_h }

    -- 绘制字体框背景和文字
    ass:rect(font_box_x, font_box_y, font_box_x + font_box_w, font_box_y + font_box_h,
        { color = fg, opacity = 0.15, border = 1, border_color = fg, radius = btn_radius, clip = panel_clip })
    ass:txt(font_box_x + 12, font_box_y + font_box_h / 2, 4, self.values.fontname,
        { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })
    -- 下拉箭头图标
    ass:icon(font_box_x + font_box_w - 20, font_box_y + font_box_h / 2, font_size * 0.9, 'expand_more', { color = bgt, opacity = 0.7, clip = panel_clip })

    -- ================== 粗体复选框 ==================
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

    -- ================== 下拉菜单区域（悬停触发，滚轮控制，左键选择） ==================
    -- 1. 先计算菜单所需要的尺寸
    local menu_item_h = h_input
    local menu_w = font_box_w
    local menu_x = font_box_x
    local menu_y = font_box_y + font_box_h
    local total_needed_h = #FONT_LIST * menu_item_h
    local menu_max_h = math.min(total_needed_h, rect.by - menu_y - 5)

    -- 若下方空间不够，则向上展开
    if menu_y + menu_max_h > rect.by then
        menu_y = font_box_y - menu_max_h
        if menu_y < rect.ay then
            menu_y = rect.ay
            menu_max_h = math.min(total_needed_h, rect.by - rect.ay)
        end
    end
    local menu_rect = { ax = menu_x, ay = menu_y, bx = menu_x + menu_w, by = menu_y + menu_max_h }
    
    -- 2. 检测悬停逻辑
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

    -- 5. “描边类型”标签
    ass:txt(rect.ax + pad, y + h_label/2, 4, '描边类型', { size = font_size, color = fg, bold = true, opacity = 1, clip = panel_clip })
    y = y + h_label + gap

    -- ================== 描边按钮平均分布 ==================
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
    y = y + h_input + gap*2

    -- ================== 恢复默认设置 ==================
    ass:rect(rect.ax, y, rect.bx, y + 1, { color = fg, opacity = 0.15, clip = panel_clip })
    y = y + gap

    local reset_text = '恢复默认设置'
    local reset_w = (rect.bx - rect.ax) * 0.5
    local reset_x = rect.ax + pad
    local reset_h = h_input

    ass:rect(reset_x, y, reset_x + reset_w, y + reset_h, { color = fg, opacity = 0.15, border = 1, border_color = fg, radius = btn_radius, clip = panel_clip })
    ass:txt(reset_x + reset_w/2, y + reset_h/2, 5, reset_text, { size = font_size, color = bgt, bold = true, opacity = 1, clip = panel_clip })

    cursor:zone('primary_click', { ax=reset_x, ay=y, bx=reset_x+reset_w, by=y+reset_h }, function()
        self:reset_to_defaults()
    end)

    -- ============================================================
    -- 【移到最底部绘制的下拉菜单，确保在最上层】
    -- ============================================================
    if self.font_picker_open then
        local max_visible = math.floor(menu_max_h / menu_item_h)
        local max_scroll = #FONT_LIST - max_visible
        if max_scroll < 0 then max_scroll = 0 end

        -- 防止偏移越界
        if self.font_scroll_offset > max_scroll then self.font_scroll_offset = max_scroll end

        -- 绘制菜单背景
        ass:rect(menu_rect.ax, menu_rect.ay, menu_rect.bx, menu_rect.by,
            { color = '1c1c1c', opacity = 1.0, border = 1, border_color = '333333', radius = btn_radius })

        -- 绘制每个字体选项
        local start_i = 1 + self.font_scroll_offset
        local end_i = math.min(#FONT_LIST, max_visible + self.font_scroll_offset)

        for i = start_i, end_i do
            local font_name = FONT_LIST[i]
            local item_idx = i - self.font_scroll_offset
            local item_y = menu_rect.ay + (item_idx - 1) * menu_item_h
            local is_selected = (self.values.fontname == font_name)
            
            -- 检测鼠标悬停高亮
            local item_rect = { ax = menu_rect.ax, ay = item_y, bx = menu_rect.bx, by = item_y + menu_item_h }
            local is_hover = get_point_to_rectangle_proximity(cursor, item_rect) <= 0

            local item_bg_color = '333333'
            if is_selected then
                item_bg_color = '2c2c2c'
            elseif is_hover then
                item_bg_color = '4a4a4a'
            end

            if is_selected or is_hover then
                ass:rect(menu_rect.ax, item_y, menu_rect.bx, item_y + menu_item_h,
                    { color = item_bg_color, opacity = 1.0 })
            end
            
            -- 文字使用浅色/白色
            ass:txt(menu_rect.ax + 10, item_y + menu_item_h / 2, 4, font_name,
                { size = font_size * 0.9, color = 'eeeeee', bold = true, opacity = 1 })

            -- 左键点击选择字体并关闭菜单
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

        -- 绘制右侧滚动条区域
        local scroll_bar_x = menu_rect.bx - 8
        local scroll_bar_w = 4
        local scroll_bar_h = menu_max_h - 12
        local scroll_bar_y = menu_rect.ay + 6
        ass:rect(scroll_bar_x, scroll_bar_y, scroll_bar_x + scroll_bar_w, scroll_bar_y + scroll_bar_h, 
            { color = '333333', opacity = 0.8, radius = 2 })

        -- 绘制滚动条滑块
        if max_scroll > 0 then
            local thumb_h = math.max(24, (menu_max_h / total_needed_h) * scroll_bar_h)
            local thumb_y = scroll_bar_y + (self.font_scroll_offset / max_scroll) * (scroll_bar_h - thumb_h)
            ass:rect(scroll_bar_x, thumb_y, scroll_bar_x + scroll_bar_w, thumb_y + thumb_h,
                { color = '777777', opacity = 0.9, radius = 2 })
        end

        -- 滚轮滚动事件绑定
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

-- 交互逻辑
function DanmakuStyles:_start_slider_drag(slider, left, right, track_y, item_y)
    if self._dragging then
        cursor:off('move', self._dragging.move_handler)
        cursor:off('primary_up', self._dragging.up_handler)
        self._dragging = nil
    end

    local function move_handler()
        local t = (cursor.x - left) / (right - left)
        t = math.max(0, math.min(1, t))
        local val = slider.min + (slider.max - slider.min) * t
        if slider.step then val = math.floor((val - slider.min) / slider.step + 0.5) * slider.step + slider.min end
        val = math.max(slider.min, math.min(slider.max, val))
        self:apply_slider_value(slider, val)
    end
    local function up_handler()
        if self._dragging then
            cursor:off('move', self._dragging.move_handler)
            cursor:off('primary_up', self._dragging.up_handler)
            self._dragging = nil
        end
        self:update_style_settings()
    end

    cursor:on('move', move_handler)
    cursor:once('primary_up', up_handler)
    self._dragging = { key = slider.key, move_handler = move_handler, up_handler = up_handler }
    move_handler()
end

function DanmakuStyles:_adjust_slider(slider, step)
    local raw = self.values[slider.key]
    local sv = (slider.key == 'fontsize') and (raw / 36 * 100) or raw
    local new_val = sv + (slider.step or 1) * step
    new_val = math.max(slider.min, math.min(slider.max, new_val))
    self:apply_slider_value(slider, new_val)
end

function DanmakuStyles:apply_slider_value(slider, val)
    local actual = (slider.key == 'fontsize') and slider.get_raw(val) or val
    self.values[slider.key] = actual
    request_render()
end

function DanmakuStyles:apply_stroke_type(type_id)
    self.stroke_type = type_id
    self.danmaku_opts.stroke_type = type_id
    self.danmaku_opts.outline = (type_id == 'heavy' and 1.0) or (type_id == 'outline' and 0.3) or 0
    self.danmaku_opts.shadow = (type_id == 'shadow' and 1.2) or 0
    self:update_style_settings()
    request_render()
end

	--恢复默认设置
function DanmakuStyles:reset_to_defaults()
    -- 预设只包含 2 级菜单的默认值：字体为微软雅黑，粗体开启，描边为重墨
    local defaults = {
        fontname = '微软雅黑', bold = true,
        outline = 1.0, shadow = 0, stroke_type = 'heavy'
    }
    
    -- 仅更新 2 级菜单相关的设置
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
    -- 1. 通知 uosc 面板同步显示
    mp.commandv("script-message-to", "uosc", "danmaku-style-update", "fontname", self.values.fontname)
    mp.commandv("script-message-to", "uosc", "danmaku-style-update", "bold", tostring(self.values.bold))
    mp.commandv("script-message-to", "uosc", "danmaku-style-update", "displayarea", tostring(self.values.displayarea))
    mp.commandv("script-message-to", "uosc", "danmaku-style-update", "opacity", tostring(self.values.opacity))
    mp.commandv("script-message-to", "uosc", "danmaku-style-update", "fontsize", tostring(self.values.fontsize))
    mp.commandv("script-message-to", "uosc", "danmaku-style-update", "scrolltime", tostring(self.values.scrolltime))

    -- 2. 通知 uosc_danmaku 更新所有样式字段
    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", "fontname", self.values.fontname)
    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", "bold", tostring(self.values.bold))
    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", "fontsize", tostring(self.values.fontsize))
    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", "opacity", tostring(self.values.opacity))
    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", "displayarea", tostring(self.values.displayarea))
    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", "scrolltime", tostring(self.values.scrolltime))
    mp.commandv("script-message-to", "uosc_danmaku", "setup-danmaku-style", "stroke_type", self.stroke_type)
end

return DanmakuStyles