local Element = require('elements/Element')
local Button = require('elements/Button')
local Chapter = require('elements/Chapter')
local CycleButton = require('elements/CycleButton')
local ManagedButton = require('elements/ManagedButton')
local Speed = require('elements/Speed')
local Time = require('elements/Time')
local Volume = require('elements/Volume')
local PlayMode = require('elements/PlayMode')
local Episode = require('elements/Episode')
local Subtitle = require('elements/Subtitle')
local Audio = require('elements/Audio')
local DanmakuStyles = require('elements/DanmakuStyles')

-- sizing:
--   static - shrink, have highest claim on available space, disappear when there's not enough of it
--   dynamic - shrink to make room for static elements until they reach their ratio_min, then disappear
--   gap - shrink if there's no space left
--   space - expands to fill available space, shrinks as needed
-- scale - `options.controls_size` scale factor.
-- ratio - Width/height ratio of a static or dynamic element.
-- ratio_min Min ratio for 'dynamic' sized element.
---@alias ControlItem {element?: Element; kind: string; sizing: 'space' | 'static' | 'dynamic' | 'gap'; scale: number; ratio?: number; ratio_min?: number; hide: boolean; dispositions?: {[string]: boolean}[]}

---@class Controls : Element
local Controls = class(Element)

function Controls:new() return Class.new(self) --[[@as Controls]] end
function Controls:init()
	Element.init(self, 'controls', {render_order = 4})
	---@type ControlItem[] All control elements serialized from `options.controls`.
	self.controls = {}
	---@type ControlItem[] Only controls that match current dispositions.
	self.layout = {}

	self:init_options()
end

function Controls:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    -- 1. 保护 Controls 自身区域（空白）
    cursor:zone('primary_click', self, function() end)

    -- 2. 保护底部间隙（如果存在）
    if self.by < display.height then
        local gap_rect = {
            ax = self.ax,
            ay = self.by,
            bx = self.bx,
            by = display.height
        }
        cursor:zone('primary_click', gap_rect, function() end)
    end

    -- 3. 注册各个按钮的交互 zone（后注册会覆盖上面的空白 zone）
    for _, control in ipairs(self.layout) do
        local element = control.element
        if element and not control.hide then
            if element.ax and element.bx and element.ay and element.by then
                local handler = nil
                if element.on_click then
                    handler = element.on_click
                elseif element.toggle then
                    handler = function() element:toggle() end
                elseif element.prop then
                    handler = function() element:cycle() end
                end
                if handler then
                    cursor:zone('primary_click', element, handler, element.ax, element.ay, element.bx, element.by)
                end
            end
        end
    end

    return nil
end

---@param index integer 控件在 self.controls 中的索引
---@param new_ratio number 新的宽高比
function Controls:update_control_ratio(index, new_ratio)
    local control = self.controls[index]
    if not control or control.sizing ~= 'static' and control.sizing ~= 'dynamic' then
        return
    end
    if control.ratio ~= new_ratio then
        control.ratio = new_ratio
        if control.sizing == 'dynamic' then
            control.ratio_min = new_ratio
        end
        self:reflow()
    end
end

function Controls:destroy()
	self:destroy_elements()
	Element.destroy(self)
end

function Controls:init_options()
	-- Serialize control elements
	local shorthands = {
		['play-pause'] = 'cycle:pause:pause:no=pause/yes=play_arrow?' .. t('Play/Pause'),
		menu = 'command:menu:script-binding uosc/menu-blurred?' .. t('Menu'),
		subtitles = 'command:subtitles:script-binding uosc/subtitles#sub>0?' .. t('Subtitles'),
		audio = 'command:graphic_eq:script-binding uosc/audio#audio>1?' .. t('Audio'),
		['audio-device'] = 'command:speaker:script-binding uosc/audio-device?' .. t('Audio device'),
		video = 'command:theaters:script-binding uosc/video#video>1?' .. t('Video'),
		playlist = 'command:list_alt:script-binding uosc/playlist?' .. t('Playlist'),
		chapters = 'command:bookmark:script-binding uosc/chapters#chapters>0?' .. t('Chapters'),
		['editions'] = 'command:bookmarks:script-binding uosc/editions#editions>1?' .. t('Editions'),
		['stream-quality'] = 'command:high_quality:script-binding uosc/stream-quality?' .. t('Stream quality'),
		['open-file'] = 'command:file_open:script-binding uosc/open-file?' .. t('Open file'),
		['items'] = 'command:list_alt:script-binding uosc/items?' .. t('Playlist/Files'),
		prev = 'command:skip_previous:script-binding uosc/prev?' .. t('上一个 ([)'),
		next = 'command:skip_next:script-binding uosc/next?' .. t('下一个 (])'),
		first = 'command:first_page:script-binding uosc/first?' .. t('First'),
		last = 'command:last_page:script-binding uosc/last?' .. t('Last'),
		['loop-playlist'] = 'cycle:repeat:loop-playlist:no/inf!?' .. t('Loop playlist'),
		['loop-file'] = 'cycle:repeat_one:loop-file:no/inf!?' .. t('Loop file'),
		shuffle = 'toggle:shuffle:shuffle?' .. t('Shuffle'),
		autoload = 'toggle:hdr_auto:autoload@uosc?' .. t('Autoload'),
		fullscreen = 'cycle:fullscreen:fullscreen:no/yes?',
		danmaku_toggle = 'cycle:show_danmaku@uosc_danmaku:on=speaker_notes/off=speaker_notes_off?' .. t('Toggle danmaku'),
	}

	-- Parse out disposition/config pairs
	local items = {}
	local in_disposition = false
	local current_item = nil
	for c in options.controls:gmatch('.') do
		if not current_item then current_item = {disposition = '', config = ''} end
		if c == '<' and #current_item.config == 0 then
			in_disposition = true
		elseif c == '>' and #current_item.config == 0 then
			in_disposition = false
		elseif c == ',' and not in_disposition then
			items[#items + 1] = current_item
			current_item = nil
		else
			local prop = in_disposition and 'disposition' or 'config'
			current_item[prop] = current_item[prop] .. c
		end
	end
	items[#items + 1] = current_item

	-- Create controls
	self.controls = {}
	for i, item in ipairs(items) do
		local config = shorthands[item.config] and shorthands[item.config] or item.config
		local config_tooltip = split(config, ' *%? *')
		local tooltip = config_tooltip[2]
		config = shorthands[config_tooltip[1]]
			and split(shorthands[config_tooltip[1]], ' *%? *')[1] or config_tooltip[1]
		local config_badge = split(config, ' *# *')
		config = config_badge[1]
		local badge = config_badge[2]
		local parts = split(config, ' *: *')
		local kind, params = parts[1], itable_slice(parts, 2)

		-- Serialize dispositions into OR groups of AND conditions
		---@type {[string]: boolean}[]
		local dispositions = {}
		---@type string[]
		local disposition_props = {}
		for _, or_group in ipairs(comma_split(item.disposition)) do
			local group = {}
			for _, condition in ipairs(split(or_group, ' *+ *')) do
				if #condition > 0 then
					local value = condition:sub(1, 1) ~= '!'
					local name = not value and condition:sub(2) or condition
					if name:sub(1, 4) == 'has_' or itable_has({'idle', 'image', 'audio', 'video', 'stream'}, name) then
						local prop = name:sub(1, 4) == 'has_' and name or 'is_' .. name
						group[prop] = value
					else
						disposition_props[#disposition_props + 1] = name
						group[name] = value
					end
				end
			end
			dispositions[#dispositions + 1] = group
		end

		-- Convert toggles into cycles
		if kind == 'toggle' then
			kind = 'cycle'
			params[#params + 1] = 'no/yes!'
		end

		-- Create a control element
		local control = {dispositions = dispositions, kind = kind}

		if kind == 'space' then
			control.sizing = 'space'
		elseif kind == 'gap' then
			table_assign(control, {sizing = 'gap', scale = 1, ratio = params[1] or 0.3, ratio_min = 0})
		elseif kind == 'command' then
            if #params ~= 2 then
                mp.msg.error(string.format(
                    'command button needs 2 parameters, %d received: %s', #params, table.concat(params, '/')
                ))
            else
                local icon = params[1]
                local command = params[2]
                local is_chapter = command == 'script-binding uosc/chapters'
                local is_subtitles = command == 'script-binding uosc/subtitles'
                local is_audio = command == 'script-binding uosc/audio'

                if is_chapter then
                    local element = Chapter:new('control_' .. i, {
                        render_order = self.render_order,
                        anchor_id = 'controls',
                        tooltip = tooltip or t('章节'),
                    })
                    table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
                    if badge then self:register_badge_updater(badge, element) end
                elseif is_subtitles then
                    local element = Subtitle:new('control_' .. i, {
                        render_order = self.render_order,
                        anchor_id = 'controls',
                        tooltip = tooltip or t('字幕'),
                    })
                    table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
                    if badge then self:register_badge_updater(badge, element) end
                elseif is_audio then
                    local element = Audio:new('control_' .. i, {
                        render_order = self.render_order,
                        anchor_id = 'controls',
                        tooltip = tooltip or t('音轨'),
                    })
                    table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
                    if badge then self:register_badge_updater(badge, element) end
                else
                    local element = Button:new('control_' .. i, {
                        render_order = self.render_order,
                        icon = icon,
                        anchor_id = 'controls',
                        on_click = function() mp.command(command) end,
                        tooltip = tooltip,
                        count_prop = 'sub',
                    })
                    table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
                    if badge then self:register_badge_updater(badge, element) end
                end
            end
		elseif kind == 'cycle' then
			local prop, states_def
			if #params == 3 then
				local icon = params[1]
				prop = params[2]
				states_def = params[3]
			elseif #params == 2 then
				prop = params[1]
				states_def = params[2]
			else
				mp.msg.error(string.format(
					'cycle button needs 2 or 3 parameters, %d received: %s',
					#params, table.concat(params, '/')
				))
				goto continue
			end
			local state_configs = split(states_def, ' */ *')
			local states = {}
			local default_icon = nil
			for _, state_config in ipairs(state_configs) do
				local active = false
				if state_config:sub(-1) == '!' then
					active = true
					state_config = state_config:sub(1, -2)
				end
				local state_params = split(state_config, ' *= *')
				local value, icon = state_params[1], state_params[2]
				if not icon then icon = value end
				if not default_icon then default_icon = icon end
				states[#states + 1] = {value = value, icon = icon, active = active}
			end
			local state_tooltips = nil
			if prop == 'show_danmaku@uosc_danmaku' then
				state_tooltips = {
					on  = '关闭弹幕 (d)',
					off = '开启弹幕 (d)',
				}
			elseif prop == 'fullscreen' then
				state_tooltips = {
					['no']  = '进入全屏 (f)',
					['yes'] = '退出全屏 (f)',
				}
				tooltip = nil
			end
			local args = {
				render_order = self.render_order,
				prop = prop,
				anchor_id = 'controls',
				states = states,
				state_tooltips = state_tooltips,
			}
			if #params == 3 then
				args.icon = params[1]
			end
			local element = CycleButton:new('control_' .. i, args)
			table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
			if badge then self:register_badge_updater(badge, element) end
		elseif kind == 'button' then
			if #params ~= 1 then
				mp.msg.error(string.format(
					'managed button needs 1 parameter, %d received: %s', #params, table.concat(params, '/')
				))
			else
				local name = params[1]
				local element = ManagedButton:new('control_' .. i, {
					name = name,
					render_order = self.render_order,
					anchor_id = 'controls',
					on_hide = function() self:reflow() end,
				})
				table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
			end
		elseif kind == 'speed' then
			if not Elements.speed then
				local element = Speed:new({anchor_id = 'controls', render_order = self.render_order})
				local scale = tonumber(params[1]) or 1
				table_assign(control, {
					element = element, sizing = 'dynamic', scale = 1, ratio = 1.2, ratio_min = 1.2,
				})
			else
				msg.error('there can only be 1 speed slider')
			end
		elseif kind == 'time' then
			local element = Time:new({
				anchor_id = 'controls',
				render_order = self.render_order,
			})
			-- control_index 属性，指向自身在 control 列表中的位置
			local control_index = #self.controls + 1
			element.control_index = control_index
			table_assign(control, {element = element, sizing = 'dynamic', scale = 1, ratio = 2, ratio_min = 1.5,})
		elseif kind == 'volume' then
			local element = Volume:new('control_' .. i, {
				render_order = self.render_order,
				anchor_id = 'controls',
				tooltip = tooltip or t('Volume'),
			})
			table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
		elseif kind == 'play-mode' then
			local element = PlayMode:new('control_' .. i, {
				render_order = self.render_order,
				anchor_id = 'controls',
				tooltip = tooltip,
			})
			table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
		elseif kind == 'episode' then
			local element = Episode:new('control_' .. i, {
				render_order = self.render_order,
				anchor_id = 'controls',
				tooltip = tooltip or t('选集'),
			})
			table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
		elseif kind == 'danmaku_styles' then
			local element = DanmakuStyles:new('control_' .. i, {
				render_order = self.render_order,
				anchor_id = 'controls',
				tooltip = t('弹幕设置'),
			})
			table_assign(control, {element = element, sizing = 'static', scale = 1, ratio = 1})
		else
			msg.error('unknown element kind "' .. kind .. '"')
			break
		end
		::continue::

		if control.element then
			for _, prop in ipairs(disposition_props) do
				control.element:observe_mp_property(prop, function() self:reflow() end)
			end
		end
		self.controls[#self.controls + 1] = control
	end

	self:reflow()
end

function Controls:reflow()
	-- Populate the layout only with items that are not hidden and match current disposition
	self.layout = {}
	for _, control in ipairs(self.controls) do
		local matches = false
		local conditions_num = 0

		for _, group in pairs(control.dispositions) do
			local group_matches = true
			for prop, value in pairs(group) do
				conditions_num = conditions_num + 1
				local current_value
				if prop:sub(1, 4) == 'has_' or prop:sub(1, 3) == 'is_' then
					current_value = state[prop]
				else
					current_value = mp.get_property_bool(prop, false)
				end
				if current_value ~= value then
					group_matches = false
					break
				end
			end
			if group_matches then
				matches = true
				break
			end
		end

		if conditions_num == 0 then matches = true end
		local show = matches and (not control.element or control.element.hide ~= true)
		if control.element then control.element.enabled = show end
		if show then self.layout[#self.layout + 1] = control end
	end

	self:update_dimensions()
	Elements:trigger('controls_reflow')
end

function Controls:register_badge_updater(badge, element)
	local prop_and_limit = split(badge, ' *> *')
	local prop, limit = prop_and_limit[1], tonumber(prop_and_limit[2] or -1)
	local observable_name, serializer, is_external_prop = prop, nil, false

	if itable_index_of({'sub', 'audio', 'video'}, prop) then
		observable_name = 'track-list'
		serializer = function(value)
			local count = 0
			for _, track in ipairs(value) do if track.type == prop then count = count + 1 end end
			return count
		end
	else
		local parts = split(prop, '@')
		if #parts > 1 then prop, is_external_prop = parts[1] ~= '' and parts[1] or parts[2], true end
		serializer = function(value) return value and (type(value) == 'table' and #value or tostring(value)) or nil end
	end

	local function handler(_, value)
		local new_value = serializer(value)
		local value_number = tonumber(new_value)
		if value_number then new_value = value_number > limit and value_number or nil end
		element.badge = new_value
		request_render()
	end

	if is_external_prop then
		element['on_external_prop_' .. prop] = function(_, value) handler(prop, value) end
	else
		element:observe_mp_property(observable_name, handler)
	end
end

function Controls:get_visibility()
	return Elements:v('speed', 'dragging') and 1 or Elements:maybe('timeline', 'get_is_hovered')
		and -1 or Element.get_visibility(self)
end

function Controls:update_dimensions()
	local window_border = Elements:v('window_border', 'size', 0)
	local size = round(options.controls_size * state.scale)
	local spacing = round(options.controls_spacing * state.scale)
	local margin = round(options.controls_margin * state.scale)

	local available_space = display.height - window_border * 2 - Elements:v('top_bar', 'size', 0)
	self.enabled = available_space > size + 10

	if not self.enabled then 
		for _, control in ipairs(self.layout) do
			if control.element then control.element.enabled = false end
        end
		return
	end

	self.ay = display.height - window_border - margin - size
    self.by = self.ay + size
    self.ax = window_border + margin
    self.bx = display.width - window_border - margin

	local available_width, statics_width = self.bx - self.ax, 0
	local min_content_width = statics_width
	local max_dynamics_width, dynamic_units, spaces, gaps = 0, 0, 0, 0

	for c, control in ipairs(self.layout) do
		if control.sizing == 'space' then
			spaces = spaces + 1
		elseif control.sizing == 'gap' then
			gaps = gaps + control.scale * control.ratio
		elseif control.sizing == 'static' then
			local width = size * control.scale * control.ratio + (c ~= #self.layout and spacing or 0)
			statics_width = statics_width + width
			min_content_width = min_content_width + width
		elseif control.sizing == 'dynamic' then
			local spacing = (c ~= #self.layout and spacing or 0)
			statics_width = statics_width + spacing
			min_content_width = min_content_width + size * control.scale * control.ratio_min + spacing
			max_dynamics_width = max_dynamics_width + size * control.scale * control.ratio
			dynamic_units = dynamic_units + control.scale * control.ratio
		end
	end

	if min_content_width > available_width then
		local i = math.ceil(#self.layout / 2 + 0.1)
		for a = 0, #self.layout - 1, 1 do
			i = i + (a * (a % 2 == 0 and 1 or -1))
			local control = self.layout[i]

			if control.sizing ~= 'gap' and control.sizing ~= 'space' then
				control.hide = true
				if control.element then control.element.enabled = false end
				if control.sizing == 'static' then
					local width = size * control.scale * control.ratio
					min_content_width = min_content_width - width - spacing
					statics_width = statics_width - width - spacing
				elseif control.sizing == 'dynamic' then
					statics_width = statics_width - spacing
					min_content_width = min_content_width - size * control.scale * control.ratio_min - spacing
					max_dynamics_width = max_dynamics_width - size * control.scale * control.ratio
					dynamic_units = dynamic_units - control.scale * control.ratio
				end

				if min_content_width < available_width then break end
			end
		end
	end

	local current_x = self.ax
	local width_for_dynamics = available_width - statics_width
	local empty_space_width = width_for_dynamics - max_dynamics_width
	local width_for_gaps = math.min(empty_space_width, size * gaps)

	local space_widths = {}
	if spaces == 2 then
		local section = 1
		local section_widths = {0, 0, 0}
		for c, control in ipairs(self.layout) do
			if not control.hide then
				if control.sizing == 'space' then
					section = section + 1
				else
					local w = 0
					if control.sizing == 'gap' then
						if width_for_gaps > 0 then w = width_for_gaps * (control.ratio / gaps) end
					elseif control.sizing == 'static' then
						w = size * control.scale * control.ratio + (c ~= #self.layout and spacing or 0)
					elseif control.sizing == 'dynamic' then
						local height = size * control.scale
						w = (max_dynamics_width < width_for_dynamics
							and height * control.ratio or width_for_dynamics * ((control.scale * control.ratio) / dynamic_units))
							+ (c ~= #self.layout and spacing or 0)
					end
					section_widths[section] = section_widths[section] + w
				end
			end
		end
		local left_w, middle_w = section_widths[1], section_widths[2]
		local total_space = empty_space_width - width_for_gaps
		local space1 = (available_width - middle_w) / 2 - left_w + spacing / 2
		local space2 = total_space - space1
		if space1 < 0 then
			space2 = space2 + space1
			space1 = 0
		elseif space2 < 0 then
			space1 = space1 + space2
			space2 = 0
		end
		if space1 < 0 then space1 = 0 end
		if space2 < 0 then space2 = 0 end
		space_widths = {space1, space2}
	else
		local individual_space_width = spaces > 0 and ((empty_space_width - width_for_gaps) / spaces) or 0
		for i = 1, spaces do space_widths[i] = individual_space_width end
	end

	local space_index = 0
	for c, control in ipairs(self.layout) do
		if not control.hide then
			local sizing, element, scale, ratio = control.sizing, control.element, control.scale, control.ratio
			local width, height = 0, 0

			if sizing == 'space' then
				space_index = space_index + 1
				width = space_widths[space_index] or 0
			elseif sizing == 'gap' then
				if width_for_gaps > 0 then width = width_for_gaps * (ratio / gaps) end
			elseif sizing == 'static' then
				height = size * scale
				width = height * ratio
			elseif sizing == 'dynamic' then
				height = size * scale
				width = max_dynamics_width < width_for_dynamics
					and height * ratio or width_for_dynamics * ((scale * ratio) / dynamic_units)
			end

			local bx = current_x + width
			if element then element:set_coordinates(round(current_x), round(self.by - height), bx, self.by) end
			current_x = element and bx + spacing or bx
		end
	end

	Elements:update_proximities()
	request_render()
end

function Controls:on_dispositions() self:reflow() end
function Controls:on_display() self:update_dimensions() end
function Controls:on_prop_border() self:update_dimensions() end
function Controls:on_prop_title_bar() self:update_dimensions() end
function Controls:on_prop_fullormaxed() self:update_dimensions() end
function Controls:on_timeline_enabled() self:update_dimensions() end

function Controls:destroy_elements()
	for _, control in ipairs(self.controls) do
		if control.element then control.element:destroy() end
	end
end

function Controls:on_options()
	self:destroy_elements()
	self:init_options()
end

return Controls