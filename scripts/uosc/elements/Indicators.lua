-- elements/Indicators.lua
local Element = require('elements/Element')

-- ============================================================
-- BaseIndicator: 所有一次性提示的基类
-- ============================================================
---@class BaseIndicator : Element
local BaseIndicator = class(Element)

BaseIndicator.duration = 1.0
BaseIndicator.render_order = 20000

function BaseIndicator:init(id, props)
    Element.init(self, id, table_assign({
        ignores_curtain = true,
        render_order = self.render_order,
    }, props or {}))
    self.show = false
    self.hide_timer = nil
end

function BaseIndicator:show_indicator(duration)
    self.show = true
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    self.hide_timer = mp.add_timeout(duration or self.duration, function()
        self.show = false
        self.hide_timer = nil
        request_render()
    end)
    request_render()
end

function BaseIndicator:hide_indicator()
    self.show = false
    if self.hide_timer then
        self.hide_timer:kill()
        self.hide_timer = nil
    end
    request_render()
end

-- ============================================================
-- BufferingIndicator
-- ============================================================
---@class BufferingIndicator : Element
local BufferingIndicator = class(Element)

function BufferingIndicator:init()
    Element.init(self, 'buffering_indicator', {ignores_curtain = true, render_order = 2})
    self.enabled = false
    self:decide_enabled()
end

function BufferingIndicator:decide_enabled()
    local cache = state.cache_underrun or state.cache_buffering and state.cache_buffering < 100
    local player = state.core_idle and not state.eof_reached
    if self.enabled then
        if not player or (state.pause and not cache) then self.enabled = false end
    elseif player and cache and state.uncached_ranges then
        self.enabled = true
    end
end

function BufferingIndicator:on_prop_pause() self:decide_enabled() end
function BufferingIndicator:on_prop_core_idle() self:decide_enabled() end
function BufferingIndicator:on_prop_eof_reached() self:decide_enabled() end
function BufferingIndicator:on_prop_uncached_ranges() self:decide_enabled() end
function BufferingIndicator:on_prop_cache_buffering() self:decide_enabled() end
function BufferingIndicator:on_prop_cache_underrun() self:decide_enabled() end

function BufferingIndicator:render()
    local ass = assdraw.ass_new()
    ass:rect(0, 0, display.width, display.height, {color = bg, opacity = config.opacity.buffering_indicator})
    local size = round(30 + math.min(display.width, display.height) / 10)
    local opacity = (Elements.menu and Elements.menu:is_alive()) and 0.3 or 0.8
    ass:spinner(display.width / 2, display.height / 2, size, {color = fg, opacity = opacity})
    return ass
end

-- ============================================================
-- PauseIndicator
-- ============================================================
---@class PauseIndicator : Element
local PauseIndicator = class(Element)

function PauseIndicator:init()
    Element.init(self, 'pause_indicator', {ignores_curtain = true, render_order = 6.5})
    self.paused = state.pause
    self:observe_mp_property('pause', 'bool', function(_, val)
        self.paused = val
        request_render()
    end)
end

function PauseIndicator:render()
    if not self.paused or state.is_idle then return nil end
    local icon_size = round(160 * state.scale)
    local cx, cy = display.width / 2, display.height / 2
    local ass = assdraw.ass_new()
    ass:icon(cx, cy, icon_size, 'live_tv', {color = 'ffffff', shadow = 3, shadow_color = '000000', opacity = 1})
    return ass
end

-- ============================================================
-- MuteIndicator
-- ============================================================
---@class MuteIndicator : BaseIndicator
local MuteIndicator = class(BaseIndicator)

MuteIndicator.render_order = 20000
MuteIndicator.duration = 1.0

function MuteIndicator:init()
    BaseIndicator.init(self, 'mute_indicator')
    self.mute = mp.get_property_native('mute') or false
    self._first = true
    self.base_font_size = 32
    self:observe_mp_property('mute', 'native', function()
        if self._first then self._first = false; return end
        self.mute = mp.get_property_native('mute') or false
        self:show_indicator()
    end)
end

function MuteIndicator:render()
    if not self.show then return nil end
    local ass = assdraw.ass_new()
    local cx, cy = display.width / 2, display.height / 2
    local font_size = self.base_font_size * options.font_scale
    local padding = round(font_size * 0.4)
    local height = round(font_size * 1.6)
    local text_str = self.mute and '静音' or '关闭静音'
    local text_w = text_width(text_str, {size = font_size, bold = true})
    local total_w = padding * 2 + text_w
    local ax, ay = cx - total_w / 2, cy - height / 2
    ass:rect(ax, ay, ax + total_w, ay + height, {color = '000000', opacity = 1, radius = round(height * 0.15)})
    ass:txt(cx, ay + height / 2, 5, text_str, {size = font_size, color = 'ffffff', bold = true, opacity = 1})
    return ass
end

-- ============================================================
-- VolumeIndicator
-- ============================================================
---@class VolumeIndicator : BaseIndicator
local VolumeIndicator = class(BaseIndicator)

VolumeIndicator.render_order = 20000
VolumeIndicator.duration = 1.0

function VolumeIndicator:init()
    BaseIndicator.init(self, 'volume_indicator')
    self.height = 80
    self.volume = mp.get_property_native('volume') or 0
    self.mute = mp.get_property_native('mute') or false

    local function on_change()
        local new_volume = mp.get_property_native('volume') or 0
        local new_mute   = mp.get_property_native('mute') or false
        local changed = (new_volume ~= self.volume) or (new_mute ~= self.mute)
        self.volume = new_volume
        self.mute   = new_mute
        if not changed then return end
        if self.mute then
            self:hide_indicator()
        else
            self:show_indicator()
        end
    end
    self:observe_mp_property('volume', 'native', on_change)
    self:observe_mp_property('mute', 'native', on_change)
end

function VolumeIndicator:flash() self:show_indicator() end

function VolumeIndicator:render()
    if not self.show or self.mute then return nil end
    local ass = assdraw.ass_new()
    local cx, cy = display.width / 2, display.height / 2
    local h = self.height
    local icon_size, font_size = h * 0.6, h * 0.55
    local left_margin, right_margin, gap = 20, 20, 12

    local text_str = self.volume == 0 and '静音' or (tostring(math.floor(self.volume)) .. '%')
    local text_opts = {size = font_size, bold = true}
    local max_vol = mp.get_property_native('volume-max') or 130
    local max_text_w = text_width(tostring(math.floor(max_vol)) .. '%', text_opts)
    local min_w = left_margin + icon_size + gap + max_text_w + right_margin
    local content_w = left_margin + icon_size + gap + text_width(text_str, text_opts) + right_margin
    local total_w = math.max(min_w, content_w)

    local ax, ay = cx - total_w / 2, cy - h / 2
    ass:rect(ax, ay, ax + total_w, ay + h, {color = 'ffffff', opacity = 0.85, radius = 10})

    local icon
    if self.mute or self.volume == 0 then icon = 'volume_off'
    elseif self.volume <= 30 then icon = 'volume_mute'
    elseif self.volume <= 70 then icon = 'volume_down'
    else icon = 'volume_up' end
    ass:icon(ax + left_margin + icon_size / 2, ay + h / 2, icon_size, icon, {color = '000000', opacity = 1})
    ass:txt(ax + total_w - right_margin, ay + h / 2, 6, text_str,
        {size = font_size, color = '000000', bold = true, opacity = 1})
    return ass
end

-- ============================================================
-- FullscreenIndicator
-- ============================================================
---@class FullscreenIndicator : BaseIndicator
local FullscreenIndicator = class(BaseIndicator)

FullscreenIndicator.render_order = 20000
FullscreenIndicator.duration = 1.2

function FullscreenIndicator:init()
    BaseIndicator.init(self, 'fullscreen_indicator')
    self._first = true
    self.base_font_size = 32
    self:observe_mp_property('fullscreen', 'native', function()
        if self._first then self._first = false; return end
        if mp.get_property_native('fullscreen') then
            self:show_indicator()
        else
            self:hide_indicator()
        end
    end)
end

function FullscreenIndicator:render()
    if not self.show then return nil end
    local ass = assdraw.ass_new()
    local cx = display.width / 2
    local top_margin = round(display.height / 11)
    local font_size = self.base_font_size * options.font_scale
    local padding = round(font_size * 3.0)
    local height = round(font_size * 2.4)
    local text_str = '若要退出全屏，请按Esc'
    local text_w = text_width(text_str, {size = font_size, bold = true})
    local total_w = padding * 2 + text_w
    local ax, ay = cx - total_w / 2, top_margin
    ass:rect(ax, ay, ax + total_w, ay + height, {color = '322c28', opacity = 1})
    ass:txt(cx, ay + height / 2, 5, text_str, {size = font_size, color = 'ffffff', bold = true, opacity = 1})
    return ass
end

-- ============================================================
-- ExitFullscreenHint
-- ============================================================
---@class ExitFullscreenHint : BaseIndicator
local ExitFullscreenHint = class(BaseIndicator)

ExitFullscreenHint.render_order = 10000
ExitFullscreenHint.duration = 1.2

function ExitFullscreenHint:init()
    BaseIndicator.init(self, 'exit_fullscreen_hint')
    self.threshold = 10
    self.color, self.opacity = '322c28', 0.9
    self.fullscreen = mp.get_property_native('fullscreen') or false
    self.triggered = false
    self:observe_mp_property('fullscreen', 'native', function(_, val)
        self.fullscreen = val
        if not val then
            self.triggered = false
            self:hide_indicator()
        end
    end)
end

function ExitFullscreenHint:render()
    if not self.fullscreen then return end
    if cursor.hidden or cursor.x == math.huge or cursor.y == math.huge then return end

    if cursor.y <= self.threshold then
        if not self.triggered then
            self.triggered = true
            self:show_indicator()
        end
    else
        self.triggered = false
    end

    if not self.show then return end

    local icon_size = math.max(25, math.min(display.width, display.height) / 40)
    local circle_radius = round(icon_size * 1.1)
    local cx, cy = display.width / 2, display.height / 12
    local ass = assdraw.ass_new()
    ass:circle(cx, cy, circle_radius, {color = self.color, opacity = self.opacity})
    ass:icon(cx, cy, icon_size * 1.2, 'close', {color = 'ffffff', opacity = 1})

    cursor:zone('primary_click', {point = {x = cx, y = cy}, r = circle_radius}, function()
        mp.commandv('set', 'fullscreen', 'no')
    end)
    return ass
end

return setmetatable({
    BufferingIndicator = BufferingIndicator,
    PauseIndicator     = PauseIndicator,
    MuteIndicator      = MuteIndicator,
    VolumeIndicator    = VolumeIndicator,
    FullscreenIndicator = FullscreenIndicator,
    ExitFullscreenHint = ExitFullscreenHint,
}, {
    __index = function(t, _) return nil end,
})