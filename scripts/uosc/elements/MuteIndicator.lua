local Element = require('elements/Element')

local MuteIndicator = class(Element)

function MuteIndicator:new()
    return Class.new(self)
end

function MuteIndicator:init()
    Element.init(self, 'mute_indicator', {
        ignores_curtain = true,
        render_order = 20000
    })

    self.show = false
    self.hide_timer = nil
    self.mute = mp.get_property_native('mute') or false
    self._first = true

    self.base_font_size = 32

    local function on_mute_change()
        if self._first then
            self._first = false
            return
        end
        self.mute = mp.get_property_native('mute') or false
        self:show_indicator()
    end

    self:observe_mp_property('mute', 'native', on_mute_change)
end

function MuteIndicator:show_indicator()
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

function MuteIndicator:hide_indicator()
    self.show = false
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    request_render()
end

function MuteIndicator:render()
    if not self.show then
        return nil
    end

    local ass = assdraw.ass_new()
    local cx = display.width / 2
    local cy = display.height / 2

    local font_size = self.base_font_size * options.font_scale

    -- 根据字体大小计算内边距和高度
    local padding = round(font_size * 0.4)
    local height = round(font_size * 1.6)

    -- 显示文字
    local text_str = self.mute and '静音' or '关闭静音'

    local text_opts = {
        size = font_size,
        bold = true,
    }
    local text_width_px = text_width(text_str, text_opts)

    -- 总宽度 = 左右内边距 + 文字宽度
    local total_width = padding * 2 + text_width_px

    local ax = cx - total_width / 2
    local ay = cy - height / 2
    local bx = ax + total_width
    local by = ay + height

    -- 黑色背景，圆角
    ass:rect(ax, ay, bx, by, {
        color = '000000',
        opacity = 1,
        radius = round(height * 0.15)
    })

    -- 白色文字，居中
    local text_x = cx
    local text_y = ay + height / 2
    ass:txt(text_x, text_y, 5, text_str, {
        size = font_size,
        color = 'ffffff',
        bold = true,
        opacity = 1
    })

    return ass
end

return MuteIndicator