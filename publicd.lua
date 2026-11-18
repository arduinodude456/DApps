--[[--
PublicD for AppDock - public room on top of the existing DChat Supabase DM server.
Style: Cyber Punk Ink.

No server changes: four "fake" DChat devices act as shared channels.
  ROOM_A -> ROOM_B : chat messages   (envelope JSON in the DM text)
  META_A -> META_B : profiles (avatar + self role) and admin role assignments
Everybody reads the A->B conversation. The real author is inside the envelope.
Needs a DChat identity (created in DChat) - PublicD reuses it.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ok_text, AppDockText = pcall(require, "appdock_text")
if ok_text and type(AppDockText) == "table" and type(AppDockText.TextBoxWidget) == "table" then
    TextBoxWidget = AppDockText.TextBoxWidget
end
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ok_kb, AppDockKeyboard = pcall(require, "appdock_keyboard")
if not ok_kb or type(AppDockKeyboard) ~= "table" or type(AppDockKeyboard.attach) ~= "function" then AppDockKeyboard = nil end
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_json, JSON = pcall(require, "json")
if not ok_json then JSON = nil end

-- ---- config ---------------------------------------------------------------
local DM_ENDPOINT = "https://qndwbriqomqqaqhkasbh.supabase.co/functions/v1/quick-endpoint"
local KEY = "sb_publishable_UAIcZameyUZHtEB-NY1ffQ_TfF67BjS"
local ADMIN_CODE = "D82637"
local SETTINGS_KEY = "appdock_publicd_v1"
local DCHAT_KEY = "appdock_dchat_v1"
local MAX_RESP = 4 * 1024 * 1024
local MAX_ATT = 512 * 1024
local ATT_DIR = DataStorage:getDataDir() .. "/appdock_dchat_images"
local AV_DIR = DataStorage:getDataDir() .. "/appdock_publicd_avatars"
local STICKER_DIR = DataStorage:getDataDir() .. "/appdock_dchat_stickers"
local ROOM_A = { id = "dch_9d0a1b2c3d4e5f6071829301", secret = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071a", name = "PublicD" }
local ROOM_B = { id = "dch_9d0a1b2c3d4e5f6071829302", secret = "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071a2b", name = "PublicD Relay" }
local META_A = { id = "dch_9d0a1b2c3d4e5f6071829303", secret = "c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071a2b3c", name = "PublicD Meta" }
local META_B = { id = "dch_9d0a1b2c3d4e5f6071829304", secret = "d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071a2b3c4d", name = "PublicD Sync" }
local DEVS = { ROOM_A, ROOM_B, META_A, META_B }

-- ---- cyber punk ink palette ------------------------------------------------
local function col(hex, fb)
    if Blitbuffer.colorFromString then
        local ok, v = pcall(Blitbuffer.colorFromString, hex)
        if ok and v then return v end
    end
    if Blitbuffer.ColorRGB32 then
        local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
        if r then
            local ok, v = pcall(Blitbuffer.ColorRGB32, tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), 255)
            if ok and v then return v end
        end
    end
    return fb
end
local BLACK, WHITE, LGRAY = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_LIGHT_GRAY
local C = {
    bg = col("#07070D", BLACK), panel = col("#12121F", BLACK), text = col("#E8E8F0", WHITE),
    dim = col("#8888AA", LGRAY), cyan = col("#00F0FF", WHITE), magenta = col("#FF2A6D", LGRAY),
    yellow = col("#FCEE0A", WHITE), line = col("#2A2A44", Blitbuffer.COLOR_DARK_GRAY),
}
local ROLE_COLORS = {
    { "CYAN", "#00F0FF" }, { "MAGENTA", "#FF2A6D" }, { "YELLOW", "#FCEE0A" }, { "GREEN", "#39FF14" },
    { "ORANGE", "#FF9F1C" }, { "VIOLET", "#B967FF" }, { "RED", "#FF2020" }, { "WHITE", "#FFFFFF" },
}
local EMOJI = { "😀", "😂", "🤣", "😊", "😍", "😘", "😎", "🤔", "😢", "😭", "😡", "👍", "👎", "🙏", "👏", "🎉", "❤️", "🔥",
    "😅", "😉", "🙌", "💪", "🤝", "✅", "😃", "😄", "😁", "😆", "🙂", "🙃", "😇", "🥰", "🤩", "😋", "😜", "🤪", "🤗",
    "🤭", "🤫", "😐", "😏", "🙄", "😴", "🤒", "🤯", "🥳", "🤓", "😮", "😳", "🥺", "😱", "💀", "👻", "🤖", "💩", "🎮",
    "💻", "📱", "⚡", "✨", "⭐", "💯", "👀", "🧠", "🚀", "🏆", "🍕", "☕", "🍺", "🌈", "🌙", "☀️" }

local function px(v) return Device.screen:scaleBySize(v) end

-- ---- helpers --------------------------------------------------------------
local function trim(v) if type(v) ~= "string" then return "" end return v:match("^%s*(.-)%s*$") or "" end
local function clamp(v, a, b) return math.max(a, math.min(b, tonumber(v) or a)) end
local function mkdir(p) pcall(function() if not lfs.attributes(p) then lfs.mkdir(p) end end) end
local function preview(t, n)
    t = tostring(t or ""):gsub("%s+", " ")
    if #t <= n then return t end
    local cut = n - 3
    while cut > 1 do local b = t:byte(cut + 1); if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end end
    return t:sub(1, cut) .. "..."
end
local function mimeFor(path)
    local l = tostring(path or ""):lower()
    if l:match("%.png$") then return "image/png" end
    if l:match("%.jpe?g$") then return "image/jpeg" end
    if l:match("%.gif$") then return "image/gif" end
    if l:match("%.webp$") then return "image/webp" end
end
local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64e(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local function ch(s) local v = math.floor(n / s) % 64 + 1; return ALPHA:sub(v, v) end
        out[#out + 1] = ch(262144) .. ch(4096) .. (b and ch(64) or "=") .. (c and ch(1) or "=")
    end
    return table.concat(out)
end
local function b64d(data)
    if type(data) ~= "string" then return nil end
    data = data:gsub("%s", "")
    if data == "" or #data % 4 ~= 0 or data:find("[^%w%+/=]") then return nil end
    local out = {}
    for i = 1, #data, 4 do
        local a, b, c, d = data:sub(i, i + 3):match("^(.)(.)(.)(.)$")
        local va, vb = ALPHA:find(a, 1, true), ALPHA:find(b, 1, true)
        if not va or not vb then return nil end
        local vc = c == "=" and 0 or (ALPHA:find(c, 1, true) or 1) - 1
        local vd = d == "=" and 0 or (ALPHA:find(d, 1, true) or 1) - 1
        local n = (va - 1) * 262144 + (vb - 1) * 4096 + vc * 64 + vd
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if c ~= "=" then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if d ~= "=" then out[#out + 1] = string.char(n % 256) end
    end
    return table.concat(out)
end
local function showInput(d)
    if AppDockKeyboard then pcall(AppDockKeyboard.attach, d) end
    UIManager:show(d)
    if d.onShowKeyboard then d:onShowKeyboard() end
end
local function notify(text) UIManager:show(InfoMessage:new{ text = text, timeout = 2 }) end

-- ---- persistence / identity ------------------------------------------------
local function prof()
    local s = G_reader_settings:readSetting(SETTINGS_KEY, {})
    if type(s) ~= "table" then s = {} end
    s.role, s.color, s.avatar = s.role or "", s.color or "#00F0FF", s.avatar or ""
    return s
end
local function saveProf(s) G_reader_settings:saveSetting(SETTINGS_KEY, s) end
local function identity()
    local s = G_reader_settings:readSetting(DCHAT_KEY, {})
    if type(s) ~= "table" then return nil end
    local id, name = trim(s.device_id), trim(s.display_name)
    if id:match("^dch_[%w_%-]+$") and name ~= "" then return { id = id, name = name } end
end

-- ---- network ---------------------------------------------------------------
local function http(method, suffix, payload, dev)
    local ok_h, https = pcall(require, "ssl.https")
    local ok_s, socket = pcall(require, "socket")
    local ok_l, ltn12 = pcall(require, "ltn12")
    local ok_u, socketutil = pcall(require, "socketutil")
    if not (ok_h and ok_s and ok_l and ok_u and JSON) then return nil, nil, "HTTPS/JSON unavailable" end
    local chunks, got = {}, 0
    local function sink(chunk, e)
        if e then return nil, e end
        if chunk then
            got = got + #chunk
            if got > MAX_RESP then return nil, "big" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    local headers = { accept = "application/json", ["user-agent"] = "AppDock-PublicD/1.0", apikey = KEY }
    local body
    if payload then
        body = JSON.encode(payload)
        headers["content-type"] = "application/json"
        headers["content-length"] = tostring(#body)
    end
    if dev then headers["x-dchat-device-id"], headers["x-dchat-device-secret"] = dev.id, dev.secret end
    local req = { url = DM_ENDPOINT .. "/api/dchat/v1" .. suffix, method = method, sink = sink, headers = headers }
    if body then req.source = ltn12.source.string(body) end
    socketutil:set_timeout(10, 25)
    local ok, code, rh, status = pcall(function() return socket.skip(1, https.request(req)) end)
    socketutil:reset_timeout()
    code = tonumber(code)
    local text, dec = table.concat(chunks), nil
    if text ~= "" then
        local o, r = pcall(JSON.decode, text, JSON.decode.simple)
        if o and type(r) == "table" then dec = r end
    end
    if not ok or not rh or not code then return nil, nil, (status == "big") and "big" or "network error" end
    if code < 200 or code > 299 then
        return nil, code, (dec and dec.error and tostring(dec.error.message)) or ("refused (" .. code .. ")")
    end
    return dec or {}, code
end

local function ensure(st)
    if st.ready then return end
    for i, d in ipairs(DEVS) do
        http("POST", "/devices", { deviceId = d.id, deviceSecret = d.secret, displayName = d.name })
    end
    st.ready = true
end

local function readChannel(a, b)
    local err
    for i, lim in ipairs({ 40, 8 }) do
        local r, code, e = http("GET", "/dms/" .. b.id .. "?limit=" .. lim, nil, a)
        if r and type(r.conversation) == "table" then
            local list = r.conversation.messages or {}
            table.sort(list, function(x, y) return (tonumber(x.id) or 0) < (tonumber(y.id) or 0) end)
            return list
        end
        err = e
        if e ~= "big" then break end
    end
    return nil, err
end

local function decode(body)
    if not JSON or type(body) ~= "string" then return nil end
    local ok, t = pcall(JSON.decode, body, JSON.decode.simple)
    if ok and type(t) == "table" then return t end
end

-- ---- state ----------------------------------------------------------------
local function stateFor(inst)
    inst.publicd = inst.publicd or { view = "chat", room = {}, users = {}, draft = "", scroll = 0, status = "BOOT // ready", emoji = false, epage = 1, files = {} }
    return inst.publicd
end

local function userRole(st, uid)
    local u = st.users[uid]
    if not u then return nil end
    if u.aset then return u.arole, u.acolor end
    return u.role, u.color
end

local function buildUsers(st, meta)
    local users = {}
    for i, m in ipairs(meta) do
        local env = decode(m.body)
        if env and type(env.u) == "string" then
            local u = users[env.u] or {}
            users[env.u] = u
            if env.t == "p" then
                u.name, u.role, u.color = tostring(env.n or ""), tostring(env.r or ""), tostring(env.c or "")
                if (m.attachmentData or "") ~= "" then u.avid, u.avdata = m.id, m.attachmentData end
            elseif env.t == "a" then
                u.arole, u.acolor, u.aset = tostring(env.r or ""), tostring(env.c or ""), true
            end
        end
    end
    mkdir(AV_DIR)
    for uid, u in pairs(users) do
        if u.avdata and uid:match("^dch_[%w_%-]+$") then
            local path = AV_DIR .. "/" .. uid .. "_" .. tostring(u.avid) .. ".png"
            local f = io.open(path, "rb")
            if f then f:close() else
                local data = b64d(u.avdata)
                if data and #data > 0 and #data <= MAX_ATT then
                    local w = io.open(path, "wb")
                    if w then w:write(data); w:close() end
                end
            end
            if io.open(path, "rb") then u.avpath = path end
            u.avdata = nil
        end
    end
    st.users = users
end

local function buildRoom(st, list)
    local room = {}
    for i, m in ipairs(list) do
        local env = decode(m.body)
        if env and type(env.u) == "string" then
            room[#room + 1] = { id = m.id, u = env.u, n = tostring(env.n or "?"), t = tostring(env.t or ""), q = env.q,
                mime = m.attachmentMime, data = m.attachmentData or "", ts = tostring(m.createdAt or "") }
        end
    end
    st.room = room
end

local function attFile(m)
    if not m.data or m.data == "" then return nil end
    local ext = ({ ["image/png"] = ".png", ["image/jpeg"] = ".jpg", ["image/gif"] = ".gif", ["image/webp"] = ".webp" })[m.mime]
    if not ext or not tostring(m.id):match("^%d+$") then return nil end
    mkdir(ATT_DIR)
    local path = ATT_DIR .. "/dchat_pd_" .. m.id .. ext
    local f = io.open(path, "rb")
    if f then f:close(); return path end
    local data = b64d(m.data)
    if not data or #data == 0 or #data > MAX_ATT then return nil end
    local w = io.open(path, "wb")
    if not w then return nil end
    w:write(data); w:close()
    return path
end

local function rebuild(ctx) ctx.requestRebuild("ui") end

local function fetchAll(st, ctx)
    local id = identity()
    if not id then st.status = "ERR // create a DChat identity first"; rebuild(ctx); return end
    ensure(st)
    local meta = readChannel(META_A, META_B)
    local room, err = readChannel(ROOM_A, ROOM_B)
    if not room then st.status = "ERR // " .. tostring(err); rebuild(ctx); return end
    if meta then buildUsers(st, meta) end
    buildRoom(st, room)
    st.scroll = 0
    st.status = "SYNC OK // " .. #st.room .. " packets"
    rebuild(ctx)
end

local function announce(st)
    local id = identity()
    if not id then return false end
    ensure(st)
    local p = prof()
    local att = p.avatar ~= "" and { mime = "image/png", data = p.avatar } or nil
    local r = http("POST", "/dms", { recipientDeviceId = META_B.id,
        text = JSON.encode({ t = "p", u = id.id, n = id.name, r = p.role, c = p.color }), attachment = att }, META_A)
    if r then st.announced = true end
    return r ~= nil
end

local function post(st, ctx, text, att)
    local id = identity()
    if not id then st.status = "ERR // create a DChat identity first"; rebuild(ctx); return end
    text = trim(text or "")
    if text == "" and not att then return end
    ensure(st)
    if not st.announced then announce(st) end
    local env = { u = id.id, n = id.name, t = text }
    if st.reply then env.q = st.reply.q end
    local enc = JSON.encode(env)
    if #enc > 1450 then st.status = "ERR // message too long"; rebuild(ctx); return end
    local r, code, err = http("POST", "/dms", { recipientDeviceId = ROOM_B.id, text = enc, attachment = att }, ROOM_A)
    if not r then st.status = "ERR // " .. tostring(err); rebuild(ctx); return end
    st.draft, st.reply, st.emoji = "", nil, false
    fetchAll(st, ctx)
end

-- ---- widgets --------------------------------------------------------------
local Tap = InputContainer:extend{ width = 0, height = 0, content = nil, callback = nil, hold = nil }
function Tap:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = self.content
    self.ges_events = { TapT = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if self.hold then self.ges_events.HoldT = { GestureRange:new{ ges = "hold", range = self.dimen } } end
end
function Tap:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    return InputContainer.paintTo(self, bb, x, y)
end
function Tap:onTapT() if self.callback then self.callback() end return true end
function Tap:onHoldT() if self.hold then self.hold() end return true end

local Swipe = InputContainer:extend{ width = 0, height = 0, content = nil, on_swipe = nil }
function Swipe:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = self.content
    self.ges_events = { SwipeS = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
end
function Swipe:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    return InputContainer.paintTo(self, bb, x, y)
end
function Swipe:onSwipeS(_a, g)
    if self.on_swipe and g then return self.on_swipe(g.direction) == true end
    return false
end

local function empty(w, h) return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, HorizontalSpan:new{ width = 0 } } end

local function btn(w, h, label, o, cb)
    o = o or {}
    local t = TextWidget:new{ text = label, face = Font:getFace("smallinfofont", o.size or math.max(px(9), math.floor(h * .3))),
        fgcolor = o.fg or C.text, bold = o.bold, max_width = math.max(1, w - px(10)) }
    local inner
    if o.left then
        inner = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, HorizontalGroup:new{ HorizontalSpan:new{ width = px(6) }, t } }
        inner = HorizontalGroup:new{ HorizontalSpan:new{ width = px(6) }, CenterContainer:new{ dimen = Geom:new{ w = w - px(6), h = h }, t } }
    else
        inner = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, t }
    end
    local frame = FrameContainer:new{ width = w, height = h, padding = 0, bordersize = o.border and px(1) or 0,
        color = o.border, background = o.bg or C.panel, radius = 0, inner }
    return Tap:new{ width = w, height = h, content = frame, callback = cb, hold = o.hold }
end

local function menu(title, items)
    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok then return end
    local m
    local list = {}
    for i, it in ipairs(items) do
        list[#list + 1] = { text = it.text, callback = function()
            UIManager:close(m)
            UIManager:nextTick(it.callback)
        end }
    end
    m = Menu:new{ title = title, item_table = list, is_borderless = true, is_popout = false, covers_fullscreen = true,
        width = Device.screen:getWidth(), height = Device.screen:getHeight(), close_callback = function() UIManager:close(m) end }
    UIManager:show(m)
end

local function pickImage(cb)
    local function show(dir)
        dir = tostring(dir or "/"):gsub("/+$", "")
        if dir == "" then dir = "/" end
        local base = dir == "/" and "" or dir
        local dirs, files = {}, {}
        local ok, it, d = pcall(lfs.dir, dir)
        if ok and it then
            for name in it, d do
                if name:sub(1, 1) ~= "." then
                    local full = base .. "/" .. name
                    local a = lfs.attributes(full)
                    if a and a.mode == "directory" then dirs[#dirs + 1] = { name .. "/", full }
                    elseif a and a.mode == "file" and mimeFor(name) then files[#files + 1] = { name, full } end
                end
            end
        end
        local function byName(a, b) return a[1]:lower() < b[1]:lower() end
        table.sort(dirs, byName); table.sort(files, byName)
        local items = {}
        if dir ~= "/" then items[#items + 1] = { text = "..", callback = function() show(dir:match("^(.*)/[^/]+$") or "/") end } end
        for i, e in ipairs(dirs) do items[#items + 1] = { text = e[1], callback = function() show(e[2]) end } end
        for i, e in ipairs(files) do items[#items + 1] = { text = e[1], callback = function() cb(e[2]) end } end
        menu(dir, items)
    end
    show(Device.home_dir or "/")
end

local function readFile(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a"); f:close()
    if not d or #d == 0 or (limit and #d > limit) then return nil end
    return d
end

local function imageWidget(path, w, h)
    local ok, IW = pcall(require, "ui/widget/imagewidget")
    if not ok then return nil end
    local ok2, wd = pcall(function() return IW:new{ file = path, width = w, height = h, scale_factor = 0, file_do_cache = false } end)
    return ok2 and wd or nil
end

-- 96px square PNG as base64
local function makeAvatar(path)
    local ok, RI = pcall(require, "ui/renderimage")
    if not ok or type(RI) ~= "table" then return nil, "no image support" end
    local src = RI:renderImageFile(path, false)
    if not src then return nil, "cannot decode image" end
    local w, h = src:getWidth(), src:getHeight()
    local side = math.min(w, h)
    local sq = Blitbuffer.new(side, side, Blitbuffer.TYPE_BBRGB32)
    sq:fill(WHITE)
    local ox, oy = math.floor((w - side) / 2), math.floor((h - side) / 2)
    if sq.alphablitFrom then sq:alphablitFrom(src, 0, 0, ox, oy, side, side) else sq:blitFrom(src, 0, 0, ox, oy, side, side) end
    pcall(src.free, src)
    local fin = sq
    if side > 96 then
        local o2, sc = pcall(function() return RI:scaleBlitBuffer(sq, 96, 96, false) end)
        if o2 and sc then pcall(sq.free, sq); fin = sc end
    end
    mkdir(AV_DIR)
    local tmp = AV_DIR .. "/own_tmp.png"
    pcall(os.remove, tmp)
    if fin.writePNG then pcall(fin.writePNG, fin, tmp) elseif fin.writeToFile then pcall(fin.writeToFile, fin, tmp, "png") end
    pcall(fin.free, fin)
    local data = readFile(tmp, MAX_ATT)
    pcall(os.remove, tmp)
    if not data then return nil, "PNG encode failed" end
    return b64e(data)
end

-- ---- chat rows ------------------------------------------------------------
local function avatarWidget(st, uid, name, own, size)
    local u = st.users[uid]
    if u and u.avpath then
        local w = imageWidget(u.avpath, size, size)
        if w then return FrameContainer:new{ width = size, height = size, padding = 0, bordersize = px(1), color = own and C.magenta or C.cyan, background = C.bg, w } end
    end
    local letter = TextWidget:new{ text = (tostring(name):match("^[\1-\127\194-\244][\128-\191]*") or "?"):upper(),
        face = Font:getFace("cfont", math.floor(size * .5)), fgcolor = own and C.magenta or C.cyan, bold = true }
    return FrameContainer:new{ width = size, height = size, padding = 0, bordersize = px(1), color = own and C.magenta or C.cyan, background = C.panel,
        CenterContainer:new{ dimen = Geom:new{ w = size, h = size }, letter } }
end

local function menuForMessage(st, ctx, m)
    local items = { { text = "REPLY", callback = function()
        st.reply = { q = m.n .. ": " .. preview(m.t ~= "" and m.t or "[image]", 70), n = m.n }
        rebuild(ctx)
    end } }
    if m.t ~= "" then
        items[#items + 1] = { text = "COPY TEXT", callback = function()
            local ok = pcall(function() Device.input.setClipboardText(m.t) end)
            notify(ok and "Copied" or "Copy not available")
        end }
    end
    if m.data ~= "" then
        items[#items + 1] = { text = "SAVE AS STICKER", callback = function()
            local ext = ({ ["image/png"] = ".png", ["image/jpeg"] = ".jpg", ["image/gif"] = ".gif", ["image/webp"] = ".webp" })[m.mime]
            local data = b64d(m.data)
            if ext and data then
                mkdir(STICKER_DIR)
                local p = STICKER_DIR .. "/publicd_" .. m.id .. ext
                local w = io.open(p, "wb")
                if w then w:write(data); w:close(); notify("Sticker saved") end
            end
        end }
    end
    menu(m.n, items)
end

local function makeRow(st, ctx, m, W, margin, area)
    local own = false
    local me = identity()
    if me and me.id == m.u then own = true end
    local av, gap, pad = px(34), px(6), px(4)
    local textx = margin + av + gap
    local textw = W - textx - margin - px(6)
    local nameCol = own and C.magenta or C.cyan
    local u = st.users[m.u]
    local shownName = (u and u.name and u.name ~= "") and u.name or m.n
    local parts = { TextWidget:new{ text = shownName, face = Font:getFace("smallinfofont", px(10)), fgcolor = nameCol, bold = true, max_width = math.floor(textw * .5) } }
    local role, rcol = userRole(st, m.u)
    if role and role ~= "" then
        local bt = TextWidget:new{ text = role:upper(), face = Font:getFace("smallinfofont", px(7)), fgcolor = BLACK, bold = true, max_width = math.floor(textw * .4) }
        parts[#parts + 1] = HorizontalSpan:new{ width = px(5) }
        parts[#parts + 1] = FrameContainer:new{ padding = px(2), bordersize = 0, background = col(rcol ~= "" and rcol or "#00F0FF", C.cyan), radius = 0, bt }
    end
    parts[#parts + 1] = HorizontalSpan:new{ width = px(6) }
    parts[#parts + 1] = TextWidget:new{ text = m.ts:match("T(%d%d:%d%d)") or "", face = Font:getFace("smallinfofont", px(7)), fgcolor = C.dim }
    local header = HorizontalGroup:new{ align = "center", unpack(parts) }
    local group = VerticalGroup:new{ align = "left", header }
    if m.q and m.q ~= "" then
        group[#group + 1] = VerticalSpan:new{ width = px(2) }
        group[#group + 1] = FrameContainer:new{ width = textw, padding = px(3), bordersize = px(1), color = C.line, background = C.panel, radius = 0,
            TextBoxWidget:new{ text = "↪ " .. preview(m.q, 90), face = Font:getFace("smallinfofont", px(8)), width = textw - px(10), fgcolor = C.dim, bgcolor = C.panel } }
    end
    if m.t ~= "" then
        group[#group + 1] = VerticalSpan:new{ width = px(2) }
        group[#group + 1] = TextBoxWidget:new{ text = m.t, face = Font:getFace("smallinfofont", px(11)), width = textw, fgcolor = C.text, bgcolor = C.bg }
    end
    local path = attFile(m)
    if path then
        local iw = imageWidget(path, math.min(textw, px(220)), math.min(px(150), math.floor(area * .45)))
        if iw then group[#group + 1] = VerticalSpan:new{ width = px(3) }; group[#group + 1] = iw end
    elseif m.data ~= "" then
        group[#group + 1] = TextWidget:new{ text = "[image unavailable]", face = Font:getFace("smallinfofont", px(8)), fgcolor = C.dim }
    end
    local rowh = math.max(av, group:getSize().h) + 2 * pad + 1
    local avw = avatarWidget(st, m.u, shownName, own, av)
    avw.overlap_offset = { margin, pad }
    group.overlap_offset = { textx, pad }
    local div = FrameContainer:new{ width = W - 2 * margin, height = 1, padding = 0, bordersize = 0, background = C.line, empty(W - 2 * margin, 1) }
    div.overlap_offset = { margin, rowh - 1 }
    local row = OverlapGroup:new{ dimen = Geom:new{ w = W, h = rowh }, allow_mirroring = false, avw, group, div }
    return Tap:new{ width = W, height = rowh, content = row, callback = function() menuForMessage(st, ctx, m) end }
end

-- ---- composer actions -----------------------------------------------------
local function sendImagePath(st, ctx, path, as_text)
    local mime = mimeFor(path)
    local data = mime and readFile(path, MAX_ATT)
    if not data then notify("Use PNG/JPEG/GIF/WEBP up to 512 KB"); return end
    post(st, ctx, as_text or st.draft, { mime = mime, data = b64e(data) })
end

local function stickerMenu(st, ctx)
    mkdir(STICKER_DIR)
    local items = {}
    local ok, it, d = pcall(lfs.dir, STICKER_DIR)
    if ok and it then
        for name in it, d do
            if mimeFor(name) and name:sub(1, 1) ~= "." then
                local p = STICKER_DIR .. "/" .. name
                items[#items + 1] = { text = name, callback = function() sendImagePath(st, ctx, p, "") end }
            end
        end
    end
    table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
    if #items == 0 then notify("No stickers yet - add some in DChat or save images from the room"); return end
    menu("STICKERS", items)
end

local function composeDialog(st, ctx)
    local d
    d = InputDialog:new{ title = "TRANSMIT", input = st.draft or "", input_hint = "message (max ~500 chars)",
        buttons = { { { text = "Cancel", callback = function() UIManager:close(d) end },
            { text = "Draft", callback = function() st.draft = trim(d:getInputText()); UIManager:close(d); rebuild(ctx) end },
            { text = "Send", is_enter_default = true, callback = function() local t = d:getInputText(); UIManager:close(d); post(st, ctx, t, nil) end } } } }
    showInput(d)
end

local function pickColor(cb)
    local items = {}
    for i, c in ipairs(ROLE_COLORS) do items[#items + 1] = { text = c[1], callback = function() cb(c[2]) end } end
    menu("BADGE COLOR", items)
end

local function roleDialog(title, initial, cb)
    local d
    d = InputDialog:new{ title = title, input = initial or "", input_hint = "role name (empty = none, max 16)",
        buttons = { { { text = "Cancel", callback = function() UIManager:close(d) end },
            { text = "OK", is_enter_default = true, callback = function()
                local t = trim(d:getInputText()):gsub("[%c]", " "):sub(1, 16)
                UIManager:close(d)
                cb(t)
            end } } } }
    showInput(d)
end

local function setOwnRole(st, ctx)
    local p = prof()
    roleDialog("YOUR ROLE", p.role, function(role)
        local function finish(color)
            local s = prof()
            s.role, s.color = role, color or s.color
            saveProf(s)
            announce(st)
            fetchAll(st, ctx)
        end
        if role == "" then finish(nil) else pickColor(finish) end
    end)
end

local function setAvatar(st, ctx)
    pickImage(function(path)
        local b64, err = makeAvatar(path)
        if not b64 then st.status = "ERR // " .. tostring(err); rebuild(ctx); return end
        local s = prof()
        s.avatar = b64
        saveProf(s)
        announce(st)
        fetchAll(st, ctx)
    end)
end

local function adminLogin(st, ctx)
    local d
    d = InputDialog:new{ title = "ADMIN ACCESS", input = "", input_hint = "access code",
        buttons = { { { text = "Cancel", callback = function() UIManager:close(d) end },
            { text = "Login", is_enter_default = true, callback = function()
                local code = trim(d:getInputText())
                UIManager:close(d)
                local s = prof()
                if code == ADMIN_CODE then s.admin = true; st.status = "ACCESS GRANTED // admin" else st.status = "ACCESS DENIED" end
                saveProf(s)
                rebuild(ctx)
            end } } } }
    showInput(d)
end

local function adminAssign(st, ctx)
    if not prof().admin then return end
    local items = {}
    for uid, u in pairs(st.users) do
        local name = (u.name and u.name ~= "") and u.name or uid
        local role = userRole(st, uid)
        items[#items + 1] = { text = name .. ((role and role ~= "") and ("  [" .. role .. "]") or ""), callback = function()
            roleDialog("ROLE FOR " .. name, role or "", function(r)
                local function send(color)
                    ensure(st)
                    local ok = http("POST", "/dms", { recipientDeviceId = META_B.id,
                        text = JSON.encode({ t = "a", u = uid, r = r, c = color or "" }) }, META_A)
                    st.status = ok and "ROLE UPLOADED" or "ERR // upload failed"
                    fetchAll(st, ctx)
                end
                if r == "" then send(nil) else pickColor(send) end
            end)
        end }
    end
    table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
    if #items == 0 then notify("No profiles yet. Users appear after their first message or role/avatar change."); return end
    menu("ASSIGN ROLE", items)
end

-- ---- panes ----------------------------------------------------------------
local function settingsPane(st, ctx)
    local W, H = ctx.dimen.w, ctx.dimen.h
    local m = px(8)
    local p = prof()
    local hh = math.max(px(40), math.floor(H * .085))
    local els = { FrameContainer:new{ width = W, height = H, padding = 0, bordersize = 0, background = C.bg, empty(W, H) } }
    els[#els + 1] = FrameContainer:new{ width = W, height = hh, padding = 0, bordersize = 0, background = C.panel, empty(W, hh) }
    els[#els + 1] = TextWidget:new{ text = "[ CONFIG ]//", face = Font:getFace("cfont", px(15)), fgcolor = C.cyan, bold = true, overlap_offset = { m, math.floor(hh * .22) } }
    local list = {
        { "ROLE: " .. (p.role ~= "" and p.role or "none"), C.cyan, function() setOwnRole(st, ctx) end },
        { "AVATAR " .. (p.avatar ~= "" and "[set]" or "[none]"), C.cyan, function() setAvatar(st, ctx) end },
    }
    if p.admin then
        list[#list + 1] = { "ADMIN // ASSIGN ROLE", C.yellow, function() adminAssign(st, ctx) end }
        list[#list + 1] = { "ADMIN // LOGOUT", C.magenta, function() local s = prof(); s.admin = false; saveProf(s); rebuild(ctx) end }
    else
        list[#list + 1] = { "ADMIN // LOGIN", C.yellow, function() adminLogin(st, ctx) end }
    end
    list[#list + 1] = { "‹ BACK TO ROOM", C.magenta, function() st.view = "chat"; rebuild(ctx) end }
    local bh = math.max(px(38), math.floor((H - hh - 3 * m - px(18)) / 6))
    local y = hh + m
    for i, e in ipairs(list) do
        local b = btn(W - 2 * m, bh, e[1], { border = e[2], fg = e[2], bold = true }, e[3])
        b.overlap_offset = { m, y }
        els[#els + 1] = b
        y = y + bh + px(6)
    end
    els[#els + 1] = TextWidget:new{ text = st.status, face = Font:getFace("smallinfofont", px(8)), fgcolor = C.dim, max_width = W - 2 * m, overlap_offset = { m, H - px(16) } }
    return OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, allow_mirroring = false, unpack(els) }
end

local function chatPane(st, ctx)
    local W, H = ctx.dimen.w, ctx.dimen.h
    local m, gap = px(6), px(4)
    local hh = math.max(px(40), math.floor(H * .085))
    local ch = math.max(px(38), math.floor(H * .07))
    local me = identity()
    local els = { FrameContainer:new{ width = W, height = H, padding = 0, bordersize = 0, background = C.bg, empty(W, H) } }
    -- header
    els[#els + 1] = FrameContainer:new{ width = W, height = hh, padding = 0, bordersize = 0, background = C.panel, empty(W, hh) }
    els[#els + 1] = FrameContainer:new{ width = W, height = px(2), padding = 0, bordersize = 0, background = C.cyan, empty(W, px(2)), overlap_offset = { 0, hh - px(2) } }
    els[#els + 1] = TextWidget:new{ text = "[ PUBLIC_D ]//", face = Font:getFace("cfont", math.max(px(13), math.floor(hh * .38))), fgcolor = C.cyan, bold = true, overlap_offset = { m, math.floor(hh * .2) } }
    local bw = math.floor(hh * 1.25)
    local sync = btn(bw, hh - px(10), "SYNC", { border = C.cyan, fg = C.cyan, bold = true, size = px(9) }, function() fetchAll(st, ctx) end)
    sync.overlap_offset = { W - m - 2 * bw - gap, px(5) }
    local cfg = btn(bw, hh - px(10), "CFG", { border = C.magenta, fg = C.magenta, bold = true, size = px(9) }, function() st.view = "settings"; rebuild(ctx) end)
    cfg.overlap_offset = { W - m - bw, px(5) }
    els[#els + 1] = sync; els[#els + 1] = cfg
    local stl = px(14)
    els[#els + 1] = TextWidget:new{ text = "> " .. st.status, face = Font:getFace("smallinfofont", px(7)), fgcolor = C.dim, max_width = W - 2 * m, overlap_offset = { m, hh + px(1) } }

    -- bottom area
    local composer_y = H - m - ch
    local cursor = composer_y - gap
    local cell = px(40)
    local cols = math.max(3, math.floor((W - 2 * m) / cell))
    if st.emoji then
        local rows = 3
        local ph = rows * cell + 2 * gap
        cursor = cursor - ph
        els[#els + 1] = FrameContainer:new{ width = W, height = ph, padding = 0, bordersize = 0, background = C.panel, empty(W, ph), overlap_offset = { 0, cursor } }
        local per = cols * rows - 1
        local pages = math.max(1, math.ceil(#EMOJI / per))
        st.epage = clamp(st.epage, 1, pages)
        local start = (st.epage - 1) * per
        for slot = 0, per - 1 do
            local e = EMOJI[start + slot + 1]
            if not e then break end
            local b = btn(cell, cell, e, { bg = C.panel, size = px(18) }, function()
                if #st.draft < 480 then st.draft = st.draft .. e end
                rebuild(ctx)
            end)
            b.overlap_offset = { m + (slot % cols) * cell, cursor + gap + math.floor(slot / cols) * cell }
            els[#els + 1] = b
        end
        local nb = btn(cell, cell, "»", { bg = C.panel, fg = C.cyan, bold = true, size = px(16) }, function() st.epage = st.epage % pages + 1; rebuild(ctx) end)
        nb.overlap_offset = { m + ((per) % cols) * cell, cursor + gap + math.floor(per / cols) * cell }
        els[#els + 1] = nb
        cursor = cursor - gap
    end
    if st.reply then
        local rh = px(22)
        cursor = cursor - rh
        local rb = btn(W - 2 * m, rh, "↪ " .. preview(st.reply.q, 60) .. "   ✕", { border = C.yellow, fg = C.yellow, left = true, size = px(8) }, function() st.reply = nil; rebuild(ctx) end)
        rb.overlap_offset = { m, cursor }
        els[#els + 1] = rb
        cursor = cursor - gap
    end
    -- composer
    local ew, pw, sw = ch, ch, math.floor(ch * 1.6)
    local fw = W - 2 * m - ew - pw - sw - 3 * gap
    local x = m
    local function put(b) b.overlap_offset = { x, composer_y }; els[#els + 1] = b end
    put(btn(ew, ch, "☺", { border = st.emoji and C.yellow or C.cyan, fg = st.emoji and C.yellow or C.cyan, size = px(15) }, function() st.emoji = not st.emoji; rebuild(ctx) end)); x = x + ew + gap
    put(btn(fw, ch, st.draft ~= "" and preview(st.draft, 60) or "> transmit...", { border = C.line, fg = st.draft ~= "" and C.text or C.dim, left = true, size = px(10) }, function() composeDialog(st, ctx) end)); x = x + fw + gap
    put(btn(pw, ch, "+", { border = C.cyan, fg = C.cyan, bold = true, size = px(16) }, function()
        menu("ATTACH", {
            { text = "IMAGE...", callback = function() pickImage(function(p) sendImagePath(st, ctx, p) end) end },
            { text = "STICKER...", callback = function() stickerMenu(st, ctx) end },
        })
    end)); x = x + pw + gap
    put(btn(sw, ch, "SEND", { bg = C.magenta, fg = BLACK, bold = true, size = px(10) }, function()
        if st.draft ~= "" then post(st, ctx, st.draft, nil) else composeDialog(st, ctx) end
    end))

    -- messages
    local top = hh + stl
    local area = math.max(1, cursor - top)
    local rows, used, idx = {}, 0, #st.room - st.scroll
    while idx >= 1 do
        local row = makeRow(st, ctx, st.room[idx], W, m, area)
        if #rows > 0 and used + row.height > area then break end
        table.insert(rows, 1, row)
        used = used + row.height
        idx = idx - 1
    end
    if not me then
        els[#els + 1] = TextBoxWidget:new{ text = "NO IDENTITY // open DChat and create a local identity first. PublicD uses it.", face = Font:getFace("smallinfofont", px(11)), width = W - 4 * m, fgcolor = C.yellow, bgcolor = C.bg, overlap_offset = { 2 * m, top + px(20) } }
    elseif #st.room == 0 then
        els[#els + 1] = TextBoxWidget:new{ text = "// channel empty. SYNC to load, or be the first to transmit.", face = Font:getFace("smallinfofont", px(10)), width = W - 4 * m, fgcolor = C.dim, bgcolor = C.bg, overlap_offset = { 2 * m, top + px(20) } }
    end
    local y = cursor - used
    for i, row in ipairs(rows) do
        row.overlap_offset = { 0, y }
        els[#els + 1] = row
        y = y + row.height
    end
    local count = #rows
    return Swipe:new{ width = W, height = H, content = OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, allow_mirroring = false, unpack(els) },
        on_swipe = function(dir)
            local step = math.max(1, math.floor(count / 2))
            local before = st.scroll
            if dir == "north" then st.scroll = math.min(math.max(0, #st.room - 1), st.scroll + step)
            elseif dir == "south" then st.scroll = math.max(0, st.scroll - step) else return false end
            if st.scroll ~= before then rebuild(ctx) end
            return true
        end }
end

return {
    id = "publicd",
    version = "1.0.0",
    title = "PublicD",
    subtitle = "Cyber Punk Ink public room",
    symbol = "P",
    buildPane = function(inst, ctx)
        local st = stateFor(inst)
        if st.view == "settings" then return settingsPane(st, ctx) end
        if not st.inited and identity() then
            st.inited = true
            UIManager:scheduleIn(0.3, function() fetchAll(st, ctx) end)
        end
        return chatPane(st, ctx)
    end,
}
