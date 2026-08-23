local Element = require('elements/Element')

---@alias ButtonProps {icon: string; on_click?: function; is_clickable?: boolean; anchor_id?: string; active?: boolean; badge?: string|number; foreground?: string; background?: string; tooltip?: string}

---@class Button : Element
local Button = class(Element)

---@param id string
---@param props ButtonProps
function Button:new(id, props) return Class.new(self, id, props) --[[@as Button]] end
---@param id string
---@param props ButtonProps
function Button:init(id, props)
	self.icon = props.icon
	self.text_icon = props.text_icon
	self.active = props.active
	self.tooltip = props.tooltip
	self.badge = props.badge
	self.foreground = props.foreground or fg
	self.background = props.background or bg
	self.is_clickable = true
	---@type fun()|nil
	self.on_click = props.on_click
	Element.init(self, id, props)
end

function Button:on_coordinates() self.font_size = round((self.by - self.ay) * 0.7) end
function Button:handle_cursor_click()
	if not self.on_click or not self.is_clickable then return end
	-- We delay the callback to next tick, otherwise we are risking race
	-- conditions as we are in the middle of event dispatching.
	-- For example, handler might add a menu to the end of the element stack, and that
	-- than picks up this click event we are in right now, and instantly closes itself.
	mp.add_timeout(0.01, self.on_click)
end

function Button:render()
	local visibility = self:get_visibility()
	if visibility <= 0 then return end
	cursor:zone('primary_click', self, function() self:handle_cursor_click() end)

	local ass = assdraw.ass_new()
	local is_clickable = self.is_clickable and self.on_click ~= nil
	local is_hover = self.proximity_raw <= 0
	local foreground = self.active and self.background or self.foreground
	local background = self.active and self.foreground or self.background
	local background_opacity = self.active and 1 or config.opacity.controls

	if is_hover and is_clickable and background_opacity < 0.3 then background_opacity = 0.3 end

	-- Background

	if background_opacity > 0 then
		local ax, ay, bx, by = self.ax, self.ay, self.bx, self.by

		-- 对文本按钮（“章节”、“字幕”）自适应背景尺寸，使 padding 均匀
		if self.text_icon then
			local opts = { size = self.font_size, bold = true }
			local text_w = text_width(self.text_icon, opts)          -- 文本宽度
			local text_h = self.font_size * 0.93                     -- 文本近似高度
			local height = self.by - self.ay
			local pad = (height - self.font_size) / 2               -- 上下自然 padding
			if pad < 2 * state.scale then pad = 2 * state.scale end -- 最小 padding

			local bg_w = text_w + pad * 2
			local bg_h = text_h + pad * 2
			local center_x = (self.ax + self.bx) / 2
			local center_y = (self.ay + self.by) / 2

			ax = center_x - bg_w / 2
			bx = center_x + bg_w / 2
			ay = center_y - bg_h / 2
			by = center_y + bg_h / 2
		end

		ass:rect(ax, ay, bx, by, {
			color = (self.active or not is_hover) and background or foreground,
			radius = state.radius,
			opacity = visibility * background_opacity,
		})
	end

	-- Tooltip on hover
	if is_hover and self.tooltip then
		local margin = 10 * state.scale
		local font_size = self.font_size * 0.8
		local pad = font_size / 4
		local text_opts = {
			size = font_size,
			color = fg,
			bold = true,
			border = options.text_border * state.scale,
			border_color = bg,
			opacity = visibility,
		}
		local text_w = text_width(self.tooltip, text_opts)
		local text_h = font_size * 0.93
		local rect_w = text_w + pad * 2
		local rect_h = text_h + pad * 2

		-- 默认置于按钮上方居中
		local tx = self.ax + (self.bx - self.ax) / 2 - rect_w / 2
		local ty = self.ay - rect_h - margin

		-- 垂直空间不足则放于下方
		if ty < 0 then
			ty = self.by + margin
		end

		-- **水平溢出处理**：若右侧超出屏幕，改为右对齐（紧贴按钮右边缘）
		local right_edge = tx + rect_w
		if right_edge > display.width - margin then
			tx = self.bx - rect_w   -- 右对齐
		end
		if tx < margin then
			tx = margin
		end

		ass:txt(tx + rect_w / 2, ty + rect_h / 2, 5, self.tooltip, text_opts)
	end

	-- Badge
	local icon_clip
	if self.badge then
		local badge_font_size = self.font_size * 0.6
		local badge_opts = {size = badge_font_size, color = background, opacity = visibility}
		local badge_width = text_width(self.badge, badge_opts)
		local width, height = math.ceil(badge_width + (badge_font_size / 7) * 2), math.ceil(badge_font_size * 0.93)
		local bx, by = self.bx - 1, self.by - 1
		ass:rect(bx - width, by - height, bx, by, {
			color = foreground,
			radius = state.radius,
			opacity = visibility,
			border = self.active and 0 or 1,
			border_color = background,
		})
		ass:txt(bx - width / 2, by - height / 2, 5, self.badge, badge_opts)

		local clip_border = math.max(self.font_size / 20, 1)
		local clip_path = assdraw.ass_new()
		clip_path:round_rect_cw(
			math.floor((bx - width) - clip_border), math.floor((by - height) - clip_border), bx, by, 3
		)
		icon_clip = '\\iclip(' .. clip_path.scale .. ', ' .. clip_path.text .. ')'
	end

	-- Icon or Text
	local x, y = round(self.ax + (self.bx - self.ax) / 2), round(self.ay + (self.by - self.ay) / 2)
	if self.text_icon then
		ass:txt(x, y, 5, self.text_icon, {
			size = self.font_size,
			color = foreground,
			bold = true,
			border = self.active and 0 or options.text_border * state.scale,
			border_color = background,
			opacity = visibility,
			clip = icon_clip,
		})
	else
		ass:icon(x, y, self.font_size, self.icon, {
			color = foreground,
			border = self.active and 0 or options.text_border * state.scale,
			border_color = background,
			opacity = visibility,
			clip = icon_clip,
		})
	end

	return ass
end

return Button
