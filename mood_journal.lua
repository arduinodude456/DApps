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
local moods = { "Calm", "Good", "Tired", "Focused" }
local MoodButton = InputContainer:extend{ callback = nil, width = nil, height = nil, label = nil }
function MoodButton:init() self.dimen = Geom:new{ w = self.width, h = self.height }; self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = px(11), background = Blitbuffer.COLOR_LIGHT_GRAY, CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.label, face = Font:getFace("smallinfofont", px(13)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true } } }; self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } } end
function MoodButton:onTap() self.callback(self.label); return true end
return { id = "mood_journal", version = "1.0.0", title = "Mood Journal", subtitle = "A private local mood check-in", symbol = "M", logo = "notes", buildPane = function(instance, context)
    local w, h, m = context.dimen.w, context.dimen.h, px(18); instance.mood = instance.mood or _("Not chosen yet"); local pane = WidgetContainer:new{ dimen = Geom:new{ w = w, h = h } }; local group = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, FrameContainer:new{ width = w, height = h, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, CenterContainer:new{ dimen = pane.dimen, TextWidget:new{ text = "" } } }, TextWidget:new{ text = _("Mood Journal"), face = Font:getFace("cfont", px(23)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { m, m } }, TextWidget:new{ text = _("Private and stored only in this session"), face = Font:getFace("smallinfofont", px(12)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { m, m + px(36) } }, TextWidget:new{ text = _("Today: ") .. instance.mood, face = Font:getFace("cfont", px(20)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { m, m + px(90) } } }
    local gap, bw, y = px(8), (w - 2 * m - px(8)) / 2, m + px(150); for i, mood in ipairs(moods) do group[#group + 1] = MoodButton:new{ label = mood, width = bw, height = px(44), callback = function(value) instance.mood = value; context.requestRebuild("ui") end, overlap_offset = { m + ((i - 1) % 2) * (bw + gap), y + math.floor((i - 1) / 2) * (px(44) + gap) } } end; pane[1] = group; return pane
end }
