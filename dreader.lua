--[[--
DReader for AppDock.
A calm, local-first E-Ink reader for HTML/XHTML and non-DRM EPUB books.
The Store, HTML, EPUB, Book, Paginator, and UI sections below are deliberately
kept separate while packaged as one AppStore-installable Lua DApp.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_util, Util = pcall(require, "util")
local ok_archive, Archiver = pcall(require, "ffi/archiver")

local Screen = Device.screen
local STORE_DIR = DataStorage:getDataDir() .. "/appdock_dreader"
local STORE_FILE = STORE_DIR .. "/library.lua"
local MAX_FILE_BYTES = 24 * 1024 * 1024
local MAX_ARCHIVE_ENTRIES = 5000
local MAX_ENTRY_BYTES = 3 * 1024 * 1024
local MAX_SPINE_ITEMS = 1600
local MAX_CHAPTER_CACHE = 5

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function trim(value) return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or "" end
local function basename(path) return (path or ""):match("([^/]+)$") or path or "" end
local function dirname(path) return (path or ""):match("^(.*)/[^/]*$") or "" end
local function empty(width, height) return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } } end
local function readableColor() return Blitbuffer.COLOR_BLACK end
local function mutedColor() return Blitbuffer.COLOR_DARK_GRAY end
local function surfaceColor() return Blitbuffer.COLOR_LIGHT_GRAY end

-- Store -----------------------------------------------------------------------
local Store = {}

local function serialize(value, indent)
    indent = indent or ""
    if type(value) == "number" then return tostring(value) end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return "nil" end
    local out, deeper = { "{" }, indent .. "  "
    for index, item in ipairs(value) do out[#out + 1] = "\n" .. deeper .. serialize(item, deeper) .. "," end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then keys[#keys + 1] = key end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        if type(key) == "string" then key = key:match("^[%a_][%w_]*$") and key or "[" .. string.format("%q", key) .. "]" else key = "[" .. tostring(key) .. "]" end
        out[#out + 1] = "\n" .. deeper .. key .. " = " .. serialize(value[key], deeper) .. ","
    end
    if #out > 1 then out[#out + 1] = "\n" .. indent end
    out[#out + 1] = "}"
    return table.concat(out)
end

local function defaultStore()
    return { version = 1, settings = { font = 18, padding = 14 }, books = {}, progress = {} }
end

function Store.ensure()
    local attr = lfs.attributes(STORE_DIR)
    if attr and attr.mode == "directory" then return true end
    return lfs.mkdir(STORE_DIR)
end

function Store.load()
    local data = defaultStore()
    local chunk = loadfile(STORE_FILE)
    if not chunk then return data end
    setfenv(chunk, {})
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" or result.version ~= 1 then return data end
    data.settings = type(result.settings) == "table" and result.settings or data.settings
    data.settings.font = clamp(tonumber(data.settings.font) or 18, 12, 30)
    data.settings.padding = clamp(tonumber(data.settings.padding) or 14, 6, 42)
    data.books = type(result.books) == "table" and result.books or {}
    data.progress = type(result.progress) == "table" and result.progress or {}
    return data
end

function Store.save(data)
    if not Store.ensure() then return nil, _("DReader could not create its storage folder.") end
    local temporary = STORE_FILE .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err or _("DReader could not save its reading state.") end
    local ok, write_err = file:write("return " .. serialize(data) .. "\n")
    file:close()
    if not ok then os.remove(temporary); return nil, write_err end
    local renamed, rename_err = os.rename(temporary, STORE_FILE)
    if not renamed then os.remove(temporary); return nil, rename_err end
    return true
end

-- HTML ------------------------------------------------------------------------
local HTML = {}

local function decodeEntities(text)
    if ok_util and Util.htmlEntitiesToUtf8 then text = Util.htmlEntitiesToUtf8(text) end
    text = text:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\"")
    return text
end

function HTML.title(source, fallback)
    local found = source:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>")
    found = found and decodeEntities(found:gsub("<[^>]->", "")) or nil
    return trim(found or "") ~= "" and trim(found) or fallback
end

function HTML.text(source)
    source = source or ""
    source = source:gsub("<!%-%-.-%-%->", "")
    source = source:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
    source = source:gsub("<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</[Ss][Tt][Yy][Ll][Ee]>", "")
    source = source:gsub("<[Hh][Ee][Aa][Dd][^>]*>.-</[Hh][Ee][Aa][Dd]>", "")
    source = source:gsub("<[Bb][Rr]%s*/?>", "\n")
    source = source:gsub("</?[Pp][^>]*>", "\n\n")
    source = source:gsub("</?[Dd][Ii][Vv][^>]*>", "\n")
    source = source:gsub("</?[Hh][1-6][^>]*>", "\n\n")
    source = source:gsub("</?[Ll][Ii][^>]*>", "\n• ")
    source = source:gsub("<[^>]->", "")
    source = decodeEntities(source)
    source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
    source = source:gsub("[ \t]+", " "):gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
    return trim(source)
end

function HTML.headings(source)
    local result = {}
    for level, content in source:gmatch("<[Hh]([1-3])[^>]*>(.-)</[Hh][1-3]>") do
        local title = trim(HTML.text(content))
        if title ~= "" then result[#result + 1] = { level = tonumber(level), title = title } end
    end
    return result
end

function HTML.sections(source, fallback_title)
    local marker = "@@DREADER_HEADING@@"
    local marked = source:gsub("<[Hh][1-3][^>]*>(.-)</[Hh][1-3]>", function(content)
        return "\n\n" .. marker .. trim(HTML.text(content)) .. "\n"
    end)
    local plain = HTML.text(marked)
    local positions = {}
    for position in plain:gmatch("()@@DREADER_HEADING@@") do positions[#positions + 1] = position end
    if #positions == 0 then return { { title = fallback_title, text = plain } } end
    local chapters = {}
    local intro = trim(plain:sub(1, positions[1] - 1))
    if intro ~= "" then chapters[#chapters + 1] = { title = fallback_title, text = intro } end
    for index, position in ipairs(positions) do
        local finish = positions[index + 1] and positions[index + 1] - 1 or #plain
        local section = plain:sub(position + #marker, finish)
        local title, body = section:match("^([^\n]+)\n?(.*)$")
        title, body = trim(title or ""), trim(body or "")
        if title ~= "" and body ~= "" then chapters[#chapters + 1] = { title = title, text = body } end
    end
    return #chapters > 0 and chapters or { { title = fallback_title, text = plain } }
end

-- EPUB ------------------------------------------------------------------------
local EPUB = {}

local function attributes(fragment)
    local values = {}
    for name, quote, value in fragment:gmatch("([%w:_%-]+)%s*=%s*([\"'])(.-)%2") do values[name:lower()] = value end
    return values
end

local function safeArchivePath(path)
    return type(path) == "string" and #path > 0 and #path <= 512 and not path:match("^/") and not path:match("%.%.")
end

local function resolvePath(base, relative)
    relative = (relative or ""):gsub("#.*$", ""):gsub("%?.*$", "")
    if relative:match("^[%a]+:") then return nil end
    local joined = base == "" and relative or base .. "/" .. relative
    local parts = {}
    for part in joined:gmatch("[^/]+") do
        if part == ".." then return nil elseif part ~= "." and part ~= "" then parts[#parts + 1] = part end
    end
    return table.concat(parts, "/")
end

local function archiveEntries(path)
    if not ok_archive then return nil, _("This KOReader build has no archive reader for EPUB files.") end
    local archive = Archiver.Reader:new()
    if not archive:open(path) then return nil, archive.err or _("EPUB archive could not be opened.") end
    local entries, count = {}, 0
    for entry in archive:iterate() do
        count = count + 1
        if count > MAX_ARCHIVE_ENTRIES then archive:close(); return nil, _("EPUB has too many archive entries.") end
        if entry.mode == "file" and safeArchivePath(entry.path) then entries[entry.path] = entry end
    end
    return archive, entries
end

local function readArchive(archive, entries, path)
    local entry = entries[path]
    if not entry then return nil, _("Required EPUB file is missing: ") .. tostring(path) end
    if tonumber(entry.size) > MAX_ENTRY_BYTES then return nil, _("An EPUB file is too large for safe in-memory reading.") end
    local content = archive:extractToMemory(path)
    return content, content and nil or (archive.err or _("EPUB file could not be read."))
end

function EPUB.open(path)
    local archive, entries_or_err = archiveEntries(path)
    if not archive then return nil, entries_or_err end
    local entries = entries_or_err
    local container, err = readArchive(archive, entries, "META-INF/container.xml")
    if not container then archive:close(); return nil, err end
    local rootfile = container:match("full%-path%s*=%s*[\"']([^\"']+)[\"']")
    if not safeArchivePath(rootfile) then archive:close(); return nil, _("EPUB container.xml has no safe OPF path.") end
    local opf, opf_err = readArchive(archive, entries, rootfile)
    if not opf then archive:close(); return nil, opf_err end
    local root = dirname(rootfile)
    local title = trim((opf:match("<[Dd][Cc]:[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Dd][Cc]:[Tt][Ii][Tt][Ll][Ee]>") or ""):gsub("<[^>]->", ""))
    if title == "" then title = basename(path):gsub("%.[^.]+$", "") end
    local manifest = {}
    for fragment in opf:gmatch("<[Ii][Tt][Ee][Mm]%s+([^>]-)/?>") do
        local item = attributes(fragment)
        if item.id and item.href then manifest[item.id] = item end
    end
    local spine = {}
    for fragment in opf:gmatch("<[Ii][Tt][Ee][Mm][Rr][Ee][Ff]%s+([^>]-)/?>") do
        local ref = attributes(fragment)
        if ref.idref and manifest[ref.idref] then
            if #spine >= MAX_SPINE_ITEMS then archive:close(); return nil, _("EPUB spine has too many chapters.") end
            local href = resolvePath(root, manifest[ref.idref].href)
            if href and entries[href] then spine[#spine + 1] = { path = href, title = nil } end
        end
    end
    if #spine == 0 then archive:close(); return nil, _("EPUB contains no readable spine chapters.") end
    local title_by_path = {}
    local function readNav(nav_path, is_ncx)
        local nav, nav_err = readArchive(archive, entries, nav_path)
        if not nav then return end
        if is_ncx then
            for label, target in nav:gmatch("<[Nn]av[Pp]oint.-<[Tt]ext[^>]*>(.-)</[Tt]ext>.-<[Cc]ontent[^>]-src%s*=%s*[\"']([^\"']+)") do
                local resolved = resolvePath(dirname(nav_path), target)
                if resolved then title_by_path[resolved] = trim(HTML.text(label)) end
            end
        else
            for target, label in nav:gmatch("<[Aa][^>]-href%s*=%s*[\"']([^\"']+)[\"'][^>]*>(.-)</[Aa]>") do
                local resolved = resolvePath(dirname(nav_path), target)
                if resolved then title_by_path[resolved] = trim(HTML.text(label)) end
            end
        end
    end
    for _, item in pairs(manifest) do
        local props = (item.properties or ""):lower()
        local media = (item["media-type"] or ""):lower()
        local target = resolvePath(root, item.href)
        if target and entries[target] and props:match("nav") then readNav(target, false) end
        if target and entries[target] and media:match("ncx") then readNav(target, true) end
    end
    for index, chapter in ipairs(spine) do chapter.title = title_by_path[chapter.path] or (_("Chapter ") .. index) end
    return { format = "epub", path = path, title = title, chapters = spine, archive = archive, entries = entries, cache = {}, cache_order = {} }
end

-- Book ------------------------------------------------------------------------
local Book = {}

function Book.supports(path)
    local extension = (path or ""):lower():match("%.([%w]+)$")
    return extension == "epub" or extension == "html" or extension == "htm" or extension == "xhtml"
end

function Book.open(path)
    if type(path) ~= "string" or #path == 0 or #path > 1024 or not Book.supports(path) then return nil, _("DReader supports local EPUB, HTML, HTM, and XHTML files only.") end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil, _("The document cannot be opened.") end
    if attr.size and attr.size > MAX_FILE_BYTES then return nil, _("The document is too large for DReader.") end
    if path:lower():match("%.epub$") then return EPUB.open(path) end
    local file, err = io.open(path, "rb")
    if not file then return nil, err or _("HTML document cannot be opened.") end
    local source = file:read("*a"); file:close()
    local title = HTML.title(source, basename(path):gsub("%.[^.]+$", ""))
    local html_chapters = HTML.sections(source, title)
    if #html_chapters == 0 or trim(html_chapters[1].text or "") == "" then return nil, _("The HTML document has no readable text.") end
    local chapters = {}
    for index, section in ipairs(html_chapters) do chapters[index] = { title = section.title, start = index } end
    return { format = "html", path = path, title = title, chapters = chapters, html_chapters = html_chapters, cache = {}, cache_order = {} }
end

function Book.chapterText(book, index)
    if book.cache[index] then return book.cache[index] end
    local chapter = book.chapters[index]
    if not chapter then return nil, _("Chapter does not exist.") end
    local text, err
    if book.format == "html" then text = book.html_chapters[index] and book.html_chapters[index].text
    else
        local source
        source, err = readArchive(book.archive, book.entries, chapter.path)
        if source then
            text = HTML.text(source)
            local title = HTML.title(source, nil)
            if chapter.title:match("^" .. (_("Chapter "):gsub("([^%w])", "%%%1"))) and title then chapter.title = title end
        end
    end
    if not text or text == "" then return nil, err or _("This chapter has no readable text.") end
    book.cache[index] = text; book.cache_order[#book.cache_order + 1] = index
    while #book.cache_order > MAX_CHAPTER_CACHE do local old = table.remove(book.cache_order, 1); book.cache[old] = nil end
    return text
end

function Book.close(book)
    if book and book.archive then book.archive:close(); book.archive = nil end
end

-- Paginator -------------------------------------------------------------------
local Paginator = {}

local function wrapParagraph(paragraph, chars)
    local lines, line = {}, ""
    for word in paragraph:gmatch("%S+") do
        if #word > chars then
            if line ~= "" then lines[#lines + 1], line = line, "" end
            while #word > chars do lines[#lines + 1], word = word:sub(1, chars), word:sub(chars + 1) end
        end
        local candidate = line == "" and word or line .. " " .. word
        if #candidate > chars and line ~= "" then lines[#lines + 1], line = line, word else line = candidate end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

function Paginator.make(text, width, height, font, padding)
    local usable_w, usable_h = math.max(scale(80), width - 2 * padding), math.max(scale(60), height - 2 * padding)
    local chars = math.max(18, math.floor(usable_w / math.max(7, font * 0.53)))
    local lines_per_page = math.max(4, math.floor(usable_h / math.max(12, font * 1.34)))
    local all_lines = {}
    for paragraph in (text .. "\n\n"):gmatch("(.-)\n\n") do
        paragraph = trim(paragraph)
        if paragraph == "" then all_lines[#all_lines + 1] = "" else
            local lines = wrapParagraph(paragraph, chars)
            for _, line in ipairs(lines) do all_lines[#all_lines + 1] = line end
            all_lines[#all_lines + 1] = ""
        end
    end
    if #all_lines == 0 then all_lines[1] = "" end
    local pages = {}
    for start = 1, #all_lines, lines_per_page do pages[#pages + 1] = table.concat(all_lines, "\n", start, math.min(#all_lines, start + lines_per_page - 1)) end
    return pages, { chars = chars, lines = lines_per_page }
end

-- UI --------------------------------------------------------------------------
local Action = InputContainer:extend{ title = nil, subtitle = nil, callback = nil, width = nil, height = nil, shade = nil, dimen = nil }
function Action:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local items = { TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", scale(10)), bold = true, fgcolor = readableColor(), max_width = self.width - scale(10) } }
    if self.subtitle then items[#items + 1] = TextWidget:new{ text = self.subtitle, face = Font:getFace("smallinfofont", scale(8)), fgcolor = mutedColor(), max_width = self.width - scale(10) } end
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.floor(self.height * .28), background = self.shade or surfaceColor(), CenterContainer:new{ dimen = self.dimen, VerticalGroup:new(unpack(items)) } }
    self.ges_events = { TapDReaderAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:paintTo(bb, x, y)
    local range = self.ges_events.TapDReaderAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    return InputContainer.paintTo(self, bb, x, y)
end
function Action:onTapDReaderAction() if self.callback then self.callback() end; return true end

local TapZone = InputContainer:extend{ callback = nil, width = nil, height = nil, dimen = nil }
function TapZone:init() self.dimen = Geom:new{ w = self.width, h = self.height }; self.ges_events = { TapDReaderZone = { GestureRange:new{ ges = "tap", range = self.dimen } } } end
function TapZone:paintTo(bb, x, y) local range = self.ges_events.TapDReaderZone[1].range; range.x, range.y = x, y; return InputContainer.paintTo(self, bb, x, y) end
function TapZone:onTapDReaderZone() if self.callback then self.callback() end; return true end

local function stateFor(instance)
    instance.dreader = instance.dreader or { store = Store.load(), book = nil, view = "library", chapter = 1, page = 1, pages = nil, layout_key = nil, controls = true, chapter_offset = 1, notice = nil }
    return instance.dreader
end

local function saveProgress(state)
    if state.book then
        state.store.progress[state.book.path] = { chapter = state.chapter, page = state.page, updated = os.time() }
        local known = nil
        for _, item in ipairs(state.store.books) do if item.path == state.book.path then known = item; break end end
        if not known then known = {}; table.insert(state.store.books, 1, known) end
        known.path, known.title, known.format, known.opened = state.book.path, state.book.title, state.book.format, os.time()
        while #state.store.books > 24 do table.remove(state.store.books) end
    end
    Store.save(state.store)
end

local function closeBook(state)
    saveProgress(state); Book.close(state.book); state.book, state.pages, state.layout_key = nil, nil, nil
end

local function formatChapter(state, context, keep_ratio)
    if not state.book then return end
    local old_count, old_page = state.pages and #state.pages or 1, state.page
    local text, err = Book.chapterText(state.book, state.chapter)
    if not text then state.notice = err; state.pages = { "" }; return end
    local content_h = math.max(scale(70), context.dimen.h - scale(104))
    local key = table.concat({ context.dimen.w, content_h, state.store.settings.font, state.store.settings.padding, state.chapter }, ":")
    if key == state.layout_key and state.pages then return end
    state.pages = Paginator.make(text, context.dimen.w, content_h, scale(state.store.settings.font), scale(state.store.settings.padding))
    state.layout_key = key
    if keep_ratio then state.page = clamp(math.floor((old_page - 1) / math.max(1, old_count - 1) * math.max(0, #state.pages - 1) + 1), 1, #state.pages) else state.page = clamp(state.page, 1, #state.pages) end
end

local function openBook(instance, context, path)
    local state = stateFor(instance)
    closeBook(state)
    local book, err = Book.open(trim(path))
    if not book then state.notice = err; state.view = "library"; if context then context.requestRebuild("ui") end; return false, err end
    state.book, state.view, state.notice, state.pages, state.layout_key = book, "reader", nil, nil, nil
    local progress = state.store.progress[book.path] or {}
    state.chapter, state.page = clamp(tonumber(progress.chapter) or 1, 1, #book.chapters), math.max(1, tonumber(progress.page) or 1)
    if context then formatChapter(state, context); context.requestRebuild("ui") end
    return true
end

local function selectBook(instance, context)
    local state, dialog = stateFor(instance), nil
    dialog = InputDialog:new{ title = _("Open EPUB or HTML"), input = "", input_hint = _("Absolute path to .epub, .html, .htm, or .xhtml"), buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Open"), is_enter_default = true, callback = function() local path = dialog:getInputText(); UIManager:close(dialog); openBook(instance, context, path) end } } } }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function readerAction(instance, context, action)
    local state = stateFor(instance)
    if not state.book then return end
    formatChapter(state, context)
    if action == "next" then
        if state.page < #state.pages then state.page = state.page + 1 elseif state.chapter < #state.book.chapters then state.chapter, state.page, state.layout_key = state.chapter + 1, 1, nil; formatChapter(state, context) end
    elseif action == "prev" then
        if state.page > 1 then state.page = state.page - 1 elseif state.chapter > 1 then state.chapter, state.page, state.layout_key = state.chapter - 1, 1, nil; formatChapter(state, context); state.page = #state.pages end
    elseif action == "controls" then state.controls = not state.controls
    elseif action == "library" then state.view = "library"; saveProgress(state)
    elseif action == "chapters" then state.view, state.chapter_offset = "chapters", math.max(1, state.chapter - 3)
    elseif action == "settings" then state.view = "settings"
    elseif action == "font_minus" then state.store.settings.font = clamp(state.store.settings.font - 1, 12, 30); state.layout_key = nil; formatChapter(state, context, true); Store.save(state.store)
    elseif action == "font_plus" then state.store.settings.font = clamp(state.store.settings.font + 1, 12, 30); state.layout_key = nil; formatChapter(state, context, true); Store.save(state.store)
    elseif action == "pad_minus" then state.store.settings.padding = clamp(state.store.settings.padding - 2, 6, 42); state.layout_key = nil; formatChapter(state, context, true); Store.save(state.store)
    elseif action == "pad_plus" then state.store.settings.padding = clamp(state.store.settings.padding + 2, 6, 42); state.layout_key = nil; formatChapter(state, context, true); Store.save(state.store)
    end
    saveProgress(state); context.requestRebuild("ui")
end

local function background(width, height)
    return FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) }
end

local function persistentPane(pane, state)
    function pane:onDeactivate()
        saveProgress(state)
    end
    return pane
end

local function libraryPane(instance, context)
    local state, width, height = stateFor(instance), context.dimen.w, context.dimen.h
    local margin, row_h, gap = scale(12), scale(48), scale(7)
    local elements = { background(width, height), TextWidget:new{ text = _("DReader"), face = Font:getFace("cfont", scale(20)), bold = true, fgcolor = readableColor(), overlap_offset = { margin, scale(10) } }, TextWidget:new{ text = _("My books · local EPUB and HTML"), face = Font:getFace("smallinfofont", scale(9)), fgcolor = mutedColor(), overlap_offset = { margin, scale(35) } }, Action:new{ title = _("Open document"), subtitle = _("EPUB, HTML, HTM, or XHTML"), width = width - 2 * margin, height = row_h, shade = Blitbuffer.COLOR_GRAY_8, callback = function() selectBook(instance, context) end, overlap_offset = { margin, scale(54) } } }
    local y = scale(54) + row_h + gap
    if #state.store.books == 0 then elements[#elements + 1] = TextWidget:new{ text = state.notice or _("No books yet. Open a local EPUB or HTML document to begin."), face = Font:getFace("smallinfofont", scale(10)), fgcolor = mutedColor(), max_width = width - 2 * margin, overlap_offset = { margin, y + scale(10) } } end
    for index, item in ipairs(state.store.books) do
        if index > 8 or y + row_h > height - scale(8) then break end
        local progress = state.store.progress[item.path] or {}
        local subtitle = (item.format or ""):upper() .. " · " .. ((progress.chapter and _("Continue at chapter ") .. progress.chapter) or _("Not started"))
        elements[#elements + 1] = Action:new{ title = item.title or basename(item.path), subtitle = subtitle, width = width - 2 * margin, height = row_h, callback = function() openBook(instance, context, item.path) end, overlap_offset = { margin, y } }
        y = y + row_h + gap
    end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function readerPane(instance, context)
    local state, width, height = stateFor(instance), context.dimen.w, context.dimen.h
    formatChapter(state, context)
    local margin, top_h, bottom_h = scale(10), scale(29), scale(30)
    local content_y = state.controls and top_h + scale(8) or scale(6)
    local content_h = state.controls and height - content_y - bottom_h - scale(7) or height - content_y - scale(6)
    local chapter = state.book.chapters[state.chapter]
    local page_text = state.pages and state.pages[state.page] or ""
    local elements = { background(width, height), TextBoxWidget:new{ text = page_text, face = Font:getFace("cfont", scale(state.store.settings.font)), width = width - 2 * scale(state.store.settings.padding), height = content_h, line_height = 0.32, alignment = "left", fgcolor = readableColor(), overlap_offset = { scale(state.store.settings.padding), content_y } } }
    if state.controls then
        local button_w = math.floor((width - 2 * margin - 4 * scale(4)) / 5)
        local labels = { { _("Library"), "library" }, { _("Chapters"), "chapters" }, { _("A−"), "font_minus" }, { _("A+"), "font_plus" }, { _("Settings"), "settings" } }
        for index, item in ipairs(labels) do elements[#elements + 1] = Action:new{ title = item[1], width = button_w, height = top_h, callback = function() readerAction(instance, context, item[2]) end, overlap_offset = { margin + (index - 1) * (button_w + scale(4)), scale(3) } } end
        local nav_w = math.floor((width - 2 * margin - scale(8)) / 2)
        elements[#elements + 1] = Action:new{ title = _("‹ Previous"), width = nav_w, height = bottom_h, callback = function() readerAction(instance, context, "prev") end, overlap_offset = { margin, height - bottom_h - scale(3) } }
        elements[#elements + 1] = Action:new{ title = _("Next ›"), width = nav_w, height = bottom_h, shade = Blitbuffer.COLOR_GRAY_8, callback = function() readerAction(instance, context, "next") end, overlap_offset = { margin + nav_w + scale(8), height - bottom_h - scale(3) } }
        elements[#elements + 1] = TextWidget:new{ text = (chapter and chapter.title or "") .. " · " .. state.page .. "/" .. #state.pages, face = Font:getFace("smallinfofont", scale(8)), fgcolor = mutedColor(), max_width = width - 2 * margin, overlap_offset = { margin, top_h + scale(2) } }
    end
    local zone_w = math.floor(width / 3)
    elements[#elements + 1] = TapZone:new{ width = zone_w, height = content_h, callback = function() readerAction(instance, context, "prev") end, overlap_offset = { 0, content_y } }
    elements[#elements + 1] = TapZone:new{ width = zone_w, height = content_h, callback = function() readerAction(instance, context, "controls") end, overlap_offset = { zone_w, content_y } }
    elements[#elements + 1] = TapZone:new{ width = width - 2 * zone_w, height = content_h, callback = function() readerAction(instance, context, "next") end, overlap_offset = { 2 * zone_w, content_y } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function chaptersPane(instance, context)
    local state, width, height = stateFor(instance), context.dimen.w, context.dimen.h
    local margin, row_h, gap, per_page = scale(10), scale(37), scale(5), 9
    local elements = { background(width, height), TextWidget:new{ text = _("Contents"), face = Font:getFace("cfont", scale(19)), bold = true, fgcolor = readableColor(), overlap_offset = { margin, scale(9) } }, Action:new{ title = _("Back to reader"), width = width - 2 * margin, height = scale(28), callback = function() state.view = "reader"; context.requestRebuild("ui") end, overlap_offset = { margin, scale(36) } } }
    local start = clamp(state.chapter_offset, 1, math.max(1, #state.book.chapters))
    local y = scale(70)
    for index = start, math.min(#state.book.chapters, start + per_page - 1) do
        local chapter = state.book.chapters[index]
        elements[#elements + 1] = Action:new{ title = (index == state.chapter and "• " or "") .. index .. "  " .. chapter.title, width = width - 2 * margin, height = row_h, shade = index == state.chapter and Blitbuffer.COLOR_GRAY_8 or surfaceColor(), callback = function() state.chapter, state.page, state.layout_key, state.view = index, 1, nil, "reader"; formatChapter(state, context); saveProgress(state); context.requestRebuild("ui") end, overlap_offset = { margin, y } }
        y = y + row_h + gap
    end
    if #state.book.chapters > per_page then
        local nav_w = math.floor((width - 2 * margin - gap) / 2)
        elements[#elements + 1] = Action:new{ title = _("Earlier"), width = nav_w, height = scale(28), callback = function() state.chapter_offset = clamp(start - per_page, 1, #state.book.chapters); context.requestRebuild("ui") end, overlap_offset = { margin, height - scale(32) } }
        elements[#elements + 1] = Action:new{ title = _("Later"), width = nav_w, height = scale(28), callback = function() state.chapter_offset = clamp(start + per_page, 1, #state.book.chapters); context.requestRebuild("ui") end, overlap_offset = { margin + nav_w + gap, height - scale(32) } }
    end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function settingsPane(instance, context)
    local state, width, height = stateFor(instance), context.dimen.w, context.dimen.h
    local margin, row_h, gap = scale(12), scale(42), scale(7)
    local half = math.floor((width - 2 * margin - gap) / 2)
    local elements = { background(width, height), TextWidget:new{ text = _("Reader settings"), face = Font:getFace("cfont", scale(19)), bold = true, fgcolor = readableColor(), overlap_offset = { margin, scale(12) } }, TextWidget:new{ text = _("Changes keep the current reading position as closely as possible."), face = Font:getFace("smallinfofont", scale(9)), fgcolor = mutedColor(), max_width = width - 2 * margin, overlap_offset = { margin, scale(39) } }, Action:new{ title = _("Font −"), width = half, height = row_h, callback = function() readerAction(instance, context, "font_minus") end, overlap_offset = { margin, scale(65) } }, Action:new{ title = _("Font +"), width = half, height = row_h, shade = Blitbuffer.COLOR_GRAY_8, callback = function() readerAction(instance, context, "font_plus") end, overlap_offset = { margin + half + gap, scale(65) } }, TextWidget:new{ text = _("Font size: ") .. state.store.settings.font, face = Font:getFace("smallinfofont", scale(10)), fgcolor = mutedColor(), overlap_offset = { margin, scale(112) } }, Action:new{ title = _("Margins −"), width = half, height = row_h, callback = function() readerAction(instance, context, "pad_minus") end, overlap_offset = { margin, scale(134) } }, Action:new{ title = _("Margins +"), width = half, height = row_h, shade = Blitbuffer.COLOR_GRAY_8, callback = function() readerAction(instance, context, "pad_plus") end, overlap_offset = { margin + half + gap, scale(134) } }, TextWidget:new{ text = _("Padding: ") .. state.store.settings.padding, face = Font:getFace("smallinfofont", scale(10)), fgcolor = mutedColor(), overlap_offset = { margin, scale(181) } }, Action:new{ title = _("Back to reader"), width = width - 2 * margin, height = row_h, callback = function() state.view = "reader"; context.requestRebuild("ui") end, overlap_offset = { margin, scale(210) } } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

return {
    id = "dreader",
    version = "1.0.1",
    title = "DReader",
    subtitle = "A calm EPUB and HTML reader",
    symbol = "R",
    logo = "document",
    openFile = function(instance, path)
        local state = stateFor(instance)
        local ok, err = openBook(instance, nil, path)
        state.notice = err or state.notice
        if ok then saveProgress(state) end
        return ok, err
    end,
    buildPane = function(instance, context)
        local state = stateFor(instance)
        if state.view == "reader" and state.book then return persistentPane(readerPane(instance, context), state) end
        if state.view == "chapters" and state.book then return persistentPane(chaptersPane(instance, context), state) end
        if state.view == "settings" and state.book then return persistentPane(settingsPane(instance, context), state) end
        return persistentPane(libraryPane(instance, context), state)
    end,
}
