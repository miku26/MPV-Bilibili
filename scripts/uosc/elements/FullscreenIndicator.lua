local Element = require('elements/Element')

local FullscreenIndicator = class(Element)

function FullscreenIndicator:new()
    return Class.new(self)
end

function FullscreenIndicator:init()
    Element.init(self, 'fullscreen_indicator', {
        ignores_curtain = true,
        render_order = 20000
    })

    self.show = false
    self.hide_timer = nil
    self._first = true
    self.base_font_size = 32

    local function on_fullscreen_change()
        if self._first then
            self._first = false
            return
        end
        local is_fullscreen = mp.get_property_native('fullscreen')
        if is_fullscreen then
            self:show_indicator()
        else
            self:hide_indicator()
        end
    end

    self:observe_mp_property('fullscreen', 'native', on_fullscreen_change)
end

function FullscreenIndicator:show_indicator()
    self.show = true
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    self.hide_timer = mp.add_timeout(1.2, function()
        self.show = false
        self.hide_timer = nil
        request_render()
    end)
    request_render()
end

function FullscreenIndicator:hide_indicator()
    self.show = false
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    request_render()
end

function FullscreenIndicator:render()
    if not self.show then
        return nil
    end

    local ass = assdraw.ass_new()
    local cx = display.width / 2
    local top_margin = round(display.height / 11)

    local font_size = self.base_font_size * options.font_scale
    local padding = round(font_size * 3.0)
    local height = round(font_size * 2.4)

    local text_str = '若要退出全屏，请按Esc'
    local text_opts = { size = font_size, bold = true }
    local text_width_px = text_width(text_str, text_opts)

    local total_width = padding * 2 + text_width_px

    local ax = cx - total_width / 2
    local ay = top_margin
    local bx = ax + total_width
    local by = ay + height

    ass:rect(ax, ay, bx, by, {
        color = '322c28',
        opacity = 1
    })

    ass:txt(cx, ay + height/2, 5, text_str, {
        size = font_size,
        color = 'ffffff',
        bold = true,
        opacity = 1
    })

    return ass
end

return FullscreenIndicator