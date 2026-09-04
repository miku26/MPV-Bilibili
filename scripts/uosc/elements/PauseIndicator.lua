-- elements/PauseIndicator.lua
local Element = require('elements/Element')

---@class PauseIndicator : Element
local PauseIndicator = class(Element)

function PauseIndicator:new() return Class.new(self) --[[@as PauseIndicator]] end
function PauseIndicator:init()
    Element.init(self, 'pause_indicator', {
        ignores_curtain = true,
        render_order = 6.5
    })
    self.paused = state.pause

    self:observe_mp_property('pause', 'bool', function(_, val)
        self.paused = val
        request_render()
    end)
end

function PauseIndicator:render()
    if not self.paused or state.is_idle then return nil end

    local icon_size = round(160 * state.scale)

    -- 直接将图标定位到屏幕正中央
    local cx = display.width / 2
    local cy = display.height / 2

    local ass = assdraw.ass_new()

    -- 绘制电视机+播放图标，并添加阴影
    ass:icon(cx, cy, icon_size, 'live_tv', {
        color = 'ffffff',
        shadow = 3,
        shadow_color = '000000',
        opacity = 1
    })

    return ass
end

return PauseIndicator