--[[--
DPdf for AppDock.

A local PDF viewing DApp. It delegates parsing and rasterization to KOReader's
DocumentRegistry, so it inherits KOReader's supported PDF renderer instead of
handling untrusted PDF syntax itself. DPdf neither downloads documents nor
uploads any document data.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DocumentRegistry = require("document/documentregistry")
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

local MAX_PAGES = 5000

local function trim(value)
    return type(value) == "string" and (value:match("^%s*(.-)%s*$") or "") or ""
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function isPdfPath(path)
    path = trim(path)
    return path ~= "" and path:sub(1, 1) == "/" and not path:match("[%z\r\n]") and path:lower():match("%.pdf$") ~= nil
end

local function localPdfPath(path)
    if not isPdfPath(path) then return nil, _("DPdf opens local .pdf files only.") end
    local file = io.open(path, "rb")
    if not file then return nil, _("The PDF file cannot be opened.") end
    file:close()
    return path
end

local function empty(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local Action = InputContainer:extend{ title = nil, callback = nil, width = nil, height = nil, primary = false, px = nil }
function Action:init()
    local px = self.px or function(value) return value end
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = 0,
        radius = math.max(px(4), math.floor(self.height * .23)),
        background = self.primary and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", px(10)), bold = true, fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, max_width = self.width - px(8) } },
    }
    self.ges_events = { TapDPdfAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:paintTo(bb, x, y)
    local range = self.ges_events.TapDPdfAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function Action:onTapDPdfAction() if self.callback then self.callback() end return true end

local PdfCanvas = WidgetContainer:extend{ document = nil, page = 1, width = nil, height = nil, dimen = nil, status = nil }
function PdfCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function PdfCanvas:paintTo(bb, x, y)
    if not self.document then return end
    local ok, err = pcall(function()
        local native = self.document:getNativePageDimensions(self.page)
        if not native or not native.w or not native.h or native.w <= 0 or native.h <= 0 then error("invalid page dimensions") end
        local inset = 2
        local zoom = math.min((self.width - 2 * inset) / native.w, (self.height - 2 * inset) / native.h)
        if zoom <= 0 then error("invalid pane zoom") end
        local size = self.document:getPageDimensions(self.page, zoom, 0)
        local rect = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
        local draw_x = x + math.floor((self.width - size.w) / 2)
        local draw_y = y + math.floor((self.height - size.h) / 2)
        self.document:drawPage(bb, draw_x, draw_y, rect, self.page, zoom, 0, 1.0, 1.0)
    end)
    if not ok then self.status.error = tostring(err) end
end

local function stateFor(instance)
    instance.dpdf = instance.dpdf or { document = nil, path = nil, pages = 0, page = 1, status = _("Open a local PDF to begin."), error = nil }
    return instance.dpdf
end

local function closeDocument(state)
    if state.document and state.document.close then pcall(state.document.close, state.document) end
    state.document, state.path, state.pages, state.page = nil, nil, 0, 1
end

local function openPdf(instance, context, path)
    local safe_path, path_err = localPdfPath(path)
    if not safe_path then return nil, path_err end
    local state = stateFor(instance)
    closeDocument(state)
    local ok, document_or_error = pcall(DocumentRegistry.openDocument, DocumentRegistry, safe_path)
    if not ok or not document_or_error then return nil, _("KOReader could not open this PDF.") end
    local pages_ok, pages = pcall(document_or_error.getPageCount, document_or_error)
    if not pages_ok or type(pages) ~= "number" or pages < 1 or pages > MAX_PAGES then
        if document_or_error.close then pcall(document_or_error.close, document_or_error) end
        return nil, _("This PDF has an unsupported page count.")
    end
    state.document, state.path, state.pages, state.page, state.error = document_or_error, safe_path, pages, 1, nil
    state.status = basename(safe_path)
    if context and context.requestRebuild then context.requestRebuild("ui") end
    return true
end

local function choosePdf(instance, context)
    local state, dialog = stateFor(instance), nil
    dialog = InputDialog:new{ title = _("Open local PDF"), input = state.path or "", input_hint = _("Absolute path to a .pdf file"), buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Open"), is_enter_default = true, callback = function()
        local ok, err = openPdf(instance, context, dialog:getInputText())
        UIManager:close(dialog)
        if not ok then state.status = err; if context.requestRebuild then context.requestRebuild("ui") end end
    end } } } }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function changePage(instance, context, delta)
    local state = stateFor(instance)
    if not state.document then return end
    state.page = math.max(1, math.min(state.pages, state.page + delta))
    state.error = nil
    if context.requestRebuild then context.requestRebuild("ui") end
end

return {
    id = "dpdf",
    version = "1.0.0",
    title = "DPdf",
    subtitle = "Local PDF viewer powered by KOReader",
    symbol = "P",
    logo = "document",
    openFile = function(instance, path) return openPdf(instance, nil, path) end,
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or function(value) return value end
        local margin, gap, bar_h = px(8), px(5), px(29)
        local canvas_y = margin + bar_h + gap
        local canvas_h = math.max(px(48), height - canvas_y - bar_h - margin - gap)
        local button_w = math.floor((width - 2 * margin - 2 * gap) / 3)
        local elements = {
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) },
            TextWidget:new{ text = "DPdf", face = Font:getFace("cfont", px(17)), bold = true, overlap_offset = { margin, margin } },
            TextWidget:new{ text = state.document and (basename(state.path) .. " · " .. state.page .. "/" .. state.pages) or state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - px(72), overlap_offset = { margin + px(42), margin + px(4) } },
            Action:new{ title = _("Open"), width = px(55), height = bar_h, px = px, callback = function() choosePdf(instance, context) end, overlap_offset = { width - margin - px(55), margin } },
        }
        if state.document then
            local canvas = PdfCanvas:new{ document = state.document, page = state.page, width = width - 2 * margin, height = canvas_h, status = state }
            canvas.overlap_offset = { margin, canvas_y }
            elements[#elements + 1] = canvas
            elements[#elements + 1] = Action:new{ title = _("‹ Previous"), width = button_w, height = bar_h, px = px, callback = function() changePage(instance, context, -1) end, overlap_offset = { margin, height - margin - bar_h } }
            elements[#elements + 1] = Action:new{ title = state.page .. "/" .. state.pages, width = button_w, height = bar_h, px = px, callback = function() end, overlap_offset = { margin + button_w + gap, height - margin - bar_h } }
            elements[#elements + 1] = Action:new{ title = _("Next ›"), width = button_w, height = bar_h, px = px, primary = true, callback = function() changePage(instance, context, 1) end, overlap_offset = { margin + 2 * (button_w + gap), height - margin - bar_h } }
            if state.error then elements[#elements + 1] = TextWidget:new{ text = _("Render error: ") .. state.error, face = Font:getFace("smallinfofont", px(8)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, canvas_y + px(3) } } end
        else
            elements[#elements + 1] = TextWidget:new{ text = _("DPdf uses KOReader’s local PDF renderer. It does not download, upload or modify PDF files."), face = Font:getFace("smallinfofont", px(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, canvas_y + px(8) } }
        end
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, unpack(elements) }
        function pane:onDeactivate() closeDocument(state) end
        return pane
    end,
    _test = { isPdfPath = isPdfPath, localPdfPath = localPdfPath, openPdf = openPdf, closeDocument = closeDocument, MAX_PAGES = MAX_PAGES },
}
