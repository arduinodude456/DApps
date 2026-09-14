local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local function px(v) return Device.screen:scaleBySize(v) end
local function button(title, width, callback)
    local B = InputContainer:extend{ width = width, height = px(46), callback = callback }
    function B:init()
        self.dimen = Geom:new{ w = self.width, h = self.height }
        self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = px(13), background = Blitbuffer.COLOR_GRAY_8, CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or title, face = Font:getFace("smallinfofont", px(13)), fgcolor = Blitbuffer.COLOR_WHITE, bold = true } } }
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    end
    function B:onTap() if self.callback then self.callback() end return true end
    return B:new{ title = title, width = width, callback = callback }
end
return {
    id = "focus_timer", version = "1.0.0", title = "Focus Timer", subtitle = "A quiet local focus timer", symbol = "T", logo = "calendar",
    buildPane = function(instance, context)
        local w, h, margin = context.dimen.w, context.dimen.h, px(18)
        instance.minutes = instance.minutes or 25; instance.running = instance.running or false
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = w, h = h } }
        local status = instance.running and _("Focus session active") or _("Ready for a calm session")
        local actions = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false,
            FrameContainer:new{ width = w, height = h, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, CenterContainer:new{ dimen = pane.dimen, TextWidget:new{ text = "" } } },
            TextWidget:new{ text = _("Focus Timer"), face = Font:getFace("cfont", px(23)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin, margin } },
            TextWidget:new{ text = status, face = Font:getFace("smallinfofont", px(12)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, margin + px(36) } },
            TextWidget:new{ text = string.format("%02d:00", instance.minutes), face = Font:getFace("cfont", px(48)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin, margin + px(78) } },
            button("− 5 min", (w - 3 * margin) / 3, function() instance.minutes = math.max(5, instance.minutes - 5); context.requestRebuild("ui") end),
            button("+ 5 min", (w - 3 * margin) / 3, function() instance.minutes = math.min(120, instance.minutes + 5); context.requestRebuild("ui") end),
            button(instance.running and _("Pause") or _("Start"), w - 2 * margin, function() instance.running = not instance.running; context.requestRebuild("ui") end),
        }
        actions[5].overlap_offset = { margin, margin + px(150) }; actions[6].overlap_offset = { w - margin - (w - 3 * margin) / 3, margin + px(150) }; actions[7].overlap_offset = { margin, margin + px(208) }
        pane[1] = actions; return pane
    end,
}
