local Element = require('elements/Element')

---@class ExitFullscreenHint : Element
local ExitFullscreenHint = class(Element)

function ExitFullscreenHint:new()
    return Class.new(self)
end

function ExitFullscreenHint:init()
    Element.init(self, 'exit_fullscreen_hint', {
        ignores_curtain = true,
        render_order = 10000,
    })

    self.visible = false
    self.timer = nil
    self.threshold = 10
    self.color = '322c28'
    self.opacity = 0.9
    self.duration = 1.2
    self.fullscreen = mp.get_property_native('fullscreen') or false
    self.triggered = false

    self:observe_mp_property('fullscreen', 'native', function(_, val)
        self.fullscreen = val
        if not val then
            self.visible = false
            self.triggered = false
            if self.timer then
                self.timer:kill()
                self.timer = nil
            end
            request_render()
        end
    end)
end

function ExitFullscreenHint:render()
    if not self.fullscreen then return end
    if cursor.hidden or cursor.x == math.huge or cursor.y == math.huge then return end

    local in_top = cursor.y <= self.threshold

    if in_top then
        if not self.triggered then
            self.triggered = true
            self.visible = true
            request_render()

            if self.timer then
                self.timer:kill()
                self.timer = nil
            end
            self.timer = mp.add_timeout(self.duration, function()
                self.visible = false
                self.timer = nil
                request_render()
            end)
        end
    else
        self.triggered = false
    end

    if not self.visible then return end

    local icon_size = math.max(25, math.min(display.width, display.height) / 40)
    local circle_radius = round(icon_size * 1.1)
    local cx = display.width / 2
    local cy = display.height / 12

    local ass = assdraw.ass_new()

    -- 圆形背景
    ass:circle(cx, cy, circle_radius, {
        color = self.color,
        opacity = self.opacity,
    })

    -- close
    ass:icon(cx, cy, icon_size * 1.2, 'close', {
        color = 'ffffff',
        opacity = 1,
    })

    -- 点击区域（圆形）
    local hitbox = {point = {x = cx, y = cy}, r = circle_radius}
    cursor:zone('primary_click', hitbox, function()
        mp.commandv('set', 'fullscreen', 'no')
    end)

    return ass
end

return ExitFullscreenHint