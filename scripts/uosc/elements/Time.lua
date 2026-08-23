local Element = require('elements/Element')

---@class Time : Element
local Time = class(Element)

---@param props? ElementProps
function Time:new(props) return Class.new(self, props) end

function Time:init(props)
    Element.init(self, 'time', props)
    self.width = 0
    self.height = 0
    self.font_size = nil
end

function Time:get_visibility()
    return Elements:maybe('timeline', 'get_is_hovered') and -1 or Element.get_visibility(self)
end

function Time:on_coordinates()
    self.height = self.by - self.ay
    self.width = self.bx - self.ax
    self.font_size = round(self.height * 0.48 * options.font_scale * 1.5)
end

function Time:on_options()
    self:on_coordinates()
end

function Time:render()
    local visibility = self:get_visibility()
    if visibility <= 0 then return end

    local total = state.duration and state.duration > 0 and format_time(state.duration, state.duration) or '--:--:--'
    local current = state.time_human or '--:--:--'
    local text = current .. ' / ' .. total

    -- 测量文本宽度
    local font_size = round(self.height * 0.48 * options.font_scale * 1.5)
    local opts = { size = font_size, bold = true }
    local text_w = text_width(text, opts)

    -- 计算所需最小宽度：文字宽度 + 两边内边距
    local pad = round(4 * state.scale)
    local needed_width = text_w + pad * 2

    -- 获取当前控件的实际宽度
    local current_width = self.bx - self.ax

    -- 如果所需宽度与当前宽度差距较大（超过 5 像素），则更新控件的 ratio
    if math.abs(needed_width - current_width) > 5 then
        local height = self.by - self.ay
        if height > 0 then
            local new_ratio = needed_width / height
            -- 限制 ratio 范围，防止过度膨胀或收缩
            new_ratio = clamp(1.2, new_ratio, 10)
            local controls = Elements.controls
            if controls and self.control_index then
                controls:update_control_ratio(self.control_index, new_ratio)
            end
        end
    end

    -- 正常绘制文本（使用 clip 防止溢出）
    local half_x = self.ax + (self.bx - self.ax) / 2
    local ass = assdraw.ass_new()
    ass:txt(half_x, self.ay + self.height / 2, 5, text, {
        size = font_size,
        color = bgt,
        border = options.text_border * state.scale,
        border_color = bg,
        opacity = visibility,
        bold = true,
        clip = '\\clip(' .. self.ax .. ',' .. self.ay .. ',' .. self.bx .. ',' .. self.by .. ')',
    })

    return ass
end

return Time