-- Reading Stats Widget: local current-document progress only; no history scan or network access.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")

local function scale(value) return Device.screen:scaleBySize(value) end
local function trimFilename(value)
    if type(value) ~= "string" then return "" end
    return value:match("([^/\\]+)$") or value
end
local function numberFrom(source, method, field)
    if type(source) ~= "table" then return nil end
    local value
    if type(source[method]) == "function" then local ok, result = pcall(source[method], source); if ok then value = result end end
    value = value or source[field]
    value = tonumber(value)
    return value and value >= 0 and math.floor(value) or nil
end

local function readingInfo(context)
    local document = context.appdock and context.appdock.ui and context.appdock.ui.document
    if type(document) ~= "table" then return nil end
    local page = numberFrom(document, "getCurrentPage", "current_page") or numberFrom(document, "getPage", "page")
    local pages = numberFrom(document, "getPageCount", "page_count") or numberFrom(document, "getPages", "pages")
    local title = trimFilename(document.file or document.title or "")
    if title == "" and not page and not pages then return nil end
    return { title = title ~= "" and title or _("Current document"), page = page, pages = pages }
end

return {
    id = "reading_stats_widget",
    version = "1.0.0",
    title = "Reading Stats",
    subtitle = "Current book progress, locally",
    symbol = "R",
    logo = "reading",
    buildWidget = function(instance, context)
        local width, height, margin = context.dimen.w, context.dimen.h, scale(16)
        local info = readingInfo(context)
        if not info then
            return OverlapGroup:new{
                dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
                TextWidget:new{ text = _("Reading Stats"), face = Font:getFace("smallinfofont", scale(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true, overlap_offset = { margin, scale(10) } },
                TextWidget:new{ text = _("Open a book to see local progress."), face = Font:getFace("smallinfofont", scale(14)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, scale(35) } },
            }
        end
        local details = _("Page information unavailable")
        if info.page and info.pages and info.pages > 0 then
            local percent = math.min(100, math.max(0, math.floor(info.page * 100 / info.pages + 0.5)))
            details = string.format(_("Page %d of %d · %d%%"), info.page, info.pages, percent)
        elseif info.page then
            details = string.format(_("Page %d"), info.page)
        end
        return OverlapGroup:new{
            dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
            TextWidget:new{ text = _("Reading Stats"), face = Font:getFace("smallinfofont", scale(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true, overlap_offset = { margin, scale(10) } },
            TextWidget:new{ text = info.title, face = Font:getFace("cfont", scale(17)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, scale(30) } },
            TextWidget:new{ text = details, face = Font:getFace("smallinfofont", scale(12)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, math.max(scale(58), height - scale(27)) } },
        }
    end,
    _test = { readingInfo = readingInfo },
}
