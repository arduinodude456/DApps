--[[--
DReader for AppDock (4.0).

A calm reader with its OWN reading engine. It never touches KOReader's document
engines (no DocumentRegistry, crengine, mupdf, djvulibre or RenderImage):

  * ZIP/Inflate, PNG, JPEG (baseline + progressive, DCT-scaled), GIF and BMP
    decoders are written in Lua;
  * EPUB, FB2, HTML/XHTML, Markdown and TXT are parsed by a small HTML/CSS
    reader and laid out by DReader's own text layout (fonts only come from the
    normal UI font renderer);
  * images (PNG/JPG/GIF/BMP) and comic archives (CBZ) open in an image viewer
    with fit-width / fit-page, margin cropping and scrolling.

The UI follows DLib (AppDock palette, header bar, cover cards, AppDock
keyboard) and adds drawn icons, bordered buttons, ornament dividers and a
status bar with clock and battery.
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
    epub = true, fb2 = true, txt = true, html = true, htm = true, xhtml = true, md = true, markdown = true, cbz = true,
    png = true, jpg = true, jpeg = true, gif = true, bmp = true,
}
local DEFAULT_SETTINGS = { font = 22, margin = 3, spacing = 2, face = "serif", fit = "width", crop = true, statusbar = false,
    footer = true, pagecolor = "app", sort = "title", flip = false, align = "book" }
local MARGINS = { 4, 10, 18, 28, 40 }
local SPACINGS = { 90, 100, 115, 130, 150 }
local FACES = { serif = "serif", sans = "sans", mono = "mono" }
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
        out.align = (s.align == "left" or s.align == "justify") and s.align or "book"
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
    for _, m in pairs(data.meta) do
        if type(m) == "table" and type(m.cover) == "string" and m.cover:match("%.png$") then m.cover, m.done = "", false end
    end
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

-- ---------------------------------------------------------------- DReader engine
-- ================================================================ DR engine (pure Lua, no KOReader document engine)
local DR = {}
do
local ffi = require("ffi")
local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

local function u16(s, p) local a, b = s:byte(p, p + 1) return a + b * 256 end
local function u32(s, p) local a, b, c, d = s:byte(p, p + 3) return a + b * 256 + c * 65536 + d * 16777216 end
local function u16b(s, p) local a, b = s:byte(p, p + 1) return a * 256 + b end
local function u32b(s, p) local a, b, c, d = s:byte(p, p + 3) return a * 16777216 + b * 65536 + c * 256 + d end
DR.u16, DR.u32 = u16, u32

-- ---------------------------------------------------------------- inflate
local lenBase = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258 }
local lenExtra = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0 }
local distBase = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577 }
local distExtra = { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 }
local clOrder = { 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 }

local function revbits(c, l)
    local r = 0
    for _ = 1, l do r = bor(lshift(r, 1), band(c, 1)); c = rshift(c, 1) end
    return r
end

local function buildHuff(lens, first, cnt)
    local count = ffi.new("int16_t[16]")
    for i = 0, cnt - 1 do local l = lens[first + i]; count[l] = count[l] + 1 end
    count[0] = 0
    local nextc, code, offs = {}, 0, {}
    local idx = 0
    for l = 1, 15 do
        code = lshift(code + count[l - 1], 1); nextc[l] = code
        offs[l] = idx; idx = idx + count[l]
    end
    local sym = ffi.new("int16_t[?]", max(cnt, 1))
    local fast = ffi.new("int16_t[1024]")
    for i = 0, cnt - 1 do
        local l = lens[first + i]
        if l > 0 then
            sym[offs[l]] = i; offs[l] = offs[l] + 1
            local c = nextc[l]; nextc[l] = c + 1
            if l <= 10 then
                local r = revbits(c, l)
                local e = l * 512 + i
                for k = r, 1023, lshift(1, l) do fast[k] = e end
            end
        end
    end
    return { fast = fast, cnt = count, sym = sym }
end

local fixedLit, fixedDist
local function getFixed()
    if fixedLit then return fixedLit, fixedDist end
    local l = {}
    for i = 0, 143 do l[i] = 8 end
    for i = 144, 255 do l[i] = 9 end
    for i = 256, 279 do l[i] = 7 end
    for i = 280, 287 do l[i] = 8 end
    fixedLit = buildHuff(l, 0, 288)
    local d = {}
    for i = 0, 29 do d[i] = 5 end
    fixedDist = buildHuff(d, 0, 30)
    return fixedLit, fixedDist
end

function DR.inflate(src, hint)
    local inp = ffi.cast("const uint8_t*", src)
    local inlen = #src
    local pos, bb, bc = 0, 0, 0
    local cap = (hint and hint > 0) and hint or max(4096, inlen * 3)
    local out = ffi.new("uint8_t[?]", cap)
    local op = 0
    local function grow(need)
        local nc = cap * 2
        while nc < op + need do nc = nc * 2 end
        local nb = ffi.new("uint8_t[?]", nc)
        ffi.copy(nb, out, op)
        out, cap = nb, nc
    end
    local function fill()
        while bc < 25 do
            local b = 0
            if pos < inlen then b = inp[pos] end
            pos = pos + 1
            bb = bor(bb, lshift(b, bc)); bc = bc + 8
        end
    end
    local function bits(n)
        if n == 0 then return 0 end
        fill()
        local v = band(bb, lshift(1, n) - 1)
        bb = rshift(bb, n); bc = bc - n
        return v
    end
    local function decode(h)
        fill()
        local e = h.fast[band(bb, 1023)]
        if e ~= 0 then
            local l = rshift(e, 9)
            bb = rshift(bb, l); bc = bc - l
            return band(e, 511)
        end
        local code, first, index = 0, 0, 0
        for len = 1, 15 do
            code = bor(code, band(bb, 1)); bb = rshift(bb, 1); bc = bc - 1
            local c = h.cnt[len]
            if code - c < first then return h.sym[index + (code - first)] end
            index = index + c
            first = lshift(first + c, 1); code = lshift(code, 1)
        end
        error("inflate: bad code")
    end
    local final
    repeat
        final = bits(1)
        local typ = bits(2)
        if typ == 0 then
            local drop = bc % 8
            bb = rshift(bb, drop); bc = bc - drop
            pos = pos - floor(bc / 8); bb, bc = 0, 0
            local len = inp[pos] + inp[pos + 1] * 256
            pos = pos + 4
            if pos + len > inlen then len = max(0, inlen - pos) end
            if op + len > cap then grow(len) end
            ffi.copy(out + op, inp + pos, len)
            op = op + len; pos = pos + len
        elseif typ == 3 then
            error("inflate: bad block")
        else
            local lit, dist
            if typ == 1 then lit, dist = getFixed()
            else
                local hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
                local cl = {}
                for i = 0, 18 do cl[i] = 0 end
                for i = 1, hclen do cl[clOrder[i]] = bits(3) end
                local clh = buildHuff(cl, 0, 19)
                local lens, i = {}, 0
                local total = hlit + hdist
                while i < total do
                    local s = decode(clh)
                    if s < 16 then lens[i] = s; i = i + 1
                    else
                        local rep, v = 0, 0
                        if s == 16 then v = lens[i - 1] or 0; rep = 3 + bits(2)
                        elseif s == 17 then rep = 3 + bits(3)
                        else rep = 11 + bits(7) end
                        for _ = 1, rep do if i < total then lens[i] = v; i = i + 1 end end
                    end
                end
                lit = buildHuff(lens, 0, hlit)
                dist = buildHuff(lens, hlit, hdist)
            end
            while true do
                local sym = decode(lit)
                if sym < 256 then
                    if op >= cap then grow(1) end
                    out[op] = sym; op = op + 1
                elseif sym == 256 then break
                else
                    sym = sym - 256
                    local len = lenBase[sym] + bits(lenExtra[sym])
                    local ds = decode(dist) + 1
                    local d = distBase[ds] + bits(distExtra[ds])
                    if d > op then error("inflate: bad distance") end
                    if op + len > cap then grow(len) end
                    local s = op - d
                    if d >= len then ffi.copy(out + op, out + s, len)
                    else for k = 0, len - 1 do out[op + k] = out[s + k] end end
                    op = op + len
                end
            end
        end
    until final == 1
    return out, op
end

function DR.inflateString(src, hint)
    local ok, buf, len = pcall(DR.inflate, src, hint)
    if not ok then return nil, buf end
    return ffi.string(buf, len)
end

function DR.zlib(src, hint)
    return DR.inflate(src:sub(3), hint)
end

-- ---------------------------------------------------------------- zip
function DR.zipOpen(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open" end
    local size = f:seek("end")
    local tail = min(size, 66000)
    f:seek("set", size - tail)
    local d = f:read(tail) or ""
    local last, p = nil, 1
    while true do
        local a = d:find("PK\5\6", p, true)
        if not a then break end
        last = a; p = a + 1
    end
    if not last or #d < last + 21 then f:close(); return nil, "not a zip file" end
    local count, cdsize, cdoff = u16(d, last + 10), u32(d, last + 12), u32(d, last + 16)
    if count == 0xFFFF or cdoff == 0xFFFFFFFF then f:close(); return nil, "zip64 not supported" end
    f:seek("set", cdoff)
    local cd = f:read(cdsize) or ""
    local z = { f = f, list = {}, map = {}, lmap = {}, path = path }
    local q = 1
    for _ = 1, count do
        if cd:sub(q, q + 3) ~= "PK\1\2" then break end
        local e = { flags = u16(cd, q + 8), method = u16(cd, q + 10), csize = u32(cd, q + 20), usize = u32(cd, q + 24), lho = u32(cd, q + 42) }
        local nl, el, cl = u16(cd, q + 28), u16(cd, q + 30), u16(cd, q + 32)
        e.name = cd:sub(q + 46, q + 45 + nl)
        q = q + 46 + nl + el + cl
        z.list[#z.list + 1] = e
        z.map[e.name] = e
        z.lmap[e.name:lower()] = e
    end
    function z:find(name)
        return self.map[name] or self.lmap[(name or ""):lower()]
    end
    function z:read(name)
        local e = type(name) == "table" and name or self:find(name)
        if not e then return nil, "missing entry" end
        self.f:seek("set", e.lho)
        local h = self.f:read(30)
        if not h or #h < 30 then return nil, "bad entry" end
        self.f:seek("set", e.lho + 30 + u16(h, 27) + u16(h, 29))
        local raw = self.f:read(e.csize) or ""
        if e.method == 0 then return raw end
        if e.method == 8 then return DR.inflateString(raw, e.usize) end
        return nil, "unsupported compression"
    end
    function z:close() if self.f then self.f:close(); self.f = nil end end
    return z
end

-- ---------------------------------------------------------------- PNG
local function unfilter(buf, off, rb, rows, bpp)
    local stride = rb + 1
    for y = 0, rows - 1 do
        local ro = off + y * stride
        local ft = buf[ro]
        local cur = ro + 1
        local prev = y > 0 and (ro - stride + 1) or nil
        if ft == 1 then
            for i = bpp, rb - 1 do buf[cur + i] = band(buf[cur + i] + buf[cur + i - bpp], 255) end
        elseif ft == 2 then
            if prev then for i = 0, rb - 1 do buf[cur + i] = band(buf[cur + i] + buf[prev + i], 255) end end
        elseif ft == 3 then
            for i = 0, rb - 1 do
                local a = i >= bpp and buf[cur + i - bpp] or 0
                local b = prev and buf[prev + i] or 0
                buf[cur + i] = band(buf[cur + i] + rshift(a + b, 1), 255)
            end
        elseif ft == 4 then
            for i = 0, rb - 1 do
                local a = i >= bpp and buf[cur + i - bpp] or 0
                local b = prev and buf[prev + i] or 0
                local c = (prev and i >= bpp) and buf[prev + i - bpp] or 0
                local p = a + b - c
                local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
                local pr
                if pa <= pb and pa <= pc then pr = a elseif pb <= pc then pr = b else pr = c end
                buf[cur + i] = band(buf[cur + i] + pr, 255)
            end
        end
    end
end

function DR.pngInfo(d)
    if d:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    return u32b(d, 17), u32b(d, 21)
end

function DR.decodePNG(d)
    if d:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "not a png" end
    local p, w, h, depth, ctype, inter, plte, trns = 9, 0, 0, 8, 2, 0, nil, nil
    local idat = {}
    while p <= #d - 11 do
        local len = u32b(d, p)
        local typ = d:sub(p + 4, p + 7)
        if typ == "IHDR" then
            w, h, depth, ctype, inter = u32b(d, p + 8), u32b(d, p + 12), d:byte(p + 16), d:byte(p + 17), d:byte(p + 20)
        elseif typ == "PLTE" then plte = d:sub(p + 8, p + 7 + len)
        elseif typ == "tRNS" then trns = d:sub(p + 8, p + 7 + len)
        elseif typ == "IDAT" then idat[#idat + 1] = d:sub(p + 8, p + 7 + len)
        elseif typ == "IEND" then break end
        p = p + 12 + len
    end
    if w <= 0 or h <= 0 or #idat == 0 then return nil, "bad png" end
    if w * h > 40000000 then return nil, "image too large" end
    local chan = ({ [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 })[ctype]
    if not chan then return nil, "bad png color type" end
    local bppbits = chan * depth
    local bpp = max(1, floor((bppbits + 7) / 8))
    local passes
    if inter == 1 then
        passes = { { 0, 0, 8, 8 }, { 4, 0, 8, 8 }, { 0, 4, 4, 8 }, { 2, 0, 4, 4 }, { 0, 2, 2, 4 }, { 1, 0, 2, 2 }, { 0, 1, 1, 2 } }
    else passes = { { 0, 0, 1, 1 } } end
    local expect = 0
    local dims = {}
    for i, ps in ipairs(passes) do
        local pw = floor((w - ps[1] + ps[3] - 1) / ps[3])
        local ph = floor((h - ps[2] + ps[4] - 1) / ps[4])
        if w <= ps[1] or h <= ps[2] then pw, ph = 0, 0 end
        local rb = ceil(pw * bppbits / 8)
        dims[i] = { pw, ph, rb, expect }
        if pw > 0 and ph > 0 then expect = expect + (rb + 1) * ph end
    end
    local buf = DR.zlib(table.concat(idat), expect)
    local comps = (ctype == 0 or ctype == 4) and 1 or 3
    local px = ffi.new("uint8_t[?]", w * h * comps)
    if comps == 1 then ffi.fill(px, w * h, 255) end
    local maxv = lshift(1, depth) - 1
    local scale = ctype == 3 and 1 or 255 / maxv
    local tr0, tr1, tr2
    if trns and ctype == 0 and #trns >= 2 then tr0 = u16b(trns, 1) end
    if trns and ctype == 2 and #trns >= 6 then tr0, tr1, tr2 = u16b(trns, 1), u16b(trns, 3), u16b(trns, 5) end
    local pal = {}
    if plte then
        for i = 0, floor(#plte / 3) - 1 do
            local a = trns and ctype == 3 and trns:byte(i + 1) or 255
            local r, g, b = plte:byte(i * 3 + 1, i * 3 + 3)
            pal[i] = { (r * a + 255 * (255 - a)) / 255, (g * a + 255 * (255 - a)) / 255, (b * a + 255 * (255 - a)) / 255 }
        end
    end
    local sm = ffi.new("int32_t[?]", w * chan + 8)
    for i, ps in ipairs(passes) do
        local pw, ph, rb, off = dims[i][1], dims[i][2], dims[i][3], dims[i][4]
        if pw > 0 and ph > 0 then
            unfilter(buf, off, rb, ph, bpp)
            for y = 0, ph - 1 do
                local ro = off + y * (rb + 1) + 1
                local n = pw * chan
                if depth == 8 then for k = 0, n - 1 do sm[k] = buf[ro + k] end
                elseif depth == 16 then for k = 0, n - 1 do sm[k] = buf[ro + k * 2] * 256 + buf[ro + k * 2 + 1] end
                else
                    local per = 8 / depth
                    for k = 0, n - 1 do
                        local byte = buf[ro + floor(k / per)]
                        local sh = 8 - depth - (k % per) * depth
                        sm[k] = band(rshift(byte, sh), maxv)
                    end
                end
                local dy = ps[2] + (y) * ps[4]
                for k = 0, pw - 1 do
                    local dx = ps[1] + k * ps[3]
                    local o = dy * w + dx
                    if ctype == 0 then
                        local v = sm[k]
                        if tr0 and v == tr0 then px[o] = 255 else px[o] = floor(v * (depth == 16 and 255 / 65535 or scale) + 0.5) end
                    elseif ctype == 4 then
                        local v = sm[k * 2] * (depth == 16 and 255 / 65535 or scale)
                        local a = sm[k * 2 + 1] * (depth == 16 and 255 / 65535 or scale)
                        px[o] = floor((v * a + 255 * (255 - a)) / 255 + 0.5)
                    elseif ctype == 3 then
                        local c = pal[sm[k]] or { 0, 0, 0 }
                        o = o * 3
                        px[o], px[o + 1], px[o + 2] = c[1], c[2], c[3]
                    else
                        local sc = depth == 16 and 255 / 65535 or scale
                        local r, g, b, a
                        if ctype == 2 then
                            r, g, b = sm[k * 3], sm[k * 3 + 1], sm[k * 3 + 2]
                            a = (tr0 and r == tr0 and g == tr1 and b == tr2) and 0 or 255
                            r, g, b = r * sc, g * sc, b * sc
                        else
                            r, g, b, a = sm[k * 4] * sc, sm[k * 4 + 1] * sc, sm[k * 4 + 2] * sc, sm[k * 4 + 3] * sc
                        end
                        if a < 255 then
                            r = (r * a + 255 * (255 - a)) / 255; g = (g * a + 255 * (255 - a)) / 255; b = (b * a + 255 * (255 - a)) / 255
                        end
                        o = o * 3
                        px[o], px[o + 1], px[o + 2] = floor(r + 0.5), floor(g + 0.5), floor(b + 0.5)
                    end
                end
            end
        end
    end
    return { w = w, h = h, comps = comps, data = px }
end

-- ---------------------------------------------------------------- JPEG
local zz = { [0] = 0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63 }
local aan = { [0] = 1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379 }

local idctM = {}
for _, n in ipairs({ 1, 2, 4, 8 }) do
    local m = {}
    for x = 0, n - 1 do
        for u = 0, n - 1 do
            local c = u == 0 and 0.70710678118 or 1
            m[x * n + u] = 0.5 * c * math.cos((2 * x + 1) * u * math.pi / (2 * n))
        end
    end
    idctM[n] = m
end

function DR.jpegInfo(d)
    if d:byte(1) ~= 0xFF or d:byte(2) ~= 0xD8 then return nil end
    local p = 3
    while p < #d - 8 do
        if d:byte(p) ~= 0xFF then p = p + 1
        else
            local m = d:byte(p + 1)
            if m == 0xFF then p = p + 1
            elseif m == 0 or m == 1 or (m >= 0xD0 and m <= 0xD8) then p = p + 2
            elseif m == 0xD9 or m == 0xDA then return nil
            else
                if (m >= 0xC0 and m <= 0xCF) and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
                    return u16b(d, p + 7), u16b(d, p + 5)
                end
                p = p + 2 + u16b(d, p + 2)
            end
        end
    end
end

local clampT = ffi.new("uint8_t[1024]")
for i = 0, 1023 do local v = i - 384; clampT[i] = v < 0 and 0 or (v > 255 and 255 or v) end

function DR.decodeJPEG(data, want)
    local p = ffi.cast("const uint8_t*", data)
    local n = #data
    if n < 4 or p[0] ~= 0xFF or p[1] ~= 0xD8 then return nil, "not a jpeg" end
    local qt, hts, comps = {}, {}, nil
    local W, H, progressive, ri, adobe = 0, 0, false, 0, nil
    local hmax, vmax, mcusX, mcusY, nb = 1, 1, 0, 0, 8
    local cf = ffi.new("double[64]")
    local ws = ffi.new("double[64]")
    local tmp = ffi.new("double[64]")
    local ip = 2
    local bb, bc, hit = 0, 0, false
    local eobrun = 0

    local function fillBits(need)
        while bc < need do
            local b = 0
            if not hit and ip < n then
                b = p[ip]
                if b == 0xFF then
                    local b2 = (ip + 1 < n) and p[ip + 1] or 0xD9
                    if b2 == 0 then ip = ip + 2 else b = 0; hit = true end
                else ip = ip + 1 end
            end
            bb = bor(lshift(bb, 8), b); bc = bc + 8
        end
    end
    local function readBits(k)
        if k == 0 then return 0 end
        fillBits(k)
        bc = bc - k
        return band(rshift(bb, bc), lshift(1, k) - 1)
    end
    local function receiveExtend(s)
        if s == 0 then return 0 end
        local v = readBits(s)
        if v < lshift(1, s - 1) then return v - lshift(1, s) + 1 end
        return v
    end
    local function decodeH(t)
        fillBits(16)
        local e = t.look[band(rshift(bb, bc - 9), 511)]
        if e ~= 0 then
            bc = bc - rshift(e, 8)
            return band(e, 255)
        end
        for len = 10, 16 do
            local code = band(rshift(bb, bc - len), lshift(1, len) - 1)
            if code <= t.maxcode[len] then
                bc = bc - len
                return t.vals[t.valptr[len] + code - t.mincode[len]]
            end
        end
        error("jpeg: bad huffman code")
    end
    local function buildTable(counts, vals)
        local t = { look = ffi.new("int16_t[512]"), maxcode = {}, mincode = {}, valptr = {}, vals = vals }
        local code, k = 0, 0
        for l = 1, 16 do
            local c = counts[l]
            t.valptr[l] = k; t.mincode[l] = code
            for _ = 1, c do
                if l <= 9 then
                    local base = lshift(code, 9 - l)
                    for j = 0, lshift(1, 9 - l) - 1 do t.look[base + j] = l * 256 + vals[k] end
                end
                code = code + 1; k = k + 1
            end
            t.maxcode[l] = c > 0 and (code - 1) or -1
            code = lshift(code, 1)
        end
        return t
    end

    local function idctBlock(comp, plane, off, stride, dcOnly)
        local nn = nb
        if nn == 8 then
            if dcOnly then
                local v = floor(cf[0] * 0.125 + 128.5)
                v = v < 0 and 0 or (v > 255 and 255 or v)
                for y = 0, 7 do ffi.fill(plane + off + y * stride, 8, v) end
                return
            end
            for c = 0, 7 do
                local t0, t1, t2, t3 = cf[c], cf[16 + c], cf[32 + c], cf[48 + c]
                local t10, t11 = t0 + t2, t0 - t2
                local t13 = t1 + t3
                local t12 = (t1 - t3) * 1.414213562 - t13
                t0, t3, t1, t2 = t10 + t13, t10 - t13, t11 + t12, t11 - t12
                local t4, t5, t6, t7 = cf[8 + c], cf[24 + c], cf[40 + c], cf[56 + c]
                local z13, z10, z11, z12 = t6 + t5, t6 - t5, t4 + t7, t4 - t7
                t7 = z11 + z13
                t11 = (z11 - z13) * 1.414213562
                local z5 = (z10 + z12) * 1.847759065
                t10 = 1.082392200 * z12 - z5
                t12 = -2.613125930 * z10 + z5
                t6 = t12 - t7; t5 = t11 - t6; t4 = t10 + t5
                ws[c], ws[56 + c], ws[8 + c], ws[48 + c] = t0 + t7, t0 - t7, t1 + t6, t1 - t6
                ws[16 + c], ws[40 + c], ws[32 + c], ws[24 + c] = t2 + t5, t2 - t5, t3 + t4, t3 - t4
            end
            for r = 0, 7 do
                local o = r * 8
                local t0, t1, t2, t3 = ws[o], ws[o + 2], ws[o + 4], ws[o + 6]
                local t10, t11 = t0 + t2, t0 - t2
                local t13 = t1 + t3
                local t12 = (t1 - t3) * 1.414213562 - t13
                t0, t3, t1, t2 = t10 + t13, t10 - t13, t11 + t12, t11 - t12
                local t4, t5, t6, t7 = ws[o + 1], ws[o + 3], ws[o + 5], ws[o + 7]
                local z13, z10, z11, z12 = t6 + t5, t6 - t5, t4 + t7, t4 - t7
                t7 = z11 + z13
                t11 = (z11 - z13) * 1.414213562
                local z5 = (z10 + z12) * 1.847759065
                t10 = 1.082392200 * z12 - z5
                t12 = -2.613125930 * z10 + z5
                t6 = t12 - t7; t5 = t11 - t6; t4 = t10 + t5
                local po = off + r * stride
                local function put(i, v)
                    local iv = floor(v * 0.125 + 128.5)
                    plane[po + i] = iv < 0 and 0 or (iv > 255 and 255 or iv)
                end
                put(0, t0 + t7); put(7, t0 - t7); put(1, t1 + t6); put(6, t1 - t6)
                put(2, t2 + t5); put(5, t2 - t5); put(4, t3 + t4); put(3, t3 - t4)
            end
        else
            local M = idctM[nn]
            for v = 0, nn - 1 do
                for x = 0, nn - 1 do
                    local s = 0
                    for u = 0, nn - 1 do s = s + cf[v * 8 + u] * M[x * nn + u] end
                    tmp[v * nn + x] = s
                end
            end
            for y = 0, nn - 1 do
                for x = 0, nn - 1 do
                    local s = 0
                    for v = 0, nn - 1 do s = s + tmp[v * nn + x] * M[y * nn + v] end
                    local iv = floor(s + 128.5)
                    plane[off + y * stride + x] = iv < 0 and 0 or (iv > 255 and 255 or iv)
                end
            end
        end
    end

    local function resync()
        bb, bc, hit = 0, 0, false
        while ip < n - 1 and not (p[ip] == 0xFF and p[ip + 1] >= 0xD0 and p[ip + 1] <= 0xD7) do ip = ip + 1 end
        ip = ip + 2
    end

    local function setupFrame()
        hmax, vmax = 1, 1
        for _, c in ipairs(comps) do hmax = max(hmax, c.h); vmax = max(vmax, c.v) end
        mcusX, mcusY = ceil(W / (8 * hmax)), ceil(H / (8 * vmax))
        nb = 8
        want = want or W
        for _, k in ipairs({ 1, 2, 4, 8 }) do if ceil(W * k / 8) >= want then nb = k; break end end
        local mem = 0
        for _, c in ipairs(comps) do
            c.bw, c.bh = mcusX * c.h, mcusY * c.v
            if progressive then mem = mem + c.bw * c.bh * 128 else mem = mem + c.bw * c.bh * nb * nb end
        end
        if mem > 110 * 1024 * 1024 then error("jpeg: image too large") end
        for _, c in ipairs(comps) do
            local q = qt[c.tq]
            if not q then error("jpeg: missing quant table") end
            c.q = {}
            for z = 0, 63 do
                if nb == 8 then c.q[z] = q[z] * aan[floor(z / 8)] * aan[z % 8] else c.q[z] = q[z] end
            end
            if progressive then c.coef = ffi.new("int16_t[?]", c.bw * c.bh * 64)
            else c.plane = ffi.new("uint8_t[?]", c.bw * nb * c.bh * nb) end
        end
    end

    local function decodeScan(sc, Ss, Se, Ah, Al)
        eobrun = 0
        for _, s in ipairs(sc) do s.c.pred = 0 end
        local mcuCount = 0
        local function blockBaseline(s, bx, by)
            local c = s.c
            ffi.fill(cf, 512)
            local t = decodeH(s.dc)
            c.pred = c.pred + (t == 0 and 0 or receiveExtend(t))
            cf[0] = c.pred * c.q[0]
            local k, dcOnly = 1, true
            while k < 64 do
                local rs = decodeH(s.ac)
                local sz, r = band(rs, 15), rshift(rs, 4)
                if sz == 0 then
                    if r < 15 then break end
                    k = k + 16
                else
                    k = k + r
                    if k > 63 then break end
                    local z = zz[k]
                    cf[z] = receiveExtend(sz) * c.q[z]
                    dcOnly = false
                    k = k + 1
                end
            end
            idctBlock(c, c.plane, by * nb * c.bw * nb + bx * nb, c.bw * nb, dcOnly and nb == 8)
        end
        local function blockProg(s, bx, by)
            local c = s.c
            local co = (by * c.bw + bx) * 64
            local coef = c.coef
            if Ss == 0 then
                if Ah == 0 then
                    local t = decodeH(s.dc)
                    c.pred = c.pred + (t == 0 and 0 or receiveExtend(t))
                    coef[co] = c.pred * lshift(1, Al)
                else
                    if readBits(1) == 1 then coef[co] = bor(coef[co], lshift(1, Al)) end
                end
            elseif Ah == 0 then
                if eobrun > 0 then eobrun = eobrun - 1; return end
                local k = Ss
                while k <= Se do
                    local rs = decodeH(s.ac)
                    local sz, r = band(rs, 15), rshift(rs, 4)
                    if sz == 0 then
                        if r < 15 then eobrun = readBits(r) + lshift(1, r) - 1; break end
                        k = k + 16
                    else
                        k = k + r
                        if k > 63 then break end
                        coef[co + zz[k]] = receiveExtend(sz) * lshift(1, Al)
                        k = k + 1
                    end
                end
            else
                local p1, m1 = lshift(1, Al), -lshift(1, Al)
                local k = Ss
                if eobrun <= 0 then
                    while k <= Se do
                        local rs = decodeH(s.ac)
                        local sz, r = band(rs, 15), rshift(rs, 4)
                        local val = 0
                        if sz == 0 then
                            if r < 15 then eobrun = lshift(1, r) + readBits(r); break end
                        else
                            val = readBits(1) == 1 and p1 or m1
                        end
                        repeat
                            local z = co + zz[k]
                            if coef[z] ~= 0 then
                                if readBits(1) == 1 then
                                    if band(coef[z], p1) == 0 then
                                        if coef[z] >= 0 then coef[z] = coef[z] + p1 else coef[z] = coef[z] + m1 end
                                    end
                                end
                            else
                                r = r - 1
                                if r < 0 then break end
                            end
                            k = k + 1
                        until k > Se
                        if val ~= 0 and k <= 63 then coef[co + zz[k]] = val end
                        k = k + 1
                    end
                end
                if eobrun > 0 then
                    while k <= Se do
                        local z = co + zz[k]
                        if coef[z] ~= 0 then
                            if readBits(1) == 1 then
                                if band(coef[z], p1) == 0 then
                                    if coef[z] >= 0 then coef[z] = coef[z] + p1 else coef[z] = coef[z] + m1 end
                                end
                            end
                        end
                        k = k + 1
                    end
                    eobrun = eobrun - 1
                end
            end
        end
        local blk = progressive and blockProg or blockBaseline
        local function restartCheck(total)
            mcuCount = mcuCount + 1
            if ri > 0 and mcuCount % ri == 0 and mcuCount < total then
                resync()
                eobrun = 0
                for _, s in ipairs(sc) do s.c.pred = 0 end
            end
        end
        if #sc > 1 then
            local total = mcusX * mcusY
            for my = 0, mcusY - 1 do
                for mx = 0, mcusX - 1 do
                    for _, s in ipairs(sc) do
                        local c = s.c
                        for v = 0, c.v - 1 do
                            for h = 0, c.h - 1 do blk(s, mx * c.h + h, my * c.v + v) end
                        end
                    end
                    restartCheck(total)
                end
            end
        else
            local s = sc[1]
            local c = s.c
            local bw = ceil(ceil(W * c.h / hmax) / 8)
            local bh = ceil(ceil(H * c.v / vmax) / 8)
            local total = bw * bh
            for by = 0, bh - 1 do
                for bx = 0, bw - 1 do
                    blk(s, bx, by)
                    restartCheck(total)
                end
            end
        end
        bb, bc, hit = 0, 0, false
    end

    local nscans = 0
    while ip < n - 1 do
        if p[ip] ~= 0xFF then ip = ip + 1
        else
            local m = p[ip + 1]
            if m == 0xFF then ip = ip + 1
            elseif m == 0 or m == 1 or (m >= 0xD0 and m <= 0xD8) then ip = ip + 2
            elseif m == 0xD9 then break
            else
                local len = p[ip + 2] * 256 + p[ip + 3]
                local s0, s1 = ip + 4, ip + 2 + len
                ip = s1
                if m == 0xDB then
                    local q = s0
                    while q < s1 do
                        local pq, tq = rshift(p[q], 4), band(p[q], 15)
                        q = q + 1
                        local t = {}
                        for k = 0, 63 do
                            if pq == 0 then t[zz[k]] = p[q]; q = q + 1
                            else t[zz[k]] = p[q] * 256 + p[q + 1]; q = q + 2 end
                        end
                        qt[tq] = t
                    end
                elseif m == 0xC4 then
                    local q = s0
                    while q < s1 do
                        local tc, th = rshift(p[q], 4), band(p[q], 15)
                        q = q + 1
                        local counts, total = {}, 0
                        for l = 1, 16 do counts[l] = p[q + l - 1]; total = total + counts[l] end
                        q = q + 16
                        local vals = {}
                        for k = 0, total - 1 do vals[k] = p[q + k] end
                        q = q + total
                        hts[tc * 4 + th] = buildTable(counts, vals)
                    end
                elseif m == 0xC0 or m == 0xC1 or m == 0xC2 then
                    if p[s0] ~= 8 then return nil, "jpeg: only 8-bit supported" end
                    progressive = (m == 0xC2)
                    H, W = p[s0 + 1] * 256 + p[s0 + 2], p[s0 + 3] * 256 + p[s0 + 4]
                    local nc = p[s0 + 5]
                    comps = {}
                    for i = 0, nc - 1 do
                        local q = s0 + 6 + i * 3
                        comps[i + 1] = { id = p[q], h = rshift(p[q + 1], 4), v = band(p[q + 1], 15), tq = p[q + 2] }
                    end
                    if W <= 0 or H <= 0 or (nc ~= 1 and nc ~= 3 and nc ~= 4) then return nil, "jpeg: unsupported layout" end
                elseif m == 0xC3 or (m >= 0xC5 and m <= 0xCF and m ~= 0xC8 and m ~= 0xCC) then
                    return nil, "jpeg: unsupported coding"
                elseif m == 0xDD then ri = p[s0] * 256 + p[s0 + 1]
                elseif m == 0xEE and len >= 14 and p[s0] == 65 and p[s0 + 1] == 100 then adobe = p[s0 + 11]
                elseif m == 0xDA then
                    if not comps then return nil, "jpeg: scan before frame" end
                    if not comps[1].plane and not comps[1].coef then setupFrame() end
                    local ns = p[s0]
                    local sc = {}
                    for j = 0, ns - 1 do
                        local cid, tt = p[s0 + 1 + j * 2], p[s0 + 2 + j * 2]
                        for _, c in ipairs(comps) do
                            if c.id == cid then sc[#sc + 1] = { c = c, dc = hts[rshift(tt, 4)], ac = hts[4 + band(tt, 15)] } end
                        end
                    end
                    local Ss, Se, AhAl = p[s0 + 1 + ns * 2], p[s0 + 2 + ns * 2], p[s0 + 3 + ns * 2]
                    local ok, err = pcall(decodeScan, sc, Ss, Se, rshift(AhAl, 4), band(AhAl, 15))
                    nscans = nscans + 1
                    if not ok then
                        if nscans == 1 and not progressive then return nil, tostring(err) end
                        break
                    end
                end
            end
        end
    end
    if not comps or not (comps[1].plane or comps[1].coef) then return nil, "jpeg: no image data" end
    if progressive then
        for _, c in ipairs(comps) do
            c.plane = ffi.new("uint8_t[?]", c.bw * nb * c.bh * nb)
            local stride = c.bw * nb
            for by = 0, c.bh - 1 do
                for bx = 0, c.bw - 1 do
                    local co = (by * c.bw + bx) * 64
                    for z = 0, 63 do cf[z] = c.coef[co + z] * c.q[z] end
                    idctBlock(c, c.plane, by * nb * stride + bx * nb, stride, false)
                end
            end
            c.coef = nil
        end
    end
    -- assemble
    local ow, oh = ceil(W * nb / 8), ceil(H * nb / 8)
    local nc = #comps
    local outc = nc == 1 and 1 or 3
    local out = ffi.new("uint8_t[?]", ow * oh * outc)
    local xm = {}
    for i, c in ipairs(comps) do
        local m = ffi.new("int32_t[?]", ow)
        for x = 0, ow - 1 do m[x] = min(floor(x * c.h / hmax), c.bw * nb - 1) end
        xm[i] = m
    end
    local function rowOf(c, y) return min(floor(y * c.v / vmax), c.bh * nb - 1) * c.bw * nb end
    if nc == 1 then
        local c = comps[1]
        for y = 0, oh - 1 do
            local ro = rowOf(c, y)
            for x = 0, ow - 1 do out[y * ow + x] = c.plane[ro + xm[1][x]] end
        end
    else
        local crR, cbB, crG, cbG = {}, {}, {}, {}
        for i = 0, 255 do
            crR[i] = floor(1.402 * (i - 128) + 0.5); cbB[i] = floor(1.772 * (i - 128) + 0.5)
            crG[i] = -0.714136 * (i - 128); cbG[i] = -0.344136 * (i - 128)
        end
        local isRGB = (adobe == 0 and nc == 3) or (nc == 4 and adobe ~= 2) or (nc == 3 and comps[1].id == 82 and comps[2].id == 71 and comps[3].id == 66)
        local c1, c2, c3, c4 = comps[1], comps[2], comps[3], comps[4]
        local x1, x2, x3, x4 = xm[1], xm[2], xm[3], xm[4]
        for y = 0, oh - 1 do
            local r1, r2, r3 = rowOf(c1, y), rowOf(c2, y), rowOf(c3, y)
            local r4 = c4 and rowOf(c4, y)
            local o = y * ow * 3
            for x = 0, ow - 1 do
                local a, b, c = c1.plane[r1 + x1[x]], c2.plane[r2 + x2[x]], c3.plane[r3 + x3[x]]
                local r, g, bl
                if isRGB then r, g, bl = a, b, c
                else
                    r = a + crR[c]; g = floor(a + cbG[b] + crG[c] + 0.5); bl = a + cbB[b]
                    r = clampT[max(0, min(1023, r + 384))]; g = clampT[max(0, min(1023, g + 384))]; bl = clampT[max(0, min(1023, bl + 384))]
                end
                if c4 then
                    local k = c4.plane[r4 + x4[x]]
                    r, g, bl = floor(r * k / 255), floor(g * k / 255), floor(bl * k / 255)
                end
                out[o], out[o + 1], out[o + 2] = r, g, bl
                o = o + 3
            end
        end
    end
    return { w = ow, h = oh, comps = outc, data = out, srcw = W, srch = H }
end

-- ---------------------------------------------------------------- GIF
function DR.gifInfo(d)
    if d:sub(1, 3) ~= "GIF" then return nil end
    return u16(d, 7), u16(d, 9)
end

function DR.decodeGIF(d)
    if d:sub(1, 3) ~= "GIF" then return nil, "not a gif" end
    local W, H = u16(d, 7), u16(d, 9)
    local flags = d:byte(11)
    local p = 14
    local gpal
    if band(flags, 0x80) ~= 0 then
        local sz = 3 * lshift(1, band(flags, 7) + 1)
        gpal = d:sub(p, p + sz - 1); p = p + sz
    end
    local trans
    while p <= #d do
        local b = d:byte(p)
        if b == 0x21 then
            local label = d:byte(p + 1)
            if label == 0xF9 and d:byte(p + 2) >= 4 then
                if band(d:byte(p + 3), 1) == 1 then trans = d:byte(p + 6) end
            end
            p = p + 2
            while true do local l = d:byte(p); p = p + 1 + l; if l == 0 then break end end
        elseif b == 0x2C then
            local ix, iy, iw, ih, fl = u16(d, p + 1), u16(d, p + 3), u16(d, p + 5), u16(d, p + 7), d:byte(p + 9)
            p = p + 10
            local pal = gpal
            if band(fl, 0x80) ~= 0 then
                local sz = 3 * lshift(1, band(fl, 7) + 1)
                pal = d:sub(p, p + sz - 1); p = p + sz
            end
            if not pal then return nil, "gif: no palette" end
            local minc = d:byte(p); p = p + 1
            local chunks = {}
            while true do
                local l = d:byte(p)
                if not l or l == 0 then break end
                chunks[#chunks + 1] = d:sub(p + 1, p + l); p = p + 1 + l
            end
            local s = table.concat(chunks)
            local px = ffi.new("uint8_t[?]", W * H * 3)
            ffi.fill(px, W * H * 3, 255)
            local clear = lshift(1, minc)
            local eoi = clear + 1
            local csize, nextc = minc + 1, clear + 2
            local prefix, suffix, stack = {}, {}, {}
            local old, first = -1, 0
            local bitb, bitn, sp = 0, 0, 1
            local x, y, pass, step = 0, 0, 0, 8
            local interlaced = band(fl, 0x40) ~= 0
            local function put(code)
                if y < ih then
                    local gx, gy = ix + x, iy + y
                    if code ~= trans and gx < W and gy < H then
                        local o = (gy * W + gx) * 3
                        local q = code * 3 + 1
                        px[o], px[o + 1], px[o + 2] = pal:byte(q) or 0, pal:byte(q + 1) or 0, pal:byte(q + 2) or 0
                    end
                end
                x = x + 1
                if x >= iw then
                    x = 0
                    if interlaced then
                        y = y + step
                        if y >= ih then
                            pass = pass + 1
                            if pass == 1 then y, step = 4, 8 elseif pass == 2 then y, step = 2, 4 else y, step = 1, 2 end
                        end
                    else y = y + 1 end
                end
            end
            while sp <= #s do
                while bitn < csize and sp <= #s do bitb = bitb + s:byte(sp) * lshift(1, bitn); bitn = bitn + 8; sp = sp + 1 end
                if bitn < csize then break end
                local code = band(bitb, lshift(1, csize) - 1)
                bitb = floor(bitb / lshift(1, csize)); bitn = bitn - csize
                if code == clear then csize, nextc, old = minc + 1, clear + 2, -1
                elseif code == eoi then break
                else
                    local incode = code
                    local top = 0
                    if old == -1 then first = code; put(code); old = code
                    else
                        if code >= nextc then top = top + 1; stack[top] = first; code = old end
                        while code >= clear do top = top + 1; stack[top] = suffix[code]; code = prefix[code] end
                        first = code
                        top = top + 1; stack[top] = first
                        for i = top, 1, -1 do put(stack[i]) end
                        if nextc < 4096 then
                            prefix[nextc], suffix[nextc] = old, first
                            nextc = nextc + 1
                            if nextc >= lshift(1, csize) and csize < 12 then csize = csize + 1 end
                        end
                        old = incode
                    end
                end
            end
            return { w = W, h = H, comps = 3, data = px }
        elseif b == 0x3B then break
        else p = p + 1 end
    end
    return nil, "gif: no image"
end

-- ---------------------------------------------------------------- BMP
function DR.bmpInfo(d)
    if d:sub(1, 2) ~= "BM" then return nil end
    local w, h = u32(d, 19), u32(d, 23)
    if w >= 0x80000000 then w = 4294967296 - w end
    if h >= 0x80000000 then h = 4294967296 - h end
    return w, h
end

function DR.decodeBMP(d)
    if d:sub(1, 2) ~= "BM" or #d < 54 then return nil, "not a bmp" end
    local off, hs = u32(d, 11), u32(d, 15)
    local w, h, bpp, comp = u32(d, 19), u32(d, 23), u16(d, 29), u32(d, 31)
    if w >= 0x80000000 then w = w - 4294967296 end
    if h >= 0x80000000 then h = h - 4294967296 end
    local top = h < 0
    h = math.abs(h)
    if w <= 0 or h <= 0 or w * h > 40000000 then return nil, "bmp: bad size" end
    if comp ~= 0 and comp ~= 3 then return nil, "bmp: compressed bmp not supported" end
    local pal = {}
    if bpp <= 8 then
        local n = u32(d, 47)
        if n == 0 then n = lshift(1, bpp) end
        local q = 15 + hs
        for i = 0, n - 1 do pal[i] = { d:byte(q + i * 4 + 2), d:byte(q + i * 4 + 1), d:byte(q + i * 4) } end
    end
    local masks
    if bpp == 16 or bpp == 32 then
        if comp == 3 then masks = { u32(d, 15 + hs), u32(d, 19 + hs), u32(d, 23 + hs) }
        elseif bpp == 16 then masks = { 0x7C00, 0x03E0, 0x001F } else masks = { 0xFF0000, 0xFF00, 0xFF } end
    end
    local px = ffi.new("uint8_t[?]", w * h * 3)
    local rb = floor((w * bpp + 31) / 32) * 4
    local function ext(v, m)
        if m == 0 then return 0 end
        local sh = 0
        while band(m, 1) == 0 do m = rshift(m, 1); sh = sh + 1 end
        return floor(band(rshift(v, sh), m) * 255 / m)
    end
    for y = 0, h - 1 do
        local sy = top and y or (h - 1 - y)
        local ro = off + sy * rb + 1
        for x = 0, w - 1 do
            local r, g, b
            if bpp == 24 then b, g, r = d:byte(ro + x * 3, ro + x * 3 + 2)
            elseif bpp == 32 then
                local v = u32(d, ro + x * 4)
                r, g, b = ext(v, masks[1]), ext(v, masks[2]), ext(v, masks[3])
            elseif bpp == 16 then
                local v = u16(d, ro + x * 2)
                r, g, b = ext(v, masks[1]), ext(v, masks[2]), ext(v, masks[3])
            else
                local idx
                if bpp == 8 then idx = d:byte(ro + x)
                else
                    local per = 8 / bpp
                    local byte = d:byte(ro + floor(x / per))
                    idx = band(rshift(byte, 8 - bpp - (x % per) * bpp), lshift(1, bpp) - 1)
                end
                local c = pal[idx] or { 0, 0, 0 }
                r, g, b = c[1], c[2], c[3]
            end
            local o = (y * w + x) * 3
            px[o], px[o + 1], px[o + 2] = r or 0, g or 0, b or 0
        end
    end
    return { w = w, h = h, comps = 3, data = px }
end

-- ---------------------------------------------------------------- dispatch
function DR.imageSize(d)
    if not d or #d < 24 then return nil end
    local w, h = DR.pngInfo(d)
    if not w then w, h = DR.jpegInfo(d) end
    if not w then w, h = DR.gifInfo(d) end
    if not w then w, h = DR.bmpInfo(d) end
    return w, h
end

function DR.imageKind(d)
    if not d or #d < 12 then return nil end
    local a, b = d:byte(1, 2)
    if d:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if a == 0xFF and b == 0xD8 then return "jpeg" end
    if d:sub(1, 3) == "GIF" then return "gif" end
    if d:sub(1, 2) == "BM" then return "bmp" end
    if d:sub(1, 4) == "RIFF" and d:sub(9, 12) == "WEBP" then return "webp" end
    return nil
end

function DR.decodeImage(d, want)
    local k = DR.imageKind(d)
    if not k then return nil, "unknown image format" end
    if k == "webp" then return nil, "WebP is not supported" end
    local fn = k == "png" and DR.decodePNG or k == "jpeg" and function(x) return DR.decodeJPEG(x, want) end
        or k == "gif" and DR.decodeGIF or DR.decodeBMP
    local ok, img, err = pcall(fn, d)
    if not ok then return nil, tostring(img) end
    return img, err
end

-- Box-filter downscale / nearest upscale into a new RGB or gray buffer.
function DR.scale(img, tw, th)
    tw, th = max(1, floor(tw)), max(1, floor(th))
    local sw, sh, c = img.w, img.h, img.comps
    if sw == tw and sh == th then return img end
    local src = img.data
    local out = ffi.new("uint8_t[?]", tw * th * c)
    local fx, fy = sw / tw, sh / th
    local x0, x1 = ffi.new("int32_t[?]", tw), ffi.new("int32_t[?]", tw)
    for x = 0, tw - 1 do
        local a = floor(x * fx)
        local b = max(a + 1, floor((x + 1) * fx))
        x0[x], x1[x] = min(a, sw - 1), min(b, sw)
    end
    for y = 0, th - 1 do
        local ya = min(floor(y * fy), sh - 1)
        local yb = min(max(ya + 1, floor((y + 1) * fy)), sh)
        local oy = y * tw * c
        if c == 1 then
            for x = 0, tw - 1 do
                local s, cnt = 0, 0
                for yy = ya, yb - 1 do
                    local ro = yy * sw
                    for xx = x0[x], x1[x] - 1 do s = s + src[ro + xx] end
                end
                cnt = (yb - ya) * (x1[x] - x0[x])
                out[oy + x] = floor(s / cnt + 0.5)
            end
        else
            for x = 0, tw - 1 do
                local sr, sg, sb = 0, 0, 0
                local xa, xb = x0[x], x1[x]
                for yy = ya, yb - 1 do
                    local o = (yy * sw + xa) * 3
                    for _ = xa, xb - 1 do sr = sr + src[o]; sg = sg + src[o + 1]; sb = sb + src[o + 2]; o = o + 3 end
                end
                local cnt = (yb - ya) * (xb - xa)
                local o2 = oy + x * 3
                out[o2], out[o2 + 1], out[o2 + 2] = floor(sr / cnt + 0.5), floor(sg / cnt + 0.5), floor(sb / cnt + 0.5)
            end
        end
    end
    return { w = tw, h = th, comps = c, data = out }
end

-- Bounding box of the non-uniform area (trim blank borders), in source pixels.
function DR.contentBox(img)
    local w, h, c, d = img.w, img.h, img.comps, img.data
    local function lum(x, y)
        local o = (y * w + x) * c
        if c == 1 then return d[o] end
        return (d[o] * 3 + d[o + 1] * 6 + d[o + 2]) / 10
    end
    local ref = (lum(0, 0) + lum(w - 1, 0) + lum(0, h - 1) + lum(w - 1, h - 1)) / 4
    local stepx, stepy = max(1, floor(w / 300)), max(1, floor(h / 300))
    local thr = 28
    local function rowHas(y)
        for x = 0, w - 1, stepx do if math.abs(lum(x, y) - ref) > thr then return true end end
        return false
    end
    local function colHas(x)
        for y = 0, h - 1, stepy do if math.abs(lum(x, y) - ref) > thr then return true end end
        return false
    end
    local t, b, l, r = 0, h - 1, 0, w - 1
    while t < b and not rowHas(t) do t = t + 1 end
    while b > t and not rowHas(b) do b = b - 1 end
    while l < r and not colHas(l) do l = l + 1 end
    while r > l and not colHas(r) do r = r - 1 end
    if (r - l) < w * 0.3 or (b - t) < h * 0.3 then return 0, 0, w, h end
    local pad = max(2, floor(w * 0.01))
    l, t = max(0, l - pad), max(0, t - pad)
    r, b = min(w - 1, r + pad), min(h - 1, b + pad)
    return l, t, r - l + 1, b - t + 1
end

function DR.crop(img, x, y, w, h)
    if x == 0 and y == 0 and w == img.w and h == img.h then return img end
    local c = img.comps
    local out = ffi.new("uint8_t[?]", w * h * c)
    for yy = 0, h - 1 do ffi.copy(out + yy * w * c, img.data + ((y + yy) * img.w + x) * c, w * c) end
    return { w = w, h = h, comps = c, data = out }
end
end
-- ================================================================ DR markup: HTML/XML parser, CSS-lite, block conversion
do
local floor, max, min = math.floor, math.max, math.min

local function utf8enc(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64) end
    return string.char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end
DR.utf8enc = utf8enc

local ENT = {}
for pair in ([[amp:38,lt:60,gt:62,quot:34,apos:39,nbsp:160,iexcl:161,cent:162,pound:163,curren:164,yen:165,brvbar:166,sect:167,uml:168,copy:169,ordf:170,laquo:171,not:172,reg:174,macr:175,deg:176,plusmn:177,sup2:178,sup3:179,acute:180,micro:181,para:182,middot:183,cedil:184,sup1:185,ordm:186,raquo:187,frac14:188,frac12:189,frac34:190,iquest:191,Agrave:192,Aacute:193,Acirc:194,Atilde:195,Auml:196,Aring:197,AElig:198,Ccedil:199,Egrave:200,Eacute:201,Ecirc:202,Euml:203,Igrave:204,Iacute:205,Icirc:206,Iuml:207,ETH:208,Ntilde:209,Ograve:210,Oacute:211,Ocirc:212,Otilde:213,Ouml:214,times:215,Oslash:216,Ugrave:217,Uacute:218,Ucirc:219,Uuml:220,Yacute:221,THORN:222,szlig:223,agrave:224,aacute:225,acirc:226,atilde:227,auml:228,aring:229,aelig:230,ccedil:231,egrave:232,eacute:233,ecirc:234,euml:235,igrave:236,iacute:237,icirc:238,iuml:239,eth:240,ntilde:241,ograve:242,oacute:243,ocirc:244,otilde:245,ouml:246,divide:247,oslash:248,ugrave:249,uacute:250,ucirc:251,uuml:252,yacute:253,thorn:254,yuml:255,OElig:338,oelig:339,Scaron:352,scaron:353,Yuml:376,Zcaron:381,zcaron:382,fnof:402,circ:710,tilde:732,ensp:8194,emsp:8195,thinsp:8201,zwnj:8204,zwj:8205,ndash:8211,mdash:8212,lsquo:8216,rsquo:8217,sbquo:8218,ldquo:8220,rdquo:8221,bdquo:8222,dagger:8224,Dagger:8225,bull:8226,hellip:8230,permil:8240,prime:8242,Prime:8243,lsaquo:8249,rsaquo:8250,euro:8364,trade:8482,larr:8592,uarr:8593,rarr:8594,darr:8595,minus:8722,ne:8800,le:8804,ge:8805,infin:8734,hearts:9829,shy:173]]):gmatch("[^,]+") do
    local k, v = pair:match("^(%w+):(%d+)$")
    ENT[k] = tonumber(v)
end

local function decodeEntities(s)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?[%w]+);", function(e)
        if e:sub(1, 1) == "#" then
            local cp
            if e:sub(2, 2) == "x" or e:sub(2, 2) == "X" then cp = tonumber(e:sub(3), 16) else cp = tonumber(e:sub(2)) end
            if cp and cp > 0 and cp < 0x110000 then return utf8enc(cp) end
            return ""
        end
        local cp = ENT[e]
        if cp then return utf8enc(cp) end
        return nil
    end))
end
DR.decodeEntities = decodeEntities

local VOID = { br = true, hr = true, img = true, meta = true, link = true, input = true, col = true, area = true, base = true, wbr = true, source = true, track = true, param = true, embed = true }
local RAW = { script = true, style = true }
local CLOSEP = { p = true, div = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, ul = true, ol = true, table = true, blockquote = true, pre = true, hr = true, dl = true, section = true, article = true, figure = true }

-- Tolerant HTML/XHTML/XML parser. Element: { tag, a = {attrs}, c = {children}, par }. Text: { t = string }.
function DR.parseHTML(s)
    local root = { tag = "#root", a = {}, c = {} }
    local cur = root
    local i, n = 1, #s
    local function addText(t)
        if t ~= "" then cur.c[#cur.c + 1] = { t = decodeEntities(t) } end
    end
    while i <= n do
        local lt = s:find("<", i, true)
        if not lt then addText(s:sub(i)); break end
        if lt > i then addText(s:sub(i, lt - 1)) end
        local c2 = s:sub(lt + 1, lt + 1)
        if s:sub(lt, lt + 3) == "<!--" then
            local e = s:find("-->", lt + 4, true)
            i = e and e + 3 or n + 1
        elseif s:sub(lt, lt + 8) == "<![CDATA[" then
            local e = s:find("]]>", lt + 9, true)
            local txt = s:sub(lt + 9, (e or n + 1) - 1)
            if txt ~= "" then cur.c[#cur.c + 1] = { t = txt } end
            i = e and e + 3 or n + 1
        elseif c2 == "!" or c2 == "?" then
            local e = s:find(">", lt, true)
            i = e and e + 1 or n + 1
        elseif c2 == "/" then
            local e = s:find(">", lt, true) or n
            local name = s:sub(lt + 2, e - 1):match("^%s*([%w:_%.%-]+)")
            i = e + 1
            if name then
                name = name:lower():gsub("^.*:", "")
                local node = cur
                while node and node.tag ~= name and node ~= root do node = node.par end
                if node and node ~= root then cur = node.par or root end
            end
        else
            -- opening tag: find end '>' honoring quotes
            local p = lt + 1
            local e
            while true do
                local q = s:find("[\"'>]", p)
                if not q then e = n; break end
                local ch = s:sub(q, q)
                if ch == ">" then e = q; break end
                local close = s:find(ch, q + 1, true)
                if not close then e = n; break end
                p = close + 1
            end
            local body = s:sub(lt + 1, e - 1)
            i = e + 1
            local selfclose = body:sub(-1) == "/"
            if selfclose then body = body:sub(1, -2) end
            local name = body:match("^([%w:_%.%-]+)")
            if name then
                name = name:lower():gsub("^.*:", "")
                local attrs = {}
                local rest = body:sub(#body:match("^[%w:_%.%-]+") + 1)
                if rest:find("=", 1, true) then
                    for k, v in rest:gmatch("([%w:_%.%-]+)%s*=%s*\"([^\"]*)\"") do attrs[(k:lower():gsub("^.*:", ""))] = decodeEntities(v) end
                    for k, v in rest:gmatch("([%w:_%.%-]+)%s*=%s*'([^']*)'") do
                        k = k:lower():gsub("^.*:", "")
                        if attrs[k] == nil then attrs[k] = decodeEntities(v) end
                    end
                    for k, v in rest:gmatch("([%w:_%.%-]+)%s*=%s*([^%s\"'>]+)") do
                        k = k:lower():gsub("^.*:", "")
                        if attrs[k] == nil then attrs[k] = decodeEntities(v) end
                    end
                end
                -- implicit closing (HTML)
                if name == "p" or CLOSEP[name] then
                    if cur.tag == "p" then cur = cur.par or root end
                end
                if name == "li" then
                    local nd = cur
                    while nd and nd ~= root and nd.tag ~= "ul" and nd.tag ~= "ol" and nd.tag ~= "li" do nd = nd.par end
                    if nd and nd.tag == "li" then cur = nd.par or root end
                elseif name == "tr" or name == "td" or name == "th" or name == "dt" or name == "dd" then
                    local nd = cur
                    local stopset = name == "tr" and { tr = true } or (name == "dt" or name == "dd") and { dt = true, dd = true } or { td = true, th = true, tr = true }
                    while nd and nd ~= root and not stopset[nd.tag] and nd.tag ~= "table" and nd.tag ~= "dl" do nd = nd.par end
                    if nd and nd ~= root and stopset[nd.tag] and (name ~= "td" and name ~= "th" or nd.tag ~= "tr") then cur = nd.par or root end
                end
                local node = { tag = name, a = attrs, c = {}, par = cur }
                cur.c[#cur.c + 1] = node
                if RAW[name] and not selfclose then
                    local e2, e3 = s:find("</" .. name .. "%s*>", i)
                    if not e2 then
                        e2 = s:lower():find("</" .. name, i, true)
                        e3 = e2 and s:find(">", e2, true)
                    end
                    node.raw = s:sub(i, (e2 or n + 1) - 1)
                    i = (e3 or n) + 1
                elseif not VOID[name] and not selfclose then
                    cur = node
                end
            else
                -- stray '<'
                addText("<")
            end
        end
    end
    return root
end

local function textOf(node, out)
    out = out or {}
    if node.t then out[#out + 1] = node.t
    else for _, ch in ipairs(node.c or {}) do textOf(ch, out) end end
    return out
end
function DR.textContent(node) return (table.concat(textOf(node)):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end

function DR.findAll(node, tag, out)
    out = out or {}
    for _, ch in ipairs(node.c or {}) do
        if ch.tag == tag then out[#out + 1] = ch end
        if ch.c then DR.findAll(ch, tag, out) end
    end
    return out
end
function DR.findFirst(node, tag)
    for _, ch in ipairs(node.c or {}) do
        if ch.tag == tag then return ch end
        if ch.c then local r = DR.findFirst(ch, tag); if r then return r end end
    end
end

-- ---------------------------------------------------------------- CSS-lite
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function parseDecls(text)
    local d = {}
    for name, value in (text or ""):gmatch("([%w%-]+)%s*:%s*([^;]+)") do
        value = trim(value:gsub("!%s*important", ""))
        d[name:lower()] = value
    end
    return d
end

local function parseSelector(sel)
    sel = trim(sel)
    if sel == "" or sel:find("[%[:+~@]") then return nil end
    local comps, comb = {}, " "
    for tok in sel:gsub(">", " > "):gmatch("%S+") do
        if tok == ">" then comb = ">"
        else
            local c = { comb = comb, classes = {} }
            local tag = tok:match("^([%w%-_]+)")
            if tag then c.tag = tag:lower() end
            if tok:sub(1, 1) == "*" then c.tag = nil end
            for cl in tok:gmatch("%.([%w%-_]+)") do c.classes[#c.classes + 1] = cl end
            c.id = tok:match("#([%w%-_]+)")
            if not c.tag and #c.classes == 0 and not c.id and tok:sub(1, 1) ~= "*" then return nil end
            comps[#comps + 1] = c
            comb = " "
        end
    end
    if #comps == 0 then return nil end
    local spec = 0
    for _, c in ipairs(comps) do spec = spec + (c.id and 100 or 0) + #c.classes * 10 + (c.tag and 1 or 0) end
    return comps, spec
end

local Css = {}
Css.__index = Css
function DR.newCss() return setmetatable({ rules = {}, ord = 0 }, Css) end

function Css:add(text)
    text = text:gsub("/%*.-%*/", "")
    local pos = 1
    while true do
        local b = text:find("{", pos, true)
        if not b then break end
        local header = trim(text:sub(pos, b - 1))
        local depth, e = 1, b + 1
        while depth > 0 do
            local c = text:find("[{}]", e)
            if not c then e = #text + 1; break end
            if text:sub(c, c) == "{" then depth = depth + 1 else depth = depth - 1 end
            e = c + 1
        end
        local body = text:sub(b + 1, e - 2)
        pos = e
        if header:sub(1, 1) == "@" then
            if header:match("^@media") and not header:find("print") and not header:find("speech") then self:add(body) end
        else
            local decl = parseDecls(body)
            if next(decl) then
                for sel in header:gmatch("[^,]+") do
                    local comps, spec = parseSelector(sel)
                    if comps then
                        self.ord = self.ord + 1
                        self.rules[#self.rules + 1] = { comps = comps, spec = spec, ord = self.ord, decl = decl }
                    end
                end
            end
        end
    end
end

function Css:merge(other)
    for _, r in ipairs(other.rules) do
        self.ord = self.ord + 1
        self.rules[#self.rules + 1] = { comps = r.comps, spec = r.spec, ord = self.ord, decl = r.decl }
    end
end

function Css:index()
    local byTag, byClass, byId, any = {}, {}, {}, {}
    for _, r in ipairs(self.rules) do
        local last = r.comps[#r.comps]
        local list
        if last.id then byId[last.id] = byId[last.id] or {}; list = byId[last.id]
        elseif #last.classes > 0 then byClass[last.classes[1]] = byClass[last.classes[1]] or {}; list = byClass[last.classes[1]]
        elseif last.tag then byTag[last.tag] = byTag[last.tag] or {}; list = byTag[last.tag]
        else list = any end
        list[#list + 1] = r
    end
    self.byTag, self.byClass, self.byId, self.any = byTag, byClass, byId, any
    return self
end

local function classSet(node)
    if node.cls then return node.cls end
    local s = {}
    for c in (node.a and node.a.class or ""):gmatch("%S+") do s[c] = true end
    node.cls = s
    return s
end

local function matchComp(c, node)
    if not node or not node.tag then return false end
    if c.tag and node.tag ~= c.tag then return false end
    if c.id and (node.a.id ~= c.id) then return false end
    if #c.classes > 0 then
        local cs = classSet(node)
        for _, k in ipairs(c.classes) do if not cs[k] then return false end end
    end
    return true
end

local function matchRule(comps, node)
    local i = #comps
    if not matchComp(comps[i], node) then return false end
    local cur = node
    while i > 1 do
        local comb = comps[i].comb
        i = i - 1
        if comb == ">" then
            cur = cur.par
            if not matchComp(comps[i], cur) then return false end
        else
            cur = cur.par
            while cur and not matchComp(comps[i], cur) do cur = cur.par end
            if not cur then return false end
        end
    end
    return true
end

function Css:matching(node)
    local cands = {}
    local function scan(list)
        if not list then return end
        for _, r in ipairs(list) do if matchRule(r.comps, node) then cands[#cands + 1] = r end end
    end
    scan(self.byTag[node.tag])
    if node.a.class then for c in node.a.class:gmatch("%S+") do scan(self.byClass[c]) end end
    if node.a.id then scan(self.byId[node.a.id]) end
    scan(self.any)
    if #cands > 1 then table.sort(cands, function(a, b) if a.spec ~= b.spec then return a.spec < b.spec end return a.ord < b.ord end) end
    return cands
end

-- ---------------------------------------------------------------- style computation
local SIZEKW = { ["xx-small"] = 0.6, ["x-small"] = 0.75, small = 0.89, medium = 1, large = 1.2, ["x-large"] = 1.5, ["xx-large"] = 2 }

local function lenEm(v, size)
    v = tostring(v or ""):lower()
    if v == "auto" or v == "" or v == "inherit" then return nil end
    local num, unit = v:match("^(-?[%d%.]+)%s*(%a*%%?)")
    num = tonumber(num)
    if not num then return nil end
    if unit == "em" or unit == "rem" then return num * (size or 1)
    elseif unit == "%" then return num * 0.3
    elseif unit == "px" then return num / 16
    elseif unit == "pt" then return num / 12
    elseif unit == "ex" then return num * 0.5 * (size or 1)
    elseif unit == "" then return num == 0 and 0 or nil end
    return nil
end

local UA = {
    b = { bold = true }, strong = { bold = true }, i = { italic = true }, em = { italic = true }, cite = { italic = true }, dfn = { italic = true }, var = { italic = true },
    code = { mono = true }, tt = { mono = true }, kbd = { mono = true }, samp = { mono = true },
    pre = { mono = true, pre = true, mt = 0.5, mb = 0.5, align = "left", ind = 0 },
    sup = { sup = true }, sub = { sub = true }, small = { size = 0.85 }, big = { size = 1.2 }, a = { link = true },
    h1 = { bold = true, size = 1.6, mt = 1.0, mb = 0.6, keep = true, head = 1, align = "left" }, h2 = { bold = true, size = 1.4, mt = 0.9, mb = 0.5, keep = true, head = 2, align = "left" },
    h3 = { bold = true, size = 1.2, mt = 0.8, mb = 0.4, keep = true, head = 3, align = "left" }, h4 = { bold = true, size = 1.1, mt = 0.6, mb = 0.3, keep = true, head = 4, align = "left" },
    h5 = { bold = true, size = 1.0, mt = 0.5, mb = 0.3, keep = true, head = 5, align = "left" }, h6 = { bold = true, size = 0.9, mt = 0.5, mb = 0.3, keep = true, head = 6, align = "left" },
    p = { mt = 0.4, mb = 0.4 }, blockquote = { ml = 1.5, mr = 0.8, mt = 0.5, mb = 0.5 }, center = { align = "center" },
    dd = { ml = 1.5 }, dt = { bold = true }, th = { bold = true, align = "center" }, figcaption = { italic = true, size = 0.9, align = "center" },
    caption = { bold = true, align = "center" }, ul = { mt = 0.3, mb = 0.3 }, ol = { mt = 0.3, mb = 0.3 }, hr = { mt = 0.6, mb = 0.6 },
    del = {}, s = {}, ins = {}, u = {},
}

local function applyDecls(st, decl, parent)
    local fs = decl["font-size"]
    if fs then
        fs = fs:lower()
        local base = parent and parent.size or 1
        if SIZEKW[fs] then st.size = SIZEKW[fs]
        elseif fs == "larger" then st.size = base * 1.2
        elseif fs == "smaller" then st.size = base / 1.2
        else
            local num, unit = fs:match("^([%d%.]+)%s*(%a*%%?)")
            num = tonumber(num)
            if num then
                if unit == "em" or unit == "rem" then st.size = base * num
                elseif unit == "%" then st.size = base * num / 100
                elseif unit == "px" then st.size = num / 16
                elseif unit == "pt" then st.size = num / 12 end
            end
        end
        st.size = max(0.5, min(3, st.size))
    end
    local v = decl["font-weight"]
    if v then v = v:lower(); local nv = tonumber(v); st.bold = (v == "bold" or v == "bolder" or (nv and nv >= 600)) and true or false end
    v = decl["font-style"]
    if v then v = v:lower(); st.italic = (v == "italic" or v == "oblique") end
    v = decl["text-align"]
    if v then
        v = v:lower()
        if v == "center" or v == "right" or v == "justify" or v == "left" then st.align = v elseif v == "start" then st.align = "left" elseif v == "end" then st.align = "right" end
    end
    v = decl["text-indent"]
    if v then local e = lenEm(v, st.size); if e then st.ind = e end end
    v = decl["display"]
    if v then st.display = v:lower() end
    v = decl["white-space"]
    if v then v = v:lower(); st.pre = (v == "pre" or v == "pre-wrap" or v == "pre-line") end
    v = decl["vertical-align"]
    if v then v = v:lower(); st.sup = (v == "super"); st.sub = (v == "sub") end
    v = decl["font-family"]
    if v and v:lower():find("mono") then st.mono = true end
    v = decl["page-break-before"] or decl["break-before"]
    if v and (v:lower() == "always" or v:lower() == "page") then st.pb = true end
    v = decl["page-break-after"] or decl["break-after"]
    if v and (v:lower() == "always" or v:lower() == "page") then st.pba = true end
    local function setm(key, val) local e = lenEm(val, st.size); if e then st[key] = max(-1, min(8, e)) end end
    v = decl["margin"]
    if v then
        local parts = {}
        for t in v:gmatch("%S+") do parts[#parts + 1] = t end
        local top, right, bottom, left = parts[1], parts[2] or parts[1], parts[3] or parts[1], parts[4] or parts[2] or parts[1]
        setm("mt", top); setm("mr", right); setm("mb", bottom); setm("ml", left)
    end
    if decl["margin-top"] then setm("mt", decl["margin-top"]) end
    if decl["margin-bottom"] then setm("mb", decl["margin-bottom"]) end
    if decl["margin-left"] then setm("ml", decl["margin-left"]) end
    if decl["margin-right"] then setm("mr", decl["margin-right"]) end
    v = decl["padding-left"]
    if v then local e = lenEm(v, st.size); if e and e > 0 then st.ml = (st.ml or 0) + min(e, 6) end end
end

local function computeStyle(node, ps, css)
    local st = { size = ps.size, bold = ps.bold, italic = ps.italic, mono = ps.mono, sup = ps.sup, sub = ps.sub, link = ps.link,
        align = ps.align, ind = ps.ind, pre = ps.pre, ml = 0, mr = 0, mt = 0, mb = 0 }
    local ua = UA[node.tag]
    if ua then for k, v in pairs(ua) do if k == "size" then st.size = ps.size * v else st[k] = v end end end
    if node.tag == "sup" then st.sub = false elseif node.tag == "sub" then st.sup = false end
    if css then
        local cands = css:matching(node)
        for _, r in ipairs(cands) do applyDecls(st, r.decl, ps) end
    end
    local style = node.a and node.a.style
    if style then applyDecls(st, parseDecls(style), ps) end
    if node.a and node.a.hidden then st.display = "none" end
    return st
end

-- ---------------------------------------------------------------- DOM -> blocks
local BLOCKTAG = {}
for t in ([[p div h1 h2 h3 h4 h5 h6 ul ol li blockquote pre table tr td th section article header footer nav aside figure figcaption dl dt dd hr body html main address form fieldset caption thead tbody tfoot center details summary]]):gmatch("%S+") do BLOCKTAG[t] = true end
local SKIPTAG = { head = true, script = true, style = true, title = true, meta = true, link = true, noscript = true, template = true, iframe = true, audio = true, video = true, object = true, button = true, select = true, input = true, textarea = true, canvas = true }

local function splitHyphens(w)
    if not (w:find("-", 1, true) or w:find("\226\128\148", 1, true)) then return { w } end
    local out, cur = {}, ""
    local i, n = 1, #w
    while i <= n do
        local ch = w:sub(i, i)
        if ch == "-" then
            cur = cur .. ch
            local nxt = w:sub(i + 1, i + 1)
            if nxt ~= "" and nxt:match("%a") and #cur >= 2 and cur:sub(-2, -2):match("[%a\128-\255]") then out[#out + 1] = cur; cur = "" end
            i = i + 1
        elseif w:sub(i, i + 2) == "\226\128\148" then
            cur = cur .. "\226\128\148"
            i = i + 3
            if i <= n then out[#out + 1] = cur; cur = "" end
        else cur = cur .. ch; i = i + 1 end
    end
    if cur ~= "" then out[#out + 1] = cur end
    return out
end

function DR.toBlocks(root, css, opts)
    opts = opts or {}
    local blocks, anchors, heads = {}, {}, {}
    local off = 0
    local P
    local carry, pend = 0, 0
    local pendPB = false
    local space = false
    local bst = { size = 1, align = nil, ind = 0 }
    local accml, accmr = 0, 0
    local lists = {}
    local base = { size = 1, ind = 0 }

    local function bitsOf(st)
        local b = 0
        if st.bold then b = b + 1 end
        if st.italic then b = b + 2 end
        if st.sup then b = b + 4 elseif st.sub then b = b + 8 end
        if st.mono then b = b + 16 end
        if st.link then b = b + 32 end
        local rel = st.size / (bst.size or 1)
        if not st.sup and not st.sub then
            if rel < 0.92 then b = b + 64 elseif rel > 1.1 then b = b + 128 end
        end
        return b
    end
    local function flush()
        if P and P.n > 0 then
            P.gap = max(carry, pend, P.gapOwn or 0)
            carry, pend = 0, 0
            if pendPB then P.pb = true; pendPB = false end
            P.len = P.len + 1
            off = off + P.len
            blocks[#blocks + 1] = P
            if P.head and P.head <= 3 then
                heads[#heads + 1] = { level = P.head, title = table.concat(P.w, " "):gsub("%s+", " "), off = P.c0 }
            end
        end
        P = nil
        space = false
    end
    local function ensureP()
        if not P then
            P = { t = "p", w = {}, st = {}, sp = {}, n = 0, len = 0, c0 = off, ml = accml, mr = accmr, ind = bst.ind or 0,
                align = bst.align, size = bst.size or 1, head = bst.head, keep = bst.keep, pre = bst.pre }
            if opts.align and not P.align then P.align = nil end
        end
        return P
    end
    local function push(s, bits, spflag)
        local p = ensureP()
        local k = p.n + 1
        p.n = k
        p.w[k], p.st[k], p.sp[k] = s, bits, spflag
        p.len = p.len + #s + (spflag > 0 and 1 or 0)
    end
    local function addText(txt, st)
        local bits = bitsOf(st)
        if st.pre then
            txt = txt:gsub("\r", ""):gsub("\t", "    ")
            local first = true
            for line in (txt .. "\n"):gmatch("(.-)\n") do
                if not first then push("\n", 0, 0) end
                first = false
                if line ~= "" then push(line, bits, 0) end
            end
            return
        end
        txt = txt:gsub("\194\173", ""):gsub("\226\128\139", ""):gsub("[ \t\r\n\f\v]+", " ")
        if txt == "" then return end
        local lead = txt:sub(1, 1) == " "
        local trail = txt:sub(-1) == " "
        if lead then space = true end
        local first = true
        for w in txt:gmatch("[^ ]+") do
            local pieces = splitHyphens(w)
            for pi, piece in ipairs(pieces) do
                local sp
                if pi == 1 then sp = (space and P and P.n > 0) and 1 or 0 else sp = 2 end
                if pi == 1 and not P and false then sp = 0 end
                push(piece, bits, sp)
            end
            space = true
            first = false
        end
        space = trail
        if first then space = space or lead end
    end
    local function addBreak(st)
        ensureP()
        push("\n", 0, 0)
        space = false
    end
    local function pushAnchor(id)
        if id and id ~= "" and anchors[id] == nil then anchors[id] = off + (P and P.len or 0) end
    end

    local walk
    local function addImage(node, st)
        local src = node.a.src or node.a.href
        local ref = src and opts.resolve and opts.resolve(src)
        if not ref then
            local alt = node.a.alt
            if alt and alt ~= "" then addText(alt, st) end
            return
        end
        flush()
        local b = { t = "img", ref = ref, c0 = off, ml = accml, mr = accmr, gap = max(carry, pend), alt = node.a.alt,
            aw = node.a.width, ah = node.a.height, align = st.align }
        carry, pend = 0, 0
        if pendPB then b.pb = true; pendPB = false end
        pushAnchor(node.a.id)
        off = off + 1
        blocks[#blocks + 1] = b
    end

    walk = function(node, ps)
        if node.t then
            if not node.t:find("%S") and not (ps.pre) and (not P or P.n == 0) then return end
            addText(node.t, ps)
            return
        end
        local tag = node.tag
        if SKIPTAG[tag] then return end
        local st = computeStyle(node, ps, css)
        if st.display == "none" then return end
        if tag == "br" then pushAnchor(node.a.id); addBreak(st); return end
        if tag == "img" or tag == "image" then addImage(node, st); return end
        if tag == "svg" then
            for _, ch in ipairs(node.c) do if not ch.t then walk(ch, st) end end
            return
        end
        local isBlock = BLOCKTAG[tag] or st.display == "block" or st.display == "list-item" or st.display == "table" or st.display == "table-row"
        if st.display == "inline" or st.display == "inline-block" or tag == "td" or tag == "th" then isBlock = false end
        if tag == "td" or tag == "th" then
            if P and P.n > 0 then push("|", 0, 1); space = true end
        end
        if tag == "hr" then
            flush()
            local b = { t = "hr", c0 = off, gap = max(carry, pend, 0.5), ml = accml, mr = accmr }
            carry, pend = 0, 0
            blocks[#blocks + 1] = b
            off = off + 1
            carry = 0.5
            return
        end
        if isBlock then
            flush()
            local savedB, savedML, savedMR = bst, accml, accmr
            pend = max(pend, st.mt)
            if st.pb then pendPB = true end
            pushAnchor(node.a.id)
            local ml = st.ml
            local listItem = false
            if tag == "ul" or tag == "ol" then
                lists[#lists + 1] = { ordered = tag == "ol", n = tonumber(node.a.start) and (tonumber(node.a.start) - 1) or 0 }
                if ml == 0 then ml = 1.3 end
            elseif tag == "li" then
                listItem = true
            end
            accml, accmr = accml + ml, accmr + st.mr
            bst = { size = st.size, align = st.align, ind = st.ind, head = st.head, keep = st.keep, pre = st.pre }
            if tag == "li" then bst.ind = 0 end
            if listItem then
                local L = lists[#lists]
                local marker = "\226\128\162"
                if L and L.ordered then L.n = L.n + 1; marker = L.n .. "." end
                ensureP()
                P.hang = true
                P.ml = accml - 1.3 > 0 and (accml - 1.3 + 0.0) or accml
                P.ml = max(0, accml - 1.3)
                push(marker, bitsOf(st) - (st.bold and 1 or 0) * 0, 0)
                space = true
            end
            for _, ch in ipairs(node.c) do walk(ch, st) end
            flush()
            carry = max(carry, st.mb)
            if st.pba then pendPB = true end
            if tag == "ul" or tag == "ol" then lists[#lists] = nil end
            bst, accml, accmr = savedB, savedML, savedMR
        else
            pushAnchor(node.a.id)
            local bitsBefore = nil
            for _, ch in ipairs(node.c) do walk(ch, st) end
        end
    end

    local start = root
    local body = DR.findFirst(root, "body")
    if body then start = body end
    base.size = 1
    for _, ch in ipairs(start.c) do walk(ch, { size = 1, ind = 0 }) end
    flush()
    if opts.after then opts.after(blocks) end
    return { blocks = blocks, anchors = anchors, heads = heads, total = max(1, off) }
end

DR.computeStyle = computeStyle
DR.parseDecls = parseDecls
end
-- ================================================================ DR layout: blocks -> pages
do
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
DR.env = DR.env or {}

local function sizeMult(bits)
    if bits >= 128 then return 1.2 elseif bits >= 64 then return 0.85 end
    if bits % 16 >= 4 and bits % 16 < 12 then return 0.72 end
    return 1
end
DR.sizeMult = sizeMult

-- P: { x0, cw, y0, ch, fs, lh, align, cache, imageSize }
function DR.layout(ch, P)
    local env = DR.env
    local cache = P.cache
    local fs = P.fs
    local function wid(bits, size, str)
        local key = bits * 1000 + size
        local t = cache[key]
        if not t then t = {}; cache[key] = t end
        local w = t[str]
        if not w then w = env.measure(bits % 32 + (bits >= 32 and bits % 64 >= 32 and 0 or 0), size, str); t[str] = w end
        return w
    end
    local pages, cur = {}, nil
    local y = 0
    local maxY = P.ch
    local function newPage(off)
        cur = { items = {}, start = off }
        pages[#pages + 1] = cur
        y = 0
    end
    local blocks = ch.blocks
    local function lineH(size)
        local h = env.metrics(0, size)
        return h * P.lh, h
    end
    local function place(item, h, off)
        if not cur then newPage(off) end
        if not cur.start then cur.start = off end
        item.y = y; item.off = off
        cur.items[#cur.items + 1] = item
        y = y + h
    end
    for bi, b in ipairs(blocks) do
        local gapPx = floor((b.gap or 0) * fs + 0.5)
        if b.pb and cur and #cur.items > 0 then cur = nil end
        local topOfPage = (not cur) or #cur.items == 0
        if topOfPage then gapPx = 0 end
        local ml, mr = floor(b.ml * fs + 0.5), floor(b.mr * fs + 0.5)
        local avail = P.cw - ml - mr
        if avail < fs * 4 then ml, mr, avail = 0, 0, P.cw end
        if b.t == "hr" then
            local h = floor(fs * 0.6)
            if cur and y + gapPx + h > maxY then cur = nil; gapPx = 0 end
            if not cur then newPage(b.c0) end
            y = y + gapPx
            place({ hr = true, x = P.x0 + ml, w = avail }, h, b.c0)
        elseif b.t == "img" then
            local iw, ih = P.imageSize(b.ref)
            local item
            if not iw or iw <= 0 then
                local h = floor(fs * 1.5)
                if cur and y + gapPx + h > maxY then cur = nil; gapPx = 0 end
                if not cur then newPage(b.c0) end
                y = y + gapPx
                place({ x = P.x0 + ml, w = avail, h = h, ph = true, alt = b.alt }, h, b.c0)
            else
                local s = min(avail / iw, (maxY * 0.98) / ih, 2.5)
                if iw < 40 then s = min(s, 1) end
                local w, h = max(1, floor(iw * s)), max(1, floor(ih * s))
                if cur and y + gapPx + h > maxY then cur = nil; gapPx = 0 end
                if not cur then newPage(b.c0) end
                y = y + gapPx
                place({ img = b.ref, x = P.x0 + ml + floor((avail - w) / 2), w = w, h = h }, h, b.c0)
            end
        else
            local size = max(8, floor(fs * b.size + 0.5))
            local lhp, fh = lineH(size)
            lhp = max(1, floor(lhp + 0.5))
            local w, st, sp, n = b.w, b.st, b.sp, b.n
            local spw = {}
            local function spaceW(i) local k = st[i]; local v = spw[k]; if not v then v = wid(k, floor(size * sizeMult(k) + 0.5), " "); spw[k] = v end; return v end
            local function tw(i) return wid(st[i], floor(size * sizeMult(st[i]) + 0.5), w[i]) end
            -- split overlong tokens
            local cloned = false
            local hangW = 0
            if b.hang and n >= 1 then hangW = tw(1) + spaceW(1) end
            local lineAvail0 = avail
            local i = 1
            while i <= n do
                if w[i] ~= "\n" then
                    local maxw = avail - (hangW > 0 and hangW or 0)
                    if tw(i) > maxw and maxw > fs then
                        if not cloned then
                            local w2, st2, sp2 = {}, {}, {}
                            for k = 1, n do w2[k], st2[k], sp2[k] = w[k], st[k], sp[k] end
                            w, st, sp, cloned = w2, st2, sp2, true
                        end
                        local s = w[i]
                        local cnt, lo = 0, 0
                        local pos, lastgood = 1, 1
                        local len = #s
                        local piece = {}
                        local startp = 1
                        local p = 1
                        while p <= len do
                            local q = p + 1
                            while q <= len and s:byte(q) >= 0x80 and s:byte(q) < 0xC0 do q = q + 1 end
                            if wid(st[i], floor(size * sizeMult(st[i]) + 0.5), s:sub(startp, q - 1)) > maxw and p > startp then
                                piece[#piece + 1] = s:sub(startp, p - 1); startp = p
                            end
                            p = q
                        end
                        piece[#piece + 1] = s:sub(startp)
                        w[i] = piece[1]
                        for k = 2, #piece do
                            table.insert(w, i + k - 1, piece[k]); table.insert(st, i + k - 1, st[i]); table.insert(sp, i + k - 1, 2)
                        end
                        n = n + #piece - 1
                    end
                end
                i = i + 1
            end
            -- wrap
            local alignMode = b.align
            if P.align == "justify" and (alignMode == nil or alignMode == "left" or alignMode == "justify") and not b.head and not b.pre then alignMode = "justify"
            elseif P.align == "left" and alignMode == "justify" then alignMode = "left"
            elseif alignMode == nil then alignMode = "left" end
            local cum = {}
            local c = b.c0
            for k = 1, n do cum[k] = c; c = c + #w[k] + (sp[k] > 0 and 1 or 0) end
            local lines = {}
            local a, lw, lastOpp = 1, 0, nil
            local indent0 = (not b.hang) and floor(b.ind * fs + 0.5) or 0
            local function availFor(li) if b.hang then return avail - (li > 1 and hangW or 0) end return avail - (li == 1 and max(0, indent0) or 0) end
            local k = 1
            while k <= n do
                if w[k] == "\n" then
                    lines[#lines + 1] = { a = a, b = k - 1, w = lw, forced = true }
                    a, lw, lastOpp = k + 1, 0, nil
                    k = k + 1
                else
                    local t = tw(k)
                    local s = (k > a and sp[k] == 1) and spaceW(k) or 0
                    local av = availFor(#lines + 1)
                    if k > a and lw + s + t > av then
                        if sp[k] > 0 then
                            lines[#lines + 1] = { a = a, b = k - 1, w = lw }
                            a, lw, lastOpp = k, t, nil
                            k = k + 1
                        elseif lastOpp then
                            lines[#lines + 1] = { a = a, b = lastOpp - 1, w = nil }
                            local ln = lines[#lines]
                            local ww = 0
                            for q = ln.a, ln.b do ww = ww + tw(q) + ((q > ln.a and sp[q] == 1) and spaceW(q) or 0) end
                            ln.w = ww
                            a = lastOpp; lw = 0; lastOpp = nil
                            for q = a, k - 1 do
                                lw = lw + tw(q) + ((q > a and sp[q] == 1) and spaceW(q) or 0)
                                if q > a and sp[q] > 0 then lastOpp = q end
                            end
                            -- retry current token on new line
                        else
                            lw = lw + s + t
                            k = k + 1
                        end
                    else
                        lw = lw + s + t
                        if k > a and sp[k] > 0 then lastOpp = k end
                        k = k + 1
                    end
                end
            end
            if a <= n then lines[#lines + 1] = { a = a, b = n, w = lw, last = true } end
            if #lines == 0 then lines[1] = { a = 1, b = 0, w = 0, last = true } end
            lines[#lines].last = true
            -- build line items
            local nl = #lines
            local items = {}
            for li, ln in ipairs(lines) do
                local av = availFor(li)
                local x = P.x0 + ml
                if b.hang then if li > 1 then x = x + hangW end
                elseif li == 1 then x = x + max(0, indent0) end
                local extra, gaps = 0, 0
                local lineW = ln.w
                if alignMode == "justify" and not ln.last and not ln.forced then
                    for q = ln.a + 1, ln.b do if sp[q] == 1 then gaps = gaps + 1 end end
                    extra = av - lineW
                    if gaps == 0 or extra < 0 then gaps, extra = 0, 0 end
                elseif alignMode == "center" then x = x + floor((av - lineW) / 2)
                elseif alignMode == "right" then x = x + (av - lineW) end
                local item = { y = 0, off = cum[ln.a] or b.c0, h = lhp, base = 0 }
                local acc = 0
                local cx = x
                local fracacc = 0
                for q = ln.a, ln.b do
                    local sz = floor(size * sizeMult(st[q]) + 0.5)
                    if q > ln.a and sp[q] == 1 then
                        cx = cx + spaceW(q)
                        if gaps > 0 then fracacc = fracacc + extra / gaps; local whole = floor(fracacc); cx = cx + whole; fracacc = fracacc - whole end
                    end
                    local bits = st[q]
                    local shift = 0
                    if bits % 16 >= 4 and bits % 16 < 8 then shift = -floor(size * 0.35) elseif bits % 16 >= 8 then shift = floor(size * 0.12) end
                    local base = (item.base ~= 0) and item.base or 0
                    item[#item + 1] = { cx, w[q], bits % 32 + (bits >= 64 and 0 or 0), sz, shift, bits }
                    cx = cx + wid(bits, sz, w[q])
                end
                items[li] = item
            end
            -- paginate lines
            local li = 1
            local first = true
            while li <= nl do
                local gp = first and gapPx or 0
                if b.pb and first and cur and #cur.items > 0 then cur = nil; gp = 0 end
                if not cur then newPage(items[li].off); gp = 0 end
                local avlLines = floor((maxY - y - gp) / lhp)
                local remaining = nl - li + 1
                if first and b.keep and remaining >= 1 then
                    local need = lhp * min(remaining, 2) + gp + lhp
                    if y + need > maxY and #cur.items > 0 then avlLines = 0 end
                end
                if avlLines >= remaining then
                    y = y + gp
                    for q = li, nl do place(items[q], lhp, items[q].off) end
                    li = nl + 1
                else
                    local take = avlLines
                    if take > 0 then
                        if li == 1 and take < 2 and nl >= 2 then take = 0 end
                        if take > 0 and remaining - take == 1 and take >= 3 then take = take - 1 end
                        if take > 0 and remaining - take == 1 and take < 3 then take = 0 end
                    end
                    if take <= 0 then
                        if #cur.items == 0 then take = max(1, avlLines) else cur = nil end
                    end
                    if take > 0 then
                        y = y + gp
                        for q = li, li + take - 1 do place(items[q], lhp, items[q].off) end
                        li = li + take
                        cur = nil
                    end
                end
                first = false
            end
            -- baseline offsets
            local asc = env.ascent and env.ascent(0, size) or fh * 0.8
            local base = floor((lhp - fh) / 2 + asc + 0.5)
            for _, it in ipairs(items) do it.base = base end
        end
    end
    if #pages == 0 then newPage(0) end
    for i, pg in ipairs(pages) do
        pg.start = pg.start or 0
        pg.stop = pages[i + 1] and pages[i + 1].start or ch.total
    end
    return pages
end

function DR.findPage(pages, off)
    local lo, hi = 1, #pages
    while lo < hi do
        local mid = floor((lo + hi + 1) / 2)
        if pages[mid].start <= off then lo = mid else hi = mid - 1 end
    end
    return lo
end

function DR.paintPage(bb, page, P, fg, bg, ox, oy)
    local env = DR.env
    for _, it in ipairs(page.items) do
        if it.img then env.drawImage(bb, it.img, ox + it.x, oy + it.y, it.w, it.h)
        elseif it.hr then env.rule(bb, ox + it.x, oy + it.y + floor(it.h / 2), it.w, fg)
        elseif it.ph then env.placeholder(bb, ox + it.x, oy + it.y, it.w, it.h, it.alt, fg)
        else
            for i = 1, #it do
                local s = it[i]
                if s[2] ~= "\n" and s[2] ~= "" then env.draw(bb, ox + s[1], oy + it.y + it.base + s[5], s[6], s[4], s[2], fg) end
            end
        end
    end
end
end
-- ================================================================ DR book formats
do
local floor, max, min = math.floor, math.max, math.min
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function extOf(p) local e = (p or ""):match("%.([%w]+)$") return e and e:lower() or "" end
local function dirOf(p) return p:match("^(.*)/[^/]*$") or "" end
local function unpct(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local function resolvePath(base, href)
    if not href or href == "" then return nil end
    href = unpct(href:gsub("#.*$", ""))
    if href == "" then return nil end
    local full
    if href:sub(1, 1) == "/" then full = href:sub(2) else full = (base ~= "" and (base .. "/") or "") .. href end
    local out = {}
    for seg in full:gmatch("[^/]+") do
        if seg == ".." then out[#out] = nil elseif seg ~= "." then out[#out + 1] = seg end
    end
    return table.concat(out, "/")
end
DR.resolvePath = resolvePath

local B64 = {}
do local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; for i = 1, 64 do B64[a:byte(i)] = i - 1 end end
function DR.base64(s)
    local out, n, acc, bits = {}, 0, 0, 0
    for i = 1, #s do
        local v = B64[s:byte(i)]
        if v then
            acc = acc * 64 + v; bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = floor(acc / 2 ^ bits) % 256
                n = n + 1; out[n] = string.char(byte)
                acc = acc % (2 ^ bits)
            end
        end
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------- markdown
local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function mdInline(s)
    s = esc(s or "")
    s = s:gsub("!%[([^%]]*)%]%([^)]*%)", "%1"):gsub("%[([^%]]+)%]%([^)]*%)", "%1")
    s = s:gsub("%*%*(.-)%*%*", "<b>%1</b>"):gsub("__(.-)__", "<b>%1</b>")
    s = s:gsub("%*(.-)%*", "<i>%1</i>"):gsub("`(.-)`", "<code>%1</code>")
    return s
end
function DR.mdToHtml(src)
    local out, para, kind, fence = {}, {}, nil, false
    local function closePara() if #para > 0 then out[#out + 1] = "<p>" .. mdInline(table.concat(para, " ")) .. "</p>"; para = {} end end
    local function closeList() if kind then out[#out + 1] = "</" .. kind .. ">"; kind = nil end end
    src = src:gsub("\r\n", "\n"):gsub("\r", "\n")
    for raw in (src .. "\n"):gmatch("(.-)\n") do
        if raw:match("^%s*```") or raw:match("^%s*~~~") then
            closePara(); closeList()
            out[#out + 1] = fence and "</pre>" or "<pre>"
            fence = not fence
        elseif fence then out[#out + 1] = esc(raw)
        else
            local h, text = raw:match("^%s*(#+)%s+(.-)%s*#*%s*$")
            local bullet = raw:match("^%s*[-+*]%s+(.+)$")
            local number = raw:match("^%s*%d+[%.%)]%s+(.+)$")
            local quote = raw:match("^%s*>%s?(.*)$")
            if h and #h <= 6 then closePara(); closeList(); out[#out + 1] = string.format("<h%d>%s</h%d>", #h, mdInline(text), #h)
            elseif raw:match("^%s*[-*_][-*_][-*_]+%s*$") then closePara(); closeList(); out[#out + 1] = "<hr/>"
            elseif bullet then
                closePara()
                if kind ~= "ul" then closeList(); out[#out + 1] = "<ul>"; kind = "ul" end
                out[#out + 1] = "<li>" .. mdInline(bullet) .. "</li>"
            elseif number then
                closePara()
                if kind ~= "ol" then closeList(); out[#out + 1] = "<ol>"; kind = "ol" end
                out[#out + 1] = "<li>" .. mdInline(number) .. "</li>"
            elseif quote then closePara(); closeList(); out[#out + 1] = "<blockquote><p>" .. mdInline(quote) .. "</p></blockquote>"
            elseif raw:match("^%s*$") then closePara(); closeList()
            else closeList(); para[#para + 1] = trim(raw) end
        end
    end
    closePara(); closeList()
    if fence then out[#out + 1] = "</pre>" end
    return "<html><body>" .. table.concat(out, "\n") .. "</body></html>"
end

-- ---------------------------------------------------------------- text decoding
local function latin1ToUtf8(s)
    return (s:gsub("[\128-\255]", function(c) return DR.utf8enc(c:byte()) end))
end
local function toUtf8(s)
    if s:sub(1, 3) == "\239\187\191" then return s:sub(4) end
    local b1, b2 = s:byte(1, 2)
    if b1 == 0xFF and b2 == 0xFE or b1 == 0xFE and b2 == 0xFF then
        local le = b1 == 0xFF
        local out = {}
        for i = 3, #s - 1, 2 do
            local a, b = s:byte(i, i + 1)
            local cp = le and (a + b * 256) or (a * 256 + b)
            if cp >= 0xD800 and cp < 0xDC00 then
                local c, d = s:byte(i + 2, i + 3)
                local lo = le and (c + d * 256) or (c * 256 + d)
                cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00); i = i + 2
            end
            out[#out + 1] = DR.utf8enc(cp)
        end
        return table.concat(out)
    end
    if s:find("[\192-\255]") and not s:find("^[%z\1-\127\194-\244\128-\191]*$") or (s:find("[\128-\255]") and not pcall(function()
        local i, n = 1, #s
        while i <= n do
            local c = s:byte(i)
            local l = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0) and 2 or (c >= 0xE0 and c < 0xF0) and 3 or (c >= 0xF0 and c < 0xF5) and 4 or error("bad")
            for k = 1, l - 1 do local x = s:byte(i + k); if not x or x < 0x80 or x > 0xBF then error("bad") end end
            i = i + l
        end
    end)) then return latin1ToUtf8(s) end
    return s
end
DR.toUtf8 = toUtf8

-- ---------------------------------------------------------------- shared chapter building
local function cssFrom(dom, readFn, baseDir, cache)
    local css = DR.newCss()
    for _, node in ipairs(DR.findAll(dom, "link")) do
        local rel = (node.a.rel or ""):lower()
        if rel:find("stylesheet") and node.a.href and readFn then
            local path = resolvePath(baseDir, node.a.href)
            if path then
                local sheet = cache and cache[path]
                if not sheet then
                    sheet = DR.newCss()
                    local txt = readFn(path)
                    if txt then sheet:add(toUtf8(txt)) end
                    if cache then cache[path] = sheet end
                end
                css:merge(sheet)
            end
        end
    end
    for _, node in ipairs(DR.findAll(dom, "style")) do if node.raw then css:add(node.raw) end end
    return css:index()
end

local function estimateText(html)
    html = html:gsub("<[sS][tT][yY][lL][eE].-</[sS][tT][yY][lL][eE]>", ""):gsub("<[sS][cC][rR][iI][pP][tT].-</[sS][cC][rR][iI][pP][tT]>", "")
    html = html:gsub("<[^>]*>", ""):gsub("%s+", " ")
    return max(1, #html)
end

-- ---------------------------------------------------------------- EPUB
local function openEPUB(path, opts)
    local z, err = DR.zipOpen(path)
    if not z then return nil, err end
    local function fail(m) z:close(); return nil, m end
    local cont = z:read("META-INF/container.xml")
    if not cont then return fail("not an EPUB (container.xml missing)") end
    local cdom = DR.parseHTML(cont)
    local rf = DR.findFirst(cdom, "rootfile")
    local opfPath = rf and rf.a["full-path"]
    if not opfPath then return fail("EPUB without package file") end
    opfPath = unpct(opfPath)
    local opf = z:read(opfPath)
    if not opf then return fail("package file missing") end
    local odom = DR.parseHTML(opf)
    local base = dirOf(opfPath)
    local book = { kind = "text", zip = z, toc = nil, format = "epub" }
    local meta = DR.findFirst(odom, "metadata")
    if meta then
        local t = DR.findFirst(meta, "title")
        book.title = t and DR.textContent(t) or ""
        local a = DR.findFirst(meta, "creator")
        book.author = a and DR.textContent(a) or ""
    end
    local manifest, byHref = {}, {}
    local mf = DR.findFirst(odom, "manifest")
    for _, it in ipairs(mf and DR.findAll(mf, "item") or {}) do
        local m = { id = it.a.id, href = resolvePath(base, it.a.href), type = it.a["media-type"] or "", props = it.a.properties or "" }
        if m.id then manifest[m.id] = m end
        if m.href then byHref[m.href] = m end
    end
    local spine, spineIdx = {}, {}
    local sp = DR.findFirst(odom, "spine")
    local ncxId = sp and sp.a.toc
    for _, ir in ipairs(sp and DR.findAll(sp, "itemref") or {}) do
        local m = manifest[ir.a.idref]
        if m and m.href and (ir.a.linear ~= "no") and (m.type:find("html") or m.type:find("xml") or extOf(m.href):find("^x?html?$")) then
            spine[#spine + 1] = m; spineIdx[m.href] = #spine
        end
    end
    if #spine == 0 then return fail("EPUB without readable content") end
    -- cover
    local coverHref
    for _, m in pairs(manifest) do if m.props:find("cover%-image") then coverHref = m.href end end
    if not coverHref then
        for _, mt in ipairs(DR.findAll(odom, "meta")) do
            if mt.a.name == "cover" and manifest[mt.a.content] then coverHref = manifest[mt.a.content].href end
        end
    end
    if not coverHref then
        for _, m in pairs(manifest) do
            if m.type:find("^image") and ((m.id or ""):lower():find("cover") or m.href:lower():find("cover")) then coverHref = m.href; break end
        end
    end
    book.coverHref = coverHref
    -- sizes
    local sizes = opts and opts.sizes
    local chapters = {}
    local ok = sizes and #sizes == #spine
    for i, m in ipairs(spine) do
        local sz = ok and sizes[i]
        if not sz then
            if opts and opts.lite then sz = 1
            else
                local d = z:read(m.href)
                sz = d and estimateText(d) or 1
            end
        end
        chapters[i] = { size = sz, name = m.href }
    end
    book.chapters = chapters
    book.sizes = {}
    for i, c in ipairs(chapters) do book.sizes[i] = c.size end
    local cssCache = {}
    local dims = {}
    local function readEntry(p) return z:read(p) end
    function book.load(i)
        local m = spine[i]
        local html = z:read(m.href)
        if not html then return { blocks = {}, anchors = {}, heads = {}, total = 1 } end
        local dom = DR.parseHTML(toUtf8(html))
        local bdir = dirOf(m.href)
        local css = cssFrom(dom, readEntry, bdir, cssCache)
        return DR.toBlocks(dom, css, { resolve = function(src)
            if src:find("^data:") or src:find("^%a+://") then return nil end
            return resolvePath(bdir, src)
        end })
    end
    function book.imageData(ref) return z:read(ref) end
    function book.coverData() return coverHref and z:read(coverHref) end
    function book.getToc()
        if book.toc then return book.toc end
        local toc = {}
        local navItem
        for _, m in pairs(manifest) do if m.props:find("nav") then navItem = m end end
        local function mapHref(bdir, href)
            local p = resolvePath(bdir, href)
            local frag = href:match("#(.+)$")
            if p and spineIdx[p] then return spineIdx[p], frag and unpct(frag) end
        end
        if navItem then
            local nd = DR.parseHTML(toUtf8(z:read(navItem.href) or ""))
            local navNode
            for _, n in ipairs(DR.findAll(nd, "nav")) do if n.a.type == "toc" or not navNode then navNode = navNode or n; if n.a.type == "toc" then navNode = n end end end
            local bdir = dirOf(navItem.href)
            local function walkList(ol, depth)
                for _, li in ipairs(ol.c) do
                    if li.tag == "li" then
                        for _, ch in ipairs(li.c) do
                            if ch.tag == "a" and ch.a.href then
                                local c, frag = mapHref(bdir, ch.a.href)
                                if c then toc[#toc + 1] = { title = DR.textContent(ch), c = c, frag = frag, depth = depth } end
                            elseif ch.tag == "span" then
                                -- heading without link
                            elseif ch.tag == "ol" or ch.tag == "ul" then walkList(ch, depth + 1) end
                        end
                    end
                end
            end
            for _, ol in ipairs(navNode and navNode.c or {}) do if ol.tag == "ol" or ol.tag == "ul" then walkList(ol, 0) end end
        end
        if #toc == 0 then
            local ncx = ncxId and manifest[ncxId]
            if not ncx then for _, m in pairs(manifest) do if m.type:find("ncx") then ncx = m end end end
            if ncx then
                local nd = DR.parseHTML(toUtf8(z:read(ncx.href) or ""))
                local bdir = dirOf(ncx.href)
                local function walkNav(node, depth)
                    for _, ch in ipairs(node.c) do
                        if ch.tag == "navpoint" then
                            local lab = DR.findFirst(ch, "text")
                            local cn
                            for _, x in ipairs(ch.c) do if x.tag == "content" then cn = x end end
                            if cn and cn.a.src then
                                local c, frag = mapHref(bdir, cn.a.src)
                                if c then toc[#toc + 1] = { title = lab and DR.textContent(lab) or "", c = c, frag = frag, depth = depth } end
                            end
                            walkNav(ch, depth + 1)
                        elseif ch.c then walkNav(ch, depth) end
                    end
                end
                walkNav(nd, 0)
            end
        end
        book.toc = toc
        return toc
    end
    function book.close() z:close() end
    return book
end

-- ---------------------------------------------------------------- FB2
local FB2MAP = { section = "div", title = "h2", subtitle = "h4", ["empty-line"] = "br", emphasis = "em", strong = "strong", poem = "blockquote",
    stanza = "div", v = "p", cite = "blockquote", epigraph = "blockquote", annotation = "blockquote", ["text-author"] = "p", strikethrough = "s" }
local function remap(node)
    if node.tag and FB2MAP[node.tag] then node.tag = FB2MAP[node.tag] end
    for _, ch in ipairs(node.c or {}) do remap(ch) end
end
local function openFB2(path)
    local f = io.open(path, "rb"); if not f then return nil, "cannot open" end
    local d = f:read("*a"); f:close()
    local head = d:sub(1, 200):lower()
    local enc = head:match('encoding%s*=%s*["\']([^"\']+)')
    if enc and enc ~= "utf-8" then d = latin1ToUtf8(d) end
    local dom = DR.parseHTML(d)
    local fb = DR.findFirst(dom, "fictionbook")
    if not fb then return nil, "not a valid FB2 file" end
    local bin = {}
    for _, b in ipairs(DR.findAll(fb, "binary")) do if b.a.id then bin[b.a.id] = b end end
    local book = { kind = "text", format = "fb2" }
    local ti = DR.findFirst(fb, "title-info")
    if ti then
        local t = DR.findFirst(ti, "book-title"); book.title = t and DR.textContent(t) or ""
        local au = DR.findFirst(ti, "author")
        if au then
            local fnm, lnm = DR.findFirst(au, "first-name"), DR.findFirst(au, "last-name")
            book.author = trim((fnm and DR.textContent(fnm) or "") .. " " .. (lnm and DR.textContent(lnm) or ""))
        end
        local cp = DR.findFirst(ti, "coverpage")
        local im = cp and DR.findFirst(cp, "image")
        book.coverRef = im and im.a.href and im.a.href:gsub("^#", "")
    end
    local body
    for _, b in ipairs(DR.findAll(fb, "body")) do if not b.a.name then body = b; break end end
    body = body or DR.findFirst(fb, "body")
    if not body then return nil, "FB2 without body" end
    local parts = {}
    local loose = { tag = "body", a = {}, c = {} }
    for _, ch in ipairs(body.c) do
        if ch.tag == "section" then
            if #loose.c > 0 then parts[#parts + 1] = loose; loose = { tag = "body", a = {}, c = {} } end
            parts[#parts + 1] = { tag = "body", a = {}, c = { ch } }
        elseif not ch.t or ch.t:find("%S") then loose.c[#loose.c + 1] = ch end
    end
    if #loose.c > 0 then parts[#parts + 1] = loose end
    if #parts == 0 then parts[1] = body end
    for _, p in ipairs(parts) do remap(p) end
    book.chapters = {}
    for i, p in ipairs(parts) do book.chapters[i] = { size = max(1, #DR.textContent(p)) } end
    local tocs = {}
    function book.load(i)
        local ch = DR.toBlocks(parts[i], DR.newCss():index(), { resolve = function(s) if s:sub(1, 1) == "#" then return s:sub(2) end end })
        tocs[i] = ch.heads
        return ch
    end
    function book.imageData(ref) local b = bin[ref]; return b and DR.base64(DR.textContent(b)) end
    function book.coverData() return book.coverRef and book.imageData(book.coverRef) end
    function book.getToc()
        local toc = {}
        for i, p in ipairs(parts) do
            local t = DR.findFirst(p, "h2")
            if t then toc[#toc + 1] = { title = DR.textContent(t), c = i, depth = 0 } end
        end
        return toc
    end
    function book.close() end
    return book
end

-- ---------------------------------------------------------------- single HTML / MD / TXT
local function openHTMLFile(path, md)
    local f = io.open(path, "rb"); if not f then return nil, "cannot open" end
    local d = f:read("*a") or ""; f:close()
    if #d > 8 * 1024 * 1024 then return nil, "The document is too large for DReader." end
    d = toUtf8(d)
    if md then d = DR.mdToHtml(d) end
    local dom = DR.parseHTML(d)
    local base = dirOf(path)
    local book = { kind = "text", format = md and "md" or "html" }
    local t = DR.findFirst(dom, "title")
    book.title = t and DR.textContent(t) or ""
    if md then book.title = DR.textContent(DR.findFirst(dom, "h1") or { c = {} }) end
    local function rd(p) local fh = io.open(p, "rb"); if not fh then return nil end local x = fh:read("*a"); fh:close(); return x end
    local css = cssFrom(dom, function(p) return rd(p) end, base, {})
    -- resolve absolute for disk files
    local function rawcss()
        local c = DR.newCss()
        for _, node in ipairs(DR.findAll(dom, "link")) do
            if (node.a.rel or ""):lower():find("stylesheet") and node.a.href then
                local x = rd(resolvePath(base, node.a.href))
                if x then c:add(toUtf8(x)) end
            end
        end
        for _, node in ipairs(DR.findAll(dom, "style")) do if node.raw then c:add(node.raw) end end
        return c:index()
    end
    css = rawcss()
    local ch
    book.chapters = { { size = max(1, estimateText(d)) } }
    function book.load(i)
        if ch then return ch end
        ch = DR.toBlocks(dom, css, { resolve = function(src)
            if src:find("^data:") or src:find("^%a+://") then return nil end
            return resolvePath(base, src)
        end })
        return ch
    end
    function book.imageData(ref) return rd(ref) end
    function book.getToc()
        local c = book.load(1)
        local toc = {}
        for _, h in ipairs(c.heads) do toc[#toc + 1] = { title = h.title, c = 1, off = h.off, depth = h.level - 1 } end
        return toc
    end
    function book.close() end
    return book
end

local TXT_HEAD = { "^Chapter%s", "^chapter%s", "^CHAPTER%s", "^Kapitel%s", "^KAPITEL%s", "^Prologue", "^Epilogue", "^Prolog", "^Epilog", "^PROLOG", "^Teil%s", "^TEIL%s", "^Part%s", "^PART%s", "^Book%s", "^Buch%s" }
local function openTXT(path)
    local f = io.open(path, "rb"); if not f then return nil, "cannot open" end
    local d = f:read("*a") or ""; f:close()
    d = toUtf8(d):gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines, nonblank, blank, midlen = {}, 0, 0, 0
    for line in (d .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
        if line:find("%S") then nonblank = nonblank + 1; if #line >= 40 and #line <= 100 then midlen = midlen + 1 end else blank = blank + 1 end
    end
    local hard = blank > nonblank * 0.05 and midlen > nonblank * 0.6
    -- paragraphs
    local paras = {}
    if hard then
        local buf = {}
        for _, l in ipairs(lines) do
            if l:find("%S") then buf[#buf + 1] = trim(l)
            elseif #buf > 0 then paras[#paras + 1] = table.concat(buf, " "); buf = {} end
        end
        if #buf > 0 then paras[#paras + 1] = table.concat(buf, " ") end
    else
        for _, l in ipairs(lines) do if l:find("%S") then paras[#paras + 1] = trim(l) end end
    end
    local chunks, cur, size = {}, {}, 0
    for _, p in ipairs(paras) do
        cur[#cur + 1] = p; size = size + #p
        if size > 60000 then chunks[#chunks + 1] = cur; cur, size = {}, 0 end
    end
    if #cur > 0 or #chunks == 0 then chunks[#chunks + 1] = cur end
    local book = { kind = "text", format = "txt", chapters = {} }
    local toc = {}
    for i, c in ipairs(chunks) do
        local sz = 0
        for _, p in ipairs(c) do sz = sz + #p + 1 end
        book.chapters[i] = { size = max(1, sz) }
    end
    local loaded = {}
    function book.load(ci)
        local blocks, off = {}, 0
        local heads = {}
        for _, p in ipairs(chunks[ci]) do
            local w, st, sp = {}, {}, {}
            for word in p:gmatch("%S+") do w[#w + 1] = word; st[#st + 1] = 0; sp[#sp + 1] = (#w > 1) and 1 or 0 end
            local isHead = #p <= 60 and (function() for _, pat in ipairs(TXT_HEAD) do if p:find(pat) then return true end end end)()
            local len = #p + 1
            blocks[#blocks + 1] = { t = "p", w = w, st = st, sp = sp, n = #w, len = len, c0 = off, ml = 0, mr = 0, ind = (not isHead) and (hard and 1.2 or 0) or 0,
                gap = isHead and 1 or (hard and 0.1 or 0.5), size = isHead and 1.2 or 1, head = isHead and 2 or nil, keep = isHead, align = isHead and "center" or nil }
            if isHead then heads[#heads + 1] = { level = 1, title = p, off = off } end
            off = off + len
        end
        loaded[ci] = heads
        return { blocks = blocks, anchors = {}, heads = heads, total = max(1, off) }
    end
    function book.getToc()
        local t = {}
        for ci = 1, #chunks do
            local hs = loaded[ci]
            if not hs then book.load(ci); hs = loaded[ci] end
            for _, h in ipairs(hs) do t[#t + 1] = { title = h.title, c = ci, off = h.off, depth = 0 } end
        end
        return t
    end
    function book.imageData() return nil end
    function book.close() end
    return book
end

function DR.openBook(path, opts)
    local e = extOf(path)
    if e == "epub" then return openEPUB(path, opts)
    elseif e == "fb2" then return openFB2(path)
    elseif e == "html" or e == "htm" or e == "xhtml" then return openHTMLFile(path, false)
    elseif e == "md" or e == "markdown" then return openHTMLFile(path, true)
    elseif e == "txt" then return openTXT(path) end
    return nil, "This file type is not supported by the DReader engine."
end
end

-- ---------------------------------------------------------------- host glue: fonts, images, drawing for the DR engine
local Host = { family = "serif", faces = {}, mets = {}, imgs = {}, imgOrder = {}, provider = nil }
do
    local ffi = require("ffi")
    local RTok, RenderText = pcall(require, "ui/rendertext")
    local files
    local function scan()
        files = {}
        local root = Font.fontdir or "fonts"
        local function walk(d, depth)
            local ok, iter, dd = pcall(lfs.dir, d)
            if not ok or type(iter) ~= "function" then return end
            for name in iter, dd do
                if name:sub(1, 1) ~= "." then
                    local p = d .. "/" .. name
                    local a = lfs.attributes(p)
                    if a and a.mode == "directory" and depth < 3 then walk(p, depth + 1)
                    elseif a and a.mode == "file" and name:lower():match("%.[to]tf$") and not files[name] then
                        files[name] = p:sub(#root + 2)
                    end
                end
            end
        end
        walk(root, 0)
    end
    local FAM = {
        serif = { "NotoSerif-Regular.ttf", "NotoSerif-Bold.ttf", "NotoSerif-Italic.ttf", "NotoSerif-BoldItalic.ttf", "infont" },
        sans = { "NotoSans-Regular.ttf", "NotoSans-Bold.ttf", "NotoSans-Italic.ttf", "NotoSans-BoldItalic.ttf", "cfont" },
        mono = { "DroidSansMono.ttf", "DroidSansMono.ttf", "DroidSansMono.ttf", "DroidSansMono.ttf", "scfont" },
    }
    local function pick(fam, bold, italic)
        if not files then scan() end
        local f = FAM[fam] or FAM.serif
        local idx = 1 + (bold and 1 or 0) + (italic and 2 or 0)
        local name = f[idx]
        if files[name] then return files[name], bold and idx % 2 == 1 and idx ~= 2 and idx ~= 4 end
        if files[f[1]] then return files[f[1]], bold end
        if fam == "mono" and files["NotoSansMono-Regular.ttf"] then return files["NotoSansMono-Regular.ttf"], bold end
        return f[5], bold
    end
    local function getFace(name, size)
        local key = name .. ":" .. size
        local f = Host.faces[key]
        if f then return f end
        local k = Screen:scaleBySize(1000) / 1000
        local arg = size / k
        local ok, face = pcall(Font.getFace, Font, name, arg)
        if (not ok or not face) and name ~= "cfont" then ok, face = pcall(Font.getFace, Font, "cfont", arg) end
        if ok and face and tonumber(face.size) and math.abs(face.size - size) > 1 then
            local ok2, f2 = pcall(Font.getFace, Font, name, arg * size / face.size)
            if ok2 and f2 then face = f2 end
        end
        if not ok then face = nil end
        Host.faces[key] = face or false
        return face
    end
    local function decode(bits)
        local bold = bits % 2 == 1
        local italic = bits % 4 >= 2
        local mono = bits % 32 >= 16
        local name, synth = pick(mono and "mono" or Host.family, bold, italic)
        return name, synth
    end
    local function measure(bits, size, str)
        local name, synth = decode(bits)
        local face = getFace(name, size)
        if not face then return #str * size * 0.5 end
        if RTok then
            local ok, r = pcall(RenderText.sizeUtf8Text, RenderText, 0, 1e9, face, str, true, synth)
            if ok and type(r) == "table" and tonumber(r.x) then return math.ceil(r.x) end
        end
        local ok, w = pcall(function()
            local tw = TextWidget:new{ text = str, face = face, bold = synth }
            local x = tw:getSize().w
            tw:free()
            return x
        end)
        return ok and w or #str * size * 0.5
    end
    local function metrics(bits, size)
        local key = Host.family .. size
        local m = Host.mets[key]
        if not m then
            local name = decode(0)
            local face = getFace(name, size)
            local h, asc = size * 1.3, size
            if face then
                pcall(function()
                    local tw = TextWidget:new{ text = "Ag", face = face }
                    h = tw:getSize().h
                    asc = tw:getBaseline()
                    tw:free()
                end)
            end
            m = { h, asc }
            Host.mets[key] = m
        end
        return m[1], m[2]
    end
    local drawFail
    DR.env.measure = measure
    DR.env.metrics = metrics
    DR.env.ascent = function(bits, size) local _, a = metrics(bits, size) return a end
    DR.env.draw = function(bb, x, base, bits, size, str, fg)
        local name, synth = decode(bits)
        local face = getFace(name, size)
        if not face then return end
        if RTok and not drawFail then
            local ok = pcall(RenderText.renderUtf8Text, RenderText, bb, x, base, face, str, true, synth, fg)
            if ok then return end
            drawFail = true
        end
        pcall(function()
            local _, asc = metrics(0, size)
            local tw = TextWidget:new{ text = str, face = face, bold = synth, fgcolor = fg }
            tw:paintTo(bb, x, base - asc)
            tw:free()
        end)
    end
    DR.env.rule = function(bb, x, y, w, fg) pcall(bb.paintRect, bb, x, y, w, math.max(1, Screen:scaleBySize(1)), fg) end
    DR.env.placeholder = function(bb, x, y, w, h, alt, fg)
        pcall(function()
            local t = math.max(1, Screen:scaleBySize(1))
            bb:paintRect(x, y, w, t, fg); bb:paintRect(x, y + h - t, w, t, fg)
            bb:paintRect(x, y, t, h, fg); bb:paintRect(x + w - t, y, t, h, fg)
        end)
    end

    -- decoded image -> Blitbuffer (BB8 for gray, otherwise the screen's type, RGB32 fallback)
    function Host.imgToBB(img)
        local w, h, d = img.w, img.h, img.data
        local stype = Screen.bb and Screen.bb:getType()
        local t
        if img.comps == 1 or stype == Blitbuffer.TYPE_BB8 then t = Blitbuffer.TYPE_BB8 else t = Blitbuffer.TYPE_BBRGB32 end
        local bb = Blitbuffer.new(w, h, t)
        local p = ffi.cast("uint8_t*", bb.data)
        local stride = bb.stride or (w * (t == Blitbuffer.TYPE_BB8 and 1 or 4))
        if t == Blitbuffer.TYPE_BB8 then
            if img.comps == 1 then
                for y = 0, h - 1 do ffi.copy(p + y * stride, d + y * w, w) end
            else
                for y = 0, h - 1 do
                    local o, q = y * w * 3, y * stride
                    for x = 0, w - 1 do
                        p[q + x] = (d[o] * 77 + d[o + 1] * 151 + d[o + 2] * 28) / 256
                        o = o + 3
                    end
                end
            end
        else
            for y = 0, h - 1 do
                local o, q = y * w * 3, y * stride
                for x = 0, w - 1 do
                    p[q], p[q + 1], p[q + 2], p[q + 3] = d[o], d[o + 1], d[o + 2], 255
                    o = o + 3; q = q + 4
                end
            end
        end
        return bb
    end

    DR.env.drawImage = function(bb, ref, x, y, w, h)
        local key = ref .. ":" .. w .. "x" .. h
        local cached = Host.imgs[key]
        if cached == nil then
            local ok, res = pcall(function()
                local data = Host.provider and Host.provider(ref)
                local img = data and DR.decodeImage(data, w)
                if not img then return false end
                return Host.imgToBB(DR.scale(img, w, h))
            end)
            cached = ok and res or false
            Host.imgs[key] = cached
            Host.imgOrder[#Host.imgOrder + 1] = key
            while #Host.imgOrder > 4 do
                local old = table.remove(Host.imgOrder, 1)
                local ob = Host.imgs[old]
                if ob then pcall(ob.free, ob) end
                Host.imgs[old] = nil
            end
        end
        if cached then bb:blitFrom(cached, x, y, 0, 0, w, h)
        else DR.env.placeholder(bb, x, y, w, h, nil, Blitbuffer.COLOR_BLACK) end
    end
    function Host.freeImages()
        for k, b in pairs(Host.imgs) do if b then pcall(b.free, b) end end
        Host.imgs, Host.imgOrder = {}, {}
    end
    function Host.reset() Host.faces, Host.mets = {}, {} end
end

-- ---------------------------------------------------------------- session
-- One open document: a book (own text engine) or a stack of images (own decoders).
local Session = {}
Session.__index = Session
local IMG_EXT = { png = true, jpg = true, jpeg = true, gif = true, bmp = true }
local function naturalKey(s) return (s:lower():gsub("%d+", function(d) return string.format("%012d", tonumber(d)) end)) end
local function readFile(p) local f = io.open(p, "rb"); if not f then return nil end local d = f:read("*a"); f:close(); return d end

function Session.open(path, cfg, W, H, px, store)
    local e = extOf(path)
    local s = setmetatable({ path = path, real = path, page = 1, count = 1, offy = 0, W = W, H = H, tsig = "", dims = {}, chs = {}, lay = {}, lru = {} }, Session)
    if IMG_EXT[e] then
        s.paged, s.kind = true, "image"
        local dir = path:match("^(.*)/[^/]*$") or "."
        local list = {}
        local ok, iter, d = pcall(lfs.dir, dir)
        if ok and type(iter) == "function" then
            for name in iter, d do
                if name:sub(1, 1) ~= "." and IMG_EXT[extOf(name)] and #list < 800 then list[#list + 1] = name end
            end
        end
        table.sort(list, function(a, b) return naturalKey(a) < naturalKey(b) end)
        local name = basename(path)
        s.pages = {}
        for i, n in ipairs(list) do
            s.pages[i] = { file = dir .. "/" .. n }
            if n == name then s.page = i end
        end
        if #s.pages == 0 then s.pages[1] = { file = path } end
        s.read = function(i) return readFile(s.pages[i].file) end
        s.title = prettyName(path)
    elseif e == "cbz" then
        s.paged, s.kind = true, "image"
        local z, err = DR.zipOpen(path)
        if not z then return nil, _("This file could not be opened. It may be damaged or protected by DRM.") end
        s.zip = z
        local names = {}
        for _, en in ipairs(z.list) do
            if IMG_EXT[extOf(en.name)] and not en.name:find("__MACOSX", 1, true) and not basename(en.name):find("^%.") then names[#names + 1] = en.name end
        end
        table.sort(names, function(a, b) return naturalKey(a) < naturalKey(b) end)
        if #names == 0 then z:close(); return nil, _("This archive contains no images.") end
        s.pages = {}
        for i, n in ipairs(names) do s.pages[i] = { name = n } end
        s.read = function(i) return z:read(s.pages[i].name) end
        s.title = prettyName(path)
    else
        s.kind = "text"
        local m = store and store.meta[path]
        local size = lfs.attributes(path, "size")
        local sizes = (m and m.fsize == size and type(m.sizes) == "table") and m.sizes or nil
        local book, err = DR.openBook(path, { sizes = sizes })
        if not book then return nil, tostring(err or _("This file could not be opened.")) end
        s.book = book
        s.title = book.title and oneLine(book.title) or ""
        s.sizes, s.fsize = (not sizes) and book.sizes or nil, size
        s.nch = #book.chapters
        s.cstart, s.total = {}, 0
        for i, c in ipairs(book.chapters) do s.cstart[i] = s.total; s.total = s.total + c.size end
        s.total = math.max(1, s.total)
        s.cur = { c = 1, p = 1 }
    end
    s:relayout(cfg, W, H, px)
    return s
end

function Session:keyOf(cfg, W, H, px)
    return table.concat({ W, H, px(1), cfg.font, cfg.margin, cfg.spacing, cfg.face, cfg.fit, tostring(cfg.crop), cfg.align }, ":")
end

-- ---- text engine glue
function Session:loadChapter(i)
    local ch = self.chs[i]
    if ch then return ch end
    Host.provider = self.book.imageData
    local ok, res = pcall(self.book.load, i)
    if not ok or type(res) ~= "table" then res = { blocks = {}, anchors = {}, heads = {}, total = 1 } end
    self.chs[i] = res
    self.chsOrder = self.chsOrder or {}
    self.chsOrder[#self.chsOrder + 1] = i
    while #self.chsOrder > 4 do
        local old = table.remove(self.chsOrder, 1)
        if old ~= self.cur.c then self.chs[old] = nil end
    end
    return res
end

function Session:layoutChapter(i)
    local pages = self.lay[i]
    if pages then return pages end
    local ch = self:loadChapter(i)
    Host.family = self.cfg.face
    Host.provider = self.book.imageData
    local ok, res = pcall(DR.layout, ch, self.LP)
    if not ok then
        self.err = tostring(res)
        res = { { items = {}, start = 0, stop = 1 } }
    end
    self.lay[i] = res
    self.layOrder = self.layOrder or {}
    self.layOrder[#self.layOrder + 1] = i
    while #self.layOrder > 4 do
        local old = table.remove(self.layOrder, 1)
        if old ~= self.cur.c then self.lay[old] = nil end
    end
    return res
end

function Session:syncText()
    local c, p = self.cur.c, self.cur.p
    local pages = self:layoutChapter(c)
    p = clamp(p, 1, #pages)
    self.cur.p = p
    local ch = self.chs[c] or self:loadChapter(c)
    local csz = self.book.chapters[c].size
    local tot = math.max(1, ch.total)
    local g0 = self.cstart[c] + pages[p].start / tot * csz
    local g1 = self.cstart[c] + pages[p].stop / tot * csz
    self.gpos = g0
    self.page = clamp(math.floor(g0 / self.cpp) + 1, 1, self.count)
    self.pct = clamp(math.floor(g1 * 100 / self.total + 0.5), 0, 100)
    if c == self.nch and p == #pages then self.pct = 100 end
end

function Session:gotoPos(c, off)
    c = clamp(c, 1, self.nch)
    local pages = self:layoutChapter(c)
    self.cur = { c = c, p = DR.findPage(pages, off or 0) }
    self:syncText()
end

function Session:gotoGlobal(g)
    g = clamp(g, 0, self.total - 1)
    local c = 1
    for i = 1, self.nch do if self.cstart[i] <= g then c = i end end
    local csz = math.max(1, self.book.chapters[c].size)
    local ch = self:loadChapter(c)
    self:gotoPos(c, math.floor((g - self.cstart[c]) / csz * ch.total))
end

function Session:relayout(cfg, W, H, px)
    self.cfg, self.W, self.H, self.px = cfg, W, H, px
    self.drawn = nil
    if self.paged then
        self.count = #self.pages
        self.page = clamp(self.page, 1, self.count)
        self.pcache = nil
        self.geoms = {}
        self.key = self:keyOf(cfg, W, H, px)
        return
    end
    local keep
    if self.laidOut then
        local pages = self.lay[self.cur.c]
        keep = { c = self.cur.c, off = pages and pages[self.cur.p] and pages[self.cur.p].start or 0 }
    end
    Host.family = cfg.face
    Host.reset()
    self.lay, self.layOrder = {}, {}
    local fs = px(cfg.font)
    local x0 = px(MARGINS[cfg.margin])
    local y0 = math.max(px(6), math.floor(x0 * 0.7))
    local dims = self.dims
    self.LP = { x0 = x0, cw = W - 2 * x0, y0 = y0, ch = H - 2 * y0, fs = fs, lh = SPACINGS[cfg.spacing] / 100 * 0.92, align = cfg.align,
        cache = {}, imageSize = function(ref)
            local d = dims[ref]
            if d == nil then
                local data = self.book.imageData(ref)
                local iw, ih
                if data then iw, ih = DR.imageSize(data) end
                d = iw and { iw, ih } or false
                dims[ref] = d
            end
            if d then return d[1], d[2] end
        end }
    local lh = DR.env.metrics(0, fs)
    local cw = DR.env.measure(0, fs, "etaoin shrdlu cmfwyp")
    local charW = math.max(1, cw / 20)
    self.cpp = math.max(200, (self.LP.cw / charW) * (self.LP.ch / (lh * self.LP.lh)) * 0.9)
    self.count = math.max(1, math.ceil(self.total / self.cpp))
    self.key = self:keyOf(cfg, W, H, px)
    self.laidOut = true
    if keep then self:gotoPos(keep.c, keep.off) else self:gotoPos(self.cur.c, 0) end
end

function Session:setTheme(bg, fg, themed, sig)
    if self.tsig ~= sig then self.drawn = nil end
    self.bg, self.fg, self.themed, self.tsig = bg, fg, themed, sig
end

-- ---- image pages
function Session:geom(pg)
    local c = self.pcache
    if c and c.pg == pg and c.key == self.key then return c end
    if c and c.bb then pcall(c.bb.free, c.bb) end
    self.pcache = nil
    local data = self.read(pg)
    if not data then self.err = "unreadable image"; return nil end
    local img, err = DR.decodeImage(data, self.W)
    if not img then self.err = tostring(err); return nil end
    if self.cfg.crop then
        local x, y, w, h = DR.contentBox(img)
        img = DR.crop(img, x, y, w, h)
    end
    local zoom = self.cfg.fit == "page" and math.min(self.W / img.w, self.H / img.h) or self.W / img.w
    local zw, zh = math.max(1, math.floor(img.w * zoom)), math.max(1, math.floor(img.h * zoom))
    local ok, bb = pcall(function() return Host.imgToBB(DR.scale(img, zw, zh)) end)
    if not ok then self.err = tostring(bb); return nil end
    self.pcache = { pg = pg, key = self.key, bb = bb, zw = zw, zh = zh }
    return self.pcache
end

function Session:renderInto(target, bg, fg)
    target:fill(bg)
    if self.paged then
        local g = self:geom(self.page)
        if not g then return false end
        local maxoff = math.max(0, g.zh - self.H)
        self.offy = clamp(self.offy, 0, maxoff)
        local vw = math.min(self.W, g.zw)
        local vh = math.min(self.H, g.zh - math.floor(self.offy))
        local dx = math.floor((self.W - vw) / 2)
        local dy = g.zh < self.H and math.floor((self.H - vh) / 2) or 0
        target:blitFrom(g.bb, dx, dy, 0, math.floor(self.offy), vw, vh)
        return true
    end
    local pages = self:layoutChapter(self.cur.c)
    local pg = pages[self.cur.p]
    if not pg then return false end
    Host.family = self.cfg.face
    Host.provider = self.book.imageData
    local ok, err = pcall(DR.paintPage, target, pg, self.LP, fg, bg, 0, self.LP.y0)
    if not ok then self.err = tostring(err); return false end
    return true
end

function Session:draw()
    local W, H = self.W, self.H
    if not self.bb or self.bb:getWidth() ~= W or self.bb:getHeight() ~= H then
        if self.bb then pcall(self.bb.free, self.bb) end
        local ok, bb = pcall(Blitbuffer.new, W, H, Screen.bb and Screen.bb:getType() or nil)
        if not ok or not bb then self.bb = nil; return nil end
        self.bb, self.drawn = bb, nil
    end
    local pos = self.paged and (self.page .. ":" .. math.floor(self.offy)) or (self.cur.c .. ":" .. self.cur.p)
    local sig = pos .. ":" .. self.key .. ":" .. tostring(self.tsig)
    if self.drawn == sig then return self.bb end
    self.err = nil
    local bg, fg = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    if self.themed then bg, fg = self.bg, self.fg end
    if self:renderInto(self.bb, bg, fg) then self.drawn = sig; return self.bb end
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
    local pages = self:layoutChapter(self.cur.c)
    if self.cur.p < #pages then self.cur.p = self.cur.p + 1; self:syncText(); return true end
    local c = self.cur.c + 1
    while c <= self.nch do
        local np = self:layoutChapter(c)
        if not (#np == 1 and #np[1].items == 0) then self.cur = { c = c, p = 1 }; self:syncText(); return true end
        c = c + 1
    end
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
    if self.cur.p > 1 then self.cur.p = self.cur.p - 1; self:syncText(); return true end
    local c = self.cur.c - 1
    while c >= 1 do
        local np = self:layoutChapter(c)
        if not (#np == 1 and #np[1].items == 0) then self.cur = { c = c, p = #np }; self:syncText(); return true end
        c = c - 1
    end
    return false
end

function Session:jump(n)
    n = clamp(math.floor(tonumber(n) or 1), 1, self.count)
    if self.paged then self.page, self.offy = n, 0; return end
    self:gotoGlobal((n - 1) * self.cpp)
end

function Session:percent()
    if self.paged then
        local g = self.pcache
        local frac = (g and g.zh > self.H) and (self.offy / g.zh) or 0
        if self.page == self.count and g and self.offy >= g.zh - self.H - 2 then return 100 end
        return clamp(math.floor((self.page - 1 + frac) * 100 / self.count), 0, 100)
    end
    return self.pct or 0
end

function Session:position()
    local pos = { page = self.page, total = self.count, pct = self:percent(), time = os.time() }
    if self.paged then pos.offy = math.floor(self.offy)
    else
        pos.c, pos.off, pos.nc = self.cur.c, (self.lay[self.cur.c] and self.lay[self.cur.c][self.cur.p] or { start = 0 }).start, self.nch
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
    if tonumber(pos.c) and tonumber(pos.nc) == self.nch then self:gotoPos(math.floor(pos.c), tonumber(pos.off) or 0)
    elseif tonumber(pos.pct) then self:gotoGlobal(tonumber(pos.pct) / 100 * self.total) end
end

function Session:gotoEntry(r)
    if self.paged or not r.c then return self:jump(r.page) end
    local ch = self:loadChapter(r.c)
    self:gotoPos(r.c, r.off or (r.frag and ch.anchors[r.frag]) or 0)
end

function Session:bookmarkPage(b)
    if not self.paged and tonumber(b.c) and tonumber(b.nc) == self.nch then
        local sz = self.book.chapters[b.c] and self.book.chapters[b.c].size or 1
        local g = self.cstart[b.c] + math.min(1, (b.off or 0) / math.max(1, sz)) * sz
        return clamp(math.floor(g / self.cpp) + 1, 1, self.count)
    end
    return clamp(math.floor(tonumber(b.page) or 1), 1, self.count)
end

function Session:bookmarkHere(b)
    if self.paged then return math.floor(tonumber(b.page) or 0) == self.page end
    if tonumber(b.c) and tonumber(b.nc) == self.nch then
        if b.c ~= self.cur.c then return false end
        local pg = (self.lay[b.c] or {})[self.cur.p]
        return pg ~= nil and (b.off or 0) >= pg.start and (b.off or 0) < pg.stop
    end
    return self:bookmarkPage(b) == self.page
end

function Session:tocList()
    if self.toc then return self.toc end
    local out = {}
    if not self.paged then
        local ok, toc = pcall(self.book.getToc)
        if ok and type(toc) == "table" then
            for _, it in ipairs(toc) do
                if #out < 2000 and it.c and self.cstart[it.c] then
                    local g = self.cstart[it.c]
                    out[#out + 1] = { title = oneLine(it.title or ""), page = clamp(math.floor(g / self.cpp) + 1, 1, self.count),
                        depth = clamp(it.depth or 0, 0, 4), c = it.c, frag = it.frag, off = it.off }
                end
            end
        end
    end
    self.toc = out
    return out
end

function Session:chapter()
    if self.paged then return "", nil end
    local title, idx = "", nil
    local ch = self.chs[self.cur.c]
    local pages = self.lay[self.cur.c]
    local start = pages and pages[self.cur.p] and pages[self.cur.p].start or 0
    for i, it in ipairs(self:tocList()) do
        local o = it.off or (it.frag and ch and ch.anchors[it.frag]) or 0
        if it.c < self.cur.c or (it.c == self.cur.c and o <= start + 1) then title, idx = it.title, i end
    end
    return title, idx
end

function Session:close()
    if self.bb then pcall(self.bb.free, self.bb); self.bb = nil end
    if self.pcache and self.pcache.bb then pcall(self.pcache.bb.free, self.pcache.bb) end
    self.pcache = nil
    Host.freeImages()
    if self.book then pcall(self.book.close); self.book = nil end
    if self.zip then self.zip:close(); self.zip = nil end
end

-- ---------------------------------------------------------------- cover thumbnails (own raw format)
local function saveCover(img, file)
    local f = io.open(file, "wb")
    if not f then return false end
    local ffi = require("ffi")
    f:write("DRC1", string.char(img.w % 256, math.floor(img.w / 256), img.h % 256, math.floor(img.h / 256), img.comps))
    f:write(ffi.string(img.data, img.w * img.h * img.comps))
    f:close()
    return true
end
local coverCache, coverOrder = {}, {}
local function loadCover(file, w, h)
    local key = file .. ":" .. w .. "x" .. h
    local c = coverCache[key]
    if c ~= nil then return c or nil end
    local bb = false
    pcall(function()
        local d = readFile(file)
        if not d or d:sub(1, 4) ~= "DRC1" then return end
        local iw, ih, comps = d:byte(5) + d:byte(6) * 256, d:byte(7) + d:byte(8) * 256, d:byte(9)
        local ffi = require("ffi")
        local buf = ffi.new("uint8_t[?]", iw * ih * comps)
        ffi.copy(buf, d:sub(10), iw * ih * comps)
        local img = { w = iw, h = ih, comps = comps, data = buf }
        local s = math.min(w / iw, h / ih)
        bb = Host.imgToBB(DR.scale(img, math.max(1, math.floor(iw * s)), math.max(1, math.floor(ih * s))))
    end)
    coverCache[key] = bb
    coverOrder[#coverOrder + 1] = key
    while #coverOrder > 40 do
        local old = table.remove(coverOrder, 1)
        local ob = coverCache[old]
        if ob then pcall(ob.free, ob) end
        coverCache[old] = nil
    end
    return bb or nil
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

-- Title, author and cover thumbnail of one book, written to the cover cache (own raw format).
local function extractMeta(path)
    local meta = { title = "", author = "", cover = "", done = true }
    local e = extOf(path)
    pcall(function()
        local data
        if IMG_EXT[e] then
            local sz = lfs.attributes(path, "size") or 0
            if not (e == "png" and sz > 6 * 1024 * 1024) and sz < 40 * 1024 * 1024 then data = readFile(path) end
        elseif e == "cbz" then
            local z = DR.zipOpen(path)
            if z then
                local names = {}
                for _, en in ipairs(z.list) do
                    if IMG_EXT[extOf(en.name)] and not en.name:find("__MACOSX", 1, true) then names[#names + 1] = en.name end
                end
                table.sort(names, function(a, b) return naturalKey(a) < naturalKey(b) end)
                if names[1] then data = z:read(names[1]) end
                z:close()
            end
        else
            local book = DR.openBook(path, { lite = true })
            if book then
                meta.title = oneLine(book.title or "")
                meta.author = oneLine(book.author or "")
                data = book.coverData and book.coverData()
                book.close()
            end
        end
        if data then
            local img = DR.decodeImage(data, 200)
            if img then
                local th = 280
                if img.h > th then img = DR.scale(img, math.max(1, math.floor(img.w * th / img.h)), th) end
                ensureDir(STORE_DIR); ensureDir(COVER_DIR)
                local file = COVER_DIR .. "/" .. pathHash(path) .. ".drc"
                if saveCover(img, file) then meta.cover = file end
            end
        end
    end)
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
            local old = state.store.meta[todo.path]
            if old then meta.sizes, meta.fsize = old.sizes, old.fsize end
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

local PageView = Widget:extend{ src = nil, width = 0, height = 0 }
function PageView:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function PageView:getSize() return self.dimen end
function PageView:free() end
function PageView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:blitFrom(self.src, x, y, 0, 0, self.width, self.height)
end

local CoverView = Widget:extend{ src = nil, width = 0, height = 0 }
function CoverView:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function CoverView:getSize() return self.dimen end
function CoverView:free() end
function CoverView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local sw, sh = self.src:getWidth(), self.src:getHeight()
    local dx, dy = x + math.floor((self.width - sw) / 2), y + math.floor((self.height - sh) / 2)
    bb:blitFrom(self.src, dx, dy, 0, 0, sw, sh)
    pcall(bb.paintBorder, bb, dx, dy, sw, sh, 1, Blitbuffer.COLOR_BLACK)
end

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
    return Tap:new{ width = w, height = h, radius = math.floor(h * .5), callback = cb,
        shadow = primary and pal.on_variant or pal.surface_variant,
        background = primary and pal.primary or pal.surface, bordersize = 1, bordercolor = primary and pal.on_surface or pal.primary,
        content = CenterContainer:new{ dimen = Geom:new{ w = w - 2, h = h - 2 }, inner } }
end

-- style: "light" (on a dark header), "primary" (solid) or "plain" (outlined)
local function iconButton(pal, w, h, kind, cb, style, hold)
    local bg, fg, border = pal.surface, pal.on_surface, pal.primary
    if style == "light" then bg, fg, border = pal.on_primary, pal.primary, nil
    elseif style == "primary" then bg, fg, border = pal.primary, pal.on_primary, pal.on_surface end
    local bs = border and 1 or 0
    local sz = math.floor(math.min(w, h) * .56)
    return Tap:new{ width = w, height = h, radius = math.floor(math.min(w, h) * .5), callback = cb, hold_callback = hold,
        shadow = style ~= "light" and pal.surface_variant or nil,
        background = bg, bordersize = bs, bordercolor = border,
        content = CenterContainer:new{ dimen = Geom:new{ w = w - 2 * bs, h = h - 2 * bs }, Icon:new{ kind = kind, size = sz, color = fg } } }
end

local function placeholder(pal, w, h, title)
    local s = tostring(title or "")
    local sum = 0
    for i = 1, #s do sum = (sum * 31 + s:byte(i)) % 9973 end
    local r, g, b = 60 + sum % 70, 50 + math.floor(sum / 7) % 70, 55 + math.floor(sum / 13) % 70
    local okc, bg = pcall(Blitbuffer.ColorRGB32, r, g, b, 0xFF)
    local oks, spine = pcall(Blitbuffer.ColorRGB32, math.floor(r * .6), math.floor(g * .6), math.floor(b * .6), 0xFF)
    local okg, gold = pcall(Blitbuffer.ColorRGB32, 225, 205, 150, 0xFF)
    if not okc then bg = pal.primary end
    if not oks then spine = pal.on_surface end
    if not okg then gold = Blitbuffer.COLOR_WHITE end
    local sp = math.max(3, math.floor(w * .07))
    local pad = math.max(4, math.floor(w * .09))
    local tw = math.max(10, w - sp - 2 * pad - 2)
    local fs = math.max(8, math.floor(w * .13))
    local text = TextBoxWidget:new{ text = clip(s, 60), face = Font:getFace("cfont", fs), bold = true, width = tw,
        height = math.max(fs * 2, h - 2 * pad - 2), height_adjust = true, height_overflow_show_ellipsis = true,
        alignment = "center", fgcolor = Blitbuffer.COLOR_WHITE, bgcolor = bg }
    local th = text:getSize().h
    local parts = {}
    put(parts, box(w - 2, h - 2, bg), 0, 0)
    put(parts, box(sp, h - 2, spine), 0, 0)
    put(parts, box(w - sp - 2 * pad + 2, 1, gold), sp + pad - 1, math.floor(pad * .6))
    put(parts, box(w - sp - 2 * pad + 2, 1, gold), sp + pad - 1, h - 2 - math.floor(pad * .6))
    put(parts, text, sp + pad, math.max(pad, math.floor((h - 2 - th) / 2)))
    return FrameContainer:new{ width = w, height = h, padding = 0, bordersize = 1, color = Blitbuffer.COLOR_BLACK, radius = 2,
        background = bg, OverlapGroup:new{ dimen = Geom:new{ w = w - 2, h = h - 2 }, allow_mirroring = false, unpack(parts) } }
end

local function imageWidget(path, w, h)
    if not exists(path) then return nil end
    local bb = loadCover(path, w - 2, h - 2)
    if not bb then return nil end
    return CoverView:new{ src = bb, width = w, height = h }
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
    put(list, box(W, px(2), pal.surface_variant), 0, y0 + hh)
    return hh + px(3)
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
    if title == "" then title = s.title or "" end
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
    local s, err = Session.open(path, state.store.settings, context.dimen.w, viewHeightOf(context.dimen.h, px, state.store.settings), px, state.store)
    hideBusy(busy)
    if not s then
        state.status = err or _("This file could not be opened.")
        state.view = "library"
        if not quiet then refresh(context) end
        return false
    end
    state.session = s
    if s.sizes then
        local m = state.store.meta[path] or {}
        state.store.meta[path] = m
        m.sizes, m.fsize = s.sizes, s.fsize
    end
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
        if s:bookmarkHere(b) then return i, b end
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
        table.insert(list, 1, { page = pos.page, c = pos.c, off = pos.off, nc = pos.nc, pct = pos.pct, total = pos.total, offy = pos.offy,
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
    put(list, Tap:new{ width = W - 2 * margin, height = rh, radius = px(14), background = pal.surface, shadow = pal.surface_variant,
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
    put(parts, FrameContainer:new{ width = pw, height = ph, padding = 0, bordersize = 1, color = pal.on_surface, radius = math.floor(ph / 2), background = pal.primary,
        CenterContainer:new{ dimen = Geom:new{ w = pw - 2, h = ph - 2 }, inner } }, tx, by)
    put(list, Tap:new{ width = W - 2 * margin, height = hh, radius = px(18), background = pal.surface, shadow = pal.surface_variant,
        bordersize = 1, bordercolor = pal.primary,
        content = OverlapGroup:new{ dimen = Geom:new{ w = W - 2 * margin - 2, h = hh - 2 }, allow_mirroring = false, unpack(parts) },
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
        put(list, PageView:new{ src = bb, width = W, height = view_h }, 0, top)
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
                    s:restore({ page = r.page, c = r.c, off = r.off, nc = r.nc, pct = r.pct, total = r.total, offy = r.offy })
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
                    s:gotoEntry(r)
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
            { "Mono", cfg.face == "mono", function() change("face", "mono") end },
        })
        choiceRow(_("Alignment"), {
            { _("Book"), cfg.align == "book", function() change("align", "book") end },
            { _("Left"), cfg.align == "left", function() change("align", "left") end },
            { _("Justify"), cfg.align == "justify", function() change("align", "justify") end },
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
    version = "4.0.0",
    title = "DReader",
    subtitle = "EPUB, FB2, TXT, comics and images, own reading engine",
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
