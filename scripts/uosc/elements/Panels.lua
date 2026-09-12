-- elements/Panels.lua
-- 列表型面板的合并文件：
--   - TrackPanel（基类）+ Audio / Subtitle：音轨/字幕列表
--   - Episode：选集列表

local PanelElement = require('elements/PanelElement')

-- ============================================================
-- TrackPanel: 音轨/字幕面板共享基类
-- ============================================================
---@class TrackPanel : PanelElement
local TrackPanel = class(PanelElement)

TrackPanel.track_type         = nil
TrackPanel.icon_name          = nil
TrackPanel.default_tooltip    = nil
TrackPanel.track_title_prefix = '轨道'
TrackPanel.load_text          = nil
TrackPanel.load_command       = nil
TrackPanel.active_color       = 'ecae00'

function TrackPanel:init(id, props)
    PanelElement.init(self, id, props)
    self.tooltip = props.tooltip or self.default_tooltip
    self.track_list = mp.get_property_native('track-list') or {}
    self.font_size = 0

    self:observe_mp_property('track-list', 'native', function()
        self.track_list = mp.get_property_native('track-list') or {}
        self.scroll_y = 0
        self._panel_rect = nil
        request_render()
    end)
end

function TrackPanel:draw_button(ass, visibility)
    local cx = (self.ax + self.bx) / 2
    local cy = (self.ay + self.by) / 2
    ass:icon(cx, cy, self.font_size, self.icon_name, {
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
    })
end

function TrackPanel:get_panel_rect()
    self.items = itable_filter(self.track_list, function(t) return t.type == self.track_type end)
    return self:calculate_panel_rect(470, 0, 40, 24, 24, 12, {
        _tracks = self.items,
        _total_items = #self.items + 1,
    })
end

function TrackPanel:get_active_track_id() return nil end
function TrackPanel:activate_track(track) end

--- 公共骨架：lang + codec + [子类额外提示] + default + forced
--- 子类若想在末尾追加更多提示（如外挂字幕），可覆盖此方法并在父类结果后追加。

function TrackPanel:get_track_hint_parts(track)
    local parts = {}
    if track.lang then table.insert(parts, track.lang) end
    local codec = track.codec or track['demux-codec']
    if codec then table.insert(parts, codec) end
    self:append_extra_track_hints(track, parts)
    if track.default then table.insert(parts, '默认') end
    if track.forced  then table.insert(parts, '强制') end
    return parts
end

--- 子类覆盖：在 lang/codec 之后、default/forced 之前追加类型特有提示。

function TrackPanel:append_extra_track_hints(track, parts) end

function TrackPanel:get_track_title(track)
    if track.title and track.title ~= '' then return track.title end
    return self.track_title_prefix .. ' ' .. track.id
end

function TrackPanel:draw_content(ass, rect)
    local tracks = rect._tracks
    local active_id = self:get_active_track_id()
    local active_color = self.active_color
    local padding_h = rect._padding_h
    local padding_v = rect._padding_v
    local row_height = rect._row_height
    local font_size = rect._font_size
    local panel_clip = '\\clip('..rect.ax..','..rect.ay..','..rect.bx..','..rect.by..')'
    local left_base  = rect.ax + padding_h
    local right_base = rect.bx - padding_h

    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
        color = '000000', opacity = 0.85, radius = round(2 * state.scale),
    })

    for i, track in ipairs(tracks) do
        local item_y = rect.ay + padding_v + (i - 1) * row_height - self.scroll_y
        if not self:is_item_visible(rect, item_y, row_height) then goto continue end

        if self:is_item_hovered(rect, item_y, row_height) then
            self:draw_item_hover(ass, rect, item_y, row_height, panel_clip)
        end

        local is_active  = (track.id == active_id)
        local left_text  = self:get_track_title(track)
        local right_text = table.concat(self:get_track_hint_parts(track), ', ')

        local text_x = left_base
        if is_active then
            ass:icon(left_base + font_size / 2, item_y + row_height / 2, font_size, 'play_arrow', {
                color = active_color, opacity = 0.9, clip = panel_clip,
            })
            text_x = left_base + font_size + 8
        end
        ass:txt(text_x, item_y + row_height / 2, 4, left_text, {
            size = font_size,
            color = is_active and active_color or 'ffffff',
            bold = is_active, opacity = 0.9, clip = panel_clip,
        })
        if right_text ~= '' then
            ass:txt(right_base, item_y + row_height / 2, 6, right_text, {
                size = font_size,
                color = is_active and active_color or 'ffffff',
                bold = is_active, opacity = 0.9, clip = panel_clip,
            })
        end

        cursor:zone('primary_click',
            { ax = rect.ax, ay = item_y, bx = rect.bx, by = item_y + row_height },
            function()
                self:activate_track(track)
                self:close_panel()
            end)
        ::continue::
    end

    if self.load_text then
        self:draw_load_row(ass, rect, #tracks + 1, panel_clip,
            left_base, right_base, font_size, row_height, padding_v)
    end

    self:draw_separators(ass, rect, padding_h, padding_v, row_height, self.scroll_y,
        rect._total_items, panel_clip)
end

function TrackPanel:draw_load_row(ass, rect, index, panel_clip, left_base, right_base,
                                   font_size, row_height, padding_v)
    local load_y = rect.ay + padding_v + (index - 1) * row_height - self.scroll_y
    if not self:is_item_visible(rect, load_y, row_height) then return end

    if self:is_item_hovered(rect, load_y, row_height) then
        self:draw_item_hover(ass, rect, load_y, row_height, panel_clip)
    end
    ass:txt(left_base, load_y + row_height / 2, 4, self.load_text, {
        size = font_size, color = 'ffffff', bold = false, opacity = 0.9, clip = panel_clip,
    })
    ass:icon(right_base - font_size / 2, load_y + row_height / 2, font_size, 'file_upload', {
        color = 'ffffff', opacity = 0.9, clip = panel_clip,
    })
    cursor:zone('primary_click',
        { ax = rect.ax, ay = load_y, bx = rect.bx, by = load_y + row_height },
        function()
            self:close_panel()
            mp.commandv('script-binding', self.load_command)
        end)
end

-- ============================================================
-- Audio
-- ============================================================
---@class Audio : TrackPanel
local Audio = class(TrackPanel)

Audio.track_type         = 'audio'
Audio.icon_name          = 'audiotrack'
Audio.default_tooltip    = '音轨'
Audio.track_title_prefix = '音轨'
Audio.load_text          = '加载音轨'
Audio.load_command       = 'uosc/load-audio'

function Audio:get_active_track_id() return mp.get_property_native('audio') end
function Audio:activate_track(track) mp.set_property_native('audio', track.id) end

function Audio:append_extra_track_hints(track, parts)
    if track['audio-channels'] then table.insert(parts, track['audio-channels'] .. '声道') end
    if track['demux-samplerate'] then table.insert(parts, (track['demux-samplerate'] / 1000) .. 'kHz') end
end

-- ============================================================
-- Subtitle
-- ============================================================
---@class Subtitle : TrackPanel
local Subtitle = class(TrackPanel)

Subtitle.track_type         = 'sub'
Subtitle.icon_name          = 'closed_caption'
Subtitle.default_tooltip    = '字幕'
Subtitle.track_title_prefix = '字幕'
Subtitle.load_text          = '加载字幕'
Subtitle.load_command       = 'uosc/load-subtitles'

function Subtitle:get_active_track_id() return mp.get_property_native('sub') end
function Subtitle:activate_track(track) mp.set_property_native('sub', track.id) end

function Subtitle:get_track_hint_parts(track)
    local parts = TrackPanel.get_track_hint_parts(self, track)
    if track.external then table.insert(parts, '外部') end
    return parts
end

-- ============================================================
-- Episode：选集面板
-- ============================================================
---@class Episode : PanelElement
local Episode = class(PanelElement)

function Episode:init(id, props)
    PanelElement.init(self, id, props)
    self.tooltip = props.tooltip or '选集'
    self.playlist = mp.get_property_native('playlist') or {}
    self.font_size = 0
	self._scroll_to_current = false

    self:observe_mp_property('playlist', 'native', function()
        self.playlist = mp.get_property_native('playlist') or {}
        self.scroll_y = 0
        self._panel_rect = nil
        request_render()
    end)
end

function Episode:open_panel()
    PanelElement.open_panel(self)
    self._scroll_to_current = true
end

function Episode:draw_hover_background(ass)
    local text = '选集'
    local opts = { size = self.font_size, bold = true }
    local text_w = text_width(text, opts)
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

function Episode:draw_button(ass, visibility)
    local cx = (self.ax + self.bx) / 2
    local cy = (self.ay + self.by) / 2
    ass:txt(cx, cy, 5, '选集', {
        size = self.font_size,
        color = bgt,
        bold = true,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
    })
end

function Episode:get_panel_rect()
    local PANEL_WIDTH = 360
    local ROW_HEIGHT = 48
    local FONT_SIZE = 24
    local PADDING_H = 20
    local PADDING_V = 12
    local TITLE_HEIGHT = 48
    local TITLE_BOTTOM_MARGIN = 16

    -- 上限按"最多显示多少集"表达
    local MAX_VISIBLE_ITEMS = 14
    local desired_height = TITLE_HEIGHT + TITLE_BOTTOM_MARGIN
        + MAX_VISIBLE_ITEMS * ROW_HEIGHT + PADDING_V * 2

    self.items = self.playlist
    local total_items = #self.items
    local list_height = total_items * ROW_HEIGHT
    self.content_height = list_height

    local total_content_height = TITLE_HEIGHT + TITLE_BOTTOM_MARGIN + list_height + PADDING_V * 2

    -- 屏幕约束
    local timeline_ay = Elements:v('timeline', 'ay', display.height)
    local screen_limit = math.min(display.height * 0.9, timeline_ay - 32)
    local MAX_HEIGHT = math.min(desired_height, screen_limit)

    local final_height = math.min(total_content_height, MAX_HEIGHT)

    local scrollable_height = final_height - PADDING_V * 2 - TITLE_HEIGHT - TITLE_BOTTOM_MARGIN
    local scroll_enabled = list_height > scrollable_height
    local max_scroll = math.max(0, list_height - scrollable_height)

    if self._scroll_to_current then
        self._scroll_to_current = false
        local current_pos = mp.get_property_native('playlist-pos-1') or 1
        current_pos = math.max(1, math.min(current_pos, total_items))
        local centered = (current_pos - 1) * ROW_HEIGHT - (scrollable_height - ROW_HEIGHT) / 2
        self.scroll_y = math.max(0, math.min(centered, max_scroll))
    else
        self.scroll_y = math.max(0, math.min(self.scroll_y, max_scroll))
    end

    local panel_x, panel_y = self:get_panel_origin(PANEL_WIDTH, final_height)
    local list_start_y = panel_y + PADDING_V + TITLE_HEIGHT + TITLE_BOTTOM_MARGIN

    return {
        ax = panel_x, ay = panel_y,
        bx = panel_x + PANEL_WIDTH, by = panel_y + final_height,
        _row_height = ROW_HEIGHT,
        _padding_h = PADDING_H,
        _padding_v = PADDING_V,
        _font_size = FONT_SIZE,
        _scroll_enabled = scroll_enabled,
        _max_scroll = max_scroll,
        _content_height = self.content_height,
        _total_items = total_items,
        _title_height = TITLE_HEIGHT,
        _title_bottom_margin = TITLE_BOTTOM_MARGIN,
        _scroll_top = list_start_y,
        _scroll_bottom = panel_y + final_height,
    }
end

function Episode:draw_content(ass, rect)
    local padding_h = rect._padding_h
    local padding_v = rect._padding_v
    local row_height = rect._row_height
    local font_size = rect._font_size
    local total_items = rect._total_items
    local title_height = rect._title_height
    local title_bottom_margin = rect._title_bottom_margin
    local current_pos = mp.get_property_native('playlist-pos-1') or 1
    local bili_blue = 'ecae00'
    local pink_bgr = '9972FB'
    local panel_clip = '\\clip('..rect.ax..','..rect.ay..','..rect.bx..','..rect.by..')'

    ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
        color = '000000', opacity = 0.85, radius = round(2 * state.scale),
    })

    local title_y = rect.ay + padding_v
    ass:txt(rect.ax + padding_h, title_y + title_height / 2, 4, '选集', {
        size = font_size, color = 'ffffff', bold = true, opacity = 0.9, clip = panel_clip,
    })
    local line_y = title_y + title_height
    ass:rect(rect.ax + padding_h, line_y, rect.bx - padding_h, line_y + 1, {
        color = 'ffffff', opacity = 0.15, clip = panel_clip,
    })

    local list_start_y = rect.ay + padding_v + title_height + title_bottom_margin
    local list_clip = '\\clip('..rect.ax..','..list_start_y..','..rect.bx..','..rect.by..')'
    local left_base = rect.ax + padding_h

    for i = 1, total_items do
        local item_y = list_start_y + (i - 1) * row_height - self.scroll_y
        if not self:is_item_visible(rect, item_y, row_height) then goto continue end

        local is_current = (i == current_pos)
        local color = is_current and bili_blue or 'ffffff'

        if self:is_item_hovered(rect, item_y, row_height) then
            self:draw_item_hover(ass, rect, item_y, row_height, list_clip)
        end

        local text_x = left_base
        if is_current then
            ass:icon(left_base + font_size / 2, item_y + row_height / 2, font_size, 'play_arrow', {
                color = color, opacity = 0.9, clip = list_clip,
            })
            text_x = left_base + font_size + 8
        end

        ass:txt(text_x, item_y + row_height / 2, 4, '第' .. i .. '话', {
            size = font_size, color = color, bold = is_current, opacity = 0.9, clip = list_clip,
        })

        if is_current then
            local playing_text = '播放'
            local playing_font_size = font_size * 0.8
            local playing_width = text_width(playing_text, {size = playing_font_size, bold = true})
            local label_padding_h = 2
            local label_padding_v = 2
            local bg_ax = rect.bx - padding_h - playing_width - label_padding_h * 2
            local bg_ay = item_y + (row_height - (playing_font_size + label_padding_v * 2)) / 2
            local bg_bx = rect.bx - padding_h
            local bg_by = bg_ay + playing_font_size + label_padding_v * 2
            local visible_bg_ay = math.max(bg_ay, rect.ay)
            local visible_bg_by = math.min(bg_by, rect.by)
            if visible_bg_ay < visible_bg_by then
                ass:rect(bg_ax, visible_bg_ay, bg_bx, visible_bg_by, {
                    color = pink_bgr, opacity = 0.9,
                    radius = round(state.radius * 0.5), clip = list_clip,
                })
            end
            ass:txt((bg_ax + bg_bx) / 2, (bg_ay + bg_by) / 2, 5, playing_text, {
                size = playing_font_size, color = fg, bold = true, opacity = 0.9, clip = list_clip,
            })
        end

        cursor:zone('primary_click',
            { ax = rect.ax, ay = item_y, bx = rect.bx, by = item_y + row_height },
            function()
                mp.commandv('playlist-play-index', i - 1)
                self:close_panel()
            end)
        ::continue::
    end
end

return {
    TrackPanel = TrackPanel,
    Audio = Audio,
    Subtitle = Subtitle,
    Episode = Episode,
}