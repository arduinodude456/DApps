--[[
    Dex Document
    ------------
    Read-only .docx viewer for AppDock (KOReader).

    Dex Document opens local .docx files (Office Open XML / WordprocessingML),
    extracts the plain readable text (paragraphs, headings, simple emphasis)
    from `word/document.xml` inside the zip container, and shows it in a
    calm, paginated, E-Ink-friendly reading view.

    Dex Document never writes back into the original .docx file and offers
    no editing controls. It is a viewer only.

    Follows the AppDock DApp contract (DeveloperManual.md):
      - buildPane(instance, context) builds a widget confined to context.dimen.
      - openFile(instance, path) accepts .docx handovers from AppDock Files.
      - State lives under instance.dex_document, never in globals.
      - context.px(...) is used for scalable sizes; requestRebuild("ui") is
        used after any state change that must be visible.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")

-- Archive reading is provided by KOReader for epub/zip-based formats; DReader
-- uses the same interface for .epub. .docx is likewise a zip container.
local ok_archiver, Archiver = pcall(require, "ffi/archiver")

local MAX_DOCX_BYTES = 24 * 1024 * 1024      -- refuse absurdly large files early
local MAX_ENTRY_BYTES = 12 * 1024 * 1024     -- refuse an oversized document.xml
local MAX_PARAGRAPHS = 6000                  -- keep pagination and memory bounded
local MAX_LIBRARY_ENTRIES = 30
local DATA_DIR = DataStorage:getDataDir() .. "/dex_document"
local LIBRARY_PATH = DATA_DIR .. "/library.lua"

local FONT_SIZES = { 14, 16, 18, 20, 23 }
local DEFAULT_FONT_INDEX = 3

--- Small helpers ------------------------------------------------------------

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function ensureDataDir()
    if not fileExists(DATA_DIR) then
        util.makePath(DATA_DIR)
    end
end

local function basename(path)
    return path:match("([^/\\]+)$") or path
end

-- Decode the handful of XML entities that occur in WordprocessingML text runs.
local function decodeXmlEntities(text)
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&apos;", "'")
    text = text:gsub("&amp;", "&")
    return text
end

--- docx parsing ---------------------------------------------------------------
-- We deliberately do not pull in a general-purpose XML parser: DApps must not
-- execute untrusted code, and WordprocessingML's shape is narrow enough that
-- a bounded pattern-based reader is both safe and sufficient for read-only
-- text extraction. We never touch styles.xml formatting beyond bold/italic on
-- runs, and we never execute macros or embedded objects.

-- Extracts an ordered list of paragraph "blocks" from document.xml.
-- Each block is { text = "...", heading = true/false, list = true/false }.
local function parseDocumentXml(xml)
    local paragraphs = {}
    if type(xml) ~= "string" or #xml == 0 then
        return paragraphs
    end

    -- Iterate over <w:p ...>...</w:p> paragraph elements.
    for para_open, para_body in xml:gmatch("(<w:p[%s>][^>]-)>(.-)</w:p>") do
        if #paragraphs >= MAX_PARAGRAPHS then break end

        -- Heading detection via the paragraph style id, e.g. pStyle val="Heading1".
        local style = para_body:match('w:pStyle%s+w:val="([^"]*)"') or ""
        local is_heading = style:lower():match("^heading") ~= nil
            or style:lower():match("^title") ~= nil
        local is_list = para_body:match("<w:numPr") ~= nil

        -- Collect run text in document order, respecting explicit line breaks.
        local pieces = {}
        local cursor = 1
        while true do
            local tag_start, tag_end, tag_name = para_body:find("<(w:t[^>]*)>", cursor)
            local br_start = para_body:find("<w:br%s*/?>", cursor)
            local tab_start = para_body:find("<w:tab%s*/?>", cursor)

            local next_special = nil
            if br_start and (not next_special or br_start < next_special) then
                next_special = br_start
            end
            if tab_start and (not next_special or tab_start < next_special) then
                next_special = tab_start
            end

            if tag_start and (not next_special or tag_start <= next_special) then
                local close_start, close_end = para_body:find("</w:t>", tag_end + 1)
                if not close_start then break end
                local inner = para_body:sub(tag_end + 1, close_start - 1)
                table.insert(pieces, decodeXmlEntities(inner))
                cursor = close_end + 1
            elseif next_special == br_start then
                table.insert(pieces, "\n")
                cursor = para_body:find(">", br_start) + 1
            elseif next_special == tab_start then
                table.insert(pieces, "    ")
                cursor = para_body:find(">", tab_start) + 1
            else
                break
            end
        end

        local text = table.concat(pieces)
        table.insert(paragraphs, {
            text = text,
            heading = is_heading,
            list = is_list,
        })
    end

    return paragraphs
end

-- Reads word/document.xml out of a .docx zip using KOReader's archive
-- interface, the same mechanism DReader relies on for .epub containers.
local function readDocumentXmlFromDocx(path)
    if not ok_archiver or not Archiver then
        return nil, "This device build has no archive reader available."
    end

    local size_file = io.open(path, "rb")
    if not size_file then
        return nil, "The file cannot be read."
    end
    local size = size_file:seek("end")
    size_file:close()
    if not size or size <= 0 then
        return nil, "The file is empty."
    end
    if size > MAX_DOCX_BYTES then
        return nil, "The file is larger than Dex Document allows."
    end

    local reader = Archiver.Reader:new()
    local opened = reader:open(path)
    if not opened then
        return nil, "This does not look like a valid .docx file."
    end

    local xml
    local err
    for entry in reader:iterate() do
        if entry and entry.path == "word/document.xml" then
            if entry.size and entry.size > MAX_ENTRY_BYTES then
                err = "The document body is larger than Dex Document allows."
                break
            end
            local extracted = reader:extractToMemory(entry.path)
            if extracted then
                xml = extracted
            end
            break
        end
    end
    reader:close()

    if not xml then
        return nil, err or "No document body was found inside this .docx file."
    end
    return xml
end

--- Library persistence -------------------------------------------------------

local function loadLibrary()
    ensureDataDir()
    if not fileExists(LIBRARY_PATH) then
        return {}
    end
    local chunk = loadfile(LIBRARY_PATH)
    if not chunk then
        return {}
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
        return {}
    end
    return result
end

local function saveLibrary(library)
    ensureDataDir()
    local tmp_path = LIBRARY_PATH .. ".tmp"
    local file = io.open(tmp_path, "w")
    if not file then return end
    file:write("return {\n")
    for _, entry in ipairs(library) do
        file:write(string.format(
            "  { path = %q, title = %q, last_opened = %d, paragraph_index = %d },\n",
            entry.path or "",
            entry.title or "",
            entry.last_opened or 0,
            entry.paragraph_index or 1
        ))
    end
    file:write("}\n")
    file:close()
    os.rename(tmp_path, LIBRARY_PATH)
end

local function touchLibrary(library, path, title, paragraph_index)
    local found
    for _, entry in ipairs(library) do
        if entry.path == path then
            found = entry
            break
        end
    end
    if not found then
        found = { path = path, title = title }
        table.insert(library, 1, found)
    end
    found.title = title
    found.last_opened = os.time()
    found.paragraph_index = paragraph_index or found.paragraph_index or 1

    table.sort(library, function(a, b)
        return (a.last_opened or 0) > (b.last_opened or 0)
    end)
    while #library > MAX_LIBRARY_ENTRIES do
        table.remove(library)
    end
    saveLibrary(library)
end

--- State ----------------------------------------------------------------------

local function stateFor(instance)
    instance.dex_document = instance.dex_document or {
        screen = "library",       -- "library" or "reader"
        library = loadLibrary(),
        doc = nil,                -- { path, title, paragraphs }
        page_starts = {},         -- paragraph index at start of each page
        page_index = 1,
        font_index = DEFAULT_FONT_INDEX,
        status = nil,
    }
    return instance.dex_document
end

--- Pagination -------------------------------------------------------------
-- Dex Document paginates by paragraph rather than by pixel row: a
-- ScrollTextWidget renders one page's worth of paragraphs at a time, so a
-- page boundary always falls between paragraphs and never mid-sentence
-- across a page turn. Pages are grouped by a stable target character count
-- so E-Ink page turns feel consistent regardless of font size.

local function buildPageStarts(paragraphs, chars_per_page)
    local starts = {}
    if #paragraphs == 0 then
        return { 1 }
    end
    local count = 0
    for index, para in ipairs(paragraphs) do
        if count == 0 then
            table.insert(starts, index)
        end
        count = count + #para.text + 40 -- paragraph spacing weight
        if count >= chars_per_page then
            count = 0
        end
    end
    return starts
end

local function pageText(paragraphs, page_starts, page_index)
    local start_index = page_starts[page_index]
    local stop_index = page_starts[page_index + 1]
    if not stop_index then
        stop_index = #paragraphs + 1
    end
    local lines = {}
    for index = start_index, stop_index - 1 do
        local para = paragraphs[index]
        if para then
            local prefix = ""
            if para.list then
                prefix = "\u{2022} "
            end
            if para.heading then
                table.insert(lines, "")
                table.insert(lines, prefix .. para.text)
                table.insert(lines, "")
            else
                table.insert(lines, prefix .. (para.text ~= "" and para.text or " "))
                table.insert(lines, "")
            end
        end
    end
    return table.concat(lines, "\n")
end

--- Opening a document -------------------------------------------------------

local function openDocxAtPath(instance, context, path)
    local state = stateFor(instance)
    local xml, err = readDocumentXmlFromDocx(path)
    if not xml then
        state.status = err or "This .docx file could not be opened."
        return false, state.status
    end

    local paragraphs = parseDocumentXml(xml)
    if #paragraphs == 0 then
        state.status = "No readable text was found in this document."
        return false, state.status
    end

    local title = basename(path):gsub("%.docx$", "")
    state.doc = {
        path = path,
        title = title,
        paragraphs = paragraphs,
    }

    local width = context and context.dimen and context.dimen.w or 600
    local chars_per_page = math.max(600, math.floor(width * 2.6))
    state.page_starts = buildPageStarts(paragraphs, chars_per_page)

    local resume_index = 1
    for _, entry in ipairs(state.library) do
        if entry.path == path then
            resume_index = entry.paragraph_index or 1
        end
    end
    state.page_index = 1
    for page_number, start_index in ipairs(state.page_starts) do
        if start_index <= resume_index then
            state.page_index = page_number
        end
    end

    touchLibrary(state.library, path, title, state.page_starts[state.page_index])
    state.screen = "reader"
    state.status = nil
    return true
end

--- UI building ---------------------------------------------------------------

local function scaledFont(context, base_size)
    local size = context and context.px and context.px(base_size)
        or Device.screen:scaleBySize(base_size)
    return size
end

local function buildButton(context, label, sub_label, width, height, on_tap)
    local face_main = Font:getFace("smallinfofont", scaledFont(context, 12))
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height },
        allow_mirroring = false,
        FrameContainer:new{
            width = width,
            height = height,
            padding = 0,
            bordersize = scaledFont(context, 1),
            color = Blitbuffer.COLOR_DARK_GRAY,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = height },
                TextWidget:new{
                    text = label,
                    face = face_main,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    bold = true,
                    max_width = width - scaledFont(context, 10),
                },
            },
        },
    }

    local button = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        group,
    }
    button.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = button.dimen,
            },
        },
    }
    button.onTap = function()
        if on_tap then on_tap() end
        return true
    end
    return button
end

local function buildLibraryScreen(instance, context, width, height)
    local state = stateFor(instance)
    local margin = context.px(14)
    local row_height = context.px(46)

    local rows = {}
    table.insert(rows, TextWidget:new{
        text = "Dex Document",
        face = Font:getFace("cfont", context.px(20)),
        fgcolor = Blitbuffer.COLOR_BLACK,
        bold = true,
        max_width = width - 2 * margin,
    })
    table.insert(rows, VerticalSpan:new{ width = context.px(4) })
    table.insert(rows, TextWidget:new{
        text = "View-only .docx reader. Nothing here can be edited or saved back.",
        face = Font:getFace("smallinfofont", context.px(11)),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = width - 2 * margin,
    })
    table.insert(rows, VerticalSpan:new{ width = context.px(10) })

    if state.status then
        table.insert(rows, TextWidget:new{
            text = state.status,
            face = Font:getFace("smallinfofont", context.px(11)),
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = width - 2 * margin,
        })
        table.insert(rows, VerticalSpan:new{ width = context.px(8) })
    end

    if #state.library == 0 then
        table.insert(rows, TextWidget:new{
            text = "No documents yet. Open a .docx file from AppDock Files with \"Open in Dex Document\".",
            face = Font:getFace("smallinfofont", context.px(12)),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = width - 2 * margin,
        })
    else
        for _, entry in ipairs(state.library) do
            local row_width = width - 2 * margin
            local row = InputContainer:new{
                dimen = Geom:new{ w = row_width, h = row_height },
                OverlapGroup:new{
                    dimen = Geom:new{ w = row_width, h = row_height },
                    allow_mirroring = false,
                    LineWidget:new{
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        dimen = Geom:new{ w = row_width, h = context.px(1) },
                        overlap_offset = { 0, row_height - context.px(1) },
                    },
                    TextWidget:new{
                        text = entry.title or basename(entry.path),
                        face = Font:getFace("cfont", context.px(15)),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        bold = true,
                        max_width = row_width - context.px(8),
                        overlap_offset = { context.px(2), context.px(4) },
                    },
                    TextWidget:new{
                        text = entry.path,
                        face = Font:getFace("smallinfofont", context.px(9)),
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                        max_width = row_width - context.px(8),
                        overlap_offset = { context.px(2), context.px(24) },
                    },
                },
            }
            row.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = row.dimen } },
            }
            row.onTap = function()
                local success, message = openDocxAtPath(instance, context, entry.path)
                if not success then
                    UIManager:show(InfoMessage:new{ text = message })
                end
                context.requestRebuild("ui")
                return true
            end
            table.insert(rows, row)
        end
    end

    return VerticalGroup:new(rows)
end

local function buildReaderToolbar(instance, context, width)
    local state = stateFor(instance)
    local button_height = context.px(34)
    local gap = context.px(6)
    local margin = context.px(10)
    local button_width = math.floor((width - 2 * margin - 4 * gap) / 5)

    local function goToPage(delta)
        local target = state.page_index + delta
        if target < 1 or target > #state.page_starts then
            return
        end
        state.page_index = target
        touchLibrary(state.library, state.doc.path, state.doc.title,
            state.page_starts[state.page_index])
        context.requestRebuild("ui")
    end

    local function changeFont(delta)
        local target = state.font_index + delta
        if target < 1 or target > #FONT_SIZES then
            return
        end
        state.font_index = target
        context.requestRebuild("ui")
    end

    local function closeDocument()
        state.screen = "library"
        state.doc = nil
        context.requestRebuild("ui")
    end

    local buttons = VerticalGroup:new{
        TextWidget:new{
            text = (state.doc and state.doc.title or "Document"),
            face = Font:getFace("cfont", context.px(15)),
            fgcolor = Blitbuffer.COLOR_BLACK,
            bold = true,
            max_width = width - 2 * margin,
        },
        VerticalSpan:new{ width = context.px(6) },
        (function()
            local row_children = {}
            local specs = {
                { "\u{2190} Prev", function() goToPage(-1) end },
                { "A-", function() changeFont(-1) end },
                { "A+", function() changeFont(1) end },
                { "Next \u{2192}", function() goToPage(1) end },
                { "Library", closeDocument },
            }
            for _, spec in ipairs(specs) do
                table.insert(row_children, buildButton(
                    context, spec[1], nil, button_width, button_height, spec[2]))
            end
            local row = row_children[1]
            local group = OverlapGroup:new{ dimen = Geom:new{ w = width - 2 * margin, h = button_height }, allow_mirroring = false }
            local x = 0
            for _, child in ipairs(row_children) do
                child.overlap_offset = { x, 0 }
                table.insert(group, child)
                x = x + button_width + gap
            end
            return group
        end)(),
    }
    return buttons
end

local function buildReaderScreen(instance, context, width, height)
    local state = stateFor(instance)
    local margin = context.px(12)
    local toolbar = buildReaderToolbar(instance, context, width)
    local page_number_label = TextWidget:new{
        text = string.format("Page %d / %d (view only)",
            state.page_index, #state.page_starts),
        face = Font:getFace("smallinfofont", context.px(10)),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = width - 2 * margin,
    }

    local body_height = height - context.px(120)
    if body_height < context.px(80) then
        body_height = context.px(80)
    end

    local text = pageText(state.doc.paragraphs, state.page_starts, state.page_index)
    local body = ScrollTextWidget:new{
        text = text,
        face = Font:getFace("cfont", FONT_SIZES[state.font_index]),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = width - 2 * margin,
        height = body_height,
        dialog = nil,
        editable = false,
    }

    return VerticalGroup:new{
        toolbar,
        VerticalSpan:new{ width = context.px(6) },
        page_number_label,
        VerticalSpan:new{ width = context.px(6) },
        FrameContainer:new{
            width = width - 2 * margin,
            height = body_height + context.px(8),
            padding = context.px(4),
            bordersize = context.px(1),
            color = Blitbuffer.COLOR_LIGHT_GRAY,
            background = Blitbuffer.COLOR_WHITE,
            body,
        },
    }
end

--- Public DApp contract ------------------------------------------------------

local function buildPane(instance, context)
    local width, height = context.dimen.w, context.dimen.h
    local state = stateFor(instance)
    local margin = context.px(14)

    local content
    if state.screen == "reader" and state.doc then
        content = buildReaderScreen(instance, context, width, height)
    else
        content = buildLibraryScreen(instance, context, width, height)
    end

    local pane = WidgetContainer:new{
        dimen = Geom:new{ w = width, h = height },
    }
    pane[1] = FrameContainer:new{
        width = width,
        height = height,
        padding = margin,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    return pane
end

local function openFile(instance, path)
    if type(path) ~= "string" or not path:lower():match("%.docx$") then
        return false, "Dex Document only opens .docx files."
    end
    local file = io.open(path, "rb")
    if not file then
        return false, "The file cannot be read."
    end
    local size = file:seek("end")
    file:close()
    if not size or size <= 0 then
        return false, "The file is empty."
    end
    if size > MAX_DOCX_BYTES then
        return false, "The file is larger than Dex Document allows."
    end

    local state = stateFor(instance)
    local xml, err = readDocumentXmlFromDocx(path)
    if not xml then
        return false, err or "This .docx file could not be opened."
    end
    -- Defer full pagination to buildPane, which knows the real pane width;
    -- just remember which path to open next render.
    state.pending_open = path
    return true
end

return {
    id = "dex_document",
    version = "1.0.0",
    title = "Dex Document",
    subtitle = "Read-only .docx viewer",
    symbol = "D",
    logo = "document",

    buildPane = function(instance, context)
        local state = stateFor(instance)
        if state.pending_open then
            local path = state.pending_open
            state.pending_open = nil
            local success, message = openDocxAtPath(instance, context, path)
            if not success then
                state.status = message
            end
        end
        return buildPane(instance, context)
    end,

    openFile = openFile,
}
