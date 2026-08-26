-- Random Book Covers: three real local history entries with optional KOReader covers.
-- No network access, generated cover art, or guessed book metadata is used.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")

local MAX_COVERS = 3
local MAX_HISTORY_CANDIDATES = 24
local seeded = false

local function scale(value) return Device.screen:scaleBySize(value) end

local function basename(value)
    if type(value) ~= "string" then return "" end
    return value:match("([^/\\]+)$") or value
end

local function randomize(items)
    if not seeded then
        math.randomseed(os.time())
        math.random()
        seeded = true
    end
    for index = #items, 2, -1 do
        local other = math.random(index)
        items[index], items[other] = items[other], items[index]
    end
end

local function historyEntries()
    local ok, history = pcall(require, "readhistory")
    if not ok or type(history) ~= "table" or type(history.hist) ~= "table" then return {} end
    local entries, seen = {}, {}
    for _, entry in ipairs(history.hist) do
        if type(entry) == "table" and not entry.dim and type(entry.file) == "string" and entry.file ~= "" and not seen[entry.file] then
            seen[entry.file] = true
            entries[#entries + 1] = { file = entry.file, title = type(entry.text) == "string" and entry.text or basename(entry.file) }
        end
    end
    return entries
end

local function getCover(bookinfo, file)
    if type(bookinfo) ~= "table" or type(bookinfo.getCoverImage) ~= "function" then return nil end
    local ok, cover = pcall(bookinfo.getCoverImage, bookinfo, nil, file)
    if not ok or not cover then return nil end
    if type(cover.getWidth) ~= "function" or type(cover.getHeight) ~= "function" then
        if type(cover.free) == "function" then pcall(cover.free, cover) end
        return nil
    end
    return cover
end

local function selectBooks(context)
    local entries = historyEntries()
    randomize(entries)
    local ui = context and context.appdock and context.appdock.ui
    local bookinfo = ui and ui.bookinfo
    local selected = {}
    for index, entry in ipairs(entries) do
        if index > MAX_HISTORY_CANDIDATES or #selected >= MAX_COVERS then break end
        selected[#selected + 1] = {
            file = entry.file,
            title = entry.title ~= "" and entry.title or basename(entry.file),
            cover = getCover(bookinfo, entry.file),
        }
    end
    return selected
end

local function card(width, cover_height, book, x, y)
    local children = {
        FrameContainer:new{
            width = width, height = cover_height, padding = 0, bordersize = scale(1),
            background = Blitbuffer.COLOR_WHITE,
            overlap_offset = { x, y },
        },
    }
    if book.cover then
        children[#children + 1] = ImageWidget:new{
            image = book.cover,
            image_disposable = true,
            width = width - scale(6), height = cover_height - scale(6), scale_factor = 0,
            overlap_offset = { x + scale(3), y + scale(3) },
        }
    else
        children[#children + 1] = TextWidget:new{
            text = _("No local cover"),
            face = Font:getFace("smallinfofont", scale(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = width - scale(10), overlap_offset = { x + scale(5), y + math.floor(cover_height / 2) - scale(6) },
        }
    end
    children[#children + 1] = TextWidget:new{
        text = book.title,
        face = Font:getFace("smallinfofont", scale(10)), fgcolor = Blitbuffer.COLOR_BLACK,
        bold = true, max_width = width, overlap_offset = { x, y + cover_height + scale(4) },
    }
    return children
end

return {
    id = "random_book_covers_widget",
    version = "1.0.0",
    title = "Random Book Covers",
    subtitle = "Three local books from reading history",
    symbol = "C",
    logo = "reading",

    buildWidget = function(instance, context)
        local width, height = context.dimen.w, context.dimen.h
        local margin, gap = scale(14), scale(8)
        local card_width = math.max(scale(42), math.floor((width - margin * 2 - gap * 2) / 3))
        local cover_height = math.max(scale(54), height - scale(38))
        local books = selectBooks(context)
        local content = { dimen = Geom:new{ w = width, h = height }, allow_mirroring = false }
        if #books == 0 then
            content[#content + 1] = TextWidget:new{
                text = _("Random Book Covers"), face = Font:getFace("smallinfofont", scale(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true,
                overlap_offset = { margin, scale(10) },
            }
            content[#content + 1] = TextWidget:new{
                text = _("Open local books to build reading history."), face = Font:getFace("smallinfofont", scale(13)), fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = width - margin * 2, overlap_offset = { margin, scale(34) },
            }
            return OverlapGroup:new(content)
        end
        for index, book in ipairs(books) do
            local x = margin + (index - 1) * (card_width + gap)
            for _, element in ipairs(card(card_width, cover_height, book, x, scale(4))) do content[#content + 1] = element end
        end
        return OverlapGroup:new(content)
    end,
    _test = { historyEntries = historyEntries, selectBooks = selectBooks },
}
