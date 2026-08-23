-- elements/Speed.lua
local Element = require('elements/Element')

---@class Speed : Element
local Speed = class(Element)

---@param props? ElementProps
function Speed:new(props) return Class.new(self, props) --[[@as Speed]] end
function Speed:init(props)
    Element.init(self, 'speed', props)

    self.width = 0
    self.height = 0
    self.font_size = nil
    self.panel_open = false
    self.hide_timer = nil
    self._panel_rect = nil

    -- 倍速选项（降序排列，顶部为 2X，底部为 0.5X）
    self.speed_options = {
        {label = '2.0x', value = 2.0},
        {label = '1.5x', value = 1.5},
        {label = '1.25x', value = 1.25},
        {label = '1.0x', value = 1.0},
        {label = '0.75x', value = 0.75},
        {label = '0.5x', value = 0.5},
    }
end

function Speed:get_visibility()
    return Elements:maybe('timeline', 'get_is_hovered') and -1 or Element.get_visibility(self)
end

function Speed:on_coordinates()
    self.height, self.width = self.by - self.ay, self.bx - self.ax
    self.font_size = round(self.height * 0.7)
end

function Speed:on_options()
    self:on_coordinates()
end

function Speed:on_display()
    self._panel_rect = nil
    request_render()
end

function Speed:open_panel()
    if not self.panel_open then
        self.panel_open = true
        Elements:set_min_visibility(1, {'controls'})
        if self.hide_timer then
            self.hide_timer:kill()
            self.hide_timer = nil
        end
        self._panel_rect = nil
        request_render()
    end
end

function Speed:close_panel()
    self.panel_open = false
    Elements:set_min_visibility(0, {'controls'})
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    self._panel_rect = nil
    request_render()
end

function Speed:render()
    local visibility = self:get_visibility()
    local opacity = visibility
    if opacity <= 0 then return end

    local ass = assdraw.ass_new()
    local is_hover = self.proximity_raw <= 0

    -- 悬停打开面板
    if is_hover and not self.panel_open then
        self:open_panel()
    end

    -- 绘制按钮背景和文字
    local speed_rounded = round(state.speed * 100) / 100
    local speed_text = (speed_rounded == 1) and '倍速' or (speed_rounded .. 'x')

    if is_hover then
        local bg_opacity = config.opacity.controls
        if bg_opacity < 0.3 then bg_opacity = 0.3 end

        local opts = { size = self.font_size, bold = true }
        local text_w = text_width(speed_text, opts)
        local text_h = self.font_size * 0.93
        local height = self.by - self.ay
        local pad = (height - self.font_size) / 2
        if pad < 2 * state.scale then pad = 2 * state.scale end

        local bg_w = text_w + pad * 2
        local bg_h = text_h + pad * 2
        local center_x = (self.ax + self.bx) / 2
        local center_y = (self.ay + self.by) / 2

        local ax = center_x - bg_w / 2
        local bx = center_x + bg_w / 2
        local ay = center_y - bg_h / 2
        local by = center_y + bg_h / 2

        ass:rect(ax, ay, bx, by, {
            color = fg,
            opacity = visibility * bg_opacity,
            radius = state.radius,
        })
    end

    ass:txt((self.ax + self.bx) / 2, (self.ay + self.by) / 2, 5, speed_text, {
        size = self.font_size,
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = opacity,
        bold = true,
    })

    -- ---- 面板逻辑 ----
    if self.panel_open then
        local panel_rect = self:get_panel_rect()
        local is_hover_panel = get_point_to_rectangle_proximity(cursor, panel_rect) <= 0

        if is_hover or is_hover_panel then
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

function Speed:get_panel_rect()
    -- 1. 调整选项自身的高度
    local item_height = math.max(28, round(self.height * 0.7))
    -- 2. 减小行与行之间的间距 (如果希望完全贴合，这里可以改成 math.max(0, ...))
    local item_gap = math.max(16, round(self.height * 0.4))
    local font_size = item_height * 0.7

    -- 3. 左右边距
    local padding_h = math.max(18, round(self.height * 0.45))
    -- 4. 上下边距 (让首尾选项和背景有一定距离)
    local padding_v = math.max(16, round(self.height * 0.5))

    -- 计算宽度
    local max_width = 0
    for _, opt in ipairs(self.speed_options) do
        local w = text_width(opt.label, {size = font_size, bold = false})
        if w > max_width then max_width = w end
    end
    local total_width = max_width + padding_h * 2 + 6
    total_width = math.max(total_width, 80)

    local display_count = #self.speed_options
    -- 5. 高度计算：选项个数 * 高度 + 间距总和 + 上下边距
    local total_height = display_count * item_height + (display_count - 1) * item_gap + padding_v * 2
    local max_height = display.height * 0.5
    local final_height = math.min(total_height, max_height)

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
        ax = panel_x, ay = panel_y, bx = panel_x + total_width, by = panel_y + final_height,
        _item_height = item_height,
        _item_gap = item_gap,
        _padding_h = padding_h,
        _padding_v = padding_v,
        _display_count = display_count,
        _font_size = font_size,
    }
end

function Speed:draw_panel(ass, rect)
    -- 关键修正：从 rect 提取我们在上面定义的参数
    local item_height = rect._item_height or 32
    local item_gap = rect._item_gap or 4
    local padding_v = rect._padding_v or 8
    local row_step = item_height + item_gap  -- 每项(包括间距)占用的总步长

    local display_count = rect._display_count or 0
    local font_size = rect._font_size or (item_height * 0.7)

    -- 绘制面板背景
    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
        color = '000000',
        opacity = 0.85,
        radius = round(2 * state.scale),
    })

    for i = 1, display_count do
        local opt = self.speed_options[i]
        
        -- 关键修正：使用 padding_v 作为顶部偏移，并计算间距
        local item_y = rect.ay + padding_v + (i - 1) * row_step
        local item_rect = {
            ax = rect.ax,
            ay = item_y,
            bx = rect.bx,
            by = item_y + item_height
        }

        local clip_str = '\\clip(' .. item_rect.ax .. ',' .. item_rect.ay .. ',' .. item_rect.bx .. ',' .. item_rect.by .. ')'

        local is_hover_item = get_point_to_rectangle_proximity(cursor, item_rect) <= 0
        if is_hover_item then
            ass:rect(item_rect.ax, item_rect.ay, item_rect.bx, item_rect.by, {
                color = 'ffffff',
                opacity = 0.4,
                radius = 0,
                clip = clip_str
            })
        end

        local text_color = (state.speed == opt.value) and 'ecae00' or 'ffffff'
        ass:txt((rect.ax + rect.bx) / 2, item_y + item_height / 2, 5, opt.label, {
            size = font_size * 1.4,
            color = text_color,
            bold = (state.speed == opt.value),
            opacity = 0.9,
            clip = clip_str
        })

        cursor:zone('primary_click', item_rect, function()
            mp.set_property_native('speed', opt.value)
            self:close_panel()
        end)
    end
end

return Speed