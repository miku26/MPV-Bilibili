-- elements/TopBar.lua
local Element = require('elements/Element')

---@alias TopBarButtonProps {icon: string; hover_fg?: string; hover_bg?: string; command: (fun():string)}

---@class TopBar : Element
local TopBar = class(Element)

function TopBar:new() return Class.new(self) --[[@as TopBar]] end
function TopBar:init()
	Element.init(self, 'top_bar', {render_order = 4})
	self.size = 0
	self.icon_size, self.font_size = 1, 1
	self.filename = ''

	local function maximized_command()
		if state.platform == 'windows' then
			mp.command(state.border
				and (state.fullscreen and 'set fullscreen no;cycle window-maximized' or 'cycle window-maximized')
				or 'set window-maximized no;cycle fullscreen')
		else
			mp.command(state.fullormaxed and 'set fullscreen no;set window-maximized no' or 'set window-maximized yes')
		end
	end

	local close = {icon = 'close', hover_bg = '2311e8', hover_fg = 'ffffff', command = function() mp.command('quit') end}
	local max = {icon = 'crop_square', command = maximized_command}
	local min = {icon = 'minimize', command = function() mp.command('cycle window-minimized') end}
	self.buttons = options.top_bar_controls == 'left' and {close, max, min} or {min, max, close}

	self:decide_enabled()
	self:update_dimensions()

	self:observe_mp_property('path', 'string', function(_, path)
		if path then
			local serialized = serialize_path(path)
			self.filename = serialized and serialized.basename or path
		else
			self.filename = ''
		end
		request_render()
	end)
end

function TopBar:decide_enabled()
	if options.top_bar == 'no-border' then
		self.enabled = not state.border or state.title_bar == false or state.fullscreen
	else
		self.enabled = options.top_bar == 'always'
	end
	self.enabled = self.enabled and (options.top_bar_controls or options.top_bar_title ~= 'no' or state.has_playlist)
end

function TopBar:update_dimensions()
	self.size = round(options.top_bar_size * state.scale)
	self.icon_size = round(self.size * 0.5)
	self.font_size = math.floor((self.size - (math.ceil(self.size * 0.25) * 2)) * options.font_scale)
	local window_border_size = Elements:v('window_border', 'size', 0)
	self.ax = window_border_size
	self.ay = window_border_size
	self.bx = display.width - window_border_size
	self.by = self.size + window_border_size
end

function TopBar:on_prop_border()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_title_bar()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_fullscreen()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_maximized()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_prop_has_playlist()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:on_display()
	self:update_dimensions()
end

function TopBar:on_options()
	self:decide_enabled()
	self:update_dimensions()
end

function TopBar:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end
	local ass = assdraw.ass_new()
	local ax, ay, bx, by = self.ax, self.ay, self.bx, self.ay + self.size
	local margin = math.floor((self.size - self.font_size) / 4)
	
	-- 1. 先注册空白区域拦截（优先级低）
    if visibility > 0 then
        cursor:zone('primary_click', self, function() end)
    end
	
	-- 2. 再绘制并注册按钮（优先级高，覆盖空白区域）
	if options.top_bar_controls then
		local is_left, button_ax = options.top_bar_controls == 'left', 0
		if is_left then
			button_ax = ax
			ax = self.size * #self.buttons
		else
			button_ax = bx - self.size * #self.buttons
			bx = button_ax
		end

		for _, button in ipairs(self.buttons) do
			local rect = {ax = button_ax, ay = ay, bx = button_ax + self.size, by = by}
			local is_hover = get_point_to_rectangle_proximity(cursor, rect) <= 0
			local opacity = is_hover and 1 or config.opacity.controls
			local button_fg = is_hover and (button.hover_fg or bg) or fg
			local button_bg = is_hover and (button.hover_bg or fg) or bg

			cursor:zone('primary_click', rect, button.command)

			local bg_size = self.size - margin
			local bg_ax, bg_ay = rect.ax + (is_left and margin or 0), rect.ay + margin
			local bg_bx, bg_by = bg_ax + bg_size, bg_ay + bg_size

			ass:rect(bg_ax, bg_ay, bg_bx, bg_by, {
				color = button_bg, opacity = visibility * opacity, radius = state.radius,
			})

			ass:icon(bg_ax + bg_size / 2, bg_ay + bg_size / 2, bg_size * 0.5, button.icon, {
				color = button_fg,
				border_color = button_bg,
				opacity = visibility,
				border = options.text_border * state.scale,
			})

			button_ax = button_ax + self.size
		end
	end

	-- 文件名（居左）
	if self.filename and self.filename ~= '' then
		local padding = round(self.font_size / 2)
		local title_ax = ax + margin
		local title_ay = self.ay + margin
		local title_bx = bx - margin
		local title_by = by - margin

		local opts = {
			size = math.floor(self.font_size * 1.35),
			bold = true,
			wrap = 2,
			color = bgt,
			opacity = visibility,
			border = options.text_border * state.scale,
			border_color = bg,
			clip = string.format('\\clip(%d, %d, %d, %d)', title_ax, title_ay, title_bx, title_by),
		}
		ass:txt(title_ax + padding, title_ay + (self.size / 2), 4, self.filename, opts)
	end

	return ass
end

return TopBar