local Element = require('elements/Element')

local VolumeIndicator = class(Element)

function VolumeIndicator:new()
    return Class.new(self)
end

function VolumeIndicator:init()
    Element.init(self, 'volume_indicator', {
        ignores_curtain = true,
        render_order = 20000
    })

    self.height = 80
    self.padding = 16
    self.icon_text_gap = 10

    self.show = false
    self.hide_timer = nil

    self.volume = mp.get_property_native('volume') or 0
    self.mute   = mp.get_property_native('mute') or false

    local function on_volume_change()
        self.volume = mp.get_property_native('volume') or 0
        self.mute   = mp.get_property_native('mute') or false
        if not self.mute then
            self:show_indicator()
        else
            self:hide_indicator()
        end
    end

    local function on_mute_change()
        self.mute = mp.get_property_native('mute') or false
        if self.mute then
            self:hide_indicator()
        else
            self:hide_indicator()
        end
    end

    self:observe_mp_property('volume', 'native', on_volume_change)
    self:observe_mp_property('mute', 'native', on_mute_change)
end

function VolumeIndicator:show_indicator()
    if self.mute then
        self:hide_indicator()
        return
    end
    self.show = true
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    self.hide_timer = mp.add_timeout(1.0, function()
        self.show = false
        self.hide_timer = nil
        request_render()
    end)
    request_render()
end

function VolumeIndicator:hide_indicator()
    self.show = false
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    request_render()
end

function VolumeIndicator:flash()
    self:show_indicator()
end

function VolumeIndicator:render()
    if not self.show then
        return nil
    end

    local ass = assdraw.ass_new()
    local cx = display.width / 2
    local cy = display.height / 2
    local h = self.height

    local icon_size = h * 0.6
    local font_size = h * 0.55
    local left_margin = 20
    local right_margin = 20
    local icon_text_gap = 12

    -- 生成显示文本
    local text_str
    if self.volume == 0 then
        text_str = '静音'
    else
        text_str = tostring(math.floor(self.volume)) .. '%'
    end

    -- 计算最大可能文本宽度（如 "130%"）
    local volume_max = mp.get_property_native('volume-max') or 130
    local max_text_str = tostring(math.floor(volume_max)) .. '%'
    local text_opts = { size = font_size, bold = true }
    local max_text_width = text_width(max_text_str, text_opts)

    -- 最小宽度 = 固定边距 + 图标 + 间距 + 最大文字宽度
    local MIN_WIDTH = left_margin + icon_size + icon_text_gap + max_text_width + right_margin

    -- 实际文本宽度
    local text_width_px = text_width(text_str, text_opts)
    local content_width = left_margin + icon_size + icon_text_gap + text_width_px + right_margin
    local total_width = math.max(MIN_WIDTH, content_width)

    local ax = cx - total_width / 2
    local ay = cy - h / 2
    local bx = ax + total_width
    local by = ay + h

    -- 绘制背景
    ass:rect(ax, ay, bx, by, {
        color = 'ffffff',
        opacity = 0.85,
        radius = 10
    })

    -- 图标（左对齐，固定左边距）
    local icon_x = ax + left_margin + icon_size / 2
    local icon_y = ay + h / 2
    local icon
    if self.mute or self.volume == 0 then
        icon = 'volume_off'
    elseif self.volume <= 30 then
        icon = 'volume_mute'
    elseif self.volume <= 70 then
        icon = 'volume_down'
    else
        icon = 'volume_up'
    end
    ass:icon(icon_x, icon_y, icon_size, icon, {
        color = '000000',
        opacity = 1
    })

    -- 数字（右对齐，固定右边距）
    local text_x = bx - right_margin
    local text_y = icon_y
    ass:txt(text_x, text_y, 6, text_str, {
        size = font_size,
        color = '000000',
        bold = true,
        opacity = 1
    })

    return ass
end

return VolumeIndicator