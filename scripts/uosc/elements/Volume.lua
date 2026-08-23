local Button = require('elements/Button')

---@class Volume : Button
local Volume = class(Button)

function Volume:new(id, props)
    return Class.new(self, id, props)
end

function Volume:init(id, props)
    props.tooltip = nil
    Button.init(self, id, props)

    self.pressed = false
    self.panel_open = false
    self.delay_timer = nil

    self:observe_mp_property('volume', 'native', function()
        self.icon = self:get_icon()
        request_render()
    end)
    self:observe_mp_property('mute', 'native', function()
        self.icon = self:get_icon()
        request_render()
    end)
    self.on_click = function()
        mp.commandv('cycle', 'mute')
    end
    self.icon = self:get_icon()
end

function Volume:get_icon()
    local mute = state.mute
    local vol = state.volume or 0
    if mute or vol == 0 then
        return 'volume_off'
    elseif vol <= 30 then
        return 'volume_mute'
    elseif vol <= 70 then
        return 'volume_down'
    else
        return 'volume_up'
    end
end

function Volume:get_slider_rect()
    local btn_ax, btn_ay, btn_bx, btn_by = self.ax, self.ay, self.bx, self.by
    local btn_width = btn_bx - btn_ax
    local slider_width = btn_width * 1.1
    local slider_height = btn_width * 5.5
    local center_x = btn_ax + btn_width / 2

    local slider_ax = center_x - slider_width / 2
    local slider_ay = btn_ay - slider_height - 4
    if slider_ay < 0 then
        slider_ay = btn_by + 4
    end
    return {
        ax = slider_ax,
        ay = slider_ay,
        bx = slider_ax + slider_width,
        by = slider_ay + slider_height,
    }
end

function Volume:draw_slider(ass)
    local rect = self:get_slider_rect()
    local ax, ay, bx, by = rect.ax, rect.ay, rect.bx, rect.by
    local width = (bx - ax) * 0.8
    local height = by - ay
    local center_x = (ax + bx) / 2
    
    local bili_blue = "ecae00"
    local max_vol = mp.get_property_native('volume-max') or 100

    local padding = height * 0.08
    local line_width = math.max(2, width * 0.14)
    local dot_radius = line_width * 1.4
    local text_size = height * 0.095
    
    -- 1. 面板背景
    ass:rect(ax, ay, bx, by, {
        color = bg,
        opacity = 0.85,
        radius = state.radius,
    })

    -- 2. 音量数字
    local vol = state.volume or 0
    local vol_int = math.floor(vol)
    local text_y = ay + padding + text_size / 2
    ass:txt(center_x, text_y, 5, tostring(vol_int), {
        size = text_size,
        color = bgt, 
        bold = true,
    })

    -- 3. 音量轨道
    local track_ay = ay + padding + text_size + padding
    local track_by = by - padding
    local track_height = track_by - track_ay

    -- 4. 未使用部分
    if track_height > 0 then
        ass:rect(center_x - line_width/2, track_ay, center_x + line_width/2, track_by, {
            color = fg,
            opacity = 0.8,
            radius = line_width / 2,
        })
    end

    -- 5. 当前音量部分
    local fill_ratio = clamp(0, vol / max_vol, 1)
    local fill_end_y = track_by - (track_height * fill_ratio)

    if fill_ratio > 0 then
        ass:rect(center_x - line_width/2, fill_end_y, center_x + line_width/2, track_by, {
            color = bili_blue,
            opacity = 0.85,
            radius = line_width / 2,
        })
    end

    -- 6. 圆点
    local dot_y = fill_end_y
    if fill_ratio <= 0.001 then
        dot_y = track_by
    end
    ass:circle(center_x, dot_y, dot_radius, {
        color = bili_blue,
        opacity = 0.9,
    })

    -- 7. 交互区域
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

function Volume:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    local ass = Button.render(self) or assdraw.ass_new()
    local is_hover = self.proximity_raw <= 0

    if is_hover then
        if not self.panel_open then
            self.panel_open = true
            Elements:set_min_visibility(1, {'controls'})
        end

        if self.delay_timer then self.delay_timer:kill() end
        self.delay_timer = mp.add_timeout(0.1, function()
            if self.panel_open then
                local slider_rect = self:get_slider_rect()
                local panel_rect = {ax = slider_rect.ax, ay = slider_rect.ay, bx = slider_rect.bx, by = slider_rect.by}
                if get_point_to_rectangle_proximity(cursor, panel_rect) > 0 then
                    self.panel_open = false
                    Elements:set_min_visibility(0, {'controls'})
                    request_render()
                end
            end
        end)
    end

    -- 按钮背景：悬停或面板打开时显示
    if is_hover or self.panel_open then
        ass:rect(self.ax, self.ay, self.bx, self.by, {
            color = fg, opacity = 0.3, radius = state.radius
        })
    end

    if self.panel_open then
        local slider_rect = self:get_slider_rect()
        local panel_rect = {ax = slider_rect.ax, ay = slider_rect.ay, bx = slider_rect.bx, by = slider_rect.by}
        local hit_panel = get_point_to_rectangle_proximity(cursor, panel_rect) <= 0
        local hit_button = get_point_to_rectangle_proximity(cursor, self) <= 0

        -- 如果鼠标成功进入面板范围内，则取消延迟定时器（面板进入持续状态）
        if hit_panel and self.delay_timer then
            self.delay_timer:kill()
            self.delay_timer = nil
        end

        -- 真正渲染音量调节面板
        self:draw_slider(ass)

        -- 面板关闭判断：
        -- 当鼠标不在按钮上、也不在面板上，并且延迟定时器已经不存在时，关闭面板
        if not hit_panel and not hit_button and not self.delay_timer then
            self.panel_open = false
            Elements:set_min_visibility(0, {'controls'})
        end
    end

    return ass
end

return Volume