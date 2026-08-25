-- A minimal offline AppDock DApp example.
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local function scale(value)
    return Device.screen:scaleBySize(value)
end

local function emptySizedWidget(width, height)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalSpan:new{ width = 0 },
    }
end

return {
    id = "quote_card",
    title = "Quote Card",
    subtitle = "A small offline reading companion",
    symbol = "Q",
    logo = "help",
    buildPane = function(instance, context)
        local width, height = context.dimen.w, context.dimen.h
        local margin = scale(16)
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{
                width = width, height = height, padding = 0, bordersize = 0,
                background = require("ffi/blitbuffer").COLOR_WHITE,
                emptySizedWidget(width, height),
            },
            FrameContainer:new{
                width = width - 2 * margin,
                height = math.min(height - 2 * margin, scale(150)),
                padding = 0,
                bordersize = scale(1),
                radius = scale(16),
                background = require("ffi/blitbuffer").COLOR_LIGHT_GRAY,
                color = require("ffi/blitbuffer").COLOR_DARK_GRAY,
                emptySizedWidget(width - 2 * margin, math.min(height - 2 * margin, scale(150))),
                overlap_offset = { margin, margin },
            },
            TextWidget:new{
                text = "“A reader lives a thousand lives before he dies.”",
                face = Font:getFace("cfont", scale(18)),
                fgcolor = require("ffi/blitbuffer").COLOR_BLACK,
                bold = true,
                max_width = width - 4 * margin,
                overlap_offset = { 2 * margin, 2 * margin },
            },
            TextWidget:new{
                text = "— George R. R. Martin",
                face = Font:getFace("smallinfofont", scale(12)),
                fgcolor = require("ffi/blitbuffer").COLOR_DARK_GRAY,
                max_width = width - 4 * margin,
                overlap_offset = { 2 * margin, scale(96) },
            },
        }
        return pane
    end,
}
