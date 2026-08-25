local Element = require('elements/Element')

---@class PlayMode : Element
local PlayMode = class(Element)

function PlayMode:new(id, props)
    return Class.new(self, id, props)
end

function PlayMode:init(id, props)
    Element.init(self, id, props)
    self.pressed = false
    self.menu_open = state.playmode_menu_open or false
    self.close_timer = nil
    self:init_items()
    self:register_observers()

    -- 如果恢复后菜单是打开的，确保控制栏被固定
    if self.menu_open then
        Elements:set_min_visibility(1, {'controls'})
    end
end

function PlayMode:init_items()
    self.items = {
        {
            label = '自动切集',
            prop = 'autoload',
            get = function() return state.autoload == true end,
            set = function(val)
                state.autoload = val
                options.autoload = val
                handle_options({autoload = val})
            end
        },
        {
            label = '单集循环',
            prop = 'loop-file',
            get = function() return state.loop_file == 'inf' or state.loop_file == 'yes' end,
            set = function(val)
                mp.set_property('loop-file', val and 'inf' or 'no')
            end
        },
        {
            label = '乱序播放',
            prop = 'shuffle',
            get = function() return state.shuffle == true end,
            set = function(val)
                state.shuffle = val
                options.shuffle = val
                handle_options({shuffle = val})
            end
        }
    }
end

function PlayMode:register_observers()
    self:observe_mp_property('loop-file', 'string', function() request_render() end)
end

function PlayMode:get_visibility()
    return Element.get_visibility(self)
end

-- 绘制截图中的“胶囊”开关
function PlayMode:draw_toggle(ass, x, y, width, height, is_on, click_handler)
    local radius = height / 2
    
    -- 1. 胶囊背景
    ass:rect(x, y, x + width, y + height, {
        color = is_on and 'ecae00' or '666666',
        opacity = is_on and 0.9 or 0.6,
        radius = radius,
    })
    
    -- 2. 白色圆点滑块
    local dot_radius = radius * 0.8
    local dot_x = is_on and (x + width - dot_radius) or (x + dot_radius)
    local dot_y = y + radius
    ass:circle(dot_x, dot_y, dot_radius, {
        color = 'ffffff',
        opacity = 1,
    })

    -- 3. 交互区域
    cursor:zone('primary_click', {ax = x, ay = y, bx = x + width, by = y + height}, click_handler)
end

function PlayMode:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    local ass = assdraw.ass_new()
    local size = self.by - self.ay
    local font_size = round(size * 0.7)
    local center_x = round(self.ax + (self.bx - self.ax) / 2)
    local center_y = round(self.ay + (self.by - self.ay) / 2)
    local is_hover = self.proximity_raw <= 0

    -- 打开菜单逻辑：鼠标悬停触发
    if is_hover and not self.menu_open then
        self.menu_open = true
        state.playmode_menu_open = true
        Elements:set_min_visibility(1, {'controls'})
    end

    -- 1. 按钮本身：悬停或菜单打开时显示背景
    if is_hover or self.menu_open then
        ass:rect(self.ax, self.ay, self.bx, self.by, {
            color = fg, opacity = 0.3, radius = state.radius
        })
    end

    -- 2. 按钮图标
    ass:icon(center_x, center_y, font_size, 'settings', {
        color = (is_hover or self.menu_open) and 'ffffff' or fg,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
    })

    -- 3. 黑色功能面板（持久化弹窗）
    if self.menu_open then
        local panel_width = round(size * 4.3)
        local panel_height = round(size * 3.8 + 10)
        local panel_x = center_x - panel_width / 2
		local timeline_ay = Elements:v('timeline', 'ay', display.height)
		local timeline_enabled = Elements.timeline and Elements.timeline.enabled
		local panel_y
		if timeline_enabled then
			panel_y = timeline_ay - 16 - panel_height
		else
			panel_y = self.ay - panel_height - 10
		end
		if panel_y < 0 then panel_y = 0 end

        local panel_rect = {ax = panel_x, ay = panel_y, bx = panel_x + panel_width, by = panel_y + panel_height}
        
        -- 绘制背景
        ass:rect(panel_x, panel_y, panel_x + panel_width, panel_y + panel_height, {
            color = bg,
            opacity = 0.85,
            radius = round(2 * state.scale),
        })

        -- 列表项渲染
        local item_height = round(panel_height / 3)
        local text_font_size = round(item_height * 0.4)
        local toggle_width = round(item_height * 0.85)
        local toggle_height = round(item_height * 0.4)

        for i, item in ipairs(self.items) do
            local item_y = panel_y + (i - 1) * item_height

            -- 左侧文字
            ass:txt(panel_x + 20, item_y + item_height / 2, 4, item.label, {
                size = text_font_size,
                color = bgt,
                bold = true,
                opacity = 0.9 * visibility,
            })

            -- 右侧开关
            local toggle_x = panel_x + panel_width - toggle_width - 20
            local toggle_y = item_y + (item_height - toggle_height) / 2
            self:draw_toggle(ass, toggle_x, toggle_y, toggle_width, toggle_height, item.get(), function()
                item.set(not item.get())
            end)
        end

        -- 延迟关闭
        local on_panel = get_point_to_rectangle_proximity(cursor, panel_rect) <= 0
        local on_button = get_point_to_rectangle_proximity(cursor, self) <= 0
        local should_stay_open = on_panel or on_button

        if should_stay_open then
            self.close_timer = nil
        else
            if not self.close_timer then
                self.close_timer = mp.get_time() + 0.1
            end

            if mp.get_time() >= self.close_timer then
                self.menu_open = false
                state.playmode_menu_open = false
                Elements:set_min_visibility(0, {'controls'})
                self.close_timer = nil
            end
        end
    end

    -- 4. 鼠标按下 PlayMode 按钮直接触发菜单（兼容纯点击操作）
    cursor:zone('primary_down', self, function()
        if not self.menu_open then
            self.menu_open = true
            state.playmode_menu_open = true
            Elements:set_min_visibility(1, {'controls'})
        end
    end)

    return ass
end

return PlayMode