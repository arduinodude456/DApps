--[[--
WidgetGenerator for AppDock.

This DApp stores only a small declarative widget specification through the
AppDock manager. It never writes or evaluates user Lua code, and it makes no
network requests. Generated widgets may show custom text plus selected local
system information on the AppDock homescreen.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local function trim(value)
    return type(value) == "string" and (value:match("^%s*(.-)%s*$") or "") or ""
end

local function empty(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local Action = InputContainer:extend{ title = nil, subtitle = nil, icon = nil, callback = nil, width = nil, height = nil, primary = false, px = nil }
function Action:init()
    local px = self.px or function(value) return value end
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local layers = {
        TextWidget:new{ text = self.icon or "", face = Font:getFace("cfont", px(15)), bold = true, fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, overlap_offset = { px(8), math.max(px(5), math.floor(self.height * .25)) } },
        TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", px(10)), bold = true, fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, max_width = self.width - px(31), overlap_offset = { px(27), math.max(px(4), math.floor(self.height * .19)) } },
    }
    if self.subtitle and self.subtitle ~= "" then
        layers[#layers + 1] = TextWidget:new{ text = self.subtitle, face = Font:getFace("smallinfofont", px(8)), fgcolor = self.primary and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY, max_width = self.width - px(31), overlap_offset = { px(27), math.max(px(20), math.floor(self.height * .54)) } }
    end
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.max(px(5), math.floor(self.height * .18)), background = self.primary and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY, OverlapGroup:new{ dimen = self.dimen, allow_mirroring = false, unpack(layers) } }
    self.ges_events = { TapWidgetGeneratorAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:paintTo(bb, x, y)
    local range = self.ges_events.TapWidgetGeneratorAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function Action:onTapWidgetGeneratorAction() if self.callback then self.callback() end return true end

local function newSpec()
    return { title = _("Custom widget"), text = "", show_time = false, show_date = false, show_battery = false }
end

local function stateFor(instance)
    instance.widget_generator = instance.widget_generator or { view = "list", editing_id = nil, draft = nil, page = 1 }
    return instance.widget_generator
end

local function rebuild(context)
    if context.requestRebuild then context.requestRebuild("ui") end
end

local function featureSummary(spec)
    local features = {}
    if trim(spec.text) ~= "" then features[#features + 1] = _("Text") end
    if spec.show_time then features[#features + 1] = _("Time") end
    if spec.show_date then features[#features + 1] = _("Date") end
    if spec.show_battery then features[#features + 1] = _("Battery") end
    return #features > 0 and table.concat(features, " · ") or _("Empty widget")
end

local function promptText(title, hint, current, on_save)
    local dialog
    dialog = InputDialog:new{ title = title, input = current or "", input_hint = hint, buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Save"), is_enter_default = true, callback = function() on_save(trim(dialog:getInputText())); UIManager:close(dialog) end } } } }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function listPane(instance, context)
    local state = stateFor(instance)
    local manager = context.manager
    local widgets = manager:getGeneratedWidgets()
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or function(value) return value end
    local margin, gap, row_h = px(9), px(6), px(46)
    local per_page = math.max(1, math.floor((height - px(104)) / (row_h + gap)))
    local pages = math.max(1, math.ceil(#widgets / per_page))
    state.page = math.max(1, math.min(pages, state.page or 1))
    local first = (state.page - 1) * per_page + 1
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) },
        TextWidget:new{ text = _("WidgetGenerator"), face = Font:getFace("cfont", px(19)), bold = true, overlap_offset = { margin, margin } },
        TextWidget:new{ text = _("Create local homescreen widgets without programming."), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(26) } },
    }
    elements[#elements + 1] = Action:new{ title = _("Create widget"), subtitle = _("Text and system information"), icon = "+", width = width - 2 * margin, height = px(35), px = px, primary = true, callback = function()
        state.view, state.editing_id, state.draft = "edit", nil, newSpec(); rebuild(context)
    end, overlap_offset = { margin, margin + px(44) } }
    local y = margin + px(85)
    if #widgets == 0 then
        elements[#elements + 1] = TextWidget:new{ text = _("No custom widgets yet. Create one, then it appears on the homescreen and in Manage apps & widgets."), face = Font:getFace("smallinfofont", px(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, y } }
    end
    for index = first, math.min(#widgets, first + per_page - 1) do
        local widget = widgets[index]
        local visible = context.appdock:isStoreWidgetEnabled(widget.id)
        elements[#elements + 1] = Action:new{ title = widget.title, subtitle = (visible and _("Shown") or _("Hidden")) .. " · " .. featureSummary(widget), icon = visible and "✓" or "○", width = width - 2 * margin, height = row_h, px = px, callback = function()
            state.view, state.editing_id = "edit", widget.id
            state.draft = { title = widget.title, text = widget.text, show_time = widget.show_time, show_date = widget.show_date, show_battery = widget.show_battery }
            rebuild(context)
        end, overlap_offset = { margin, y } }
        y = y + row_h + gap
    end
    if pages > 1 then
        local half = math.floor((width - 2 * margin - gap) / 2)
        elements[#elements + 1] = Action:new{ title = _("‹ Previous"), width = half, height = px(28), px = px, callback = function() state.page = math.max(1, state.page - 1); rebuild(context) end, overlap_offset = { margin, height - margin - px(28) } }
        elements[#elements + 1] = Action:new{ title = state.page .. "/" .. pages .. " " .. _("Next ›"), width = half, height = px(28), px = px, primary = true, callback = function() state.page = math.min(pages, state.page + 1); rebuild(context) end, overlap_offset = { margin + half + gap, height - margin - px(28) } }
    end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function editPane(instance, context)
    local state = stateFor(instance)
    local manager, draft = context.manager, state.draft or newSpec()
    state.draft = draft
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or function(value) return value end
    local margin, gap, row_h = px(8), px(5), px(32)
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) },
        TextWidget:new{ text = state.editing_id and _("Edit widget") or _("New widget"), face = Font:getFace("cfont", px(18)), bold = true, overlap_offset = { margin, margin } },
    }
    local y = margin + px(29)
    local function row(title, subtitle, icon, callback, primary)
        elements[#elements + 1] = Action:new{ title = title, subtitle = subtitle, icon = icon, width = width - 2 * margin, height = row_h, px = px, primary = primary, callback = callback, overlap_offset = { margin, y } }
        y = y + row_h + gap
    end
    row(_("Widget title"), draft.title, "T", function() promptText(_("Widget title"), _("Up to 36 characters"), draft.title, function(value) draft.title = value ~= "" and value:sub(1, 36) or _("Custom widget"); rebuild(context) end) end)
    row(_("Custom text"), trim(draft.text) ~= "" and draft.text or _("No custom text"), "¶", function() promptText(_("Custom text"), _("Optional, up to 180 characters"), draft.text, function(value) draft.text = value:sub(1, 180); rebuild(context) end) end)
    row((draft.show_time and "✓ " or "○ ") .. _("Show time"), _("Current local time"), "◷", function() draft.show_time = not draft.show_time; rebuild(context) end)
    row((draft.show_date and "✓ " or "○ ") .. _("Show date"), _("Current local date"), "□", function() draft.show_date = not draft.show_date; rebuild(context) end)
    row((draft.show_battery and "✓ " or "○ ") .. _("Show battery"), _("Available device capacity"), "▣", function() draft.show_battery = not draft.show_battery; rebuild(context) end)
    if state.editing_id then
        local visible = context.appdock:isStoreWidgetEnabled(state.editing_id)
        row((visible and "✓ " or "○ ") .. _("Show on homescreen"), visible and _("Visible in AppDock") or _("Hidden in AppDock"), "⌂", function() context.appdock:toggleStoreWidget(state.editing_id); rebuild(context) end)
    end
    local preview_y = y
    local preview_h = math.max(px(42), height - preview_y - px(72))
    elements[#elements + 1] = FrameContainer:new{ width = width - 2 * margin, height = preview_h, padding = px(7), bordersize = 1, radius = px(6), background = Blitbuffer.COLOR_LIGHT_GRAY, TextWidget:new{ text = draft.title .. "\n" .. featureSummary(draft), face = Font:getFace("smallinfofont", px(10)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin - px(14) }, overlap_offset = { margin, preview_y } }
    local control_y = height - margin - px(30)
    local control_w = math.floor((width - 2 * margin - 2 * gap) / 3)
    elements[#elements + 1] = Action:new{ title = _("‹ Back"), width = control_w, height = px(30), px = px, callback = function() state.view, state.draft, state.editing_id = "list", nil, nil; rebuild(context) end, overlap_offset = { margin, control_y } }
    elements[#elements + 1] = Action:new{ title = _("Save"), width = control_w, height = px(30), px = px, primary = true, callback = function()
        if state.editing_id then manager:updateGeneratedWidget(state.editing_id, draft) else manager:createGeneratedWidget(draft) end
        state.view, state.draft, state.editing_id = "list", nil, nil; rebuild(context)
    end, overlap_offset = { margin + control_w + gap, control_y } }
    if state.editing_id then
        elements[#elements + 1] = Action:new{ title = _("Delete"), width = control_w, height = px(30), px = px, callback = function()
            local dialog
            dialog = ConfirmBox:new{ text = _("Delete this custom widget from the homescreen?"), ok_text = _("Delete"), ok_callback = function() manager:removeGeneratedWidget(state.editing_id); state.view, state.draft, state.editing_id = "list", nil, nil; UIManager:close(dialog); rebuild(context) end }
            UIManager:show(dialog)
        end, overlap_offset = { margin + 2 * (control_w + gap), control_y } }
    end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

return {
    id = "widget_generator",
    version = "1.0.0",
    title = "WidgetGenerator",
    subtitle = "Create local widgets without programming",
    symbol = "W",
    logo = "settings",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = context.dimen.w, h = context.dimen.h } }
        pane[1] = state.view == "edit" and editPane(instance, context) or listPane(instance, context)
        return pane
    end,
    _test = { newSpec = newSpec, featureSummary = featureSummary, stateFor = stateFor },
}
