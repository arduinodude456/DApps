-- Analog Clock Widget: sampled only when the AppDock homescreen rebuilds.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")
local _ = require("gettext")

local function scale(value) return Device.screen:scaleBySize(value) end
local function line(bb, x0, y0, x1, y1, thickness, ink)
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    for step = 0, math.max(1, steps) do
        local x = math.floor(x0 + dx * step / math.max(1, steps) - thickness / 2)
        local y = math.floor(y0 + dy * step / math.max(1, steps) - thickness / 2)
        bb:paintRect(x, y, thickness, thickness, ink)
    end
end

local ClockFace = Widget:extend{ dimen = nil, hour = 0, minute = 0 }
function ClockFace:init() self.dimen = Geom:new{ w = self.size, h = self.size } end
function ClockFace:getSize() return self.dimen end
function ClockFace:paintTo(bb, x, y)
    local size, cx, cy = self.size, x + math.floor(self.size / 2), y + math.floor(self.size / 2)
    local radius, ink = math.floor(size * .42), Blitbuffer.COLOR_DARK_GRAY
    local dot = math.max(1, math.floor(size * .055))
    for index = 0, 11 do
        local angle = math.pi * 2 * index / 12
        bb:paintRect(math.floor(cx + math.sin(angle) * radius - dot / 2), math.floor(cy - math.cos(angle) * radius - dot / 2), dot, dot, ink)
    end
    local hour_angle = math.pi * 2 * ((self.hour % 12) + self.minute / 60) / 12
    local minute_angle = math.pi * 2 * self.minute / 60
    line(bb, cx, cy, cx + math.sin(hour_angle) * radius * .52, cy - math.cos(hour_angle) * radius * .52, math.max(1, dot + 1), ink)
    line(bb, cx, cy, cx + math.sin(minute_angle) * radius * .76, cy - math.cos(minute_angle) * radius * .76, dot, ink)
    bb:paintRect(cx - dot, cy - dot, dot * 2, dot * 2, Blitbuffer.COLOR_BLACK)
end

return {
    id = "analog_clock_widget",
    version = "1.0.0",
    title = "Analog Clock",
    subtitle = "A quiet homescreen clock",
    symbol = "C",
    logo = "analog_clock",
    buildWidget = function(instance, context)
        local now = os.date("*t")
        local width, height, margin = context.dimen.w, context.dimen.h, scale(14)
        local clock_size = math.max(scale(50), math.min(height - scale(20), math.floor(width * .30)))
        local time_text = os.date("%H:%M")
        return OverlapGroup:new{
            dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
            ClockFace:new{ size = clock_size, hour = now.hour, minute = now.min, overlap_offset = { margin, math.max(scale(8), math.floor((height - clock_size) / 2)) } },
            TextWidget:new{ text = _("Analog Clock"), face = Font:getFace("smallinfofont", scale(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true, overlap_offset = { margin + clock_size + scale(12), scale(16) } },
            TextWidget:new{ text = time_text, face = Font:getFace("cfont", scale(22)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin + clock_size + scale(12), math.max(scale(36), math.floor(height / 2) - scale(12)) } },
            TextWidget:new{ text = os.date("%a, %d %b"), face = Font:getFace("smallinfofont", scale(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - clock_size - 3 * margin, overlap_offset = { margin + clock_size + scale(12), height - scale(29) } },
        }
    end,
    _test = { ClockFace = ClockFace },
}
