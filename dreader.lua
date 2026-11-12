--[[--
DReader for AppDock (3.1).

A calm reader for EPUB, PDF and more. Instead of re-implementing text layout,
DReader uses KOReader's own document engines:

  * reflowable books (EPUB, FB2, MOBI/AZW3, HTML, TXT ...) are laid out by
    crengine, so publisher styles, embedded fonts, images, tables and
    hyphenation render like in the normal KOReader reader;
  * paged documents (PDF, DjVu, CBZ) are rendered by mupdf/djvulibre with
    fit-width / fit-page zoom, scrolling inside a page and margin cropping;
  * Markdown is converted to simple HTML and shown through crengine.

The UI follows DLib (AppDock palette, header bar, cover cards, AppDock
keyboard) and adds drawn icons (no font glyphs needed), bordered buttons,
ornament dividers and a status bar with clock and battery. The status bar is
always visible outside the reader and can be pinned while reading.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ok_kb, AppDockKeyboard = pcall(require, "appdock_keyboard")
if not ok_kb or type(AppDockKeyboard) ~= "table" or type(AppDockKeyboard.attach) ~= "function" then AppDockKeyboard = nil end
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
-- New AppDock hosts composite glyphs transparently; older hosts use the
-- explicit bgcolor passed to every TextBoxWidget below.
local ok_text, AppDockText = pcall(require, "appdock_text")
if ok_text and type(AppDockText) == "table" and type(AppDockText.TextBoxWidget) == "table" then
    TextBoxWidget = AppDockText.TextBoxWidget
end
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")

local Screen = Device.screen
local STORE_DIR = DataStorage:getDataDir() .. "/appdock_dreader"
local STORE_FILE = STORE_DIR .. "/library.lua"
local COVER_DIR = STORE_DIR .. "/covers"
local MD_DIR = STORE_DIR .. "/markdown"
local BOOKS_DIR = "/mnt/onboard/Books"
local MAX_RECENTS = 24
local MAX_SCAN = 1500
local MAX_MD_BYTES = 6 * 1024 * 1024
local FLUSH_SECONDS = 20

local BOOK_EXT = {
    epub = true, pdf = true, mobi = true, azw3 = true, azw = true, fb2 = true, djvu = true, cbz = true,
    txt = true, html = true, htm = true, xhtml = true, md = true, markdown = true, rtf = true,
}
local DEFAULT_SETTINGS = { font = 22, margin = 3, spacing = 2, face = "serif", fit = "width", crop = true, statusbar = false,
    footer = true, pagecolor = "app", sort = "title", flip = false }
local MARGINS = { 4, 10, 18, 28, 40 }
local SPACINGS = { 90, 100, 115, 130, 150 }
local FACES = { serif = "Noto Serif", sans = "Noto Sans" }
local SORTS = { "title", "recent", "progress" }
local function sortLabel(m) return m == "recent" and _("last read") or m == "progress" and _("progress") or _("title") end

-- ---------------------------------------------------------------- helpers
local function scale(v) return Screen:scaleBySize(v) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function trim(v) if type(v) ~= "string" then return "" end return v:match("^%s*(.-)%s*$") or "" end
local function oneLine(v) return trim((tostring(v or ""):gsub("%s+", " "))) end
local function basename(path) return (path or ""):match("([^/]+)$") or path or "" end
local function extOf(path) local e = (path or ""):match("%.([%w]+)$") return e and e:lower() or "" end
local function exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local a = lfs.attributes(path)
    return a ~= nil and a.mode == "file" and (a.size or 0) > 0
end
local function cutUtf8(s, n)
    if #s <= n then return s end
    local i = n
    while i > 0 do
        local b = s:byte(i + 1)
        if b and b >= 0x80 and b < 0xC0 then i = i - 1 else break end
    end
    return s:sub(1, i)
end
local function clip(v, n)
    v = oneLine(v)
    if #v <= n then return v end
    return cutUtf8(v, math.max(1, n - 3)) .. "…"
end
local function humanSize(n)
    n = tonumber(n) or 0
    if n <= 0 then return "" end
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%d KB", math.max(1, math.floor(n / 1024)))
end
local function pathHash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end
local function prettyName(path)
    local n = basename(path):gsub("%.[^.]+$", ""):gsub("[_]+", " ")
    return trim(n) ~= "" and trim(n) or basename(path)
end
local function blank(w, h) return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, HorizontalSpan:new{ width = 0 } } end
local function box(w, h, bg, radius, border, bordercolor)
    return FrameContainer:new{ width = w, height = h, padding = 0, bordersize = border or 0, color = bordercolor, radius = radius or 0, background = bg, blank(w, h) }
end

local function palette(context)
    local p = context and context.palette
    if type(p) ~= "table" then p = {} end
    return {
        background = p.background or Blitbuffer.COLOR_WHITE,
        surface = p.surface or Blitbuffer.COLOR_LIGHT_GRAY,
        surface_variant = p.surface_variant or Blitbuffer.COLOR_GRAY_8,
        primary = p.primary or Blitbuffer.COLOR_DARK_GRAY,
        on_primary = p.on_primary or Blitbuffer.COLOR_WHITE,
        on_surface = p.on_surface or Blitbuffer.COLOR_BLACK,
        on_variant = p.on_variant or Blitbuffer.COLOR_DARK_GRAY,
    }
end

-- RGB (0..255) of any Blitbuffer colour object; white if it cannot be read.
local function colorRGB(c)
    local r, g, b
    pcall(function() local x = c:getColorRGB32(); r, g, b = x.r, x.g, x.b end)
    if not r then pcall(function() local v = c.a; r, g, b = v, v, v end) end
    if not r then pcall(function() r, g, b = c.r, c.g, c.b end) end
    return tonumber(r) or 255, tonumber(g) or 255, tonumber(b) or 255
end

-- The reading page takes the AppDock background. On dark backgrounds the
-- text turns white, on light ones it stays black.
-- Returns: background colour, text colour, recolour needed?, cache signature.
local function pageColors(pal)
    local r, g, b = colorRGB(pal.background)
    local lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    local fg = lum < 0.5 and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    return pal.background, fg, lum < 0.985, string.format("%d.%d.%d", r, g, b)
end

-- Copy of a palette whose text colours are replaced (for text on the page background).
local function withText(pal, fg)
    local p = {}
    for k, v in pairs(pal) do p[k] = v end
    p.on_surface, p.on_variant = fg, fg
    return p
end

local function showInput(dialog)
    if AppDockKeyboard then pcall(AppDockKeyboard.attach, dialog) end
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return dialog
end
local function showBusy(text)
    local ok, w = pcall(function() return InfoMessage:new{ text = text, dismissable = false } end)
    if not ok or not w then return nil end
    UIManager:show(w)
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    return w
end
local function hideBusy(w) if w then UIManager:close(w) end end
local function refresh(context) context.requestRebuild("ui") end

local function ensureDir(path)
    local a = lfs.attributes(path)
    if a and a.mode == "directory" then return true end
    return lfs.mkdir(path) and true or false
end

-- ---------------------------------------------------------------- store
local Store = {}

local function serialize(value, indent)
    indent = indent or ""
    if type(value) == "number" then return tostring(value) end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return "nil" end
    local out, deeper = { "{" }, indent .. "  "
    for _, item in ipairs(value) do out[#out + 1] = "\n" .. deeper .. serialize(item, deeper) .. "," end
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local k
        if type(key) == "string" then k = key:match("^[%a_][%w_]*$") and key or "[" .. string.format("%q", key) .. "]"
        else k = "[" .. tostring(key) .. "]" end
        out[#out + 1] = "\n" .. deeper .. k .. " = " .. serialize(value[key], deeper) .. ","
    end
    if #out > 1 then out[#out + 1] = "\n" .. indent end
    out[#out + 1] = "}"
    return table.concat(out)
end

local function normalizeSettings(s)
    local out = {}
    for k, v in pairs(DEFAULT_SETTINGS) do out[k] = v end
    if type(s) == "table" then
        out.font = clamp(tonumber(s.font) or out.font, 12, 48)
        out.margin = clamp(math.floor(tonumber(s.margin) or out.margin), 1, #MARGINS)
        out.spacing = clamp(math.floor(tonumber(s.spacing) or out.spacing), 1, #SPACINGS)
        out.face = FACES[s.face] and s.face or out.face
        out.fit = s.fit == "page" and "page" or "width"
        out.crop = s.crop ~= false
        out.statusbar = s.statusbar == true
        out.footer = s.footer ~= false
        out.pagecolor = s.pagecolor == "white" and "white" or "app"
        out.sort = (s.sort == "recent" or s.sort == "progress") and s.sort or "title"
        out.flip = s.flip == true
    end
    return out
end

function Store.load()
    local data = { version = 2, settings = normalizeSettings(nil), books = {}, progress = {}, meta = {}, bookmarks = {} }
    local chunk = loadfile(STORE_FILE)
    if not chunk then return data end
    setfenv(chunk, {})
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then return data end
    if result.version == 2 then data.settings = normalizeSettings(result.settings) end
    -- version 1 stored a pixel font size; start over with sane defaults.
    for _, b in ipairs(type(result.books) == "table" and result.books or {}) do
        if type(b) == "table" and type(b.path) == "string" and #data.books < MAX_RECENTS then data.books[#data.books + 1] = b end
    end
    data.progress = type(result.progress) == "table" and result.progress or {}
    data.meta = type(result.meta) == "table" and result.meta or {}
    data.bookmarks = type(result.bookmarks) == "table" and result.bookmarks or {}
    return data
end

function Store.save(data)
    ensureDir(STORE_DIR)
    local tmp = STORE_FILE .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write("return " .. serialize(data) .. "\n")
    f:close()
    if not ok then os.remove(tmp) return false end
    if not os.rename(tmp, STORE_FILE) then os.remove(tmp) return false end
    return true
end

local function flush(state, force)
    if not state.dirty then return end
    if force or os.time() - (state.last_flush or 0) >= FLUSH_SECONDS then
        Store.save(state.store)
        state.dirty = false
        state.last_flush = os.time()
    end
end

-- ---------------------------------------------------------------- markdown
local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function mdInline(s)
    s = esc(s or "")
    s = s:gsub("!%[([^%]]*)%]%([^)]*%)", "%1")
    s = s:gsub("%[([^%]]+)%]%([^)]*%)", "%1")
    s = s:gsub("%*%*(.-)%*%*", "<b>%1</b>"):gsub("__(.-)__", "<b>%1</b>")
    s = s:gsub("%*(.-)%*", "<i>%1</i>"):gsub("`(.-)`", "<code>%1</code>")
    return s
end

local function mdToHtml(src, title)
    local out, para, kind, fence = {}, {}, nil, false
    local function closePara()
        if #para > 0 then out[#out + 1] = "<p>" .. mdInline(table.concat(para, " ")) .. "</p>"; para = {} end
    end
    local function closeList() if kind then out[#out + 1] = "</" .. kind .. ">"; kind = nil end end
    src = src:gsub("\r\n", "\n"):gsub("\r", "\n")
    for raw in (src .. "\n"):gmatch("(.-)\n") do
        if raw:match("^%s*```") or raw:match("^%s*~~~") then
            closePara(); closeList()
            out[#out + 1] = fence and "</pre>" or "<pre>"
            fence = not fence
        elseif fence then
            out[#out + 1] = esc(raw)
        else
            local h, text = raw:match("^%s*(#+)%s+(.-)%s*#*%s*$")
            local bullet = raw:match("^%s*[-+*]%s+(.+)$")
            local number = raw:match("^%s*%d+[%.%)]%s+(.+)$")
            local quote = raw:match("^%s*>%s?(.*)$")
            if h and #h <= 6 then
                closePara(); closeList()
                out[#out + 1] = string.format("<h%d>%s</h%d>", #h, mdInline(text), #h)
            elseif raw:match("^%s*[-*_][-*_][-*_]+%s*$") then
                closePara(); closeList(); out[#out + 1] = "<hr/>"
            elseif bullet then
                closePara()
                if kind ~= "ul" then closeList(); out[#out + 1] = "<ul>"; kind = "ul" end
                out[#out + 1] = "<li>" .. mdInline(bullet) .. "</li>"
            elseif number then
                closePara()
                if kind ~= "ol" then closeList(); out[#out + 1] = "<ol>"; kind = "ol" end
                out[#out + 1] = "<li>" .. mdInline(number) .. "</li>"
            elseif quote then
                closePara(); closeList()
                out[#out + 1] = "<blockquote><p>" .. mdInline(quote) .. "</p></blockquote>"
            elseif raw:match("^%s*$") then
                closePara(); closeList()
            else
                closeList(); para[#para + 1] = trim(raw)
            end
        end
    end
    closePara(); closeList()
    if fence then out[#out + 1] = "</pre>" end
    return '<html><head><meta charset="utf-8"/><title>' .. esc(title or "") .. "</title></head><body>" ..
        table.concat(out, "\n") .. "</body></html>"
end

local function convertMarkdown(path)
    local a = lfs.attributes(path)
    if not a or a.mode ~= "file" then return nil, _("The document cannot be opened.") end
    if (a.size or 0) > MAX_MD_BYTES then return nil, _("The document is too large for DReader.") end
    local f = io.open(path, "rb")
    if not f then return nil, _("The document cannot be opened.") end
    local src = f:read("*a") or ""
    f:close()
    ensureDir(STORE_DIR); ensureDir(MD_DIR)
    local title = oneLine(src:match("^%s*#+%s+([^\r\n]+)") or src:match("\n#+%s+([^\r\n]+)") or prettyName(path))
    local out = MD_DIR .. "/" .. pathHash(path .. tostring(a.modification)) .. ".html"
    if not exists(out) then
        local o = io.open(out, "wb")
        if not o then return nil, _("The file could not be written.") end
        o:write(mdToHtml(src, title)); o:close()
    end
    return out
end

-- ---------------------------------------------------------------- session
-- One open document. Hides the difference between reflowable (crengine) and
-- paged (mupdf, djvu) documents from the UI.
local Session = {}
Session.__index = Session

-- Draws a part of a paged page (PDF, DjVu, CBZ) into target. KOReader builds
-- differ in the trailing arguments of drawPage()/renderPage() (some need an
-- explicit render mode and fail with "attempt to concatenate a nil value"
-- when it is missing), so the variants are tried in turn and the first one
-- that works is remembered. Returns true, or false plus the last error.
local drawMode
local function drawPageTo(doc, target, dx, dy, rect, pg, zoom)
    local variants = {
        function() doc:drawPage(target, dx, dy, rect, pg, zoom, 0, 1.0, 0) end,
        function() doc:drawPage(target, dx, dy, rect, pg, zoom, 0, 1.0) end,
        function()
            local tile = doc:renderPage(pg, rect, zoom, 0, 1.0, 0)
            target:blitFrom(tile.bb, dx, dy, rect.x - tile.excerpt.x, rect.y - tile.excerpt.y, rect.w, rect.h)
        end,
        function()
            local tile = doc:renderPage(pg, rect, zoom, 0, 1.0)
            target:blitFrom(tile.bb, dx, dy, rect.x - tile.excerpt.x, rect.y - tile.excerpt.y, rect.w, rect.h)
        end,
    }
    local last
    if drawMode then
        local ok, err = pcall(variants[drawMode])
        if ok then return true end
        last, drawMode = err, nil
    end
    for i, fn in ipairs(variants) do
        local ok, err = pcall(fn)
        if ok then drawMode = i; return true end
        last = err
    end
    return false, tostring(last)
end

local function closeDoc(doc, path)
    if ok_reg and type(DocumentRegistry.closeDocument) == "function" then
        if pcall(DocumentRegistry.closeDocument, DocumentRegistry, path) then return end
    end
    pcall(doc.close, doc)
end

function Session.open(path, cfg, W, H, px)
    if not ok_reg or type(DocumentRegistry) ~= "table" then return nil, _("This KOReader build has no document engine.") end
    local real, err = path, nil
    local e = extOf(path)
    if e == "md" or e == "markdown" then
        real, err = convertMarkdown(path)
        if not real then return nil, err end
    end
    local okd, doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, real)
    if not okd or not doc then return nil, _("This file could not be opened. It may be damaged or protected by DRM.") end
    if doc.is_locked then closeDoc(doc, real); return nil, _("This document is password protected.") end
    local s = setmetatable({ doc = doc, real = real, path = path, page = 1, count = 1, offy = 0, geoms = {},
        W = W, H = H, paged = (doc.info and doc.info.has_pages) and true or false, tsig = "" }, Session)
    s:relayout(cfg, W, H, px)
    return s
end

function Session:keyOf(cfg, W, H, px)
    return table.concat({ W, H, px(1), cfg.font, cfg.margin, cfg.spacing, cfg.face, cfg.fit, tostring(cfg.crop) }, ":")
end

function Session:relayout(cfg, W, H, px)
    local doc = self.doc
    self.cfg, self.W, self.H, self.px = cfg, W, H, px
    self.toc, self.drawn, self.geoms = nil, nil, {}
    if self.paged then
        local ok, c = pcall(doc.getPageCount, doc)
        self.count = ok and tonumber(c) or 1
        self.page = clamp(self.page, 1, self.count)
    else
        local xp
        if self.laid then
            pcall(doc.gotoPage, doc, self.page)
            local ok, x = pcall(doc.getXPointer, doc)
            if ok and type(x) == "string" then xp = x end
        end
        pcall(doc.setViewDimen, doc, Geom:new{ w = W, h = H })
        pcall(doc.setFontFace, doc, FACES[cfg.face])
        pcall(doc.setFontSize, doc, px(cfg.font))
        local m = px(MARGINS[cfg.margin])
        pcall(doc.setPageMargins, doc, m, m, m, m)
        pcall(doc.setInterlineSpacePercent, doc, SPACINGS[cfg.spacing])
        pcall(doc.render, doc)
        local ok, c = pcall(doc.getPageCount, doc)
        self.count = math.max(1, ok and tonumber(c) or 1)
        self.laid = true
        if xp then
            local okg = pcall(doc.gotoXPointer, doc, xp)
            local okp, p = pcall(doc.getCurrentPage, doc)
            if okg and okp and tonumber(p) then self.page = clamp(p, 1, self.count) end
        end
        self.page = clamp(self.page, 1, self.count)
    end
    self.key = self:keyOf(cfg, W, H, px)
end

-- Geometry of a paged document page for the current zoom settings.
function Session:geom(pg)
    local g = self.geoms[pg]
    if g then return g end
    local ok, dim = pcall(self.doc.getPageDimensions, self.doc, pg, 1, 0)
    if not ok or not dim or (tonumber(dim.w) or 0) <= 0 or (tonumber(dim.h) or 0) <= 0 then
        self.err = ok and "page size unavailable" or tostring(dim)
        return nil
    end
    local x0, y0, x1, y1 = 0, 0, dim.w, dim.h
    if self.cfg.crop then
        local okb, bb = pcall(self.doc.getUsedBBox, self.doc, pg)
        if okb and type(bb) == "table" and bb.x0 and bb.x1 and bb.y0 and bb.y1
            and bb.x1 - bb.x0 > dim.w * 0.3 and bb.y1 - bb.y0 > dim.h * 0.2 then
            local pad = dim.w * 0.015
            x0, y0 = math.max(0, bb.x0 - pad), math.max(0, bb.y0 - pad)
            x1, y1 = math.min(dim.w, bb.x1 + pad), math.min(dim.h, bb.y1 + pad)
        end
    end
    local cw, ch = x1 - x0, y1 - y0
    local zoom = self.cfg.fit == "page" and math.min(self.W / cw, self.H / ch) or self.W / cw
    g = { x0 = x0, y0 = y0, zoom = zoom, zw = cw * zoom, zh = ch * zoom }
    self.geoms[pg] = g
    return g
end

function Session:paintPaged(target)
    local g = self:geom(self.page)
    if not g then return false end
    local maxoff = math.max(0, g.zh - self.H)
    self.offy = clamp(self.offy, 0, maxoff)
    local vw = math.min(self.W, math.ceil(g.zw))
    local vh = math.min(self.H, math.ceil(g.zh - self.offy))
    local rect = Geom:new{ x = math.floor(g.x0 * g.zoom), y = math.floor(g.y0 * g.zoom + self.offy), w = vw, h = vh }
    local dx = math.floor((self.W - vw) / 2)
    local dy = g.zh < self.H and math.floor((self.H - vh) / 2) or 0
    local ok, err = drawPageTo(self.doc, target, dx, dy, rect, self.page, g.zoom)
    if not ok then self.err = err end
    return ok
end

-- Draws the current page, black on white, into target.
function Session:renderInto(target)
    if self.paged then return self:paintPaged(target) end
    local ok, err = pcall(function()
        self.doc:gotoPage(self.page)
        self.doc:drawCurrentView(target, 0, 0, Geom:new{ x = 0, y = 0, w = self.W, h = self.H }, self.page)
    end)
    if not ok then self.err = tostring(err) end
    return ok
end

function Session:setTheme(bg, fg, themed, sig)
    if self.tsig ~= sig then self.drawn = nil end
    self.bg, self.fg, self.themed, self.tsig = bg, fg, themed, sig
end

-- Page in the AppDock colours: the page is rendered on white into a grey
-- scratch buffer, inverted into an "ink" mask and then blended onto the
-- background colour with the text colour. Anti-aliasing stays intact.
function Session:drawThemed()
    local W, H = self.W, self.H
    if not self.raw or self.raw:getWidth() ~= W or self.raw:getHeight() ~= H then
        if self.raw then pcall(self.raw.free, self.raw); self.raw = nil end
        local okn, raw = pcall(Blitbuffer.new, W, H, Blitbuffer.TYPE_BB8)
        if okn and raw then self.raw = raw end
    end
    if self.raw then
        self.raw:fill(Blitbuffer.COLOR_WHITE)
        if not self:renderInto(self.raw) then return false end
        local ok, err = pcall(function()
            self.raw:invertRect(0, 0, W, H)
            self.bb:fill(self.bg)
            self.bb:colorblitFrom(self.raw, 0, 0, 0, 0, W, H, self.fg)
        end)
        if ok then return true end
        self.err = tostring(err)
    end
    -- Fallback: plain white page.
    self.bb:fill(Blitbuffer.COLOR_WHITE)
    return self:renderInto(self.bb)
end

-- Returns a blitbuffer with the current view, or nil.
function Session:draw()
    local W, H = self.W, self.H
    if not self.bb or self.bb:getWidth() ~= W or self.bb:getHeight() ~= H then
        if self.bb then pcall(self.bb.free, self.bb) end
        local ok, bb = pcall(Blitbuffer.new, W, H, Screen.bb and Screen.bb:getType() or nil)
        if not ok or not bb then self.bb = nil; return nil end
        self.bb, self.drawn = bb, nil
    end
    local sig = self.page .. ":" .. math.floor(self.offy) .. ":" .. self.key .. ":" .. tostring(self.tsig)
    if self.drawn == sig then return self.bb end
    self.err = nil
    local ok
    if self.themed then
        ok = self:drawThemed()
    else
        self.bb:fill(Blitbuffer.COLOR_WHITE)
        ok = self:renderInto(self.bb)
    end
    if ok then self.drawn = sig; return self.bb end
    return nil
end

function Session:step() return math.max(1, math.floor(self.H * 0.9)) end

function Session:nextPage()
    if self.paged then
        local g = self:geom(self.page)
        local maxoff = g and math.max(0, g.zh - self.H) or 0
        if self.offy < maxoff - 2 then self.offy = math.min(maxoff, self.offy + self:step()); return true end
        if self.page < self.count then self.page, self.offy = self.page + 1, 0; return true end
        return false
    end
    if self.page < self.count then self.page = self.page + 1; return true end
    return false
end

function Session:prevPage()
    if self.paged then
        if self.offy > 2 then self.offy = math.max(0, self.offy - self:step()); return true end
        if self.page > 1 then
            self.page = self.page - 1
            local g = self:geom(self.page)
            self.offy = g and math.max(0, g.zh - self.H) or 0
            return true
        end
        return false
    end
    if self.page > 1 then self.page = self.page - 1; return true end
    return false
end

function Session:jump(n)
    self.page = clamp(math.floor(tonumber(n) or 1), 1, self.count)
    self.offy = 0
end

function Session:percent()
    if self.count <= 0 then return 0 end
    if not self.paged then return clamp(math.floor(self.page * 100 / self.count), 0, 100) end
    local g = self.geoms[self.page]
    local frac = (g and g.zh > self.H) and (self.offy / g.zh) or 0
    return clamp(math.floor((self.page - 1 + frac) * 100 / self.count), 0, 100)
end

function Session:position()
    local pos = { page = self.page, total = self.count, pct = self:percent(), offy = math.floor(self.offy), time = os.time() }
    if not self.paged then
        pcall(self.doc.gotoPage, self.doc, self.page)
        local ok, xp = pcall(self.doc.getXPointer, self.doc)
        if ok and type(xp) == "string" and xp ~= "" then pos.xp = xp end
    end
    return pos
end

function Session:restore(pos)
    if type(pos) ~= "table" then return end
    self.drawn = nil
    if self.paged then
        self.page = clamp(math.floor(tonumber(pos.page) or 1), 1, self.count)
        self.offy = math.max(0, tonumber(pos.offy) or 0)
        return
    end
    if type(pos.xp) == "string" and pos.xp ~= "" then
        local okg = pcall(self.doc.gotoXPointer, self.doc, pos.xp)
        local okp, p = pcall(self.doc.getCurrentPage, self.doc)
        if okg and okp and tonumber(p) then self.page = clamp(math.floor(p), 1, self.count); return end
    end
    if tonumber(pos.total) and tonumber(pos.total) == self.count then
        self.page = clamp(math.floor(tonumber(pos.page) or 1), 1, self.count)
    elseif tonumber(pos.pct) then
        self.page = clamp(math.ceil(tonumber(pos.pct) / 100 * self.count), 1, self.count)
    end
end

-- Page number of a bookmark in the current layout.
function Session:bookmarkPage(b)
    if not self.paged and type(b.xp) == "string" then
        local ok, p = pcall(self.doc.getPageFromXPointer, self.doc, b.xp)
        if ok and tonumber(p) then return clamp(math.floor(p), 1, self.count) end
    end
    return clamp(math.floor(tonumber(b.page) or 1), 1, self.count)
end

function Session:tocList()
    if self.toc then return self.toc end
    local out = {}
    local ok, toc = pcall(self.doc.getToc, self.doc)
    if ok and type(toc) == "table" then
        for _, it in ipairs(toc) do
            if type(it) == "table" and type(it.title) == "string" and #out < 2000 then
                local p = tonumber(it.page)
                if p then
                    out[#out + 1] = { title = oneLine(it.title), page = clamp(math.floor(p), 1, self.count),
                        depth = clamp((tonumber(it.depth) or 1) - 1, 0, 4) }
                end
            end
        end
    end
    self.toc = out
    return out
end

function Session:chapter()
    local title, idx = "", nil
    for i, it in ipairs(self:tocList()) do
        if it.page <= self.page then title, idx = it.title, i end
    end
    return title, idx
end

function Session:close()
    if self.bb then pcall(self.bb.free, self.bb); self.bb = nil end
    if self.raw then pcall(self.raw.free, self.raw); self.raw = nil end
    if self.doc then closeDoc(self.doc, self.real); self.doc = nil end
end

-- ---------------------------------------------------------------- library data
local function scanDir(dir, out, seen, depth)
    local ok, iter, d = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then return end
    for name in iter, d do
        if #out >= MAX_SCAN then return end
        if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
            local p = dir .. "/" .. name
            local a = lfs.attributes(p)
            if a then
                if a.mode == "directory" and depth < 3 then scanDir(p, out, seen, depth + 1)
                elseif a.mode == "file" and BOOK_EXT[extOf(name)] and not seen[p] then
                    seen[p] = true
                    out[#out + 1] = { path = p, ext = extOf(name), size = a.size or 0 }
                end
            end
        end
    end
end

local function scanLibrary()
    local out, seen = {}, {}
    scanDir(BOOKS_DIR, out, seen, 0)
    local home = Device.home_dir
    if type(home) == "string" and home ~= BOOKS_DIR and lfs.attributes(home, "mode") == "directory" then
        scanDir(home, out, seen, 1)
    end
    return out
end

local function makeItem(state, path, ext, size)
    local m = state.store.meta[path] or {}
    local title = trim(m.title or "")
    if title == "" then title = prettyName(path) end
    local prog = state.store.progress[path]
    return { path = path, ext = ext or extOf(path), size = size or 0, title = title, author = trim(m.author or ""),
        cover = type(m.cover) == "string" and m.cover or "", pct = prog and tonumber(prog.pct) or nil,
        time = prog and tonumber(prog.time) or nil }
end

local function readingItems(state)
    local out = {}
    for _, b in ipairs(state.store.books) do
        if exists(b.path) then out[#out + 1] = makeItem(state, b.path, extOf(b.path), nil) end
    end
    return out
end

local function libraryItems(state)
    if not state.lib then state.lib = scanLibrary() end
    local f = (state.filter or ""):lower()
    local out = {}
    for _, b in ipairs(state.lib) do
        local it = makeItem(state, b.path, b.ext, b.size)
        if f == "" or it.title:lower():find(f, 1, true) or it.author:lower():find(f, 1, true) then out[#out + 1] = it end
    end
    local mode = state.store.settings.sort
    table.sort(out, function(a, b)
        if mode == "recent" then
            local x, y = a.time or 0, b.time or 0
            if x ~= y then return x > y end
        elseif mode == "progress" then
            local x, y = a.pct or -1, b.pct or -1
            if x ~= y then return x > y end
        end
        return a.title:lower() < b.title:lower()
    end)
    return out
end

-- Title, author and cover thumbnail of one book, written to the cover cache.
local function extractMeta(path)
    local meta = { title = "", author = "", cover = "", done = true }
    local e = extOf(path)
    if e == "md" or e == "markdown" then
        local f = io.open(path, "rb")
        if f then
            local head = f:read(4096) or ""
            f:close()
            meta.title = oneLine(head:match("^%s*#+%s+([^\r\n]+)") or head:match("\n#+%s+([^\r\n]+)") or "")
        end
        return meta
    end
    if not ok_reg then return meta end
    local ok, doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, path)
    if not ok or not doc then return meta end
    pcall(function()
        local okp, props = pcall(doc.getProps, doc)
        if okp and type(props) == "table" then
            meta.title = oneLine(props.title or "")
            local a = props.authors or props.author or ""
            if type(a) == "string" then meta.author = oneLine((a:gsub("\n", ", "))) end
        end
        local file = COVER_DIR .. "/" .. pathHash(path) .. ".png"
        local bb
        local th = 280
        if doc.info and doc.info.has_pages then
            local okd, dim = pcall(doc.getPageDimensions, doc, 1, 1, 0)
            if okd and dim and (tonumber(dim.w) or 0) > 0 and (tonumber(dim.h) or 0) > 0 then
                local zoom = th / dim.h
                local w, h = math.max(1, math.ceil(dim.w * zoom)), th
                local okb, b = pcall(Blitbuffer.new, w, h, Screen.bb and Screen.bb:getType() or nil)
                if okb and b then
                    b:fill(Blitbuffer.COLOR_WHITE)
                    if drawPageTo(doc, b, 0, 0, Geom:new{ x = 0, y = 0, w = w, h = h }, 1, zoom) then bb = b
                    else pcall(b.free, b) end
                end
            end
        else
            local okc, img = pcall(doc.getCoverPageImage, doc)
            if okc and img then
                bb = img
                local okr, RenderImage = pcall(require, "ui/renderimage")
                local w0, h0 = img:getWidth(), img:getHeight()
                if okr and type(RenderImage) == "table" and h0 > th then
                    local tw = math.max(1, math.floor(w0 * th / h0))
                    local oks, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, img, tw, th, true)
                    if oks and scaled then bb = scaled end
                end
            end
        end
        if bb then
            ensureDir(STORE_DIR); ensureDir(COVER_DIR)
            if pcall(function() bb:writePNG(file) end) and exists(file) then meta.cover = file end
            pcall(bb.free, bb)
        end
    end)
    closeDoc(doc, path)
    return meta
end

local function ensureMeta(state, context, items)
    if state.meta_job or state.session then return end
    local todo
    for _, it in ipairs(items) do
        local m = state.store.meta[it.path]
        if (not m or not m.done) and not state.meta_fail[it.path] then todo = it; break end
    end
    if not todo then return end
    state.meta_job = true
    UIManager:scheduleIn(0.4, function()
        if state.session or state.view ~= "library" then state.meta_job = false; return end
        local meta
        local ok = pcall(function() meta = extractMeta(todo.path) end)
        state.meta_job = false
        if ok and meta then
            state.store.meta[todo.path] = meta
            state.dirty = true
            flush(state, false)
        else
            state.meta_fail[todo.path] = true
        end
        if state.view == "library" then refresh(context) end
    end)
end

-- ---------------------------------------------------------------- drawing primitives
-- Icons are drawn with rectangles and strokes, so they never depend on font
-- glyphs and always take the palette colour.
local function pnt(bb, x, y, w, h, c)
    pcall(bb.paintRect, bb, math.floor(x + .5), math.floor(y + .5), math.max(1, math.floor(w + .5)), math.max(1, math.floor(h + .5)), c)
end
local function stroke(bb, x0, y0, x1, y1, t, c)
    local n = math.max(math.ceil(math.max(math.abs(x1 - x0), math.abs(y1 - y0))), 1)
    for i = 0, n do
        pnt(bb, x0 + (x1 - x0) * i / n - t / 2, y0 + (y1 - y0) * i / n - t / 2, t, t, c)
    end
end
local function ring(bb, x, y, w, h, bw, c, r)
    pcall(bb.paintBorder, bb, math.floor(x + .5), math.floor(y + .5), math.floor(w + .5), math.floor(h + .5), bw, c, r)
end

local Icon = Widget:extend{ kind = "list", size = 24, color = nil }
function Icon:init() self.dimen = Geom:new{ w = self.size, h = self.size } end
function Icon:free() end
function Icon:paintTo(bb, x, y)
    local s, c = self.size, self.color or Blitbuffer.COLOR_BLACK
    local u = s / 24
    local t = math.max(2, math.floor(s / 11 + .5))
    local function P(a, b, w, h) pnt(bb, x + a * u, y + b * u, w * u, h * u, c) end
    local function L(a, b, d, e) stroke(bb, x + a * u, y + b * u, x + d * u, y + e * u, t, c) end
    local k = self.kind
    if k == "back" or k == "prev" then L(15, 5, 8, 12); L(8, 12, 15, 19)
    elseif k == "next" then L(9, 5, 16, 12); L(16, 12, 9, 19)
    elseif k == "list" then
        for _, yy in ipairs({ 6, 12, 18 }) do P(3, yy - 1.3, 3, 2.6); P(8, yy - 1.3, 13, 2.6) end
    elseif k == "search" then
        ring(bb, x + 3 * u, y + 3 * u, 13 * u, 13 * u, t, c, math.floor(13 * u / 2))
        L(14.5, 14.5, 21, 21)
    elseif k == "folder" then
        P(3, 5, 8, 3.5)
        ring(bb, x + 3 * u, y + 8 * u, 18 * u, 12 * u, t, c, math.floor(2 * u))
    elseif k == "bookmark" then
        L(7, 3, 17, 3); L(7, 3, 7, 21); L(17, 3, 17, 21); L(7, 21, 12, 15.5); L(12, 15.5, 17, 21)
    elseif k == "bookmark_on" then
        for py = math.floor(3 * u), math.floor(21 * u) do
            local yu = py / u
            if yu <= 15.5 then pnt(bb, x + 7 * u, y + py, 10 * u, 1, c)
            else
                local half = (yu - 15.5) * (5 / 5.5)
                local wd = math.max(1, (5 - half) * u)
                pnt(bb, x + 7 * u, y + py, wd, 1, c)
                pnt(bb, x + (12 + half) * u, y + py, wd, 1, c)
            end
        end
    elseif k == "type" then
        L(3, 19, 8, 5); L(8, 5, 13, 19); L(5.2, 14, 10.8, 14)
        ring(bb, x + 14 * u, y + 12 * u, 7 * u, 7 * u, t, c, math.floor(3.5 * u))
        L(20.5, 12.5, 20.5, 19.5)
    elseif k == "plus" then L(12, 5, 12, 19); L(5, 12, 19, 12)
    elseif k == "minus" then L(5, 12, 19, 12)
    elseif k == "goto" then L(3, 12, 17, 12); L(12, 7, 17, 12); L(17, 12, 12, 17); L(21, 6, 21, 18)
    elseif k == "book" then
        L(12, 6, 4, 5); L(4, 5, 4, 19); L(4, 19, 12, 20)
        L(12, 6, 20, 5); L(20, 5, 20, 19); L(20, 19, 12, 20); L(12, 6, 12, 20)
    elseif k == "grid" then P(4, 4, 7, 7); P(13, 4, 7, 7); P(4, 13, 7, 7); P(13, 13, 7, 7)
    elseif k == "close" then L(6, 6, 18, 18); L(18, 6, 6, 18)
    elseif k == "check" then L(5, 13, 10, 18); L(10, 18, 19, 7)
    elseif k == "sort" then P(3, 5, 18, 2.6); P(3, 11, 12, 2.6); P(3, 17, 6, 2.6)
    elseif k == "bolt" then L(14, 2, 6, 13); L(6, 13, 13, 13); L(13, 13, 10, 22)
    end
end

-- Horizontal divider with a small diamond flourish in the middle.
local Ornament = Widget:extend{ width = 0, height = 0, color = nil }
function Ornament:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function Ornament:free() end
function Ornament:paintTo(bb, x, y)
    local c = self.color or Blitbuffer.COLOR_DARK_GRAY
    local w, h = self.width, self.height
    local cx, cy = x + math.floor(w / 2), y + math.floor(h / 2)
    local d = math.max(3, math.floor(h / 2))
    local function diamond(mx, r)
        for dy = -r, r do
            local half = r - math.abs(dy)
            pnt(bb, mx - half, cy + dy, 2 * half + 1, 1, c)
        end
    end
    diamond(cx, d)
    local small = math.max(2, math.floor(d / 2))
    diamond(cx - d * 3, small)
    diamond(cx + d * 3, small)
    local th = math.max(1, math.floor(h / 8))
    local gap = d * 4 + 2
    local pad = math.floor(w * 0.04)
    local lw = cx - gap - (x + pad)
    if lw > 4 then
        pnt(bb, x + pad, cy - th / 2, lw, th, c)
        pnt(bb, cx + gap, cy - th / 2, lw, th, c)
        diamond(x + pad, small)
        diamond(x + w - pad, small)
    end
end

local BatteryIcon = Widget:extend{ width = 0, height = 0, pct = 100, color = nil }
function BatteryIcon:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function BatteryIcon:free() end
function BatteryIcon:paintTo(bb, x, y)
    local c, w, h = self.color or Blitbuffer.COLOR_BLACK, self.width, self.height
    local bw = w - 3
    local th = math.max(1, math.floor(h / 8))
    ring(bb, x, y, bw, h, th, c, 2)
    pnt(bb, x + bw, y + h * .3, 3, h * .4, c)
    local fill = (bw - 2 * th - 2) * clamp(self.pct, 0, 100) / 100
    if fill >= 1 then pnt(bb, x + th + 1, y + th + 1, fill, h - 2 * th - 2, c) end
end

local function batteryInfo()
    local ok, pd = pcall(function() return Device:getPowerDevice() end)
    if not ok or not pd then return nil end
    local okc, cap = pcall(pd.getCapacity, pd)
    if not okc or not tonumber(cap) then return nil end
    local okh, ch = pcall(pd.isCharging, pd)
    return clamp(math.floor(tonumber(cap)), 0, 100), okh and ch == true
end

-- ---------------------------------------------------------------- widgets
local Tap = InputContainer:extend{ width = 0, height = 0, content = nil, background = nil, radius = 0, callback = nil, hold_callback = nil,
    bordersize = 0, bordercolor = nil, shadow = nil }
function Tap:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local o = { width = self.width, height = self.height, padding = 0, bordersize = self.bordersize, radius = self.radius,
        self.content or blank(self.width, self.height) }
    if self.bordercolor then o.color = self.bordercolor end
    if self.background then o.background = self.background end
    self[1] = FrameContainer:new(o)
    self.ges_events = { TapDReader = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if self.hold_callback then self.ges_events.HoldDReader = { GestureRange:new{ ges = "hold", range = self.dimen } } end
end
function Tap:paintTo(bb, x, y)
    if self.shadow then
        local o = Screen:scaleBySize(2)
        pcall(bb.paintRoundedRect, bb, x + o, y + o + 1, self.dimen.w, self.dimen.h, self.shadow, self.radius or 0)
    end
    for _, ev in pairs(self.ges_events) do local r = ev[1].range r.x, r.y, r.w, r.h = x, y, self.dimen.w, self.dimen.h end
    return InputContainer.paintTo(self, bb, x, y)
end
function Tap:onTapDReader() if self.callback then self.callback() end return true end
function Tap:onHoldDReader() if self.hold_callback then self.hold_callback() end return true end

-- Reading area: left/right thirds turn pages, the middle toggles the controls.
local ReadZones = InputContainer:extend{ width = 0, height = 0, on_prev = nil, on_next = nil, on_toggle = nil }
function ReadZones:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = blank(self.width, self.height)
    self.ges_events = {
        TapRead = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeRead = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end
function ReadZones:paintTo(bb, x, y)
    self.ox = x
    for _, ev in pairs(self.ges_events) do local r = ev[1].range r.x, r.y, r.w, r.h = x, y, self.dimen.w, self.dimen.h end
    return InputContainer.paintTo(self, bb, x, y)
end
function ReadZones:onTapRead(_, ges)
    local rel = ges and ges.pos and (ges.pos.x - (self.ox or 0)) / math.max(1, self.width) or 0.5
    if rel < 0.3 then if self.on_prev then self.on_prev() end
    elseif rel > 0.7 then if self.on_next then self.on_next() end
    elseif self.on_toggle then self.on_toggle() end
    return true
end
function ReadZones:onSwipeRead(_, ges)
    local d = ges and ges.direction
    if d == "west" then if self.on_next then self.on_next() end return true end
    if d == "east" then if self.on_prev then self.on_prev() end return true end
    return false
end

local Seek = InputContainer:extend{ width = 0, height = 0, content = nil, on_seek = nil }
function Seek:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, self.content or blank(self.width, self.height) }
    self.ges_events = { TapSeek = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Seek:paintTo(bb, x, y)
    self.ox = x
    local r = self.ges_events.TapSeek[1].range
    r.x, r.y, r.w, r.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function Seek:onTapSeek(_, ges)
    if self.on_seek and ges and ges.pos then
        self.on_seek(clamp((ges.pos.x - (self.ox or 0)) / math.max(1, self.width), 0, 1))
    end
    return true
end

local function put(list, widget, x, y) widget.overlap_offset = { x, y } list[#list + 1] = widget return widget end

-- Text button with optional icon. Primary buttons are solid with a heavy
-- outline, secondary ones are light with a dark outline.
local function button(pal, w, h, text, primary, cb, size, icon)
    local fg = primary and pal.on_primary or pal.on_surface
    local isz = math.floor(h * .5)
    local gapw = math.floor(h * .16)
    local label = TextWidget:new{ text = text, face = Font:getFace("smallinfofont", size or math.max(8, math.floor(h * .36))),
        fgcolor = fg, bold = primary, max_width = math.max(1, w - 12 - (icon and (isz + gapw) or 0)) }
    local inner = label
    if icon then
        inner = HorizontalGroup:new{ align = "center", Icon:new{ kind = icon, size = isz, color = fg }, HorizontalSpan:new{ width = gapw }, label }
    end
    return Tap:new{ width = w, height = h, radius = math.floor(h * .3), callback = cb,
        shadow = primary and pal.on_variant or pal.surface_variant,
        background = primary and pal.primary or pal.surface, bordersize = 2, bordercolor = primary and pal.on_surface or pal.primary,
        content = CenterContainer:new{ dimen = Geom:new{ w = w - 4, h = h - 4 }, inner } }
end

-- style: "light" (on a dark header), "primary" (solid) or "plain" (outlined)
local function iconButton(pal, w, h, kind, cb, style, hold)
    local bg, fg, border = pal.surface, pal.on_surface, pal.primary
    if style == "light" then bg, fg, border = pal.on_primary, pal.primary, nil
    elseif style == "primary" then bg, fg, border = pal.primary, pal.on_primary, pal.on_surface end
    local bs = border and 2 or 0
    local sz = math.floor(math.min(w, h) * .56)
    return Tap:new{ width = w, height = h, radius = math.floor(math.min(w, h) * .3), callback = cb, hold_callback = hold,
        shadow = style ~= "light" and pal.surface_variant or nil,
        background = bg, bordersize = bs, bordercolor = border,
        content = CenterContainer:new{ dimen = Geom:new{ w = w - 2 * bs, h = h - 2 * bs }, Icon:new{ kind = kind, size = sz, color = fg } } }
end

local function placeholder(pal, w, h, title)
    local s = tostring(title or "")
    local b = s:byte(1)
    local len = 1
    if b and b >= 0xF0 then len = 4 elseif b and b >= 0xE0 then len = 3 elseif b and b >= 0xC0 then len = 2 end
    local first = s ~= "" and s:sub(1, len) or "?"
    return FrameContainer:new{ width = w, height = h, padding = 0, bordersize = 1, background = pal.surface,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h },
            TextWidget:new{ text = first:upper(), face = Font:getFace("cfont", math.max(10, math.floor(h * .3))), fgcolor = pal.on_variant } } }
end

local function imageWidget(path, w, h)
    if not exists(path) then return nil end
    local ok, widget = pcall(function() return ImageWidget:new{ file = path, width = w, height = h, file_do_cache = false } end)
    return ok and widget or nil
end
local function coverBox(pal, it, w, h)
    return (it.cover ~= "" and imageWidget(it.cover, w, h)) or placeholder(pal, w, h, it.title)
end

-- Status strip with clock on the left and battery on the right.
local function statusBar(pal, list, px, W, y, h, dark)
    local bg = dark and pal.primary or pal.background
    local fg = dark and pal.on_primary or pal.on_surface
    put(list, box(W, h, bg), 0, y)
    local face = Font:getFace("cfont", px(9))
    local t = TextWidget:new{ text = os.date("%H:%M"), face = face, fgcolor = fg, bold = true }
    put(list, t, px(12), y + math.floor((h - t:getSize().h) / 2))
    local pct, charging = batteryInfo()
    if pct then
        local label = TextWidget:new{ text = pct .. "%", face = face, fgcolor = fg }
        local lw = label:getSize().w
        local x = W - px(12) - lw
        put(list, label, x, y + math.floor((h - label:getSize().h) / 2))
        local bw, bh = px(24), math.max(8, math.floor(h * .5))
        x = x - px(6) - bw
        put(list, BatteryIcon:new{ width = bw, height = bh, pct = pct, color = fg }, x, y + math.floor((h - bh) / 2))
        if charging then
            put(list, Icon:new{ kind = "bolt", size = bh, color = fg }, x - bh - px(2), y + math.floor((h - bh) / 2))
        end
    end
    return h
end

-- Header bar with icon buttons. Returns its total height including the
-- accent rule below it. actions: { { icon, callback }, ... }
local function header(pal, list, px, W, hh, title, back, margin, actions, y0, subtitle)
    y0 = y0 or 0
    put(list, box(W, hh, pal.primary), 0, y0)
    local bs = hh - px(14)
    local by = y0 + math.floor((hh - bs) / 2)
    local x = margin
    if back then
        put(list, iconButton(pal, bs, bs, "back", back, "light"), margin, by)
        x = margin + bs + px(10)
    end
    local rx = W - margin
    for i = #(actions or {}), 1, -1 do
        local a = actions[i]
        rx = rx - bs
        put(list, iconButton(pal, bs, bs, a[1], a[2], "light"), rx, by)
        rx = rx - px(8)
    end
    local t = TextWidget:new{ text = title, face = Font:getFace("cfont", math.max(12, math.floor(hh * (subtitle and .32 or .38)))), fgcolor = pal.on_primary, bold = true,
        max_width = math.max(1, rx - x - px(4)) }
    local ty = y0 + math.floor((hh - t:getSize().h) / 2)
    if subtitle and subtitle ~= "" then
        local st = TextWidget:new{ text = clip(subtitle, 60), face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_primary,
            max_width = math.max(1, rx - x - px(4)) }
        ty = y0 + math.floor((hh - t:getSize().h - st:getSize().h) / 2)
        put(list, st, x, ty + t:getSize().h)
    end
    put(list, t, x, ty)
    put(list, box(W, px(2), pal.on_surface), 0, y0 + hh)
    put(list, box(W, 1, pal.on_surface), 0, y0 + hh + px(4))
    return hh + px(5)
end

local function statusLine(pal, list, text, W, margin, y, px)
    put(list, TextWidget:new{ text = clip(text, 90), face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant, max_width = W - 2 * margin }, margin, y)
end

local function pager(pal, list, px, W, H, margin, gap, fh, page, pages, onprev, onnext)
    local fy = H - fh - gap
    local bw = math.floor((W - 2 * margin - 2 * gap) * .3)
    put(list, iconButton(pal, bw, fh, "prev", onprev, "plain"), margin, fy)
    local lbl = TextWidget:new{ text = page .. " / " .. pages, face = Font:getFace("cfont", px(10)), bold = true, fgcolor = pal.on_surface }
    put(list, lbl, math.floor((W - lbl:getSize().w) / 2), fy + math.floor((fh - lbl:getSize().h) / 2))
    put(list, iconButton(pal, bw, fh, "next", onnext, "primary"), W - margin - bw, fy)
    return fy
end

local function progressBar(pal, list, x, y, w, h, pct)
    put(list, box(w, h, pal.surface_variant, math.floor(h / 2)), x, y)
    local fw = math.floor(w * clamp(pct, 0, 100) / 100)
    if fw >= h then put(list, box(fw, h, pal.primary, math.floor(h / 2)), x, y) end
end

-- ---------------------------------------------------------------- state & actions
local function stateFor(instance)
    if not instance.dreader then
        instance.dreader = { store = Store.load(), view = "library", rpage = 1, tpage = nil, status = "", controls = false,
            filter = "", last_flush = os.time(), meta_fail = {}, toc_tab = "toc" }
        pcall(function() ensureDir(STORE_DIR); ensureDir(COVER_DIR) end)
    end
    local st = instance.dreader
    if not st.tab then st.tab = #st.store.books > 0 and "reading" or "library" end
    return st
end

local function saveProgress(state, force)
    local s = state.session
    if s then
        state.store.progress[s.path] = s:position()
        state.dirty = true
    end
    flush(state, force)
end

local function closeSession(state)
    if state.session then
        saveProgress(state, true)
        state.session:close()
        state.session = nil
    end
end

local function touchBook(state, s)
    local rec = state.store.books
    for i = #rec, 1, -1 do if rec[i].path == s.path then table.remove(rec, i) end end
    local m = state.store.meta[s.path]
    local title = m and trim(m.title or "") or ""
    if title == "" then
        local ok, props = pcall(s.doc.getProps, s.doc)
        if ok and type(props) == "table" then title = oneLine(props.title or "") end
    end
    if title == "" then title = prettyName(s.path) end
    if not m then
        state.store.meta[s.path] = { title = title ~= prettyName(s.path) and title or "", author = "", cover = "", done = false }
    end
    table.insert(rec, 1, { path = s.path, title = title, format = extOf(s.path), opened = os.time() })
    while #rec > MAX_RECENTS do table.remove(rec) end
    state.dirty = true
end

-- The reading area leaves room for the footer and, if pinned, the status bar.
local function viewHeightOf(H, px, cfg)
    return H - (cfg.footer and px(20) or 0) - (cfg.statusbar and px(20) or 0)
end

local function ensureLayout(state, context)
    local s = state.session
    if not s then return end
    local px = context.px or scale
    local cfg = state.store.settings
    local W, H = context.dimen.w, viewHeightOf(context.dimen.h, px, cfg)
    if s.key ~= s:keyOf(cfg, W, H, px) then s:relayout(cfg, W, H, px) end
end

local function openBook(state, context, path, quiet)
    closeSession(state)
    state.status = ""
    if not exists(path) then
        state.status = _("The file no longer exists.")
        state.view = "library"
        if not quiet then refresh(context) end
        return false
    end
    local px = context.px or scale
    local busy = showBusy(_("Opening…"))
    local s, err = Session.open(path, state.store.settings, context.dimen.w, viewHeightOf(context.dimen.h, px, state.store.settings), px)
    hideBusy(busy)
    if not s then
        state.status = err or _("This file could not be opened.")
        state.view = "library"
        if not quiet then refresh(context) end
        return false
    end
    state.session = s
    s:restore(state.store.progress[path])
    touchBook(state, s)
    state.view, state.controls = "reader", false
    saveProgress(state, true)
    if not quiet then refresh(context) end
    return true
end

local function go(state, context, view)
    state.view = view
    if view == "library" then closeSession(state); state.controls = false end
    if view == "toc" then state.tpage = nil end
    state.status = ""
    refresh(context)
end

local function turn(state, context, dir)
    local s = state.session
    if not s then return end
    local moved = dir > 0 and s:nextPage() or s:prevPage()
    if moved then
        state.status = ""
        saveProgress(state, false)
    else
        state.status = dir > 0 and _("End of book.") or _("Start of book.")
    end
    refresh(context)
end

local function bookmarksOf(state)
    local s = state.session
    local list = state.store.bookmarks[s.path]
    if type(list) ~= "table" then list = {}; state.store.bookmarks[s.path] = list end
    return list
end
local function findBookmark(state)
    local s = state.session
    for i, b in ipairs(bookmarksOf(state)) do
        if s:bookmarkPage(b) == s.page then return i, b end
    end
end
local function toggleBookmark(state, context)
    local s = state.session
    local list = bookmarksOf(state)
    local i = findBookmark(state)
    if i then table.remove(list, i)
    else
        local pos = s:position()
        local title = s:chapter()
        table.insert(list, 1, { page = pos.page, xp = pos.xp, pct = pos.pct, total = pos.total, offy = pos.offy,
            title = title, time = os.time() })
        while #list > 200 do table.remove(list) end
    end
    state.dirty = true
    flush(state, true)
    refresh(context)
end

local function promptOpenPath(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Open file"), input = "", input_hint = _("Absolute path to a book or document"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Open"), is_enter_default = true, callback = function()
                local path = trim(dialog:getInputText())
                UIManager:close(dialog)
                if path == "" then return end
                if not BOOK_EXT[extOf(path)] then
                    state.status = _("This file type is not supported.")
                    refresh(context)
                    return
                end
                openBook(state, context, path)
            end } } },
    }
    showInput(dialog)
end

local function promptSearch(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Search library"), input = state.filter or "", input_hint = _("Title or author"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                state.filter = trim(dialog:getInputText())
                state.rpage = 1
                if state.filter ~= "" then state.tab = "library" end
                UIManager:close(dialog)
                refresh(context)
            end } } },
    }
    showInput(dialog)
end

local function promptGoto(state, context)
    local s = state.session
    if not s then return end
    local dialog
    dialog = InputDialog:new{
        title = _("Go to"), input = "",
        input_hint = string.format(_("Page 1–%d, or a percentage like 50%%"), s.count),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Go"), is_enter_default = true, callback = function()
                local text = trim(dialog:getInputText())
                UIManager:close(dialog)
                local pct = text:match("^(%d+%.?%d*)%s*%%$")
                local page
                if pct then page = math.ceil(tonumber(pct) / 100 * s.count) else page = tonumber(text:match("^%d+$")) end
                if page then
                    s:jump(page)
                    state.view, state.controls = "reader", false
                    saveProgress(state, false)
                else
                    state.status = _("Enter a page number or a percentage.")
                end
                refresh(context)
            end } } },
    }
    showInput(dialog)
end

-- ---------------------------------------------------------------- views
local function itemRow(state, context, pal, list, px, W, margin, y, rh, it, hold)
    local parts = {}
    local cw, ch = math.floor((rh - 8) * .68), rh - 8
    put(parts, coverBox(pal, it, cw, ch), margin, 4)
    local bt = TextWidget:new{ text = it.ext:upper(), face = Font:getFace("smallinfofont", px(7)), fgcolor = pal.on_primary, bold = true }
    local bw0, bh0 = bt:getSize().w + px(8), bt:getSize().h + px(2)
    if cw > bw0 + px(6) then
        put(parts, FrameContainer:new{ width = bw0, height = bh0, padding = 0, bordersize = 0, radius = px(3), background = pal.primary,
            CenterContainer:new{ dimen = Geom:new{ w = bw0, h = bh0 }, bt } }, margin + px(3), 4 + ch - bh0 - px(3))
    end
    local tx, tw = margin + cw + margin, W - 2 * margin - cw - margin - px(34)
    put(parts, TextWidget:new{ text = clip(it.title, 70), face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface, max_width = tw }, tx, math.floor(rh * .10))
    local sub = it.author ~= "" and it.author or (it.ext:upper() .. (it.size > 0 and " · " .. humanSize(it.size) or ""))
    put(parts, TextWidget:new{ text = clip(sub, 60), face = Font:getFace("smallinfofont", px(9)), fgcolor = pal.on_variant, max_width = tw }, tx, math.floor(rh * .42))
    if it.pct and it.pct > 0 then
        local bw = math.min(tw - px(44), px(150))
        progressBar(pal, parts, tx, math.floor(rh * .76), bw, px(7), it.pct)
        put(parts, TextWidget:new{ text = it.pct >= 100 and _("Finished") or (it.pct .. "%"), face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant }, tx + bw + px(8), math.floor(rh * .72))
    else
        put(parts, TextWidget:new{ text = it.ext:upper() .. " · " .. _("New"), face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant, max_width = tw }, tx, math.floor(rh * .72))
    end
    local isz = px(18)
    put(parts, Icon:new{ kind = "next", size = isz, color = pal.primary }, W - 2 * margin - isz - px(8), math.floor((rh - isz) / 2))
    put(list, Tap:new{ width = W - 2 * margin, height = rh, radius = px(10), background = pal.surface, shadow = pal.surface_variant,
        bordersize = 1, bordercolor = pal.surface_variant,
        content = OverlapGroup:new{ dimen = Geom:new{ w = W - 2 * margin - 2, h = rh - 2 }, allow_mirroring = false, unpack(parts) },
        callback = function() openBook(state, context, it.path) end, hold_callback = hold }, margin, y)
end

local function heroCard(state, context, pal, list, px, W, margin, y, hh, it)
    local parts = {}
    local pad = px(8)
    local ch = hh - 2 * pad - 2
    local cw = math.floor(ch * .68)
    put(parts, coverBox(pal, it, cw, ch), pad, pad)
    local tx = pad + cw + margin
    local tw = W - 2 * margin - tx - pad - 4
    put(parts, TextWidget:new{ text = _("Continue reading"), face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant, bold = true, max_width = tw }, tx, pad)
    put(parts, TextBoxWidget:new{ text = clip(it.title, 80), face = Font:getFace("cfont", px(13)), bold = true, width = tw, height = px(44), fgcolor = pal.on_surface, bgcolor = pal.surface }, tx, pad + px(18))
    put(parts, TextWidget:new{ text = clip(it.author ~= "" and it.author or it.ext:upper(), 50), face = Font:getFace("smallinfofont", px(9)), fgcolor = pal.on_variant, max_width = tw }, tx, pad + px(18) + px(46))
    local ph = px(34)
    local by = hh - pad - ph - 2
    if it.pct then
        local bw = math.min(tw - px(44), px(180))
        progressBar(pal, parts, tx, by - px(14), bw, px(6), it.pct)
        put(parts, TextWidget:new{ text = it.pct .. "%", face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant }, tx + bw + px(8), by - px(18))
    end
    local pw = math.min(tw, px(160))
    local label = TextWidget:new{ text = it.pct and _("Continue") or _("Start reading"), face = Font:getFace("smallinfofont", px(10)), fgcolor = pal.on_primary, bold = true, max_width = pw - px(36) }
    local inner = HorizontalGroup:new{ align = "center", Icon:new{ kind = "book", size = px(18), color = pal.on_primary }, HorizontalSpan:new{ width = px(6) }, label }
    put(parts, FrameContainer:new{ width = pw, height = ph, padding = 0, bordersize = 2, color = pal.on_surface, radius = px(9), background = pal.primary,
        CenterContainer:new{ dimen = Geom:new{ w = pw - 4, h = ph - 4 }, inner } }, tx, by)
    put(list, Tap:new{ width = W - 2 * margin, height = hh, radius = px(14), background = pal.surface, shadow = pal.surface_variant,
        bordersize = 2, bordercolor = pal.primary,
        content = OverlapGroup:new{ dimen = Geom:new{ w = W - 2 * margin - 4, h = hh - 4 }, allow_mirroring = false, unpack(parts) },
        callback = function() openBook(state, context, it.path) end }, margin, y)
end

local function emptyState(pal, list, px, W, y, icon, text, margin)
    local isz = px(52)
    put(list, Icon:new{ kind = icon, size = isz, color = pal.on_variant }, math.floor((W - isz) / 2), y + px(16))
    put(list, Ornament:new{ width = math.floor(W * .5), height = px(12), color = pal.on_variant }, math.floor(W * .25), y + px(16) + isz + px(10))
    put(list, TextBoxWidget:new{ text = text, face = Font:getFace("smallinfofont", px(10)), width = W - 2 * margin, height = px(70),
        fgcolor = pal.on_variant, bgcolor = pal.background, alignment = "center" }, margin, y + px(16) + isz + px(30))
end

local function viewLibrary(state, context, pal, W, H, px)
    local list, margin, gap = {}, math.max(px(10), math.floor(W / 40)), px(6)
    local sb = px(20)
    statusBar(pal, list, px, W, 0, sb, true)
    local hh = math.max(px(46), math.floor(H * .075))
    local cfg = state.store.settings
    local sub = state.tab == "reading" and string.format(_("%d recently opened"), #state.store.books)
        or (_("Library") .. " · " .. _("sorted by") .. " " .. sortLabel(cfg.sort))
    local hu = header(pal, list, px, W, hh, "DReader", nil, margin, {
        { state.filter ~= "" and "close" or "search", function()
            if state.filter ~= "" then state.filter = ""; state.rpage = 1; refresh(context) else promptSearch(state, context) end
        end },
        { "sort", function()
            local idx = 1
            for i, m in ipairs(SORTS) do if m == cfg.sort then idx = i end end
            cfg.sort = SORTS[idx % #SORTS + 1]
            state.dirty = true
            flush(state, true)
            state.tab, state.rpage = "library", 1
            state.status = _("Sorted by") .. " " .. sortLabel(cfg.sort)
            refresh(context)
        end },
        { "folder", function() promptOpenPath(state, context) end },
    }, sb, sub)
    local y = sb + hu + gap
    local th = math.max(px(38), math.floor(H * .066))
    local half = math.floor((W - 2 * margin - gap) / 2)
    put(list, button(pal, half, th, _("Reading") .. (#state.store.books > 0 and (" (" .. #state.store.books .. ")") or ""), state.tab == "reading", function()
        state.tab, state.rpage, state.status = "reading", 1, ""
        refresh(context)
    end, px(10), "book"), margin, y)
    put(list, button(pal, half, th, _("Library"), state.tab == "library", function()
        state.tab, state.rpage, state.status, state.lib = "library", 1, "", nil
        refresh(context)
    end, px(10), "grid"), margin + half + gap, y)
    y = y + th + gap

    local items = state.tab == "reading" and readingItems(state) or libraryItems(state)
    local fh = math.max(px(38), math.floor(H * .07))
    local stat_h = state.status ~= "" and px(18) or 0
    local area = H - y - fh - 2 * gap - stat_h
    local rh = math.max(px(70), math.floor(H * .11))
    local hero = (state.tab == "reading" and state.filter == "" and items[1]) or nil
    local hero_h = hero and clamp(math.floor(H * .25), px(120), px(210)) or 0
    local orn_h = px(12)
    local rest = {}
    for i = hero and 2 or 1, #items do rest[#rest + 1] = items[i] end
    local first_used = hero and (hero_h + gap + orn_h + gap) or 0
    local cap1 = math.max(1, math.floor((area - first_used + gap) / (rh + gap)))
    local capN = math.max(1, math.floor((area + gap) / (rh + gap)))
    local pages = 1 + math.max(0, math.ceil((#rest - cap1) / capN))
    state.rpage = clamp(state.rpage or 1, 1, pages)
    local from, to
    if state.rpage == 1 then from, to = 1, math.min(#rest, cap1)
    else from = cap1 + (state.rpage - 2) * capN + 1; to = math.min(#rest, from + capN - 1) end

    local visible = {}
    if hero and state.rpage == 1 then
        heroCard(state, context, pal, list, px, W, margin, y, hero_h, hero)
        y = y + hero_h + gap
        put(list, Ornament:new{ width = W - 2 * margin, height = orn_h, color = pal.on_variant }, margin, y)
        y = y + orn_h + gap
        visible[#visible + 1] = hero
    end
    for i = from, to do
        local it = rest[i]
        local hold
        if state.tab == "reading" then
            hold = function()
                UIManager:show(ConfirmBox:new{ text = _("Remove this book from the reading list? The file stays on the reader."), ok_callback = function()
                    local rec = state.store.books
                    for j = #rec, 1, -1 do if rec[j].path == it.path then table.remove(rec, j) end end
                    state.dirty = true
                    flush(state, true)
                    refresh(context)
                end })
            end
        else
            hold = function()
                UIManager:show(InfoMessage:new{ text = it.title .. "\n" .. (it.author ~= "" and (it.author .. "\n") or "") ..
                    it.ext:upper() .. (it.size > 0 and (" · " .. humanSize(it.size)) or "") .. "\n" .. it.path })
            end
        end
        itemRow(state, context, pal, list, px, W, margin, y, rh, it, hold)
        visible[#visible + 1] = it
        y = y + rh + gap
    end
    if #items == 0 then
        if state.filter ~= "" then emptyState(pal, list, px, W, y, "search", _("No books match your search."), margin)
        elseif state.tab == "reading" then emptyState(pal, list, px, W, y, "book", _("Nothing here yet. Open the Library tab and pick a book."), margin)
        else emptyState(pal, list, px, W, y, "grid", string.format(_("No books found in %s. Use the folder button to enter a path."), BOOKS_DIR), margin) end
    end
    local fy = pager(pal, list, px, W, H, margin, gap, fh, state.rpage, pages,
        function() state.rpage = math.max(1, state.rpage - 1); refresh(context) end,
        function() state.rpage = math.min(pages, state.rpage + 1); refresh(context) end)
    if state.status ~= "" then statusLine(pal, list, state.status, W, margin, fy - px(16), px)
    elseif state.tab == "library" and #items > 0 then
        statusLine(pal, list, string.format(_("%d books"), #items) .. (state.filter ~= "" and ("  ·  “" .. state.filter .. "”") or ""), W, margin, fy - px(16), px)
    elseif state.tab == "reading" and #items > 1 then
        statusLine(pal, list, _("Tap to open · hold to remove"), W, margin, fy - px(16), px)
    end
    ensureMeta(state, context, visible)
    return list
end

local function viewReader(state, context, pal, W, H, px)
    local s = state.session
    local cfg = state.store.settings
    local list, margin = {}, px(10)
    local footer_h = cfg.footer and px(20) or 0
    local top = cfg.statusbar and px(20) or 0
    local view_h = H - footer_h - top
    -- the page takes the AppDock background; text turns white on dark ones
    local pbg, pfg, themed, tsig = pageColors(pal)
    if cfg.pagecolor == "white" then themed, tsig = false, "white" end
    local tpal = withText(pal, pfg)
    s:setTheme(pbg, pfg, themed, tsig)
    local bb = s:draw()
    if bb then
        put(list, ImageWidget:new{ image = bb, image_disposable = false, scale_factor = 1 }, 0, top)
    else
        local msg = _("This page could not be displayed.")
        if s.err and s.err ~= "" then msg = msg .. "\n" .. clip(s.err, 260) end
        put(list, TextBoxWidget:new{ text = msg, face = Font:getFace("smallinfofont", px(11)),
            width = W - 2 * margin, height = px(110), fgcolor = pfg, bgcolor = pal.background }, margin, top + px(60))
    end
    if top > 0 then
        statusBar(tpal, list, px, W, 0, top, false)
        put(list, box(W, 1, pal.surface_variant), 0, top - 1)
    end
    local fy0 = top + view_h
    local bm_here = findBookmark(state)
    if footer_h > 0 then
        -- footer: chapter on the left, position on the right
        put(list, box(W, footer_h, pal.background), 0, fy0)
        put(list, box(W, 1, pal.surface_variant), 0, fy0)
        local right = TextWidget:new{ text = string.format("%d / %d · %d%%", s.page, s.count, s:percent()), face = Font:getFace("smallinfofont", px(8)), fgcolor = pfg }
        local rw, rhh = right:getSize().w, right:getSize().h
        put(list, right, W - margin - rw, fy0 + math.floor((footer_h - rhh) / 2))
        local left = TextWidget:new{ text = clip((s:chapter()), 50), face = Font:getFace("smallinfofont", px(8)), fgcolor = pfg, max_width = math.max(1, W - 2 * margin - rw - px(24)) }
        put(list, left, margin, fy0 + math.floor((footer_h - left:getSize().h) / 2))
        if bm_here then
            local isz = px(14)
            put(list, Icon:new{ kind = "bookmark_on", size = isz, color = pal.primary }, W - margin - rw - isz - px(6), fy0 + math.floor((footer_h - isz) / 2))
        end
    elseif bm_here then
        local isz = px(18)
        put(list, Icon:new{ kind = "bookmark_on", size = isz, color = themed and pfg or Blitbuffer.COLOR_BLACK }, W - margin - isz, top + px(2))
    end

    local sb = px(20)
    local hh, bh = math.max(px(46), math.floor(H * .075)), px(170)
    local hu = hh + px(5)
    local zy, zh = top, view_h
    if state.controls then zy, zh = sb + hu, H - bh - sb - hu end
    local lp, ln = -1, 1
    if cfg.flip then lp, ln = 1, -1 end
    put(list, ReadZones:new{ width = W, height = math.max(1, zh),
        on_prev = function() turn(state, context, lp) end,
        on_next = function() turn(state, context, ln) end,
        on_toggle = function() state.controls = not state.controls; refresh(context) end }, 0, zy)

    if state.controls then
        local m = state.store.meta[s.path]
        local title = m and trim(m.title or "") or ""
        if title == "" then title = prettyName(s.path) end
        local author = m and trim(m.author or "") or ""
        statusBar(pal, list, px, W, 0, sb, true)
        header(pal, list, px, W, hh, clip(title, 40), function() go(state, context, "library") end, margin, {
            { "type", function() state.view = "settings"; refresh(context) end },
            { "list", function() go(state, context, "toc") end },
        }, sb, author ~= "" and author or s.path:match("%.(%w+)$") and s.path:match("%.(%w+)$"):upper() or "")
        local by = H - bh
        put(list, box(W, bh, pal.surface), 0, by)
        put(list, box(W, px(2), pal.on_surface), 0, by)
        put(list, box(W, 1, pal.on_surface), 0, by + px(4))
        local half_w = math.floor((W - 2 * margin) * .48)
        local info = TextWidget:new{ text = string.format(_("Page %d of %d"), s.page, s.count) .. "  ·  " .. s:percent() .. "%", face = Font:getFace("smallinfofont", px(9)), bold = true, fgcolor = pal.on_surface, max_width = half_w }
        put(list, info, margin, by + px(10))
        local chap = clip((s:chapter()), 36)
        if chap ~= "" then
            local cw = TextWidget:new{ text = chap, face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant, max_width = half_w }
            put(list, cw, W - margin - cw:getSize().w, by + px(11))
        end
        local sw, sh = W - 2 * margin, px(26)
        local frac = s.count > 1 and (s.page - 1) / (s.count - 1) or 0
        local parts = {}
        put(parts, box(sw, px(8), pal.surface_variant, px(4)), 0, math.floor((sh - px(8)) / 2))
        local fw = math.floor(sw * frac)
        if fw > px(4) then put(parts, box(fw, px(8), pal.primary, px(4)), 0, math.floor((sh - px(8)) / 2)) end
        local kn = px(20)
        put(parts, box(kn, kn, pal.primary, math.floor(kn / 2), 2, pal.on_surface), clamp(fw - math.floor(kn / 2), 0, sw - kn), math.floor((sh - kn) / 2))
        put(list, Seek:new{ width = sw, height = sh, content = OverlapGroup:new{ dimen = Geom:new{ w = sw, h = sh }, allow_mirroring = false, unpack(parts) },
            on_seek = function(f)
                s:jump(math.floor(f * (s.count - 1) + 0.5) + 1)
                saveProgress(state, false)
                refresh(context)
            end }, margin, by + px(30))
        local gap = px(8)
        -- quick settings row
        local function setCfg(k, v) cfg[k] = v; state.dirty = true; flush(state, true); refresh(context) end
        local acts = {}
        if s.paged then
            acts[#acts + 1] = { cfg.fit == "width" and _("Width") or _("Page"), false, function() setCfg("fit", cfg.fit == "width" and "page" or "width") end, "grid" }
            acts[#acts + 1] = { _("Crop"), cfg.crop, function() setCfg("crop", not cfg.crop) end }
        else
            acts[#acts + 1] = { "A-", false, function() setCfg("font", clamp(cfg.font - 1, 12, 48)) end }
            acts[#acts + 1] = { "A+", false, function() setCfg("font", clamp(cfg.font + 1, 12, 48)) end }
            acts[#acts + 1] = { cfg.face == "serif" and "Serif" or "Sans", false, function() setCfg("face", cfg.face == "serif" and "sans" or "serif") end }
        end
        acts[#acts + 1] = { _("Go to"), false, function() promptGoto(state, context) end, "goto" }
        local n = #acts
        local aw = math.floor((W - 2 * margin - (n - 1) * gap) / n)
        for i, a in ipairs(acts) do
            put(list, button(pal, aw, px(40), a[1], a[2], a[3], px(9), a[4]), margin + (i - 1) * (aw + gap), by + px(62))
        end
        -- navigation row
        local bw = math.floor((W - 2 * margin - 2 * gap) / 3)
        local bhh = px(44)
        local brow = H - bhh - px(6)
        put(list, iconButton(pal, bw, bhh, "prev", function() turn(state, context, -1) end, "plain"), margin, brow)
        put(list, iconButton(pal, bw, bhh, bm_here and "bookmark_on" or "bookmark", function() toggleBookmark(state, context) end, bm_here and "primary" or "plain"), margin + bw + gap, brow)
        put(list, iconButton(pal, bw, bhh, "next", function() turn(state, context, 1) end, "primary"), margin + 2 * (bw + gap), brow)
    elseif state.status ~= "" then
        statusLine(tpal, list, state.status, W, margin, fy0 - px(16), px)
    end
    return list
end

local function viewContents(state, context, pal, W, H, px)
    local s = state.session
    local list, margin, gap = {}, math.max(px(10), math.floor(W / 40)), px(5)
    local sb = px(20)
    statusBar(pal, list, px, W, 0, sb, true)
    local hh = math.max(px(46), math.floor(H * .075))
    local bm0 = state.store.meta[s.path]
    local bt0 = bm0 and trim(bm0.title or "") or ""
    if bt0 == "" then bt0 = prettyName(s.path) end
    local hu = header(pal, list, px, W, hh, _("Contents"), function() state.view, state.controls = "reader", false; refresh(context) end, margin, {
        { "goto", function() promptGoto(state, context) end },
    }, sb, bt0)
    local y = sb + hu + gap
    local th = math.max(px(38), math.floor(H * .066))
    local half = math.floor((W - 2 * margin - gap) / 2)
    put(list, button(pal, half, th, _("Chapters"), state.toc_tab == "toc", function() state.toc_tab, state.tpage = "toc", nil; refresh(context) end, px(10), "list"), margin, y)
    put(list, button(pal, half, th, _("Bookmarks"), state.toc_tab == "marks", function() state.toc_tab, state.tpage = "marks", nil; refresh(context) end, px(10), "bookmark"), margin + half + gap, y)
    y = y + th + gap
    local fh = math.max(px(38), math.floor(H * .07))
    local rh = state.toc_tab == "marks" and math.max(px(54), math.floor(H * .09)) or math.max(px(42), math.floor(H * .07))
    local area = H - y - fh - 2 * gap - px(16)
    local cap = math.max(1, math.floor((area + gap) / (rh + gap)))
    local rows = {}
    local cur_idx
    if state.toc_tab == "marks" then
        for _, b in ipairs(bookmarksOf(state)) do rows[#rows + 1] = b end
    else
        rows = s:tocList()
        local _t
        _t, cur_idx = s:chapter()
    end
    local pages = math.max(1, math.ceil(#rows / cap))
    if not state.tpage then state.tpage = cur_idx and math.ceil(cur_idx / cap) or 1 end
    state.tpage = clamp(state.tpage, 1, pages)
    if #rows == 0 then
        if state.toc_tab == "marks" then emptyState(pal, list, px, W, y, "bookmark", _("No bookmarks yet. Use the bookmark button in the reader controls."), margin)
        else emptyState(pal, list, px, W, y, "list", _("This book has no table of contents. Use the go-to button or the progress bar."), margin) end
    end
    for i = (state.tpage - 1) * cap + 1, math.min(#rows, state.tpage * cap) do
        local r = rows[i]
        if state.toc_tab == "marks" then
            local page = s:bookmarkPage(r)
            local parts = {}
            local isz = px(18)
            put(parts, Icon:new{ kind = "bookmark_on", size = isz, color = pal.primary }, px(10), math.floor((rh - isz) / 2))
            local tx = px(10) + isz + px(10)
            put(parts, TextWidget:new{ text = string.format(_("Page %d"), page) .. "  ·  " .. (r.pct or 0) .. "%", face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface, max_width = W - 2 * margin - tx - px(10) }, tx, math.floor(rh * .14))
            put(parts, TextWidget:new{ text = clip((r.title or "") ~= "" and r.title or os.date("%d.%m.%Y %H:%M", r.time or 0), 60), face = Font:getFace("smallinfofont", px(9)), fgcolor = pal.on_variant, max_width = W - 2 * margin - tx - px(10) }, tx, math.floor(rh * .56))
            put(list, Tap:new{ width = W - 2 * margin, height = rh, radius = px(8), background = pal.surface,
                bordersize = 1, bordercolor = pal.surface_variant,
                content = OverlapGroup:new{ dimen = Geom:new{ w = W - 2 * margin - 2, h = rh - 2 }, allow_mirroring = false, unpack(parts) },
                callback = function()
                    s:restore({ page = r.page, xp = r.xp, pct = r.pct, total = r.total, offy = r.offy })
                    state.view, state.controls = "reader", false
                    saveProgress(state, false)
                    refresh(context)
                end,
                hold_callback = function()
                    UIManager:show(ConfirmBox:new{ text = _("Delete this bookmark?"), ok_callback = function()
                        local list2 = bookmarksOf(state)
                        for j = #list2, 1, -1 do if list2[j] == r then table.remove(list2, j) end end
                        state.dirty = true; flush(state, true); refresh(context)
                    end })
                end }, margin, y)
        else
            local is_cur = (i == cur_idx)
            local fg = is_cur and pal.on_primary or pal.on_surface
            local parts = {}
            local indent = px(10) + r.depth * px(14)
            local pgw = TextWidget:new{ text = tostring(r.page), face = Font:getFace("smallinfofont", px(9)), fgcolor = is_cur and pal.on_primary or pal.on_variant }
            local pw = pgw:getSize().w
            put(parts, pgw, W - 2 * margin - pw - px(12), math.floor((rh - pgw:getSize().h) / 2))
            local t = TextWidget:new{ text = clip(r.title, 80), face = Font:getFace("cfont", px(10)), bold = is_cur, fgcolor = fg, max_width = math.max(1, W - 2 * margin - indent - pw - px(26)) }
            put(parts, t, indent, math.floor((rh - t:getSize().h) / 2))
            put(list, Tap:new{ width = W - 2 * margin, height = rh, radius = px(8), background = is_cur and pal.primary or pal.surface,
                bordersize = is_cur and 2 or 1, bordercolor = is_cur and pal.on_surface or pal.surface_variant,
                content = OverlapGroup:new{ dimen = Geom:new{ w = W - 2 * margin - 4, h = rh - 4 }, allow_mirroring = false, unpack(parts) },
                callback = function()
                    s:jump(r.page)
                    state.view, state.controls = "reader", false
                    saveProgress(state, false)
                    refresh(context)
                end }, margin, y)
        end
        y = y + rh + gap
    end
    local fy = pager(pal, list, px, W, H, margin, gap, fh, state.tpage, pages,
        function() state.tpage = math.max(1, state.tpage - 1); refresh(context) end,
        function() state.tpage = math.min(pages, state.tpage + 1); refresh(context) end)
    if state.toc_tab == "marks" and #rows > 0 then statusLine(pal, list, _("Tap to open · hold to delete"), W, margin, fy - px(16), px) end
    return list
end

local function viewSettings(state, context, pal, W, H, px)
    local s = state.session
    local cfg = state.store.settings
    local list, margin, gap = {}, math.max(px(10), math.floor(W / 40)), px(7)
    local sb = px(20)
    statusBar(pal, list, px, W, 0, sb, true)
    local hh = math.max(px(46), math.floor(H * .075))
    local bm0 = state.store.meta[s.path]
    local bt0 = bm0 and trim(bm0.title or "") or ""
    if bt0 == "" then bt0 = prettyName(s.path) end
    local hu = header(pal, list, px, W, hh, _("Reading settings"), function() state.view, state.controls = "reader", false; refresh(context) end, margin, nil, sb, bt0)
    local y = sb + hu + gap
    local orn_h = px(12)
    put(list, Ornament:new{ width = W - 2 * margin, height = orn_h, color = pal.on_variant }, margin, y)
    y = y + orn_h + gap
    local rh = math.max(px(46), math.floor(H * .064))
    local cw = W - 2 * margin
    local function change(key, value)
        cfg[key] = value
        state.dirty = true
        flush(state, true)
        refresh(context)
    end
    local function rowBase(label)
        put(list, box(cw, rh, pal.surface, px(12), 1, pal.surface_variant), margin, y)
        local t = TextWidget:new{ text = label, face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface, max_width = math.floor(cw * .34) }
        put(list, t, margin + px(12), y + math.floor((rh - t:getSize().h) / 2))
    end
    local function stepRow(label, value, onminus, onplus)
        rowBase(label)
        local bw, bh = px(52), rh - px(14)
        local by = y + px(7)
        local xplus = margin + cw - bw - px(6)
        local xminus = xplus - px(90) - bw
        put(list, iconButton(pal, bw, bh, "minus", onminus, "plain"), xminus, by)
        put(list, iconButton(pal, bw, bh, "plus", onplus, "primary"), xplus, by)
        local v = TextWidget:new{ text = value, face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface }
        local x0 = xminus + bw
        put(list, v, x0 + math.floor((xplus - x0 - v:getSize().w) / 2), y + math.floor((rh - v:getSize().h) / 2))
        y = y + rh + gap
    end
    local function choiceRow(label, options)
        rowBase(label)
        local bw, bh = px(92), rh - px(14)
        local x = margin + cw - px(6)
        for i = #options, 1, -1 do
            local o = options[i]
            x = x - bw
            put(list, button(pal, bw, bh, o[1], o[2], o[3], px(10)), x, y + px(7))
            x = x - px(6)
        end
        y = y + rh + gap
    end
    if not s.paged then
        stepRow(_("Font size"), tostring(cfg.font), function() change("font", clamp(cfg.font - 1, 12, 48)) end, function() change("font", clamp(cfg.font + 1, 12, 48)) end)
        choiceRow(_("Typeface"), {
            { "Serif", cfg.face == "serif", function() change("face", "serif") end },
            { "Sans", cfg.face == "sans", function() change("face", "sans") end },
        })
        stepRow(_("Margins"), tostring(cfg.margin), function() change("margin", clamp(cfg.margin - 1, 1, #MARGINS)) end, function() change("margin", clamp(cfg.margin + 1, 1, #MARGINS)) end)
        stepRow(_("Line spacing"), SPACINGS[cfg.spacing] .. "%", function() change("spacing", clamp(cfg.spacing - 1, 1, #SPACINGS)) end, function() change("spacing", clamp(cfg.spacing + 1, 1, #SPACINGS)) end)
    else
        choiceRow(_("Page fit"), {
            { _("Width"), cfg.fit == "width", function() change("fit", "width") end },
            { _("Page"), cfg.fit == "page", function() change("fit", "page") end },
        })
        choiceRow(_("Crop margins"), {
            { _("On"), cfg.crop, function() change("crop", true) end },
            { _("Off"), not cfg.crop, function() change("crop", false) end },
        })
    end
    choiceRow(_("Page color"), {
        { "AppDock", cfg.pagecolor == "app", function() change("pagecolor", "app") end },
        { _("White"), cfg.pagecolor == "white", function() change("pagecolor", "white") end },
    })
    choiceRow(_("Footer"), {
        { _("Show"), cfg.footer, function() change("footer", true) end },
        { _("Hide"), not cfg.footer, function() change("footer", false) end },
    })
    choiceRow(_("Status bar"), {
        { _("Menus"), not cfg.statusbar, function() change("statusbar", false) end },
        { _("Always"), cfg.statusbar, function() change("statusbar", true) end },
    })
    choiceRow(_("Page turn"), {
        { _("Normal"), not cfg.flip, function() change("flip", false) end },
        { _("Flipped"), cfg.flip, function() change("flip", true) end },
    })
    statusLine(pal, list, cfg.flip and _("Left edge turns forward, right edge turns back.") or _("Left edge turns back, right edge turns forward."), W, margin, y, px)
    local bh = math.max(px(42), math.floor(H * .075))
    put(list, button(pal, cw, bh, _("Back to book"), true, function() state.view, state.controls = "reader", false; refresh(context) end, px(11), "book"), margin, H - bh - margin)
    return list
end

-- A failed view must never take the whole pane down: show the error and a way back.
local function viewError(state, context, pal, W, H, px, err)
    local list, margin = {}, math.max(px(10), math.floor(W / 40))
    local sb = px(20)
    statusBar(pal, list, px, W, 0, sb, true)
    local hh = math.max(px(46), math.floor(H * .075))
    local hu = header(pal, list, px, W, hh, "DReader", nil, margin, nil, sb)
    put(list, TextBoxWidget:new{ text = _("Something went wrong:") .. "\n" .. clip(tostring(err), 300), face = Font:getFace("smallinfofont", px(10)),
        width = W - 2 * margin, height = math.floor(H * .4), fgcolor = pal.on_surface, bgcolor = pal.background }, margin, sb + hu + px(12))
    local bh = math.max(px(42), math.floor(H * .07))
    put(list, button(pal, W - 2 * margin, bh, _("Back to library"), true, function() go(state, context, "library") end, px(11), "grid"), margin, H - bh - margin)
    return list
end

return {
    id = "dreader",
    version = "3.1.0",
    title = "DReader",
    subtitle = "EPUB, PDF and more, rendered by KOReader",
    symbol = "R",
    logo = "document",
    openFile = function(instance, path)
        local state = stateFor(instance)
        if type(path) ~= "string" or not BOOK_EXT[extOf(path)] then return false, _("This file type is not supported.") end
        state.pending_open = path
        return true
    end,
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local pal = palette(context)
        local W, H = context.dimen.w, context.dimen.h
        local px = context.px or scale
        if state.pending_open then
            local p = state.pending_open
            state.pending_open = nil
            openBook(state, context, p, true)
        end
        if state.view ~= "library" and not state.session then state.view = "library" end
        local builder = viewLibrary
        if state.session then
            if state.view == "reader" then builder = viewReader
            elseif state.view == "toc" then builder = viewContents
            elseif state.view == "settings" then builder = viewSettings
            else state.view = "library" end
            if state.view == "reader" or state.view == "toc" then ensureLayout(state, context) end
        end
        local ok, list = pcall(builder, state, context, pal, W, H, px)
        if not ok then
            local err = list
            closeSession(state)
            state.view = "library"
            list = viewError(state, context, pal, W, H, px, err)
        end
        local pane = OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, allow_mirroring = false,
            FrameContainer:new{ width = W, height = H, padding = 0, bordersize = 0, background = pal.background, blank(W, H) },
            unpack(list) }
        function pane:onDeactivate() saveProgress(state, true) end
        return pane
    end,
}
