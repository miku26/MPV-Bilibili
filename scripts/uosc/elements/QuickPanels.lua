-- elements/QuickPanels.lua
-- Controls 中两个“快捷小面板”的合并文件：
--   - PlayMode：自动切集 / 单集循环 / 乱序播放 开关面板
--   - Speed   ：播放倍速选择面板

local PanelElement = require('elements/PanelElement')

-- ============================================================
-- PlayMode
-- ============================================================
---@class PlayMode : PanelElement
local PlayMode = class(PanelElement)

function PlayMode:init(id, props)
    PanelElement.init(self, id, props)
    self:init_items()
    self:register_observers()
    if state.playmode_menu_open then self:open_panel() end
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
            end,
        },
        {
            label = '单集循环',
            prop = 'loop-file',
            get = function() return state.loop_file == 'inf' or state.loop_file == 'yes' end,
            set = function(val) mp.set_property('loop-file', val and 'inf' or 'no') end,
        },
        {
            label = '乱序播放',
            prop = 'shuffle',
            get = function() return state.shuffle == true end,
            set = function(val)
                state.shuffle = val
                options.shuffle = val
                handle_options({shuffle = val})
            end,
        },
    }
end

function PlayMode:register_observers()
    self:observe_mp_property('loop-file', 'string', function() request_render() end)
end

function PlayMode:open_panel()
    PanelElement.open_panel(self)
    state.playmode_menu_open = true
end

function PlayMode:close_panel()
    PanelElement.close_panel(self)
    state.playmode_menu_open = false
end

function PlayMode:draw_button(ass, visibility)
    local cx = (self.ax + self.bx) / 2
    local cy = (self.ay + self.by) / 2
    local font_size = round((self.by - self.ay) * 0.55)
    local is_hover = self.proximity_raw <= 0

    if is_hover or self.panel_open then
        ass:rect(self.ax, self.ay, self.bx, self.by, {
            color = fg, opacity = 0.3, radius = state.radius,
        })
    end

    ass:icon(cx, cy, font_size, 'settings', {
        color = (is_hover or self.panel_open) and 'ffffff' or fg,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
    })
end

function PlayMode:get_panel_rect()
    local PANEL_WIDTH = 220
    local ITEM_HEIGHT = 48
    local PANEL_HEIGHT = 3 * ITEM_HEIGHT

    local panel_x, panel_y = self:get_panel_origin(PANEL_WIDTH, PANEL_HEIGHT)

    return {
        ax = panel_x, ay = panel_y,
        bx = panel_x + PANEL_WIDTH, by = panel_y + PANEL_HEIGHT,
        _scroll_enabled = false,
        _item_height = ITEM_HEIGHT,
    }
end

function PlayMode:draw_content(ass, rect)
    local panel_x, panel_y = rect.ax, rect.ay
    local panel_width = rect.bx - rect.ax
    local panel_height = rect.by - rect.ay
    local item_height = rect._item_height

    ass:rect(panel_x, panel_y, panel_x + panel_width, panel_y + panel_height, {
        color = bg, opacity = 0.85, radius = round(2 * state.scale),
    })

    local text_font_size = round(item_height * 0.5)
    local toggle_width = round(item_height * 0.85)
    local toggle_height = round(item_height * 0.5)

    for i, item in ipairs(self.items) do
        local item_y = panel_y + (i - 1) * item_height

        ass:txt(panel_x + 20, item_y + item_height / 2, 4, item.label, {
            size = text_font_size, color = bgt, bold = true, opacity = 0.9,
        })

        local toggle_x = panel_x + panel_width - toggle_width - 20
        local toggle_y = item_y + (item_height - toggle_height) / 2
        self:draw_toggle(ass, toggle_x, toggle_y, toggle_width, toggle_height,
            item.get(), function() item.set(not item.get()) end)
    end
end

function PlayMode:draw_toggle(ass, x, y, width, height, is_on, click_handler)
    local radius = height / 2
    ass:rect(x, y, x + width, y + height, {
        color = is_on and 'ecae00' or '666666',
        opacity = is_on and 0.9 or 0.6,
        radius = radius,
    })
    local dot_radius = radius * 0.8
    local dot_x = is_on and (x + width - dot_radius) or (x + dot_radius)
    local dot_y = y + radius
    ass:circle(dot_x, dot_y, dot_radius, { color = 'ffffff', opacity = 1 })
    cursor:zone('primary_click', { ax = x, ay = y, bx = x + width, by = y + height }, click_handler)
end

-- ============================================================
-- Speed
-- ============================================================
---@class Speed : PanelElement
local Speed = class(PanelElement)

function Speed:init(props)
    PanelElement.init(self, 'speed', props)
    self.speed_options = {
        {label = '2.0x', value = 2.0},
        {label = '1.5x', value = 1.5},
        {label = '1.25x', value = 1.25},
        {label = '1.0x', value = 1.0},
        {label = '0.75x', value = 0.75},
        {label = '0.5x', value = 0.5},
    }
    self.font_size = 0
end

function Speed:get_visibility()
    return Elements:maybe('timeline', 'get_is_hovered') and -1 or PanelElement.get_visibility(self)
end

function Speed:draw_hover_background(ass)
    local speed_rounded = round(state.speed * 100) / 100
    local speed_text = (speed_rounded == 1) and '倍速' or (speed_rounded .. 'x')
    local opts = { size = self.font_size, bold = true }
    local text_w = text_width(speed_text, opts)
    local text_h = self.font_size * 0.93
    local height = self.by - self.ay
    local pad = (height - self.font_size) / 2
    if pad < 2 * state.scale then pad = 2 * state.scale end
    local bg_w = text_w + pad * 2
    local bg_h = text_h + pad * 2
    local cx = (self.ax + self.bx) / 2
    local cy = (self.ay + self.by) / 2
    ass:rect(cx - bg_w/2, cy - bg_h/2, cx + bg_w/2, cy + bg_h/2, {
        color = fg, opacity = 0.3, radius = state.radius,
    })
end

function Speed:draw_button(ass, visibility)
    local speed_rounded = round(state.speed * 100) / 100
    local speed_text = (speed_rounded == 1) and '倍速' or (speed_rounded .. 'x')
    local cx = (self.ax + self.bx) / 2
    local cy = (self.ay + self.by) / 2
    ass:txt(cx, cy, 5, speed_text, {
        size = self.font_size,
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
        bold = true,
    })
end

function Speed:get_panel_rect()
    local PANEL_WIDTH = 100
    local ROW_HEIGHT = 36
    local ITEM_GAP = 8
    local FONT_SIZE = 28
    local PADDING_V = 12

    local display_count = #self.speed_options
    local total_height = display_count * ROW_HEIGHT + (display_count - 1) * ITEM_GAP + PADDING_V * 2
    local final_height = math.min(total_height, display.height * 0.5)

    local panel_x, panel_y = self:get_panel_origin(PANEL_WIDTH, final_height)

    return {
        ax = panel_x, ay = panel_y,
        bx = panel_x + PANEL_WIDTH, by = panel_y + final_height,
        _item_height = ROW_HEIGHT,
        _item_gap = ITEM_GAP,
        _padding_v = PADDING_V,
        _font_size = FONT_SIZE,
        _scroll_enabled = false,
    }
end

function Speed:draw_content(ass, rect)
    local item_height = rect._item_height
    local item_gap = rect._item_gap
    local padding_v = rect._padding_v
    local font_size = rect._font_size

    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
        color = '000000', opacity = 0.85, radius = round(2 * state.scale),
    })

    for i, opt in ipairs(self.speed_options) do
        local item_y = rect.ay + padding_v + (i - 1) * (item_height + item_gap)
        local item_rect = { ax = rect.ax, ay = item_y, bx = rect.bx, by = item_y + item_height }
        local is_hover = get_point_to_rectangle_proximity(cursor, item_rect) <= 0
        if is_hover then
            ass:rect(item_rect.ax, item_rect.ay, item_rect.bx, item_rect.by, {
                color = 'ffffff', opacity = 0.4,
                clip = '\\clip('..item_rect.ax..','..item_rect.ay..','..item_rect.bx..','..item_rect.by..')',
            })
        end
        local is_current = state.speed == opt.value
        ass:txt((rect.ax + rect.bx) / 2, item_y + item_height / 2, 5, opt.label, {
            size = font_size,
            color = is_current and 'ecae00' or 'ffffff',
            bold = is_current,
            opacity = 0.9,
        })
        cursor:zone('primary_click', item_rect, function()
            mp.set_property_native('speed', opt.value)
            self:close_panel()
        end)
    end
end

return {
    PlayMode = PlayMode,
    Speed = Speed,
}