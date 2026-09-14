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
local NextButton = InputContainer:extend{ callback = nil, width = nil, height = nil }
function NextButton:init() self.dimen = Geom:new{ w = self.width, h = self.height }; self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = px(13), background = Blitbuffer.COLOR_GRAY_8, CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = _("Next conversion"), face = Font:getFace("smallinfofont", px(13)), fgcolor = Blitbuffer.COLOR_WHITE, bold = true } } }; self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } } end
function NextButton:onTap() self.callback(); return true end
local conversions = { { "1 km", "0.621 mi" }, { "1 kg", "2.205 lb" }, { "20 °C", "68 °F" }, { "1 L", "33.814 fl oz" } }
return { id = "unit_converter", version = "1.0.0", title = "Unit Converter", subtitle = "Quick offline everyday conversions", symbol = "U", logo = "calculator", buildPane = function(instance, context)
    local w, h, m = context.dimen.w, context.dimen.h, px(18); instance.index = instance.index or 1; local pair = conversions[instance.index]
    local pane = WidgetContainer:new{ dimen = Geom:new{ w = w, h = h } }; pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, FrameContainer:new{ width = w, height = h, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, CenterContainer:new{ dimen = pane.dimen, TextWidget:new{ text = "" } } }, TextWidget:new{ text = _("Unit Converter"), face = Font:getFace("cfont", px(23)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { m, m } }, TextWidget:new{ text = _("Offline reference conversions"), face = Font:getFace("smallinfofont", px(12)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { m, m + px(36) } }, TextWidget:new{ text = pair[1], face = Font:getFace("cfont", px(30)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { m, m + px(100) } }, TextWidget:new{ text = "=  " .. pair[2], face = Font:getFace("cfont", px(30)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true, overlap_offset = { m, m + px(148) } }, NextButton:new{ width = w - 2 * m, height = px(46), callback = function() instance.index = instance.index % #conversions + 1; context.requestRebuild("ui") end, overlap_offset = { m, h - m - px(46) } } }; return pane
end }
