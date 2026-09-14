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
local Check = InputContainer:extend{ callback = nil, width = nil, height = nil, checked = false }
function Check:init() self.dimen = Geom:new{ w = self.width, h = self.height }; self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = px(13), background = Blitbuffer.COLOR_LIGHT_GRAY, CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.checked and "✓  " .. _("Completed") or _("Mark today complete"), face = Font:getFace("smallinfofont", px(13)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true } } }; self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } } end
function Check:onTap() self.callback(); return true end
return { id = "habit_tracker", version = "1.0.0", title = "Habit Tracker", subtitle = "One calm daily habit", symbol = "H", logo = "calendar", buildPane = function(instance, context)
    local w, h, m = context.dimen.w, context.dimen.h, px(18); instance.completed = instance.completed or false; instance.streak = instance.streak or 0; local pane = WidgetContainer:new{ dimen = Geom:new{ w = w, h = h } }; pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, FrameContainer:new{ width = w, height = h, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, CenterContainer:new{ dimen = pane.dimen, TextWidget:new{ text = "" } } }, TextWidget:new{ text = _("Habit Tracker"), face = Font:getFace("cfont", px(23)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { m, m } }, TextWidget:new{ text = _("A tiny daily check-in"), face = Font:getFace("smallinfofont", px(12)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { m, m + px(36) } }, TextWidget:new{ text = _("Read for ten minutes"), face = Font:getFace("cfont", px(22)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { m, m + px(100) } }, TextWidget:new{ text = string.format(_("Current streak: %d day(s)"), instance.streak), face = Font:getFace("smallinfofont", px(15)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { m, m + px(142) } }, Check:new{ width = w - 2 * m, height = px(50), checked = instance.completed, callback = function() if not instance.completed then instance.streak = instance.streak + 1 end; instance.completed = true; context.requestRebuild("ui") end, overlap_offset = { m, h - m - px(50) } } }; return pane
end }
