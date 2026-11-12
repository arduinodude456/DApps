--[[--
DLib for AppDock.

A small library app: search free books on Open Library and Archive.org, browse
categories, read details, download books to /mnt/onboard/Books, open them
straight in the reader and keep a list of recent downloads.

Covers come from covers.openlibrary.org and archive.org/services/img and are
cached locally. Only freely downloadable (public) files can be fetched;
borrow-only titles are shown but cannot be downloaded.

Like DChat, DLib keeps its state on the pane instance, takes colours from the
AppDock palette, uses the AppDock keyboard for text input, asks for Wi-Fi when
the device has a Wi-Fi toggle and reports problems in a status line instead of
failing silently.
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
local _ = require("gettext")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local SETTINGS_KEY = "appdock_dlib_v1"
local BOOKS_DIR = "/mnt/onboard/Books"
local COVER_DIR = DataStorage:getDataDir() .. "/appdock_dlib_covers"
local OL = "https://openlibrary.org"
local IA = "https://archive.org"
local PAGE_SIZE = 40
local MAX_RECENTS = 24
local MAX_JSON = 4 * 1024 * 1024
local MAX_COVER = 1024 * 1024
local MAX_BOOK = 400 * 1024 * 1024
local COVER_BATCH = 4
local COVER_KEEP_SECONDS = 30 * 24 * 3600

local CATEGORIES = {
    { "Fiction", "fiction" }, { "Sci-Fi", "science fiction" }, { "Fantasy", "fantasy" },
    { "Mystery", "mystery" }, { "Romance", "romance" }, { "History", "history" },
    { "Science", "science" }, { "Philosophy", "philosophy" }, { "Children", "juvenile fiction" },
    { "Poetry", "poetry" }, { "Computers", "computers" }, { "Biography", "biography" },
}
local FORMAT_RANK = { epub = 1, pdf = 2, mobi = 3, azw3 = 4, fb2 = 5, djvu = 6, cbz = 7, txt = 8 }

-- ---------------------------------------------------------------- helpers
local function trim(v) if type(v) ~= "string" then return "" end return v:match("^%s*(.-)%s*$") or "" end
local function scale(v) return Device.screen:scaleBySize(v) end
local function urlEncode(v) return (tostring(v):gsub("([^%w%-_%.~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local a = lfs.attributes(path)
    return a ~= nil and a.mode == "file" and (a.size or 0) > 0
end
local function firstOf(v) if type(v) == "table" then return v[1] end return v end
local function oneLine(v) return trim((tostring(v or ""):gsub("%s+", " "))) end

-- Cut a string to at most n bytes without splitting a UTF-8 character.
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
local function sanitize(v)
    v = tostring(v or ""):gsub('[%c/\\:*?"<>|]', "_")
    v = trim((v:gsub("%s+", " ")))
    v = cutUtf8(v, 90)
    v = v:gsub("[%. ]+$", "")
    if v == "" then v = "book" end
    return v
end
local function humanSize(n)
    n = tonumber(n) or 0
    if n <= 0 then return "" end
    if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
    return string.format("%d KB", math.max(1, math.floor(n / 1024)))
end
local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64) end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
local function stripHtml(s)
    s = tostring(s or "")
    s = s:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n"):gsub("<[^>]+>", "")
    s = s:gsub("&#(%d+);", function(d) local n = tonumber(d) if n and n > 0 and n < 0x110000 then return utf8char(n) end return "" end)
    s = s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
    s = s:gsub("[ \t]+", " "):gsub("\n%s*\n%s*\n+", "\n\n")
    return trim(s)
end
-- Lucene special characters in a user query would break both search APIs.
local function cleanQuery(q)
    q = tostring(q or ""):gsub('[%+%-&|!%(%){}%[%]%^"~%*%?:\\/]', " ")
    return trim((q:gsub("%s+", " ")))
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

local function blank(w, h) return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, HorizontalSpan:new{ width = 0 } } end

-- ---------------------------------------------------------------- network
-- Only devices with a Wi-Fi switch (Kobo, Kindle ...) are asked to go online;
-- everywhere else the request is simply tried.
local function wifiKnownOff()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or type(NetworkMgr) ~= "table" or type(NetworkMgr.isWifiOn) ~= "function" then return false, nil end
    if type(Device.hasWifiToggle) == "function" and not Device:hasWifiToggle() then return false, nil end
    local ok_on, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return ok_on and on == false, NetworkMgr
end

local function withNetwork(state, context, fn)
    local off, NetworkMgr = wifiKnownOff()
    if off then
        if NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
            pcall(NetworkMgr.runWhenOnline, NetworkMgr, fn)
            return
        end
        state.status = _("Wi-Fi is off. Turn it on and try again.")
        context.requestRebuild("ui")
        return
    end
    fn()
end

-- opts: file (open file handle), max_bytes, accept, connect, total (seconds)
-- Returns body (or true for file mode) or nil, message, http_code.
local function request(url, opts)
    opts = opts or {}
    local ok_https, https = pcall(require, "ssl.https")
    local ok_socket, socket = pcall(require, "socket")
    local ok_util, socketutil = pcall(require, "socketutil")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not (ok_https and ok_socket and ok_util and ok_ltn) then return nil, _("HTTPS support is unavailable.") end
    local total = opts.total or 30
    local deadline = os.time() + total
    local chunks, received = {}, 0
    local function sink(chunk, sink_err)
        if sink_err then return nil, sink_err end
        if chunk then
            if os.time() > deadline then return nil, "timeout" end
            received = received + #chunk
            if opts.max_bytes and received > opts.max_bytes then return nil, "too large" end
            if opts.file then
                local ok_w, werr = opts.file:write(chunk)
                if not ok_w then return nil, werr or "write error" end
            else
                chunks[#chunks + 1] = chunk
            end
        end
        return 1
    end
    socketutil:set_timeout(opts.connect or 10, total)
    local ok, code, headers = pcall(function()
        return socket.skip(1, https.request{ url = url, method = "GET", sink = sink,
            headers = { accept = opts.accept or "*/*", ["user-agent"] = "AppDock-DLib/1.1" } })
    end)
    socketutil:reset_timeout()
    local numeric = tonumber(code)
    if not ok or not headers or not numeric then
        if code == "timeout" then return nil, _("The service took too long to answer.") end
        if code == "too large" then return nil, _("The file is too large.") end
        return nil, _("Could not reach the service. Check Wi-Fi.")
    end
    if numeric < 200 or numeric > 299 then
        return nil, string.format(_("The service answered with HTTP %d."), numeric), numeric
    end
    if opts.file then return true end
    return table.concat(chunks)
end

local function getJson(url)
    local body, err = request(url, { max_bytes = MAX_JSON, accept = "application/json", connect = 10, total = 40 })
    if not body then return nil, err end
    local ok_json, JSON = pcall(require, "json")
    if not ok_json then return nil, _("JSON support is unavailable.") end
    local ok, data = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok or type(data) ~= "table" then return nil, _("The service returned invalid data.") end
    return data
end

local function looksLikeHtml(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = (f:read(256) or ""):lower()
    f:close()
    return head:find("<!doctype html", 1, true) ~= nil or head:find("<html", 1, true) ~= nil
end

local function downloadFile(url, path)
    local tmp = path .. ".part"
    local f = io.open(tmp, "wb")
    if not f then return false, _("The file could not be written.") end
    local ok, err, code = request(url, { file = f, max_bytes = MAX_BOOK, connect = 15, total = 1800 })
    pcall(f.close, f)
    if not ok then
        pcall(os.remove, tmp)
        if code == 401 or code == 403 then return false, _("This file is not freely downloadable (borrow-only).") end
        return false, err or _("The download failed.")
    end
    if not exists(tmp) or looksLikeHtml(tmp) then
        pcall(os.remove, tmp)
        return false, _("The download failed.")
    end
    if not os.rename(tmp, path) then
        pcall(os.remove, tmp)
        return false, _("The file could not be written.")
    end
    return true
end

-- ---------------------------------------------------------------- data
local function loadStore()
    local raw = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(raw) ~= "table" then raw = {} end
    local recents = {}
    if type(raw.recents) == "table" then
        for _, r in ipairs(raw.recents) do
            if type(r) == "table" and type(r.path) == "string" and #recents < MAX_RECENTS then
                recents[#recents + 1] = { title = tostring(r.title or ""), author = tostring(r.author or ""),
                    path = r.path, cover = type(r.cover) == "string" and r.cover or "", time = tonumber(r.time) or 0 }
            end
        end
    end
    return { recents = recents, source = raw.source == "ia" and "ia" or "ol", free_only = raw.free_only ~= false }
end
local function saveStore(state)
    G_reader_settings:saveSetting(SETTINGS_KEY, { recents = state.store.recents, source = state.store.source, free_only = state.store.free_only })
end

local function coverUrl(item)
    if item.cover_i then return "https://covers.openlibrary.org/b/id/" .. item.cover_i .. "-M.jpg?default=false" end
    if item.ia then return IA .. "/services/img/" .. urlEncode(item.ia) end
end
local function coverFile(item)
    local key = item.cover_i and ("ol" .. item.cover_i) or (item.ia and ("ia_" .. sanitize(item.ia)))
    if not key then return nil end
    return COVER_DIR .. "/" .. key .. ".jpg"
end
local function looksLikeImage(b)
    return #b > 200 and (b:sub(1, 2) == "\255\216" or b:sub(1, 4) == "\137PNG" or b:sub(1, 3) == "GIF")
end

local function parseOL(data)
    local out = {}
    for _, d in ipairs(type(data.docs) == "table" and data.docs or {}) do
        if type(d) == "table" and type(d.title) == "string" then
            local ia_list = {}
            if type(d.ia) == "table" then
                for _, id in ipairs(d.ia) do
                    if type(id) == "string" and id ~= "" and #ia_list < 4 then ia_list[#ia_list + 1] = id end
                end
            end
            out[#out + 1] = { src = "ol", title = oneLine(d.title), author = oneLine(firstOf(d.author_name) or ""),
                year = d.first_publish_year and tostring(d.first_publish_year) or "",
                cover_i = tonumber(d.cover_i), ia = ia_list[1], ia_list = ia_list, access = tostring(d.ebook_access or "") }
        end
    end
    return out, tonumber(data.numFound) or 0
end
local function parseIA(data, free_only)
    local out = {}
    local resp = type(data.response) == "table" and data.response or {}
    for _, d in ipairs(type(resp.docs) == "table" and resp.docs or {}) do
        if type(d) == "table" and type(d.identifier) == "string" then
            out[#out + 1] = { src = "ia", title = oneLine(firstOf(d.title) or d.identifier),
                author = oneLine(firstOf(d.creator) or ""), year = d.year and tostring(firstOf(d.year)) or "",
                ia = d.identifier, ia_list = { d.identifier }, access = free_only and "public" or "" }
        end
    end
    return out, tonumber(resp.numFound) or 0
end

local function pruneCovers()
    local ok, iter, dir = pcall(lfs.dir, COVER_DIR)
    if not ok or type(iter) ~= "function" then return end
    local limit = os.time() - COVER_KEEP_SECONDS
    for name in iter, dir do
        if name ~= "." and name ~= ".." then
            local p = COVER_DIR .. "/" .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" and (a.modification or os.time()) < limit then pcall(os.remove, p) end
        end
    end
end

local function stateFor(instance)
    if not instance.dlib then
        instance.dlib = { store = loadStore(), view = "home", results = {}, rpage = 1, recpage = 1, spage = 0, more = false,
            title = "", query = "", mode = nil, status = "", failed = {} }
        pcall(function()
            if not lfs.attributes(COVER_DIR) then lfs.mkdir(COVER_DIR) end
            pruneCovers()
        end)
    end
    return instance.dlib
end

local function refresh(context) context.requestRebuild("ui") end

local function go(state, context, view)
    state.view = view
    state.status = ""
    refresh(context)
end

-- ---------------------------------------------------------------- search
local function runSearch(state, context, mode, append)
    local source = state.store.source
    local free = state.store.free_only
    local page = append and (state.spage + 1) or 1
    local busy = showBusy(_("Searching…"))
    local data, err, items, total
    if source == "ol" then
        local q = mode.category and ('subject:"' .. mode.category .. '"') or cleanQuery(mode.query)
        q = q .. " has_fulltext:true" .. (free and " ebook_access:public" or "")
        data, err = getJson(OL .. "/search.json?q=" .. urlEncode(q) .. "&limit=" .. PAGE_SIZE ..
            "&page=" .. page .. "&fields=key,title,author_name,first_publish_year,cover_i,ia,ebook_access")
        if data then items, total = parseOL(data) end
    else
        local q = mode.category and ("subject:(" .. mode.category .. ")") or ("(" .. cleanQuery(mode.query) .. ")")
        q = q .. " AND mediatype:texts" .. (free and " AND NOT access-restricted-item:true" or "")
        data, err = getJson(IA .. "/advancedsearch.php?q=" .. urlEncode(q) ..
            "&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=creator&fl%5B%5D=year&sort%5B%5D=downloads+desc&rows=" ..
            PAGE_SIZE .. "&page=" .. page .. "&output=json")
        if data then items, total = parseIA(data, free) end
    end
    hideBusy(busy)
    if not items then state.status = err or _("Search failed."); refresh(context); return end
    if append then
        local seen = {}
        for _, it in ipairs(state.results) do seen[(it.src or "") .. (it.title or "") .. (it.author or "")] = true end
        for _, it in ipairs(items) do
            local key = (it.src or "") .. (it.title or "") .. (it.author or "")
            if not seen[key] then seen[key] = true; state.results[#state.results + 1] = it end
        end
        state.rpage = state.rpage + 1
    else
        state.results, state.rpage = items, 1
        state.mode = mode
        state.title = mode.category and (_("Category: ") .. mode.category) or ('"' .. mode.query .. '"')
    end
    state.spage = page
    state.more = page * PAGE_SIZE < total and #items > 0
    state.view = "results"
    state.status = #state.results == 0 and _("No results.") or ""
    refresh(context)
end

local function search(state, context, mode, append)
    withNetwork(state, context, function() runSearch(state, context, mode, append) end)
end

local function promptSearch(state, context)
    local dialog
    dialog = InputDialog:new{
        title = state.store.source == "ol" and _("Search Open Library") or _("Search Archive.org"),
        input = state.query or "", input_hint = _("Title, author or topic"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = trim(dialog:getInputText())
                UIManager:close(dialog)
                if #cleanQuery(q) < 2 then
                    state.status = _("Type at least two characters.")
                    refresh(context)
                    return
                end
                state.query = q
                search(state, context, { query = q }, false)
            end } } },
    }
    showInput(dialog)
end

-- ---------------------------------------------------------------- covers
local function ensureCovers(state, context, items, from, to)
    if state.cover_job or wifiKnownOff() then return end
    local todo = {}
    for i = from, to do
        local it = items[i]
        if it then
            local f = coverFile(it)
            if f and not exists(f) and not state.failed[f] and coverUrl(it) then todo[#todo + 1] = it end
        end
    end
    if #todo == 0 then return end
    state.cover_job = true
    UIManager:scheduleIn(0.3, function()
        local got = false
        pcall(function()
            for i = 1, math.min(#todo, COVER_BATCH) do
                local it = todo[i]
                local f = coverFile(it)
                local body = request(coverUrl(it), { max_bytes = MAX_COVER, accept = "image/*", connect = 6, total = 15 })
                if body and looksLikeImage(body) then
                    local h = io.open(f, "wb")
                    if h then h:write(body); h:close(); got = true else state.failed[f] = true end
                else
                    state.failed[f] = true
                end
            end
        end)
        state.cover_job = false
        if got then refresh(context) elseif #todo > COVER_BATCH then ensureCovers(state, context, todo, COVER_BATCH + 1, #todo) end
    end)
end

local function imageWidget(path, w, h)
    if not exists(path) then return nil end
    local ok_i, ImageWidget = pcall(require, "ui/widget/imagewidget")
    if not ok_i then return nil end
    local ok, widget = pcall(function()
        return ImageWidget:new{ file = path, width = w, height = h, file_do_cache = false }
    end)
    return ok and widget or nil
end

-- ---------------------------------------------------------------- widgets
local Tap = InputContainer:extend{ width = 0, height = 0, content = nil, background = nil, radius = 0, callback = nil, hold_callback = nil }
function Tap:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local o = { width = self.width, height = self.height, padding = 0, bordersize = 0, radius = self.radius,
        self.content or blank(self.width, self.height) }
    if self.background then o.background = self.background end
    self[1] = FrameContainer:new(o)
    self.ges_events = { TapDLib = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if self.hold_callback then self.ges_events.HoldDLib = { GestureRange:new{ ges = "hold", range = self.dimen } } end
end
function Tap:paintTo(bb, x, y)
    for _, ev in pairs(self.ges_events) do local r = ev[1].range r.x, r.y, r.w, r.h = x, y, self.dimen.w, self.dimen.h end
    return InputContainer.paintTo(self, bb, x, y)
end
function Tap:onTapDLib() if self.callback then self.callback() end return true end
function Tap:onHoldDLib() if self.hold_callback then self.hold_callback() end return true end

local function put(list, widget, x, y) widget.overlap_offset = { x, y } list[#list + 1] = widget return widget end

local function button(pal, w, h, text, primary, cb, size)
    local label = TextWidget:new{ text = text, face = Font:getFace("smallinfofont", size or math.max(8, math.floor(h * .36))),
        fgcolor = primary and pal.on_primary or pal.on_surface, bold = primary, max_width = math.max(1, w - 8) }
    return Tap:new{ width = w, height = h, radius = math.floor(h * .22), callback = cb,
        background = primary and pal.primary or pal.surface,
        content = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, label } }
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

local function coverBox(pal, item, w, h)
    local f = coverFile(item)
    return (f and imageWidget(f, w, h)) or placeholder(pal, w, h, item.title)
end

local function header(pal, list, W, hh, title, back, margin)
    put(list, FrameContainer:new{ width = W, height = hh, padding = 0, bordersize = 0, background = pal.primary, blank(W, hh) }, 0, 0)
    local x = margin
    if back then
        local bw = math.floor(hh * .9)
        put(list, Tap:new{ width = bw, height = hh, callback = back, content = CenterContainer:new{ dimen = Geom:new{ w = bw, h = hh },
            TextWidget:new{ text = "‹", face = Font:getFace("cfont", math.floor(hh * .6)), fgcolor = pal.on_primary, bold = true } } }, 0, 0)
        x = bw
    end
    local t = TextWidget:new{ text = title, face = Font:getFace("cfont", math.max(12, math.floor(hh * .38))), fgcolor = pal.on_primary, bold = true, max_width = math.max(1, W - x - margin) }
    put(list, t, x, math.floor((hh - t:getSize().h) / 2))
end

local function statusLine(pal, list, text, W, margin, y, px)
    put(list, TextWidget:new{ text = clip(text, 90), face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant, max_width = W - 2 * margin }, margin, y)
end

-- ---------------------------------------------------------------- recents / downloads
local function addRecent(state, item, path)
    local rec = state.store.recents
    for i = #rec, 1, -1 do if rec[i].path == path then table.remove(rec, i) end end
    local cf = coverFile(item)
    table.insert(rec, 1, { title = item.title, author = item.author, path = path, cover = (cf and exists(cf)) and cf or "", time = os.time() })
    while #rec > MAX_RECENTS do table.remove(rec) end
    saveStore(state)
end

local function destDir()
    local a = lfs.attributes(BOOKS_DIR)
    if not a then pcall(lfs.mkdir, BOOKS_DIR) a = lfs.attributes(BOOKS_DIR) end
    if a and a.mode == "directory" then return BOOKS_DIR, true end
    local home = Device.home_dir
    if type(home) == "string" and lfs.attributes(home, "mode") == "directory" then return home, false end
    return DataStorage:getDataDir(), false
end

local function runDownload(state, context, item, file)
    local dir, ok_dir = destDir()
    local base = sanitize(item.title .. (item.author ~= "" and (" - " .. item.author) or ""))
    local path = dir .. "/" .. base .. "." .. file.ext
    local n = 1
    while exists(path) do n = n + 1; path = dir .. "/" .. base .. " (" .. n .. ")." .. file.ext end
    local busy = showBusy(string.format(_("Downloading %s…"), file.ext:upper()))
    local url = IA .. "/download/" .. urlEncode(item.ia) .. "/" .. (urlEncode(file.name):gsub("%%2F", "/"))
    local ok, err = downloadFile(url, path)
    hideBusy(busy)
    if not ok then state.status = err or _("The download failed."); refresh(context); return end
    addRecent(state, item, path)
    state.last_item, state.last_path = item, path
    state.status = (ok_dir and _("Saved to ") or _("Books folder not found. Saved to ")) .. path
    pcall(function() if context.notify then context.notify{ title = "DLib", message = clip(item.title, 40), source = "DLib", priority = "normal" } end end)
    refresh(context)
end

local function download(state, context, item, file)
    withNetwork(state, context, function() runDownload(state, context, item, file) end)
end

-- Collects the downloadable formats of one Archive.org item.
local function readFiles(data)
    local files, seen = {}, {}
    for _, f in ipairs(type(data.files) == "table" and data.files or {}) do
        if type(f) == "table" and type(f.name) == "string" and not f.name:find("^__ia_thumb") then
            local ext = f.name:match("%.(%w+)$")
            ext = ext and ext:lower()
            if ext and FORMAT_RANK[ext] and tostring(f.private) ~= "true" then
                local entry = { name = f.name, ext = ext, size = tonumber(f.size) or 0 }
                local prev = seen[ext]
                if not prev or entry.size > prev.size then seen[ext] = entry end
            end
        end
    end
    for _, e in pairs(seen) do files[#files + 1] = e end
    table.sort(files, function(a, b) return FORMAT_RANK[a.ext] < FORMAT_RANK[b.ext] end)
    return files
end

local function runOpenDetail(state, context, item)
    local busy = showBusy(_("Loading details…"))
    local candidates = (type(item.ia_list) == "table" and #item.ia_list > 0) and item.ia_list or { item.ia }
    local last_err, restricted
    for _, id in ipairs(candidates) do
        local data, err = getJson(IA .. "/metadata/" .. urlEncode(id))
        if not data then
            last_err = err
            break
        end
        local meta = type(data.metadata) == "table" and data.metadata or {}
        if tostring(meta["access-restricted-item"]) == "true" then
            restricted = true
        else
            local files = readFiles(data)
            if #files > 0 then
                item.ia = id
                local desc = meta.description
                if type(desc) == "table" then
                    local parts = {}
                    for _, p in ipairs(desc) do if type(p) == "string" then parts[#parts + 1] = p end end
                    desc = table.concat(parts, " ")
                end
                state.desc = clip(stripHtml(desc), 700)
                state.files = files
                restricted = false
                last_err = nil
                break
            end
        end
    end
    hideBusy(busy)
    if #state.files == 0 then
        if last_err then state.status = last_err
        elseif restricted then state.status = _("Borrow-only title: it can only be read on archive.org.")
        else state.status = _("No downloadable files found.") end
    end
    refresh(context)
end

local function openDetail(state, context, item)
    state.item, state.files, state.status, state.desc = item, {}, "", ""
    state.view = "detail"
    if not item.ia then state.status = _("This title has no free digital copy."); refresh(context); return end
    withNetwork(state, context, function() runOpenDetail(state, context, item) end)
end

local function openBook(context, path)
    if not exists(path) then UIManager:show(InfoMessage:new{ text = _("The file no longer exists.") }) return end
    UIManager:show(ConfirmBox:new{ text = _("Open this book now?"), ok_text = _("Open"), ok_callback = function()
        local opened = false
        if type(context.openFile) == "function" then opened = pcall(context.openFile, path) end
        if not opened then
            opened = pcall(function() require("apps/reader/readerui"):showReader(path) end)
        end
        if not opened then UIManager:show(InfoMessage:new{ text = path }) end
    end })
end

-- ---------------------------------------------------------------- views
local function accessTag(it)
    if not it.ia then return _("No digital copy"), false end
    if it.access == "public" then return _("Free download"), true end
    if it.access == "borrowable" or it.access == "printdisabled" then return _("Borrow only"), false end
    return _("Archive.org"), true
end

local function viewHome(state, context, pal, W, H, px)
    local list, margin, gap = {}, math.max(px(8), math.floor(W / 40)), px(6)
    local hh = math.max(px(44), math.floor(H * .09))
    header(pal, list, W, hh, "DLib", nil, margin)
    local y = hh + gap
    local sh = math.max(px(38), math.floor(H * .075))
    put(list, button(pal, W - 2 * margin, sh, state.query ~= "" and state.query or _("Search books, authors, topics…"), false,
        function() promptSearch(state, context) end), margin, y)
    y = y + sh + gap
    local third = math.floor((W - 2 * margin - 2 * gap) / 3)
    local bh = math.max(px(30), math.floor(sh * .8))
    put(list, button(pal, third, bh, "Open Library", state.store.source == "ol", function() state.store.source = "ol"; saveStore(state); refresh(context) end, px(9)), margin, y)
    put(list, button(pal, third, bh, "Archive.org", state.store.source == "ia", function() state.store.source = "ia"; saveStore(state); refresh(context) end, px(9)), margin + third + gap, y)
    put(list, button(pal, third, bh, _("Free only"), state.store.free_only, function() state.store.free_only = not state.store.free_only; saveStore(state); refresh(context) end, px(9)), margin + 2 * (third + gap), y)
    y = y + bh + gap
    put(list, TextWidget:new{ text = _("Categories"), face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface }, margin, y)
    y = y + px(20)
    local ch = math.max(px(30), math.floor(H * .065))
    local rows = math.max(2, math.min(4, math.floor(H * .34 / (ch + gap))))
    local cw = math.floor((W - 2 * margin - 2 * gap) / 3)
    for i = 1, rows * 3 do
        local c = CATEGORIES[i]
        if not c then break end
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        put(list, button(pal, cw, ch, c[1], false, function() state.query = ""; search(state, context, { category = c[2] }, false) end, px(9)),
            margin + col * (cw + gap), y + row * (ch + gap))
    end
    y = y + rows * (ch + gap) + px(2)
    put(list, Tap:new{ width = W - 2 * margin, height = px(22), callback = function() go(state, context, "recents") end,
        content = TextWidget:new{ text = _("Recent downloads  ›"), face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface } }, margin, y)
    y = y + px(24)
    local stat_h = state.status ~= "" and px(18) or 0
    local th = H - y - margin - stat_h
    local rec = state.store.recents
    if #rec == 0 then
        put(list, TextWidget:new{ text = _("Nothing downloaded yet."), face = Font:getFace("smallinfofont", px(9)), fgcolor = pal.on_variant, max_width = W - 2 * margin }, margin, y)
    elseif th >= px(50) then
        local tw = math.floor(th * .66)
        local count = math.max(1, math.floor((W - 2 * margin + gap) / (tw + gap)))
        for i = 1, math.min(count, #rec) do
            local r = rec[i]
            local cover = (r.cover ~= "" and imageWidget(r.cover, tw, th)) or placeholder(pal, tw, th, r.title)
            put(list, Tap:new{ width = tw, height = th, content = cover, callback = function() openBook(context, r.path) end },
                margin + (i - 1) * (tw + gap), y)
        end
    end
    if state.status ~= "" then statusLine(pal, list, state.status, W, margin, H - px(16), px) end
    return list
end

local function viewResults(state, context, pal, W, H, px)
    local list, margin, gap = {}, math.max(px(8), math.floor(W / 40)), px(5)
    local hh = math.max(px(44), math.floor(H * .09))
    header(pal, list, W, hh, clip(state.title, 34), function() go(state, context, "home") end, margin)
    local fh = math.max(px(34), math.floor(H * .07))
    local rh = math.max(px(72), math.floor(H * .13))
    local area = H - hh - fh - 3 * gap - (state.status ~= "" and px(16) or 0)
    local cap = math.max(1, math.floor((area + gap) / (rh + gap)))
    local pages = math.max(1, math.ceil(#state.results / cap))
    state.rpage = math.max(1, math.min(state.rpage, pages))
    local from = (state.rpage - 1) * cap + 1
    local to = math.min(#state.results, from + cap - 1)
    local y = hh + gap
    for i = from, to do
        local it = state.results[i]
        local cw, chh = math.floor((rh - 8) * .68), rh - 8
        local parts = {}
        put(parts, coverBox(pal, it, cw, chh), margin, 4)
        local tx, tw = margin + cw + margin, W - 2 * margin - cw - margin - px(4)
        put(parts, TextWidget:new{ text = clip(it.title, 70), face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface, max_width = tw }, tx, math.floor(rh * .12))
        local sub = it.author ~= "" and it.author or _("Unknown author")
        if it.year ~= "" then sub = sub .. " · " .. it.year end
        put(parts, TextWidget:new{ text = clip(sub, 60), face = Font:getFace("smallinfofont", px(9)), fgcolor = pal.on_variant, max_width = tw }, tx, math.floor(rh * .44))
        local tag, strong = accessTag(it)
        put(parts, TextWidget:new{ text = tag, face = Font:getFace("smallinfofont", px(8)), fgcolor = strong and pal.primary or pal.on_variant, bold = strong, max_width = tw }, tx, math.floor(rh * .70))
        put(list, Tap:new{ width = W - 2 * margin, height = rh, radius = px(6), background = pal.surface,
            content = OverlapGroup:new{ dimen = Geom:new{ w = W - 2 * margin, h = rh }, allow_mirroring = false, unpack(parts) },
            callback = function() openDetail(state, context, it) end }, margin, y)
        y = y + rh + gap
    end
    if #state.results == 0 then
        put(list, TextWidget:new{ text = state.status ~= "" and state.status or _("No results."), face = Font:getFace("smallinfofont", px(10)), fgcolor = pal.on_variant, max_width = W - 2 * margin }, margin, hh + px(20))
    end
    local fy = H - fh - gap
    local bw = math.floor((W - 2 * margin - 2 * gap) * .3)
    put(list, button(pal, bw, fh, "‹ " .. _("Prev"), false, function() if state.rpage > 1 then state.rpage = state.rpage - 1; refresh(context) end end), margin, fy)
    local lbl = TextWidget:new{ text = state.rpage .. " / " .. pages .. (state.more and "+" or ""), face = Font:getFace("cfont", px(10)), fgcolor = pal.on_surface }
    put(list, lbl, math.floor((W - lbl:getSize().w) / 2), fy + math.floor((fh - lbl:getSize().h) / 2))
    put(list, button(pal, bw, fh, _("Next") .. " ›", true, function()
        if state.rpage < pages then state.rpage = state.rpage + 1; refresh(context)
        elseif state.more and state.mode then search(state, context, state.mode, true) end
    end), W - margin - bw, fy)
    if state.status ~= "" and #state.results > 0 then statusLine(pal, list, state.status, W, margin, fy - px(15), px) end
    ensureCovers(state, context, state.results, from, to)
    return list
end

local function viewDetail(state, context, pal, W, H, px)
    local list, margin, gap = {}, math.max(px(10), math.floor(W / 40)), px(6)
    local it = state.item
    local hh = math.max(px(44), math.floor(H * .09))
    header(pal, list, W, hh, clip(it.title, 30), function()
        state.view = (#state.results > 0) and "results" or "home"
        state.status = ""
        refresh(context)
    end, margin)
    local y = hh + gap
    local cw = math.floor(W * .3)
    local chh = math.floor(cw * 1.45)
    put(list, coverBox(pal, it, cw, chh), margin, y)
    local tx, tw = margin + cw + margin, W - 2 * margin - cw - margin
    put(list, TextBoxWidget:new{ text = it.title, face = Font:getFace("cfont", px(13)), bold = true, width = tw, height = math.floor(chh * .45), fgcolor = pal.on_surface, bgcolor = pal.background }, tx, y)
    put(list, TextWidget:new{ text = clip(it.author ~= "" and it.author or _("Unknown author"), 50), face = Font:getFace("smallinfofont", px(10)), fgcolor = pal.on_variant, max_width = tw }, tx, y + math.floor(chh * .5))
    local meta = (it.year ~= "" and it.year .. " · " or "") .. (it.src == "ol" and "Open Library" or "Archive.org")
    put(list, TextWidget:new{ text = meta, face = Font:getFace("smallinfofont", px(9)), fgcolor = pal.on_variant, max_width = tw }, tx, y + math.floor(chh * .62))
    y = y + chh + gap
    local bh = math.max(px(36), math.floor(H * .07))
    local can_open = state.last_item == it and exists(state.last_path)
    local nfiles = math.min(#state.files, 4)
    local nbtn = nfiles + (can_open and 1 or 0)
    local btn_area = nbtn * (bh + gap) + (state.status ~= "" and px(34) or 0)
    local dh = H - y - btn_area - margin
    if state.desc ~= "" and dh >= px(30) then
        put(list, TextBoxWidget:new{ text = state.desc, face = Font:getFace("smallinfofont", px(9)), width = W - 2 * margin, height = dh, fgcolor = pal.on_surface, bgcolor = pal.background }, margin, y)
        y = y + dh + gap
    end
    if can_open then
        put(list, button(pal, W - 2 * margin, bh, _("Open book"), true, function() openBook(context, state.last_path) end), margin, y)
        y = y + bh + gap
    end
    for i = 1, nfiles do
        local f = state.files[i]
        local label = string.format(_("Download %s"), f.ext:upper()) .. (f.size > 0 and ("  ·  " .. humanSize(f.size)) or "")
        put(list, button(pal, W - 2 * margin, bh, label, i == 1 and not can_open, function() download(state, context, it, f) end), margin, y)
        y = y + bh + gap
    end
    if state.status ~= "" then
        put(list, TextBoxWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(8)), width = W - 2 * margin, height = px(30), fgcolor = pal.on_variant, bgcolor = pal.background }, margin, H - px(34))
    end
    ensureCovers(state, context, { it }, 1, 1)
    return list
end

local function viewRecents(state, context, pal, W, H, px)
    local list, margin, gap = {}, math.max(px(8), math.floor(W / 40)), px(5)
    local hh = math.max(px(44), math.floor(H * .09))
    header(pal, list, W, hh, _("Recent downloads"), function() go(state, context, "home") end, margin)
    local rec = state.store.recents
    local fh = math.max(px(34), math.floor(H * .07))
    local rh = math.max(px(64), math.floor(H * .12))
    local cap = math.max(1, math.floor((H - hh - fh - 3 * gap + gap) / (rh + gap)))
    local pages = math.max(1, math.ceil(#rec / cap))
    state.recpage = math.max(1, math.min(state.recpage or 1, pages))
    local y = hh + gap
    if #rec == 0 then
        put(list, TextWidget:new{ text = _("Nothing downloaded yet."), face = Font:getFace("smallinfofont", px(10)), fgcolor = pal.on_variant, max_width = W - 2 * margin }, margin, y + px(10))
    end
    for i = (state.recpage - 1) * cap + 1, math.min(#rec, state.recpage * cap) do
        local r = rec[i]
        local parts = {}
        local cw, chh = math.floor((rh - 8) * .68), rh - 8
        put(parts, (r.cover ~= "" and imageWidget(r.cover, cw, chh)) or placeholder(pal, cw, chh, r.title), margin, 4)
        local tx, tw = margin + cw + margin, W - 2 * margin - cw - margin - px(4)
        put(parts, TextWidget:new{ text = clip(r.title, 60), face = Font:getFace("cfont", px(11)), bold = true, fgcolor = pal.on_surface, max_width = tw }, tx, math.floor(rh * .14))
        put(parts, TextWidget:new{ text = clip(r.author, 50), face = Font:getFace("smallinfofont", px(9)), fgcolor = pal.on_variant, max_width = tw }, tx, math.floor(rh * .48))
        put(parts, TextWidget:new{ text = os.date("%d.%m.%Y %H:%M", r.time) .. (exists(r.path) and "" or "  ·  " .. _("missing")), face = Font:getFace("smallinfofont", px(8)), fgcolor = pal.on_variant, max_width = tw }, tx, math.floor(rh * .72))
        put(list, Tap:new{ width = W - 2 * margin, height = rh, radius = px(6), background = pal.surface,
            content = OverlapGroup:new{ dimen = Geom:new{ w = W - 2 * margin, h = rh }, allow_mirroring = false, unpack(parts) },
            callback = function() openBook(context, r.path) end,
            hold_callback = function()
                UIManager:show(ConfirmBox:new{ text = _("Remove this entry from the list? The file stays on the reader."), ok_callback = function()
                    for j = #rec, 1, -1 do if rec[j] == r then table.remove(rec, j) end end
                    saveStore(state); refresh(context)
                end })
            end }, margin, y)
        y = y + rh + gap
    end
    local fy = H - fh - gap
    local bw = math.floor((W - 2 * margin - 2 * gap) * .3)
    put(list, button(pal, bw, fh, "‹ " .. _("Prev"), false, function() state.recpage = math.max(1, state.recpage - 1); refresh(context) end), margin, fy)
    local lbl = TextWidget:new{ text = state.recpage .. " / " .. pages, face = Font:getFace("cfont", px(10)), fgcolor = pal.on_surface }
    put(list, lbl, math.floor((W - lbl:getSize().w) / 2), fy + math.floor((fh - lbl:getSize().h) / 2))
    put(list, button(pal, bw, fh, _("Next") .. " ›", true, function() state.recpage = math.min(pages, state.recpage + 1); refresh(context) end), W - margin - bw, fy)
    if #rec > 0 then statusLine(pal, list, _("Tap to open · hold to remove"), W, margin, fy - px(15), px) end
    return list
end

-- A failed view must never take the whole pane down: show the error and a way back.
local function viewError(state, context, pal, W, H, px, err)
    local list, margin = {}, math.max(px(10), math.floor(W / 40))
    local hh = math.max(px(44), math.floor(H * .09))
    header(pal, list, W, hh, "DLib", nil, margin)
    put(list, TextBoxWidget:new{ text = _("Something went wrong:") .. "\n" .. clip(tostring(err), 300), face = Font:getFace("smallinfofont", px(10)),
        width = W - 2 * margin, height = math.floor(H * .4), fgcolor = pal.on_surface, bgcolor = pal.background }, margin, hh + px(12))
    local bh = math.max(px(36), math.floor(H * .07))
    put(list, button(pal, W - 2 * margin, bh, _("Back to start"), true, function() go(state, context, "home") end), margin, H - bh - margin)
    return list
end

return {
    id = "dlib",
    version = "1.1.0",
    title = "DLib",
    subtitle = "Free books from Open Library and Archive.org",
    symbol = "L",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local pal = palette(context)
        local W, H = context.dimen.w, context.dimen.h
        local px = context.px or scale
        local builder = viewHome
        if state.view == "results" then builder = viewResults
        elseif state.view == "detail" and state.item then builder = viewDetail
        elseif state.view == "recents" then builder = viewRecents
        else state.view = "home" end
        local ok, list = pcall(builder, state, context, pal, W, H, px)
        if not ok then
            state.view = "home"
            list = viewError(state, context, pal, W, H, px, list)
        end
        return OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, allow_mirroring = false,
            FrameContainer:new{ width = W, height = H, padding = 0, bordersize = 0, background = pal.background, blank(W, H) },
            unpack(list) }
    end,
}
