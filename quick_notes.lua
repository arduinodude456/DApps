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
local AddButton = InputContainer:extend{ callback = nil, width = nil, height = nil }
function AddButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = px(13), background = Blitbuffer.COLOR_GRAY_8, CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = _("Add note"), face = Font:getFace("smallinfofont", px(13)), fgcolor = Blitbuffer.COLOR_WHITE, bold = true } } }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function AddButton:onTap() self.callback(); return true end
return {
    id = "quick_notes", version = "1.0.0", title = "Quick Notes", subtitle = "Small local notes for the day", symbol = "N", logo = "notes",
    buildPane = function(instance, context)
        local w, h, m = context.dimen.w, context.dimen.h, px(18); instance.notes = instance.notes or {}
        local lines = { TextWidget:new{ text = _("Quick Notes"), face = Font:getFace("cfont", px(23)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { m, m } }, TextWidget:new{ text = _("Notes stay in this AppDock session."), face = Font:getFace("smallinfofont", px(12)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { m, m + px(36) } } }
        local y = m + px(72)
        if #instance.notes == 0 then lines[#lines + 1] = TextWidget:new{ text = _("No notes yet. Add a first thought."), face = Font:getFace("smallinfofont", px(14)), fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { m, y } } else for i, note in ipairs(instance.notes) do lines[#lines + 1] = TextWidget:new{ text = string.format("%d. %s", i, note), face = Font:getFace("smallinfofont", px(13)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = w - 2 * m, overlap_offset = { m, y } }; y = y + px(28) end end
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = w, h = h } }; local group = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, FrameContainer:new{ width = w, height = h, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, CenterContainer:new{ dimen = pane.dimen, TextWidget:new{ text = "" } } } }
        for _, line in ipairs(lines) do group[#group + 1] = line end
        group[#group + 1] = AddButton:new{ width = w - 2 * m, height = px(46), callback = function() instance.notes[#instance.notes + 1] = string.format(_("Note %d"), #instance.notes + 1); context.requestRebuild("ui") end, overlap_offset = { m, h - m - px(46) } }
        pane[1] = group; return pane
    end,
}
