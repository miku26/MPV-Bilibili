local Element = require('elements/Element')

---@class Timeline : Element
local Timeline = class(Element)

function Timeline:new() return Class.new(self) --[[@as Timeline]] end
function Timeline:init()
	Element.init(self, 'timeline', {render_order = 5})
	---@type false|{pause: boolean, distance: number, last: {x: number, y: number}}
	self.pressed = false
	self.obstructed = false
	self.size = 0
	self.progress_size = 0
	self.min_progress_size = 0 -- used for `flash-progress`
	self.font_size = 0
	self.top_border = 0
	self.line_width = 0
	self.progress_line_width = 0
	self.is_hovered = false
	self.has_thumbnail = false
	self.heatmap = nil

	self:decide_progress_size()
	self:update_dimensions()

	-- Load Youtube heatmap data if available
	self:register_mp_event('file-loaded', function()
		self.heatmap = load_youtube_heatmap()
	end)
	-- Release any dragging and clear heatmap when file gets unloaded
	self:register_mp_event('end-file', function()
		self.pressed = false
		self.heatmap = nil
	end)
end

function Timeline:get_visibility()
	return math.max(Elements:maybe('controls', 'get_visibility') or 0, Element.get_visibility(self))
end

function Timeline:decide_enabled()
	local previous = self.enabled
	self.enabled = not self.obstructed and state.duration ~= nil and state.duration > 0 and state.time ~= nil
	if self.enabled ~= previous then Elements:trigger('timeline_enabled', self.enabled) end
end

function Timeline:get_effective_size()
	if Elements:v('speed', 'dragging') then return self.size end
	local progress_size = math.max(self.min_progress_size, self.progress_size)
	return progress_size + math.ceil((self.size - self.progress_size) * self:get_visibility())
end

function Timeline:get_is_hovered() return self.enabled and self.is_hovered end

function Timeline:update_dimensions()

	Elements:maybe('controls', 'update_dimensions')
	self.size = round(options.timeline_size * state.scale)
	self.top_border = round(options.timeline_border * state.scale)
	self.line_width = round(options.timeline_line_width * state.scale)
	self.progress_line_width = round(options.progress_line_width * state.scale)
	self.font_size = math.floor(math.min((self.size + 60 * state.scale) * 0.2, self.size * 0.9) * options.font_scale * 1.15)

	local window_border_size = Elements:v('window_border', 'size', 0)
	local controls_ay = Elements:v('controls', 'ay', display.height - window_border_size - self.size - self.top_border)
	local spacing = 12 * state.scale
	
	self.ax = window_border_size
	self.bx = display.width - window_border_size
	self.by = controls_ay - spacing
	self.ay = self.by - self.size - self.top_border
	self.width = self.bx - self.ax

	self.chapter_size = math.max((self.by - self.ay) / 10, 3)
	self.chapter_size_hover = self.chapter_size * 2

	-- Disable if not enough space
	local available_space = display.height - window_border_size * 2 - Elements:v('top_bar', 'size', 0)
	self.obstructed = available_space < self.size + 10
	self:decide_enabled()
end

function Timeline:decide_progress_size()
	local show = options.progress == 'always'
		or (options.progress == 'fullscreen' and state.fullormaxed)
		or (options.progress == 'windowed' and not state.fullormaxed)
	self.progress_size = show and options.progress_size or 0
end

function Timeline:toggle_progress()
	local current = self.progress_size
	self:tween_property('progress_size', current, current > 0 and 0 or options.progress_size)
	request_render()
end

function Timeline:flash_progress()
	if self.enabled and options.flash_duration > 0 then
		if not self._flash_progress_timer then
			self._flash_progress_timer = mp.add_timeout(options.flash_duration / 1000, function()
				self:tween_property('min_progress_size', options.progress_size, 0)
			end)
			self._flash_progress_timer:kill()
		end

		self:tween_stop()
		self.min_progress_size = options.progress_size
		request_render()
		self._flash_progress_timer.timeout = options.flash_duration / 1000
		self._flash_progress_timer:kill()
		self._flash_progress_timer:resume()
	end
end

function Timeline:get_time_at_x(x)
	local line_width = (options.timeline_style == 'line' and self.line_width - 1 or 0)
	local time_width = self.width - line_width - 1
	local fax = (time_width) * state.time / state.duration
	local fbx = fax + line_width
	-- time starts 0.5 pixels in
	x = x - self.ax - 0.5
	if x > fbx then
		x = x - line_width
	elseif x > fax then
		x = fax
	end
	local progress = clamp(0, x / time_width, 1)
	return state.duration * progress
end

---@param fast? boolean
function Timeline:set_from_cursor(fast)
	if state.time and state.duration then
		mp.commandv('seek', self:get_time_at_x(cursor.x), fast and 'absolute+keyframes' or 'absolute+exact')
	end
end

function Timeline:clear_thumbnail()
	if self.has_thumbnail then
		clear_thumbnail()
		self.has_thumbnail = false
	end
end

function Timeline:handle_cursor_down()
	self.pressed = {pause = state.pause, distance = 0, last = {x = cursor.x, y = cursor.y}}
	mp.set_property_native('pause', true)
	self:set_from_cursor()
end
function Timeline:on_prop_duration() self:decide_enabled() end
function Timeline:on_prop_time() self:decide_enabled() end
function Timeline:on_prop_border() self:update_dimensions() end
function Timeline:on_prop_title_bar() self:update_dimensions() end
function Timeline:on_prop_fullormaxed()
	self:decide_progress_size()
	self:update_dimensions()
end
function Timeline:on_display() self:update_dimensions() end
function Timeline:on_options()
	self:decide_progress_size()
	self:update_dimensions()
end
function Timeline:handle_cursor_up()
	if self.pressed then
		mp.set_property_native('pause', self.pressed.pause)
		self.pressed = false
	end
end
function Timeline:on_global_mouse_leave()
	self.pressed = false
end

function Timeline:on_global_mouse_move()
	if self.pressed then
		self.pressed.distance = self.pressed.distance + get_point_to_point_proximity(self.pressed.last, cursor)
		self.pressed.last.x, self.pressed.last.y = cursor.x, cursor.y
		if state.is_video and math.abs(cursor:get_velocity().x) / self.width * state.duration > 30 then
			self:set_from_cursor(true)
		else
			self:set_from_cursor()
		end
	end
end

function Timeline:cursor_command(command)
	if type(command) == 'string' and #command > 0 and state.time and state.duration then
		local expanded_command = command:gsub("{time}", self:get_time_at_x(cursor.x))
		mp.command(expanded_command)
	end
end

function Timeline:render()
	if self.size == 0 then
		self:clear_thumbnail()
		return
	end

	local size = self:get_effective_size()
	local visibility = self:get_visibility()
	self.is_hovered = false
	-- 注册 Timeline 与 Controls 之间的间隙保护
    local controls_ay = Elements:v('controls', 'ay', display.height)
    if self.by < controls_ay then
        local gap_rect = {
            ax = self.ax,
            ay = self.by,
            bx = self.bx,
            by = controls_ay
        }
        cursor:zone('primary_click', gap_rect, function() end)
    end
	if size < 1 then
		self:clear_thumbnail()
		return
	end

	if self.proximity_raw <= 0 then
		self.is_hovered = true
	end
	if visibility > 0 then
		cursor:zone('primary_down', self, function()
			self:handle_cursor_down()
			cursor:once('primary_up', function() self:handle_cursor_up() end)
		end)
		if #options.timeline_mbtn_right > 0 then
			cursor:zone('secondary_down', self, function()
				self:cursor_command(options.timeline_mbtn_right)
			end)
		end
		if config.timeline_step ~= 0 then
			cursor:zone('wheel_down', self, function()
				mp.commandv('seek', -config.timeline_step, config.timeline_step_flag)
			end)
			cursor:zone('wheel_up', self, function()
				mp.commandv('seek', config.timeline_step, config.timeline_step_flag)
			end)
		end
	end

	local ass = assdraw.ass_new()
	local progress_size = math.max(self.min_progress_size, self.progress_size)

	local tooltip_gap = round(2 * state.scale)
	local timestamp_gap = tooltip_gap

	local spacing = math.max(math.floor((self.size - self.font_size) / 2.5), 4)
	local progress = state.time / state.duration
	local is_line = options.timeline_style == 'line'

	-- Foreground & Background bar coordinates
	local bax, bay, bbx, bby = self.ax, self.by - size - self.top_border, self.bx, self.by
	local fax, fay, fbx, fby = 0, bay + self.top_border, 0, bby
	local fcy = fay + (size / 2)

	local line_width = 0

	if is_line then
		local minimized_fraction = 1 - math.min((size - progress_size) / ((self.size - progress_size) / 8), 1)
		local progress_delta = progress_size > 0 and self.progress_line_width - self.line_width or 0
		line_width = self.line_width + (progress_delta * minimized_fraction)
		fax = bax + (self.width - line_width) * progress
		fbx = fax + line_width
		line_width = line_width - 1
	else
		fax, fbx = bax, bax + self.width * progress
	end

	local foreground_size = fby - fay
	local foreground_coordinates = round(fax) .. ',' .. fay .. ',' .. round(fbx) .. ',' .. fby -- for clipping

	-- time starts 0.5 pixels in
	local time_ax = bax + 0.5
	local time_width = self.width - line_width - 1

	-- time to x: calculates x coordinate so that it never lies inside of the line
	local function t2x(time)
		local x = time_ax + time_width * time / state.duration
		return time <= state.time and x or x + line_width
	end

	-- Background (removed)
	--ass:new_event()
	--ass:pos(0, 0)
	--ass:append('{\\rDefault\\an7\\blur0\\bord0\\1c&H' .. fg .. '}')
	--ass:opacity(0.3)
	--ass:draw_start()
	--ass:rect_cw(bax, bay, fax, bby) --left of progress
	--ass:rect_cw(fbx, bay, bbx, bby) --right of progress
	--ass:rect_cw(fax, bay, fbx, fay) --above progress
	--ass:draw_stop()

	-- Youtube heatmap
	local function draw_heatmap()
		if options.timeline_heatmap ~= 'no' and self.heatmap and config.opacity.heatmap > 0 and visibility > 0 then
			local is_above = options.timeline_heatmap == 'above'
			local height = math.min(40, size / self.size * 40)
			local ax, ay = bax, is_above and (bay - height) or (bay + self.top_border)
			local bx, by = bbx, is_above and bay or bby
			local opts = {color = config.color.heatmap, opacity = config.opacity.heatmap * visibility}
			local clip_ay = is_above and (ay - 10) or ay
			opts.clip = string.format('\\clip(%d,%d,%d,%d)', ax, clip_ay, bx, by)
			ass:smooth_curve(ax, ay, bx, by, self.heatmap, opts)
		end
	end

	-- Progress (分段绘制，仅显示在章节区间内已播放的部分)
	local function draw_progress()
		local chapter_times = {}
		for _, ch in ipairs(state.chapters) do
			table.insert(chapter_times, ch.time)
		end

		if #chapter_times == 0 then
			-- 无章节时，绘制连续进度条
			ass:rect(fax, fay, fbx, fby, {
				color = "ecae00",
				opacity = 0.9,
				boder = 0
			})
		else
			-- 有章节时，分段绘制进度条
			table.insert(chapter_times, state.duration)  -- 添加虚拟结尾
			local current_time = state.time
			local gap = 3  -- 与章节分段间隙保持一致
			for i = 1, #chapter_times - 1 do
				local start_time = chapter_times[i]
				local end_time = chapter_times[i+1]
				local play_start = start_time
				local play_end = math.min(end_time, current_time)
				if play_end > play_start then
					local x1 = t2x(play_start) + gap
					local x2 = t2x(play_end) - gap
					if x1 < x2 then
						ass:rect(x1, fay, x2, fby, {
							color = "ecae00",
							opacity = 0.9,
							boder = 0
						})
					end
				end
			end
		end
	end

	-- 收集章节时间（供后续使用）
	local chapter_times = {}
	for _, ch in ipairs(state.chapters) do
		table.insert(chapter_times, ch.time)
	end

	-- 存储悬停的章节分段信息（起始/结束时间，起始/结束x）
	local hovered_segment = nil  -- {start_time, end_time, start_x, end_x}

	-- 1. 绘制普通章节分段（非悬停），同时检测悬停
	if (config.opacity.chapters > 0 and (#chapter_times > 0 or state.ab_loop_a or state.ab_loop_b)) then
		local chapter_opacity = config.opacity.chapters
		local gap = 4
		local diamond_border = options.timeline_border and math.max(options.timeline_border, 1) or 1

		for i = 1, #chapter_times do
			local start_time = chapter_times[i]
			local end_time = (i < #chapter_times) and chapter_times[i+1] or state.duration
			local start_x = t2x(start_time)
			local end_x = t2x(end_time)
			start_x = start_x + gap
			end_x = end_x - gap
			if start_x < end_x then
				local rect = {ax = start_x, ay = fay, bx = end_x, by = fby}
				local is_hover = get_point_to_rectangle_proximity(cursor, rect) <= 0
				if is_hover then
					hovered_segment = {
						start_time = start_time,
						end_time = end_time,
						start_x = start_x,
						end_x = end_x
					}
					self.is_hovered = true
				else
					ass:rect(start_x, fay, end_x, fby, {
						color = fg,
						opacity = chapter_opacity,
						border = 0,
					})
				end
			end
		end

		-- A-B loop indicators
		local has_a, has_b = state.ab_loop_a and state.ab_loop_a >= 0, state.ab_loop_b and state.ab_loop_b > 0
		local ab_radius = round(math.min(math.max(8, foreground_size * 0.25), foreground_size))

		---@param time number
		---@param kind 'a'|'b'
		local function draw_ab_indicator(time, kind)
			local x = t2x(time)
			ass:new_event()
			ass:append(string.format(
				'{\\pos(0,0)\\rDefault\\an7\\blur0\\yshad0.01\\bord%f\\1c&H%s\\3c&H%s\\4c&H%s\\1a&H%X&\\3a&H00&\\4a&H00&}',
				diamond_border, fg, bg, bg, opacity_to_alpha(config.opacity.chapters)
			))
			ass:draw_start()
			ass:move_to(x, fby - ab_radius)
			if kind == 'b' then ass:line_to(x + 3, fby - ab_radius) end
			ass:line_to(x + (kind == 'a' and 0 or ab_radius), fby)
			ass:line_to(x - (kind == 'b' and 0 or ab_radius), fby)
			if kind == 'a' then ass:line_to(x - 3, fby - ab_radius) end
			ass:draw_stop()
		end

		if has_a then draw_ab_indicator(state.ab_loop_a, 'a') end
		if has_b then draw_ab_indicator(state.ab_loop_b, 'b') end
	end

	-- 2. 绘制 uncached ranges 和 custom ranges
	if state.uncached_ranges then
		local opts = {size = 80, anchor_y = fby}
		local texture_char = visibility > 0 and 'b' or 'a'
		local offset = opts.size / (visibility > 0 and 24 or 28)
		for _, range in ipairs(state.uncached_ranges) do
			if options.timeline_cache then
				local ax = range[1] < 0.5 and bax or math.floor(t2x(range[1]))
				local bx = range[2] > state.duration - 0.5 and bbx or math.ceil(t2x(range[2]))
				opts.color, opts.opacity, opts.anchor_x = 'ffffff', 0.4 - (0.2 * visibility), bax
				ass:texture(ax, fay, bx, fby, texture_char, opts)
				opts.color, opts.opacity, opts.anchor_x = '000000', 0.6 - (0.2 * visibility), bax + offset
				ass:texture(ax, fay, bx, fby, texture_char, opts)
			end
		end
	end

	for _, chapter_range in ipairs(state.chapter_ranges) do
		local rax = chapter_range.start < 0.1 and bax or t2x(chapter_range.start)
		local rbx = chapter_range['end'] > state.duration - 0.1 and bbx
			or t2x(math.min(chapter_range['end'], state.duration))
		ass:rect(rax, fay, rbx, fby, {color = chapter_range.color, opacity = chapter_range.opacity})
	end

	-- 3. 绘制进度条（与 heatmap，顺序由 is_line 决定）
	if is_line then
		draw_heatmap()
		draw_progress()
	else
		draw_progress()
		draw_heatmap()
	end

	-- 4. 最后绘制悬停的章节分段（放大效果，已播放和未播放颜色保持与普通状态一致）
	if hovered_segment then
		local start_x = hovered_segment.start_x
		local end_x = hovered_segment.end_x
		local start_time = hovered_segment.start_time
		local end_time = hovered_segment.end_time
		local current_time = state.time

		-- 计算该分段内已播放的右边界（时间）
		local play_time = math.min(end_time, current_time)
		local play_x = t2x(play_time)
		-- 裁剪到分段范围内
		play_x = math.max(start_x, math.min(end_x, play_x))

		-- 扩展量
		local expand = size * 0.7
		local expanded_ay = fay - expand
		local expanded_by = fby + expand

		-- 已播放部分
		if play_x > start_x then
			ass:rect(start_x, expanded_ay, play_x, expanded_by, {
				color = "ecae00",
				opacity = 0.9,
				border = 0,
			})
		end
		-- 未播放部分（使用普通分段颜色和透明度，保持颜色一致）
		if play_x < end_x then
			ass:rect(play_x, expanded_ay, end_x, expanded_by, {
				color = fg,
				opacity = config.opacity.chapters,  -- 与普通分段透明度一致
				border = 0,
			})
		end
	end

	-- Hovered time and chapter
	local rendered_thumbnail = false
	local hovered_chapter = nil
	if hovered_segment then
		local center_x = (hovered_segment.start_x + hovered_segment.end_x) / 2
		local hovered_time = self:get_time_at_x(center_x)
		for _, ch in ipairs(state.chapters) do
			if math.abs(ch.time - hovered_time) < 0.5 then
				hovered_chapter = ch
				break
			end
		end
	end

	if (self.proximity_raw <= 0 or self.pressed or hovered_chapter) and not Elements:v('speed', 'dragging') then
		local cursor_x = hovered_chapter and t2x(hovered_chapter.time) or cursor.x
		local hovered_seconds = hovered_chapter and hovered_chapter.time or self:get_time_at_x(cursor.x)

		-- Cursor line
		local color = ((fax - 0.5) < cursor_x and cursor_x < (fbx + 0.5)) and bg or fg
		local ax, ay, bx, by = cursor_x - 0.5, fay, cursor_x + 0.5, fby
		ass:rect(ax, ay, bx, by, {color = color, opacity = 0.33})
		local tooltip_anchor = {ax = ax, ay = ay - self.top_border, bx = bx, by = by}

		-- Thumbnail
		if not thumbnail.disabled
			and (not self.pressed or self.pressed.distance < 5)
			and thumbnail.width ~= 0
			and thumbnail.height ~= 0
		then
			local border = 0
			local thumb_x_margin, thumb_y_margin = tooltip_gap + bax, tooltip_gap + 35
			local thumb_width, thumb_height = thumbnail.width, thumbnail.height
			local thumb_x = round(clamp(
				thumb_x_margin,
				cursor_x - thumb_width / 2,
				display.width - thumb_width - thumb_x_margin
			))
			local thumb_y = round(tooltip_anchor.ay - thumb_y_margin - thumb_height)
			local ax, ay = (thumb_x - border), (thumb_y - border)
			local bx, by = (thumb_x + thumb_width + border), (thumb_y + thumb_height + border)
			ass:rect(ax, ay, bx, by, {
				color = bg,
				border = 0,
				opacity = {main = config.opacity.thumbnail, border = 0.08 * config.opacity.thumbnail},
				border_color = fg,
				radius = state.radius,
			})
			local thumb_seconds = (state.rebase_start_time == false and state.start_time) and
				(hovered_seconds - state.start_time) or hovered_seconds
			request_thumbnail(thumb_seconds, thumb_x, thumb_y)
			self.has_thumbnail, rendered_thumbnail = true, true
			tooltip_anchor.ay = ay
		end

		-- Timestamp
		local opts = {
			size = self.font_size * 4.6,
			offset = timestamp_gap,
			margin = tooltip_gap,
			timestamp = options.time_precision > 0,
			background = false,
			bold = true,
		}
		local hovered_time_human = format_time(hovered_seconds, state.duration)
		opts.width_overwrite = timestamp_width(hovered_time_human, opts)
		tooltip_anchor = ass:tooltip(tooltip_anchor, hovered_time_human, opts)
	end

	-- Clear thumbnail
	if not rendered_thumbnail then self:clear_thumbnail() end

	return ass
end

return Timeline