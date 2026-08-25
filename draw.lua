--[[--
Draw for AppDock.

A compact, vector-stroke sketchbook for E-Ink. Drawings are kept as pages of
serializable strokes. Kobo-style stylus events are consumed when KOReader
exposes them; otherwise the canvas remains fully usable with touch gestures.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local Screen = Device.screen
local STORE_DIR = DataStorage:getDataDir() .. "/appdock_draw"
local MAX_IMAGE_PATH_BYTES = 512
local QUICK_COLORS = {
    { name = "Ink", hex = "#1d1b20" }, { name = "Blue", hex = "#1f5e9f" },
    { name = "Red", hex = "#a11d2d" }, { name = "Green", hex = "#236f48" },
    { name = "Amber", hex = "#9b6200" }, { name = "Purple", hex = "#6b3fa0" },
    { name = "White", hex = "#ffffff" },
}
local BACKGROUNDS = { "blank", "lined", "grid", "image" }

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

local function emptySizedWidget(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local function hexToRGB(hex)
    hex = type(hex) == "string" and hex:upper() or "#1D1B20"
    if not hex:match("^#%x%x%x%x%x%x$") then return 29, 27, 32 end
    return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

local function inkFor(hex)
    local r, g, b = hexToRGB(hex)
    if Screen:isColorEnabled() then return Blitbuffer.ColorRGB32(r, g, b, 0xFF) end
    if r + g + b > 660 then return Blitbuffer.COLOR_WHITE end
    return Blitbuffer.COLOR_BLACK
end

local function backgroundInk()
    return Blitbuffer.COLOR_WHITE
end

local function isImagePath(path)
    local extension = type(path) == "string" and path:lower():match("%.([%w]+)$") or nil
    return extension == "png" or extension == "jpg" or extension == "jpeg" or extension == "gif" or extension == "webp"
end

local function ensureStore()
    local attr = lfs.attributes(STORE_DIR)
    if attr and attr.mode == "directory" then return true end
    return lfs.mkdir(STORE_DIR)
end

local function safeName(value)
    value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("[^%w%-_ ]", " "):gsub("%s+", "_")
    value = value:gsub("^_+", ""):gsub("_+$", "")
    if value == "" then value = "drawing" end
    return value:sub(1, 48)
end

local function serialize(value, indent)
    indent = indent or ""
    local kind = type(value)
    if kind == "number" then return string.format("%.5f", value)
    elseif kind == "boolean" then return value and "true" or "false"
    elseif kind == "string" then return string.format("%q", value)
    elseif kind ~= "table" then return "nil" end
    local parts, next_indent = { "{" }, indent .. "  "
    for index, item in ipairs(value) do parts[#parts + 1] = "\n" .. next_indent .. serialize(item, next_indent) .. "," end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then keys[#keys + 1] = key end end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    for _, key in ipairs(keys) do
        local encoded_key = type(key) == "string" and (key:match("^[%a_][%w_]*$") and key or "[" .. string.format("%q", key) .. "]") or "[" .. tostring(key) .. "]"
        parts[#parts + 1] = "\n" .. next_indent .. encoded_key .. " = " .. serialize(value[key], next_indent) .. ","
    end
    if #parts > 1 then parts[#parts + 1] = "\n" .. indent end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local function newDocument()
    return {
        version = 1,
        title = "drawing",
        pages = { { background = "blank", image_path = nil, strokes = {} } },
        selected_page = 1,
        color = QUICK_COLORS[1].hex,
        width = 3,
        tool = "pen",
    }
end

local function validateDocument(document)
    if type(document) ~= "table" or document.version ~= 1 or type(document.pages) ~= "table" or #document.pages < 1 then return nil end
    for _, page in ipairs(document.pages) do
        if type(page) ~= "table" or type(page.strokes) ~= "table" then return nil end
        if page.background ~= "lined" and page.background ~= "grid" and page.background ~= "image" then page.background = "blank" end
        page.image_path = type(page.image_path) == "string" and page.image_path:sub(1, MAX_IMAGE_PATH_BYTES) or nil
        for _, stroke in ipairs(page.strokes) do
            if type(stroke) ~= "table" or type(stroke.points) ~= "table" then return nil end
        end
    end
    document.selected_page = clamp(tonumber(document.selected_page) or 1, 1, #document.pages)
    document.color = type(document.color) == "string" and document.color or QUICK_COLORS[1].hex
    document.width = clamp(tonumber(document.width) or 3, 1, 14)
    document.tool = document.tool == "eraser" and "eraser" or document.tool == "highlighter" and "highlighter" or "pen"
    return document
end

local function currentPage(document)
    document.selected_page = clamp(document.selected_page or 1, 1, #document.pages)
    return document.pages[document.selected_page]
end

local function documentPath(name)
    return STORE_DIR .. "/" .. safeName(name) .. ".draw.lua"
end

local function saveDocument(document, name)
    if not ensureStore() then return nil, _("Draw could not create its storage folder.") end
    local path = documentPath(name)
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err or _("The drawing could not be saved.") end
    document.title = safeName(name)
    local ok, write_err = file:write("return " .. serialize(document) .. "\n")
    file:close()
    if not ok then os.remove(temporary); return nil, write_err or _("The drawing could not be saved.") end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then os.remove(temporary); return nil, rename_err or _("The drawing could not replace its previous version.") end
    return path
end

local function loadDocument(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err or _("The drawing cannot be read.") end
    local content = file:read("*a")
    file:close()
    if not content or #content > 2 * 1024 * 1024 then return nil, _("This drawing file is unavailable or too large.") end
    local chunk, load_err = loadstring(content, "@" .. path)
    if not chunk then return nil, load_err end
    setfenv(chunk, {})
    local ok, document = pcall(chunk)
    if not ok then return nil, document end
    document = validateDocument(document)
    if not document then return nil, _("This is not a valid Draw document.") end
    return document
end

local function listDocuments()
    ensureStore()
    local documents = {}
    local ok, iterator, object = pcall(lfs.dir, STORE_DIR)
    if not ok then return documents end
    for name in iterator, object do
        if name:match("%.draw%.lua$") then documents[#documents + 1] = name end
    end
    table.sort(documents)
    return documents
end

local function drawLine(bb, x0, y0, x1, y1, thickness, ink)
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 1 then bb:paintRect(math.floor(x0 - thickness / 2), math.floor(y0 - thickness / 2), thickness, thickness, ink); return end
    for step = 0, steps do
        local x = math.floor(x0 + dx * step / steps - thickness / 2)
        local y = math.floor(y0 + dy * step / steps - thickness / 2)
        bb:paintRect(x, y, thickness, thickness, ink)
    end
end

local Canvas = InputContainer:extend{
    document = nil,
    width = nil,
    height = nil,
    on_changed = nil,
    dimen = nil,
    _origin_x = 0,
    _origin_y = 0,
    _active_stroke = nil,
    _last_refresh_region = nil,
    _stylus_active = false,
    _stylus_id = nil,
}

function Canvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        DrawPan = { GestureRange:new{ ges = "pan", range = self.dimen, rate = 8 } },
        DrawPanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        DrawTap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Canvas:page() return currentPage(self.document) end

function Canvas:_point(pos)
    return {
        x = clamp((pos.x or 0) - self._origin_x, 0, self.width),
        y = clamp((pos.y or 0) - self._origin_y, 0, self.height),
        p = tonumber(pos.pressure or pos.p) or 1,
    }
end

function Canvas:_toolFor(input, slot)
    if input and input.stylus_eraser_active then return "eraser" end
    if input and input.stylus_highlighter_active then return "highlighter" end
    local tool = tostring(slot and slot.tool or ""):lower()
    if tool:find("eraser", 1, true) or tool:find("rubber", 1, true) then return "eraser" end
    if tool:find("highlight", 1, true) then return "highlighter" end
    return self.document.tool or "pen"
end

function Canvas:_refreshRegion(first, second, tool)
    second = second or first
    local width = clamp(tonumber(self.document.width) or 3, 1, 14)
    if tool == "highlighter" then width = width * 1.7 end
    local padding = math.max(2, math.ceil(width / 2) + 2)
    local left = math.floor(self._origin_x + math.min(first.x, second.x) - padding)
    local top = math.floor(self._origin_y + math.min(first.y, second.y) - padding)
    local right = math.ceil(self._origin_x + math.max(first.x, second.x) + padding)
    local bottom = math.ceil(self._origin_y + math.max(first.y, second.y) + padding)
    return Geom:new{ x = left, y = top, w = math.max(1, right - left + 1), h = math.max(1, bottom - top + 1) }
end

function Canvas:_begin(point, tool)
    local stroke = { tool = tool or self.document.tool or "pen", color = self.document.color, width = self.document.width, points = { point } }
    self._active_stroke = stroke
    table.insert(self:page().strokes, stroke)
    self._last_refresh_region = self:_refreshRegion(point, point, stroke.tool)
    return self._last_refresh_region
end

function Canvas:_extend(point, tool)
    if not self._active_stroke then return self:_begin(point, tool) end
    local previous = self._active_stroke.points[#self._active_stroke.points]
    table.insert(self._active_stroke.points, point)
    self._last_refresh_region = self:_refreshRegion(previous, point, self._active_stroke.tool)
    return self._last_refresh_region
end

function Canvas:_finish(region)
    if self._active_stroke then
        if #self._active_stroke.points == 1 then table.insert(self._active_stroke.points, self._active_stroke.points[1]) end
        region = region or self._last_refresh_region
        self._active_stroke = nil
        self._last_refresh_region = nil
        if self.on_changed then self.on_changed(true, region) end
    end
end

function Canvas:_renderBackground(bb, x, y)
    local page = self:page()
    -- An ImageWidget may already have painted an image behind the canvas.
    if page.background == "image" and isImagePath(page.image_path) then return end
    bb:paintRect(x, y, self.width, self.height, backgroundInk())
    if page.background == "lined" then
        for line_y = y + scale(20), y + self.height, scale(20) do bb:paintRect(x, line_y, self.width, 1, Blitbuffer.COLOR_LIGHT_GRAY) end
    elseif page.background == "grid" then
        for line_y = y + scale(20), y + self.height, scale(20) do bb:paintRect(x, line_y, self.width, 1, Blitbuffer.COLOR_LIGHT_GRAY) end
        for line_x = x + scale(20), x + self.width, scale(20) do bb:paintRect(line_x, y, 1, self.height, Blitbuffer.COLOR_LIGHT_GRAY) end
    end
end

function Canvas:_renderStroke(bb, x, y, stroke)
    local points = stroke.points or {}
    local ink = stroke.tool == "eraser" and backgroundInk() or inkFor(stroke.color)
    local base_width = clamp(tonumber(stroke.width) or 3, 1, 14)
    for index = 2, #points do
        local previous, point = points[index - 1], points[index]
        local pressure = clamp((tonumber(point.p) or 1), 0.25, 2)
        local thickness = math.max(1, math.floor(base_width * (stroke.tool == "highlighter" and 1.7 or pressure)))
        drawLine(bb, x + previous.x, y + previous.y, x + point.x, y + point.y, thickness, ink)
    end
end

function Canvas:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    self:_renderBackground(bb, x, y)
    for _, stroke in ipairs(self:page().strokes) do self:_renderStroke(bb, x, y, stroke) end
end

function Canvas:onPanDrawPan(_, ges)
    local region = self:_extend(self:_point(ges.pos or ges), self.document.tool)
    if self.on_changed then self.on_changed(false, region) end
    return true
end

function Canvas:onPanReleaseDrawPanRelease(_, ges)
    local region = self:_extend(self:_point(ges.pos or ges), self.document.tool)
    self:_finish(region)
    return true
end

function Canvas:onTapDrawTap(_, ges)
    local point = self:_point(ges.pos or ges)
    local region = self:_begin(point, self.document.tool)
    self:_finish(region)
    return true
end

function Canvas:onStylus(input, slot)
    local x, y = tonumber(slot.x), tonumber(slot.y)
    if not x or not y or x < self._origin_x or y < self._origin_y or x > self._origin_x + self.width or y > self._origin_y + self.height then return false end
    if self._stylus_active and self._stylus_id and slot.id and slot.id ~= self._stylus_id then self:finishStylus() end
    local point = self:_point{ x = x, y = y, pressure = slot.pressure or slot.p }
    local region = self:_extend(point, self:_toolFor(input, slot))
    self._stylus_active = true
    self._stylus_id = slot.id
    if self.on_changed then self.on_changed(false, region) end
    return true
end

function Canvas:finishStylus()
    if self._stylus_active then self._stylus_active = false; self._stylus_id = nil; self:_finish() end
end

local ToolButton = InputContainer:extend{ title = nil, callback = nil, width = nil, height = nil, background = nil, dimen = nil }
function ToolButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.floor(self.height * 0.32), background = self.background or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", scale(10)), bold = true, max_width = self.width - scale(6) } } }
    self.ges_events = { TapDrawTool = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function ToolButton:paintTo(bb, x, y)
    local range = self.ges_events.TapDrawTool[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function ToolButton:onTapDrawTool() if self.callback then self.callback() end return true end

local ThicknessSlider = InputContainer:extend{ document = nil, width = nil, height = nil, callback = nil, dimen = nil }
function ThicknessSlider:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapThickness = { GestureRange:new{ ges = "tap", range = self.dimen } }, PanThickness = { GestureRange:new{ ges = "pan", range = self.dimen, rate = 8 } }, PanReleaseThickness = { GestureRange:new{ ges = "pan_release", range = self.dimen } } }
end
function ThicknessSlider:paintTo(bb, x, y)
    self._x, self._y = x, y
    bb:paintRect(x, y + math.floor(self.height / 2) - 1, self.width, scale(2), Blitbuffer.COLOR_GRAY)
    local ratio = ((self.document.width or 3) - 1) / 13
    local knob_x = x + math.floor(ratio * (self.width - scale(14)))
    bb:paintRect(knob_x, y + math.floor(self.height / 2) - scale(6), scale(14), scale(12), inkFor(self.document.color))
end
function ThicknessSlider:_set(ges)
    local position = (ges.pos or ges).x or self._x
    local ratio = clamp((position - self._x) / math.max(1, self.width - scale(14)), 0, 1)
    self.document.width = clamp(math.floor(1 + ratio * 13 + 0.5), 1, 14)
    if self.callback then self.callback() end
    return true
end
ThicknessSlider.onTapThickness = ThicknessSlider._set
ThicknessSlider.onPanThickness = ThicknessSlider._set
ThicknessSlider.onPanReleaseThickness = ThicknessSlider._set

local function stateFor(instance)
    instance.draw = instance.draw or { document = newDocument(), status = _("New drawing"), canvas = nil }
    return instance.draw
end

local function rebuild(context) context.requestRebuild("ui") end

local function saveDialog(instance, context)
    local state = stateFor(instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Save drawing"), input = state.document.title or "drawing", input_hint = _("Drawing name"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Save"), is_enter_default = true, callback = function()
            local path, err = saveDocument(state.document, dialog:getInputText())
            UIManager:close(dialog)
            state.status = path and (_("Saved: ") .. path) or (_("Save failed: ") .. tostring(err))
            rebuild(context)
        end } } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function loadDialog(instance, context)
    local entries = listDocuments()
    if #entries == 0 then UIManager:show(InfoMessage:new{ text = _("No saved Draw documents yet.") }); return end
    local buttons, dialog = {}, nil
    for _, name in ipairs(entries) do
        buttons[#buttons + 1] = { { text = name:gsub("%.draw%.lua$", ""), callback = function()
            local document, err = loadDocument(STORE_DIR .. "/" .. name)
            UIManager:close(dialog)
            local state = stateFor(instance)
            if document then state.document = document; state.status = _("Loaded: ") .. name else state.status = _("Load failed: ") .. tostring(err) end
            rebuild(context)
        end } }
    end
    dialog = ButtonDialog:new{ title = _("Load drawing"), buttons = buttons }
    UIManager:show(dialog)
end

local function customColorDialog(instance, context)
    local state = stateFor(instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Custom color"), input = state.document.color, input_hint = _("#RRGGBB"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Use color"), is_enter_default = true, callback = function()
            local value = (dialog:getInputText() or ""):upper()
            UIManager:close(dialog)
            if value:match("^#%x%x%x%x%x%x$") then state.document.color = value; state.status = _("Custom color selected") else state.status = _("Use a six-digit color such as #245C9B.") end
            rebuild(context)
        end } } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function nextBackground(instance, context)
    local state, page = stateFor(instance), currentPage(stateFor(instance).document)
    local index = 1
    for position, background in ipairs(BACKGROUNDS) do if page.background == background then index = position; break end end
    page.background = BACKGROUNDS[index % #BACKGROUNDS + 1]
    if page.background == "image" and not isImagePath(page.image_path) then
        local dialog
        dialog = InputDialog:new{
            title = _("Image background"), input = page.image_path or "", input_hint = _("Full path to PNG, JPG, GIF or WEBP"),
            buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog); page.background = "blank"; rebuild(context) end }, { text = _("Use image"), is_enter_default = true, callback = function()
                page.image_path = (dialog:getInputText() or ""):sub(1, MAX_IMAGE_PATH_BYTES)
                UIManager:close(dialog)
                if not isImagePath(page.image_path) then page.background = "blank"; state.status = _("Image background needs a PNG, JPG, GIF or WEBP path.") end
                rebuild(context)
            end } } },
        }
        UIManager:show(dialog); dialog:onShowKeyboard()
        return
    end
    state.status = _("Background: ") .. page.background
    rebuild(context)
end

local function newPage(instance, context)
    local document = stateFor(instance).document
    table.insert(document.pages, { background = "blank", image_path = nil, strokes = {} })
    document.selected_page = #document.pages
    stateFor(instance).status = _("New page added")
    rebuild(context)
end

local function movePage(instance, context, direction)
    local document = stateFor(instance).document
    document.selected_page = clamp(document.selected_page + direction, 1, #document.pages)
    stateFor(instance).status = _("Page ") .. document.selected_page .. "/" .. #document.pages
    rebuild(context)
end

return {
    id = "draw",
    title = "Draw",
    subtitle = "Multi-page E-Ink sketchbook",
    symbol = "D",
    logo = "notes",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local document = state.document
        local width, height = context.dimen.w, context.dimen.h
        local margin, gap = scale(10), scale(5)
        local actions_y, button_h = scale(48), scale(31)
        local button_w = math.max(scale(42), math.floor((width - 2 * margin - 4 * gap) / 5))
        local color_y, color_h = actions_y + button_h + scale(5), scale(24)
        local color_w = math.max(scale(28), math.floor((width - 2 * margin - 6 * gap) / 7))
        local slider_y, slider_h = color_y + color_h + scale(5), scale(24)
        local canvas_y = slider_y + slider_h + scale(8)
        local canvas_h = math.max(scale(72), height - canvas_y - scale(22))
        local canvas_w = width - 2 * margin
        local canvas = Canvas:new{ document = document, width = canvas_w, height = canvas_h, on_changed = function(final, region)
            if final then state.status = _("Stroke added") end
            -- Every sampled drawing movement redraws only its changed canvas area
            -- with KOReader's E-Ink fast mode. This must never trigger a full refresh.
            if context.requestRefresh then
                context.requestRefresh("fast", region)
            elseif context.requestRebuild then
                context.requestRebuild("ui")
            end
        end }
        state.canvas = canvas
        local page = currentPage(document)
        local layers = {
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = _("Draw") .. " · " .. _("Page ") .. document.selected_page .. "/" .. #document.pages, face = Font:getFace("cfont", scale(18)), bold = true, overlap_offset = { margin, scale(7) } },
            ToolButton:new{ title = _("Save"), width = button_w, height = button_h, callback = function() saveDialog(instance, context) end, overlap_offset = { margin, actions_y } },
            ToolButton:new{ title = _("Load"), width = button_w, height = button_h, callback = function() loadDialog(instance, context) end, overlap_offset = { margin + (button_w + gap), actions_y } },
            ToolButton:new{ title = _("Pg-"), width = button_w, height = button_h, callback = function() movePage(instance, context, -1) end, overlap_offset = { margin + (button_w + gap) * 2, actions_y } },
            ToolButton:new{ title = _("Pg+"), width = button_w, height = button_h, callback = function() movePage(instance, context, 1) end, overlap_offset = { margin + (button_w + gap) * 3, actions_y } },
            ToolButton:new{ title = _("New"), width = button_w, height = button_h, callback = function() newPage(instance, context) end, overlap_offset = { margin + (button_w + gap) * 4, actions_y } },
        }
        for index, preset in ipairs(QUICK_COLORS) do
            layers[#layers + 1] = ToolButton:new{ title = "", width = color_w, height = color_h, background = inkFor(preset.hex), callback = function() document.color = preset.hex; document.tool = "pen"; state.status = preset.name; rebuild(context) end, overlap_offset = { margin + (index - 1) * (color_w + gap), color_y } }
        end
        layers[#layers + 1] = ThicknessSlider:new{ document = document, width = math.floor(canvas_w * 0.40), height = slider_h, callback = function() state.status = _("Thickness: ") .. document.width; context.requestRefresh("fast") end, overlap_offset = { margin, slider_y } }
        layers[#layers + 1] = ToolButton:new{ title = _("Color"), width = math.floor(canvas_w * 0.18), height = slider_h, callback = function() customColorDialog(instance, context) end, overlap_offset = { margin + math.floor(canvas_w * 0.42), slider_y } }
        layers[#layers + 1] = ToolButton:new{ title = document.tool == "eraser" and _("Eraser") or _("Erase"), width = math.floor(canvas_w * 0.18), height = slider_h, callback = function() document.tool = document.tool == "eraser" and "pen" or "eraser"; rebuild(context) end, overlap_offset = { margin + math.floor(canvas_w * 0.61), slider_y } }
        layers[#layers + 1] = ToolButton:new{ title = _("Bg"), width = math.floor(canvas_w * 0.18), height = slider_h, callback = function() nextBackground(instance, context) end, overlap_offset = { margin + math.floor(canvas_w * 0.80), slider_y } }
        if page.background == "image" and isImagePath(page.image_path) then
            local ok, image = pcall(ImageWidget.new, ImageWidget, { file = page.image_path, width = canvas_w, height = canvas_h, stretch_limit_percentage = 8 })
            if ok and image then image.overlap_offset = { margin, canvas_y }; layers[#layers + 1] = image else state.status = _("Image background could not be loaded.") end
        end
        canvas.overlap_offset = { margin, canvas_y }
        layers[#layers + 1] = canvas
        layers[#layers + 1] = TextWidget:new{ text = state.status or "", face = Font:getFace("smallinfofont", scale(9)), max_width = canvas_w, overlap_offset = { margin, height - scale(15) } }
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, unpack(layers) }
        function pane:onDeactivate()
            if state.canvas and Device.input and Device.input.unregisterStylusCallback then Device.input:unregisterStylusCallback(); state.canvas:finishStylus() end
        end
        if Device.input and Device.input.registerStylusCallback then
            Device.input:registerStylusCallback(function(input, slot) return canvas:onStylus(input, slot) end)
            state.status = _("Stylus ready when supported; touch drawing is always available.")
        end
        return pane
    end,
    test = {
        newDocument = newDocument,
        validateDocument = validateDocument,
        serialize = serialize,
        highlight = function(document) return currentPage(document).background end,
        saveDocument = saveDocument,
        loadDocument = loadDocument,
        safeName = safeName,
        Canvas = Canvas,
    },
}
