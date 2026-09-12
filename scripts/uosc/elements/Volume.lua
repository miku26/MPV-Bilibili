-- elements/Volume.lua
local PanelElement = require('elements/PanelElement')

local Volume = class(PanelElement)

function Volume:init(id, props)
    PanelElement.init(self, id, props)
    self.tooltip = nil
    self.pressed = false

    --- 音量/静音变化更新图标
    self:observe_mp_property('volume', 'native', function()
        request_render()
    end)
    self:observe_mp_property('mute', 'native', function()
        request_render()
    end)
end

function Volume:get_icon()
    local mute = state.mute
    local vol = state.volume or 0
    if mute or vol == 0 then return 'volume_off'
    elseif vol <= 30 then return 'volume_mute'
    elseif vol <= 70 then return 'volume_down'
    else return 'volume_up' end
end

--- 绘制按钮图标、点击静音
function Volume:draw_button(ass, visibility)
    local cx = (self.ax + self.bx) / 2
    local cy = (self.ay + self.by) / 2
    local icon = self:get_icon()
    ass:icon(cx, cy, self.font_size, icon, {
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
    })

    cursor:zone('primary_click', self, function()
        mp.commandv('cycle', 'mute')
    end)
end

--- 计算滑块面板矩形
function Volume:get_panel_rect()
    local SLIDER_WIDTH = 54
    local SLIDER_HEIGHT = 240
    local panel_x, panel_y = self:get_panel_origin(SLIDER_WIDTH, SLIDER_HEIGHT, 4)

    return {
        ax = panel_x, ay = panel_y,
        bx = panel_x + SLIDER_WIDTH, by = panel_y + SLIDER_HEIGHT,
        _scroll_enabled = false,
    }
end

--- 绘制音量面板
function Volume:draw_content(ass, rect)
    local ax, ay, bx, by = rect.ax, rect.ay, rect.bx, rect.by
    local center_x = (ax + bx) / 2

    local PADDING = 16
    local LINE_WIDTH = 6
    local DOT_RADIUS = 8
    local TEXT_SIZE = 20
    local bili_blue = "ecae00"
    local max_vol = mp.get_property_native('volume-max') or 100

    --- 面板背景
    ass:rect(ax, ay, bx, by, {
        color = bg, opacity = 0.85, radius = state.radius,
    })

    --- 音量数字
    local vol = state.volume or 0
    local vol_int = math.floor(vol)
    ass:txt(center_x, ay + PADDING + TEXT_SIZE/2, 5, tostring(vol_int), {
        size = TEXT_SIZE, color = bgt, bold = true,
    })

    --- 轨道
    local track_ay = ay + PADDING + TEXT_SIZE + PADDING
    local track_by = by - PADDING
    local track_height = track_by - track_ay
    if track_height > 0 then
        ass:rect(center_x - LINE_WIDTH/2, track_ay, center_x + LINE_WIDTH/2, track_by, {
            color = fg, opacity = 0.8, radius = LINE_WIDTH/2,
        })
    end

    --- 填充
    local fill_ratio = clamp(0, vol / max_vol, 1)
    local fill_end_y = track_by - (track_height * fill_ratio)
    if fill_ratio > 0 then
        ass:rect(center_x - LINE_WIDTH/2, fill_end_y, center_x + LINE_WIDTH/2, track_by, {
            color = bili_blue, opacity = 0.85, radius = LINE_WIDTH/2,
        })
    end

    --- 圆点
    local dot_y = fill_end_y
    if fill_ratio <= 0.001 then dot_y = track_by end
    ass:circle(center_x, dot_y, DOT_RADIUS, {
        color = bili_blue, opacity = 0.9,
    })

    --- 交互区域
    local hitbox = {ax = ax, ay = ay, bx = bx, by = by}
    cursor:zone('primary_down', hitbox, function()
        self.pressed = true
        local function move_handler()
            if not self.pressed then return end
            local y = cursor.y
            local ratio = clamp(0, 1 - (y - track_ay) / track_height, 1)
            local new_vol = ratio * max_vol
            mp.commandv('set', 'volume', new_vol)
            Elements:flash({'volume_indicator'})
        end
        cursor:on('move', move_handler)
        move_handler()
        cursor:once('primary_up', function()
            self.pressed = false
            cursor:off('move', move_handler)
        end)
    end)
    cursor:zone('wheel_down', hitbox, function()
        mp.commandv('add', 'volume', -5)
        Elements:flash({'volume_indicator'})
    end)
    cursor:zone('wheel_up', hitbox, function()
        mp.commandv('add', 'volume', 5)
        Elements:flash({'volume_indicator'})
    end)
end

return Volume