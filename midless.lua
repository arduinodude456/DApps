--[[--
Midless for AppDock (DApp).

Midless is a small Minecraft-like voxel game (Sirvoid/Midless, MIT). The game itself runs as a
native background process (/mnt/onboard/.adds/midless/bin/midless, raylib software renderer) that
publishes its picture through a loopback-only VNC server (127.0.0.1:5964). This DApp starts that
process, shows the picture inside an AppDock pane and sends touch input back as key/mouse events.

Like the other DApps it exports { id, version, title, subtitle, symbol, buildPane } and draws into
the pane it is given. Game frames only repaint the game view (UIManager:widgetRepaint + a refresh of
the changed rectangle), never the whole AppDock pane.

Files expected on the device (installed by midless-kobo.zip, unchanged):
  /mnt/onboard/.adds/midless/bin/midless
  /mnt/onboard/.adds/midless/home/textures/terrain.png   (the world is saved in home/world/)

Screens: splash (Play) -> game (picture + touch controls, "Stop" in the header).
The game process only lives while the game pane is on screen: leaving the DApp, suspending the
device or pressing Stop shuts it down and the pane returns to the splash screen.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

-- ---------------------------------------------------------------- config ----
local MD_DIR = os.getenv("MD_DIR") or "/mnt/onboard/.adds/midless"
local MD_LOG = MD_DIR .. "/midless.log"
local MD_HOME = MD_DIR .. "/home"            -- working dir: textures/, world/
local VNC_HOST, VNC_PORT = "127.0.0.1", 5964 -- must match scripts/03-midless.sh
local POLL_INTERVAL = 0.08
local CONNECT_TIMEOUT = 20
local READ_TIMEOUT = 15      -- seconds a half-received message may take before the connection counts as dead
local HOLD_SAFETY = 6          -- seconds after which a held key is released even without a "release" event
local BUTTON_FEEDBACK = true   -- redraw a control button while it is held
-- KOReader refresh mode for game frames: "ui" (default), "partial", "fast" (A2, ghosty,
-- bad colours on Kaleido screens but the quickest).
local REFRESH_MODE = os.getenv("MD_REFRESH") or "ui"

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- The size of the game picture the binary will produce (MD_W x MD_H, shrunk by an
-- integer factor until it fits into avail_w). Only used to lay out the pane before the
-- first frame arrives; the real size is taken from the VNC handshake.
local function expectedPicture(avail_w)
    local w = tonumber(os.getenv("MD_W")) or 480
    local h = tonumber(os.getenv("MD_H")) or 360
    local f = 1
    while math.ceil(w / f) > avail_w and f < 8 do f = f + 1 end
    return math.ceil(w / f), math.ceil(h / f)
end

-- ------------------------------------------------------------ RFB client ----
local function be16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end
local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end
local function s32(s, i)
    local v = be32(s, i)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end
local function p16(v) v = math.floor(v); return string.char(math.floor(v / 256) % 256, v % 256) end
local function p32(v)
    v = math.floor(v)
    return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256, v % 256)
end

local function bbStride(bb)
    local ok, v = pcall(function() return bb.stride end)
    if ok and v then return tonumber(v) end
    ok, v = pcall(function() return bb.pitch end)
    if ok and v then return tonumber(v) end
    return bb:getWidth() * 4
end

local RFB = {}
RFB.__index = RFB

function RFB:send(data)
    local i = 1
    local deadline = os.time() + READ_TIMEOUT
    while i <= #data do
        local sent, err, last = self.sock:send(data, i)
        if sent then
            i = sent + 1
        elseif last and last >= i then
            i = last + 1
        elseif err == "timeout" and os.time() < deadline then
            -- socket buffer full, try again
        else
            error("rfb send: " .. tostring(err))
        end
    end
end

function RFB:read(n)
    if n == 0 then return "" end
    local parts, got = {}, 0
    local deadline = os.time() + READ_TIMEOUT
    while got < n do
        local data, err, partial = self.sock:receive(n - got)
        data = data or partial
        if data and #data > 0 then
            parts[#parts + 1] = data
            got = got + #data
        elseif err == "timeout" and os.time() < deadline then
            -- nothing yet (busy CPU / big frame): keep waiting instead of treating it as a crash
        else
            error("rfb read: " .. tostring(err))
        end
    end
    return table.concat(parts)
end

function RFB:handshake()
    local ver = self:read(12)
    if not ver:match("^RFB 003%.%d%d%d\n$") then error("not an RFB server") end
    self:send("RFB 003.008\n")
    local n = self:read(1):byte()
    if n == 0 then error("rfb: server refused connection") end
    local types = self:read(n)
    local has_none = false
    for i = 1, n do if types:byte(i) == 1 then has_none = true end end
    if not has_none then error("rfb: server wants authentication") end
    self:send("\1")
    if be32(self:read(4), 1) ~= 0 then error("rfb: security handshake failed") end
    self:send("\1") -- shared session
    local init = self:read(24)
    self.w, self.h = be16(init, 1), be16(init, 3)
    self:read(be32(init, 21)) -- desktop name
    -- 32 bpp, depth 24, little endian, true colour, R in the lowest byte so the
    -- memory layout is R,G,B,pad like a KOReader RGB32 blitbuffer.
    self:send("\0\0\0\0" .. string.char(32, 24, 0, 1)
        .. p16(255) .. p16(255) .. p16(255) .. string.char(0, 8, 16) .. "\0\0\0")
    self:send("\2\0" .. p16(1) .. p32(0)) -- encodings: Raw only
    self.bb = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BBRGB32)
    self.bb:fill(Blitbuffer.COLOR_BLACK)
end

function RFB.connect(host, port)
    local socket = require("socket")
    local sock = socket.tcp()
    sock:settimeout(3)
    local ok, err = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, err
    end
    local self = setmetatable({ sock = sock }, RFB)
    local hs_ok, hs_err = pcall(self.handshake, self)
    if not hs_ok then
        sock:close()
        return nil, hs_err
    end
    return self
end

function RFB:close()
    if self.sock then pcall(self.sock.close, self.sock); self.sock = nil end
end

function RFB:requestUpdate(incremental)
    self:send("\3" .. string.char(incremental and 1 or 0)
        .. p16(0) .. p16(0) .. p16(self.w) .. p16(self.h))
end

function RFB:blit(x, y, w, h, data)
    local bb = self.bb
    local stride = bbStride(bb)
    local src = ffi.cast("const uint8_t*", data)
    for row = 0, h - 1 do
        if y + row >= self.h then break end
        local dst = bb.data + (y + row) * stride + x * 4
        ffi.copy(dst, src + row * w * 4, w * 4)
        for i = 0, w - 1 do dst[i * 4 + 3] = 255 end -- opaque alpha
    end
end

-- Returns nil (nothing pending), false (message handled, no pixels), or the
-- union rectangle {x0,y0,x1,y1} of changed pixels.
function RFB:poll()
    local socket = require("socket")
    local ready = socket.select({ self.sock }, nil, 0)
    if not ready or not ready[1] then return nil end
    local t = self:read(1):byte()
    if t == 0 then
        local n = be16(self:read(3), 2)
        local x0, y0, x1, y1
        for _ = 1, n do
            local rh = self:read(12)
            local x, y, w, h = be16(rh, 1), be16(rh, 3), be16(rh, 5), be16(rh, 7)
            if s32(rh, 9) ~= 0 then error("rfb: unsupported encoding") end
            self:blit(x, y, w, h, self:read(w * h * 4))
            x0 = x0 and math.min(x0, x) or x
            y0 = y0 and math.min(y0, y) or y
            x1 = x1 and math.max(x1, x + w) or (x + w)
            y1 = y1 and math.max(y1, y + h) or (y + h)
        end
        if x0 then return { x0, y0, x1, y1 } end
        return false
    elseif t == 2 then -- bell
        return false
    elseif t == 3 then -- server cut text
        self:read(be32(self:read(7), 4))
        return false
    end
    error("rfb: unexpected server message " .. tostring(t))
end

function RFB:pointer(x, y, mask)
    self:send("\5" .. string.char(mask) .. p16(math.max(0, x)) .. p16(math.max(0, y)))
end

function RFB:key(keysym, down)
    self:send("\4" .. string.char(down and 1 or 0) .. "\0\0" .. p32(keysym))
end

-- ---------------------------------------------------------- process mgmt ----
local Proc = { pid = nil }

local function binaryPath()
    local p = MD_DIR .. "/bin/midless"
    if fileExists(p) then return p end
end

function Proc.available()
    if not binaryPath() then
        return false, _("Midless is not installed. Unzip midless-kobo.zip into the Kobo root (see README).")
    end
    return true
end

-- SIGTERM first so the game can write its world, SIGKILL only if it lingers (~2 s).
function Proc.stop()
    local pid = Proc.pid
    Proc.pid = nil
    os.execute("pkill -x midless >/dev/null 2>&1")
    if pid then
        os.execute(string.format(
            "i=0; while [ -d /proc/%d ] && [ $i -lt 10 ]; do sleep 0.2; i=$((i+1)); done", pid))
    end
    os.execute("pkill -9 -x midless >/dev/null 2>&1")
end

function Proc.start(out_w)
    Proc.stop()
    local exe = binaryPath()
    if not exe then return false end
    -- The VNC server binds to 127.0.0.1; some e-readers leave "lo" down, so bring it up.
    os.execute("ifconfig lo 127.0.0.1 netmask 255.0.0.0 up >/dev/null 2>&1 || ip link set lo up >/dev/null 2>&1")
    os.execute("mkdir -p " .. shq(MD_HOME))
    -- MD_OUT_W: the game picture is shrunk (integer factor) until it is at most this wide.
    local cmd = string.format(
        "(trap '' PIPE; cd %s && MD_OUT_W=%d MD_FPS=%s LD_LIBRARY_PATH=%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} %s; echo \"[midless exit code $?]\") >%s 2>&1 & echo $!",
        shq(MD_HOME), out_w, os.getenv("MD_FPS") or "15", shq(MD_DIR .. "/lib"), shq(exe), shq(MD_LOG))
    local p = io.popen(cmd)
    if not p then return false end
    local pid = p:read("*l")
    p:close()
    Proc.pid = tonumber(pid)
    return Proc.pid ~= nil
end

function Proc.alive()
    if not Proc.pid then return false end
    return fileExists("/proc/" .. Proc.pid .. "/stat")
end

local function logTail()
    local f = io.open(MD_LOG, "rb")
    if not f then return "" end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - 700))
    local data = f:read("*a") or ""
    f:close()
    if size > 700 then data = data:gsub("^[^\n]*\n", "", 1) end
    return data
end

-- -------------------------------------------------------------- controls ----
-- X11 keysyms understood by midless/md_shim.cpp
local K = {
    Left = 0xFF51, Up = 0xFF52, Right = 0xFF53, Down = 0xFF54,
    Enter = 0xFF0D, Esc = 0xFF1B, Space = 0x20,
}
local function ch(c) return c:byte() end

-- Rows of buttons; every row is split evenly. All buttons are "hold = key held".
local LAYOUT = {
    { { "Break", ch("e") }, { "Place", ch("q") }, { "Jump", K.Space } },
    { { "W  ↑", ch("w") } },
    { { "A  ←", ch("a") }, { "S  ↓", ch("s") }, { "D  →", ch("d") } },
    { { "Look ◀", K.Left }, { "Look ▲", K.Up }, { "Look ▼", K.Down }, { "Look ▶", K.Right } },
    { { "Block −", ch("z") }, { "Block +", ch("x") } },
}

-- ------------------------------------------------------------ game state ----
-- One game at a time: the process, the VNC connection and the timers live here, not in
-- the panes, because AppDock may rebuild the pane (buildPane) while the game is running.
local Game = { running = false, rfb = nil, view = nil, state = nil, context = nil, status = nil }

local function requestRebuild(context)
    if context and context.requestRebuild then context.requestRebuild("ui"); return true end
    return false
end

function Game:cancelStop()
    if self.stop_cb then UIManager:unschedule(self.stop_cb); self.stop_cb = nil end
end

function Game:closeConn()
    if self.connect_cb then UIManager:unschedule(self.connect_cb); self.connect_cb = nil end
    if self.poll_cb then UIManager:unschedule(self.poll_cb); self.poll_cb = nil end
    if self.rfb then self.rfb:close(); self.rfb = nil end
end

function Game:shutdown()
    self:cancelStop()
    self:closeConn()
    self.running = false
    self.status = nil
    Proc.stop()
end

function Game:launch(state, context, out_w)
    self.state, self.context = state, context
    self:cancelStop()
    self:closeConn()
    if not Proc.start(out_w) then return false, _("Could not start Midless.") end
    self.running = true
    self.status = _("Starting Midless…")
    self.connect_deadline = os.time() + CONNECT_TIMEOUT
    self.connect_cb = function() self:tryConnect() end
    UIManager:scheduleIn(0.5, self.connect_cb)
    return true
end

-- Stops the game and sends the pane back to the splash screen.
function Game:leave(message, rebuild)
    local state, context = self.state, self.context
    self:shutdown()
    if state then
        state.screen = "splash"
        state.error = message and tostring(message) or nil
    end
    if rebuild ~= false and not requestRebuild(context) and message then
        UIManager:show(InfoMessage:new{ text = tostring(message), timeout = 6 })
    end
end

function Game:fail(message)
    if not self.running then return end
    self:leave(message, true)
end

function Game:attach(view)
    self.view = view
    view.active = true
    self:cancelStop()
end

-- The pane was deactivated (user left the DApp). A rebuild attaches a new view within a
-- moment; if nobody does, the game process is stopped.
function Game:detach(view)
    if self.view ~= view then return end
    view.active = false
    self:cancelStop()
    self.stop_cb = function()
        self.stop_cb = nil
        if self.view == view and not view.active and self.running then
            self:leave(nil, false)
        end
    end
    UIManager:scheduleIn(1.0, self.stop_cb)
end

function Game:tryConnect()
    if not self.running then return end
    local rfb = RFB.connect(VNC_HOST, VNC_PORT)
    if rfb then
        self.rfb = rfb
        self.status = nil
        pcall(rfb.requestUpdate, rfb, false)
        self.poll_cb = function() self:poll() end
        UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb)
        local view = self.view
        if view and (view.expect_w ~= rfb.w or view.expect_h ~= rfb.h) then
            -- the picture is not the size the pane was laid out for: lay it out again
            requestRebuild(self.context)
        end
        return
    end
    if os.time() > self.connect_deadline then
        self:fail(_("Midless did not start.") .. "\n" .. logTail())
        return
    end
    UIManager:scheduleIn(0.4, self.connect_cb)
end

function Game:poll()
    if not self.running or not self.rfb then return end
    local ok, res = pcall(self.rfb.poll, self.rfb)
    if not ok then
        -- the game quit or crashed.
        logger.warn("Midless: " .. tostring(res))
        self:fail(_("Midless exited.") .. "\n" .. tostring(res) .. "\n" .. logTail())
        return
    end
    if res then
        pcall(self.rfb.requestUpdate, self.rfb, true)
        local w, h = res[3] - res[1], res[4] - res[2]
        local view = self.view
        if w > 0 and h > 0 and view and view.active then
            view:refreshRegion(res[1], res[2], w, h)
        end
    end
    if self.running and self.poll_cb then UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb) end
end

function Game:sendKey(key, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.key, self.rfb, key, down)
    if not ok then
        logger.warn("Midless: " .. tostring(err))
        self:fail(_("Midless exited.") .. "\n" .. tostring(err) .. "\n" .. logTail())
    end
end

function Game:pulseKey(key, seconds)
    self:sendKey(key, true)
    UIManager:scheduleIn(seconds or 0.15, function() self:sendKey(key, false) end)
end

function Game:pointer(x, y, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.pointer, self.rfb, x, y, down and 1 or 0)
    if not ok then
        logger.warn("Midless: " .. tostring(err))
        self:fail(_("Midless exited.") .. "\n" .. tostring(err) .. "\n" .. logTail())
    end
end

-- ------------------------------------------------------------ small widgets ----
local function paintBevel(bb, x, y, w, h, pressed)
    local shadow = math.max(1, math.min(3, math.floor(h * 0.06)))
    local face = pressed and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_LIGHT_GRAY
    bb:paintRect(x + shadow, y + shadow, w - shadow, h - shadow, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, w - shadow, h - shadow, face)
    local edge = pressed and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    bb:paintRect(x + 2, y + 2, math.max(1, w - shadow - 4), 1, edge)
    bb:paintRect(x + 2, y + 2, 1, math.max(1, h - shadow - 4), edge)
    return shadow
end

local Fill = InputContainer:extend{ width = nil, height = nil, color = nil, dimen = nil }

function Fill:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function Fill:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, self.color or Blitbuffer.COLOR_WHITE)
end

local MLButton = InputContainer:extend{
    title = "", width = nil, height = nil, callback = nil, primary = false, dimen = nil,
}

function MLButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.range = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { TapMidlessButton = { GestureRange:new{ ges = "tap", range = self.range } } }
end

function MLButton:paintTo(bb, x, y)
    local r = self.range
    r.x, r.y, r.w, r.h = x, y, self.width, self.height
    local shadow = paintBevel(bb, x, y, self.width, self.height, false)
    if self.primary then
        bb:paintRect(x + 3, y + 3, math.max(1, self.width - shadow - 6), math.max(1, self.height - shadow - 6), Blitbuffer.COLOR_BLACK)
    end
    local label = TextWidget:new{
        text = self.title, face = Font:getFace("smallinfofont", clamp(math.floor(self.height * 0.34), 12, 22)),
        fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, bold = true,
        max_width = math.max(scale(12), self.width - shadow - scale(8)),
    }
    local size = label:getSize()
    label:paintTo(bb, x + math.floor((self.width - shadow - size.w) / 2), y + math.floor((self.height - shadow - size.h) / 2))
    label:free()
    return true
end

function MLButton:onTapMidlessButton()
    if self.callback then self.callback() end
    return true
end

-- --------------------------------------------------------------- game view ----
-- Shows the VNC picture. Tapping the picture = left click = break the block you look at.
local GameView = InputContainer:extend{ width = nil, height = nil, dimen = nil }

function GameView:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.range = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local screen_range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ptr_slot = {}
    self.ges_events = {
        TouchMidlessGame = { GestureRange:new{ ges = "touch", range = self.range } },
        ReleaseMidlessGame = { GestureRange:new{ ges = "release", range = screen_range } },
        TapMidlessGame = { GestureRange:new{ ges = "tap", range = self.range } },
    }
    self.status_face = Font:getFace("cfont", 22)
end

function GameView:pictureX()
    local rfb = Game.rfb
    if not rfb then return 0 end
    return math.max(0, math.floor((self.width - rfb.w) / 2))
end

function GameView:paintTo(bb, x, y)
    self._ox, self._oy = x, y
    local r = self.range
    r.x, r.y, r.w, r.h = x, y, self.width, self.height
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local rfb = Game.rfb
    if rfb then
        local px0 = self:pictureX()
        bb:blitFrom(rfb.bb, x + px0, y, 0, 0, math.min(self.width - px0, rfb.w), math.min(self.height, rfb.h))
    else
        local text = TextWidget:new{ text = Game.status or _("Starting Midless…"), face = self.status_face, max_width = self.width - 40 }
        text:paintTo(bb, x + 20, y + 20)
        text:free()
    end
end

-- Repaint only this view and refresh only the rectangle that changed.
function GameView:refreshRegion(rx, ry, rw, rh)
    local ox, oy = self._ox, self._oy
    if not ox then return end
    local region = Geom:new{ x = ox + self:pictureX() + rx, y = oy + ry, w = rw, h = rh }
    if UIManager.widgetRepaint then
        UIManager:widgetRepaint(self, ox, oy)
        UIManager:setDirty(nil, REFRESH_MODE, region)
    else
        UIManager:setDirty(self.pane or self, REFRESH_MODE, region)
    end
end

-- Position inside the game picture (picture coordinates) or nil.
function GameView:gamePos(pos)
    local rfb = Game.rfb
    if not rfb or not pos then return nil end
    local x = pos.x - (self._ox or 0) - self:pictureX()
    local y = pos.y - (self._oy or 0)
    if x < 0 or y < 0 or x >= rfb.w or y >= rfb.h then return nil end
    return x, y
end

function GameView:onTouchMidlessGame(_arg, ges)
    local gx, gy = self:gamePos(ges.pos)
    if not gx then return true end
    self.ptr_slot[ges.slot or 0] = true
    self.last_game_touch = os.clock()
    self.last_gx, self.last_gy = gx, gy
    Game:pointer(gx, gy, true)
    return true
end

function GameView:onReleaseMidlessGame(_arg, ges)
    local slot = ges.slot or 0
    if not self.ptr_slot[slot] then return false end
    self.ptr_slot[slot] = nil
    local gx, gy = self:gamePos(ges.pos)
    Game:pointer(gx or self.last_gx or 0, gy or self.last_gy or 0, false)
    return true
end

-- Fallback for devices/KOReader versions that do not deliver touch/release:
-- a plain tap becomes a short click.
function GameView:onTapMidlessGame(_arg, ges)
    local gx, gy = self:gamePos(ges.pos)
    if gx and os.clock() - (self.last_game_touch or -10) > 1.0 then
        Game:pointer(gx, gy, true)
        UIManager:scheduleIn(0.2, function() Game:pointer(gx, gy, false) end)
    end
    return true
end

-- --------------------------------------------------------------------- pad ----
-- The button grid below the picture (hold = key held).
local Pad = InputContainer:extend{ width = nil, height = nil, dimen = nil }

function Pad:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.range = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local screen_range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.held, self.by_slot, self.last_touch = {}, {}, {}
    self.ges_events = {
        TouchMidlessPad = { GestureRange:new{ ges = "touch", range = self.range } },
        ReleaseMidlessPad = { GestureRange:new{ ges = "release", range = screen_range } },
        TapMidlessPad = { GestureRange:new{ ges = "tap", range = self.range } },
    }
    self:layoutButtons()
end

function Pad:layoutButtons()
    local sw = self.width
    self.buttons = {}
    local margin = scale(6)
    local avail = self.height - margin
    if avail < 100 then return end
    local rows = #LAYOUT
    local unit = math.min(math.floor(avail / rows), scale(110))
    local face = Font:getFace("cfont", clamp(math.floor(unit * 0.28), 14, 24))
    local y = margin
    for _, row in ipairs(LAYOUT) do
        local cell_w = math.floor((sw - margin * (#row + 1)) / #row)
        for i, def in ipairs(row) do
            self.buttons[#self.buttons + 1] = {
                label = def[1], key = def[2],
                rect = { x = margin + (i - 1) * (cell_w + margin), y = y, w = cell_w, h = unit - margin },
                text = TextWidget:new{ text = def[1], face = face, max_width = cell_w - 8 },
            }
        end
        y = y + unit
    end
end

function Pad:paintTo(bb, x, y)
    self._ox, self._oy = x, y
    local r = self.range
    r.x, r.y, r.w, r.h = x, y, self.width, self.height
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    for _, b in ipairs(self.buttons) do
        local br = b.rect
        local pressed = self.held[b]
        local shadow = paintBevel(bb, x + br.x, y + br.y, br.w, br.h, pressed)
        local ts = b.text:getSize()
        b.text:paintTo(bb, x + br.x + math.floor((br.w - shadow - ts.w) / 2), y + br.y + math.floor((br.h - shadow - ts.h) / 2))
    end
end

-- Redraw one button right away (held / released) without touching the rest of the pane.
function Pad:redrawButton(b)
    if not BUTTON_FEEDBACK or not self._ox then return end
    local br = b.rect
    local region = Geom:new{ x = self._ox + br.x, y = self._oy + br.y, w = br.w, h = br.h }
    if UIManager.widgetRepaint then
        UIManager:widgetRepaint(self, self._ox, self._oy)
        UIManager:setDirty(nil, "fast", region)
    else
        UIManager:setDirty(self.pane or self, "fast", region)
    end
end

function Pad:buttonAt(pos)
    if not pos then return nil end
    local lx, ly = pos.x - (self._ox or 0), pos.y - (self._oy or 0)
    for _, b in ipairs(self.buttons) do
        local r = b.rect
        if lx >= r.x and lx < r.x + r.w and ly >= r.y and ly < r.y + r.h then return b end
    end
end

function Pad:press(b)
    if self.held[b] then return end
    self.held[b] = true
    Game:sendKey(b.key, true)
    -- safety net in case the "release" event never arrives
    b.timeout_cb = function() b.timeout_cb = nil; self:release(b) end
    UIManager:scheduleIn(HOLD_SAFETY, b.timeout_cb)
    self:redrawButton(b)
end

function Pad:release(b)
    if not self.held[b] then return end
    self.held[b] = nil
    if b.timeout_cb then UIManager:unschedule(b.timeout_cb); b.timeout_cb = nil end
    Game:sendKey(b.key, false)
    self:redrawButton(b)
end

function Pad:pulse(b, seconds)
    self:press(b)
    UIManager:scheduleIn(seconds or 0.2, function() self:release(b) end)
end

function Pad:onTouchMidlessPad(_arg, ges)
    local b = self:buttonAt(ges.pos)
    if not b then return true end
    self.last_touch[b] = os.clock()
    self.by_slot[ges.slot or 0] = b
    self:press(b)
    return true
end

function Pad:onReleaseMidlessPad(_arg, ges)
    local slot = ges.slot or 0
    local b = self.by_slot[slot]
    if not b then return false end
    self.by_slot[slot] = nil
    self:release(b)
    return true
end

-- Fallback for devices/KOReader versions that do not deliver touch/release:
-- a plain tap becomes a short key press.
function Pad:onTapMidlessPad(_arg, ges)
    local b = self:buttonAt(ges.pos)
    if b and os.clock() - (self.last_touch[b] or -10) > 1.0 then self:pulse(b, 0.2) end
    return true
end

-- -------------------------------------------------------------------- pane ----
local MidlessPane = InputContainer:extend{ game_view = nil, state = nil }

-- AppDock calls this when the pane is left.
function MidlessPane:onDeactivate()
    if self.game_view then Game:detach(self.game_view) end
end

-- If the host re-shows this pane after the game was stopped, lay it out again (splash).
function MidlessPane:onActivate()
    if self.game_view and not Game.running and self.state and self.state.screen ~= "game" then
        requestRebuild(Game.context)
    end
end

function MidlessPane:_stopForSystem(rebuild)
    if self.game_view and Game.view == self.game_view and Game.running then
        Game:leave(nil, rebuild)
    end
    return false -- let other widgets see the event as well
end
function MidlessPane:onSuspend() return self:_stopForSystem(true) end
function MidlessPane:onExit() return self:_stopForSystem(false) end
function MidlessPane:onRestart() return self:_stopForSystem(false) end
function MidlessPane:onPowerOff() return self:_stopForSystem(false) end
function MidlessPane:onReboot() return self:_stopForSystem(false) end

-- Page-turn buttons = jump (only while the game is on).
function MidlessPane:onMidlessJump()
    if not (Game.running and Game.rfb) then return false end
    Game:pulseKey(K.Space)
    return true
end

local function stateFor(instance)
    if instance.midless then return instance.midless end
    local state = { screen = "splash", error = nil }
    instance.midless = state
    return state
end

local function newPane(width, height, children, extra)
    local dimen = Geom:new{ w = width, h = height }
    local pane = MidlessPane:new{ dimen = dimen }
    for k, v in pairs(extra or {}) do pane[k] = v end
    pane[1] = OverlapGroup:new{ dimen = dimen, allow_mirroring = false, unpack(children) }
    return pane
end

-- ------------------------------------------------------------------ splash ----
local function buildSplash(state, context, width, height)
    if Game.running then Game:shutdown() end
    local px = context.px or scale
    local children = { Fill:new{ width = width, height = height, color = Blitbuffer.COLOR_WHITE } }
    local margin = math.max(px(16), math.floor(width * 0.06))
    local text_w = width - 2 * margin
    local y = math.max(px(18), math.floor(height * 0.07))
    local function add(widget, x)
        widget.overlap_offset = { x or margin, y }
        children[#children + 1] = widget
        y = y + widget:getSize().h
    end

    add(TextWidget:new{
        text = "Midless", face = Font:getFace("cfont", clamp(math.floor(width / 11), 28, px(54))),
        bold = true, max_width = text_w,
    })
    y = y + px(4)
    add(TextWidget:new{
        text = _("Voxel sandbox for your Kobo · single player"),
        face = Font:getFace("smallinfofont", clamp(math.floor(width / 38), 12, px(17))), max_width = text_w,
    })
    y = y + px(18)
    add(TextBoxWidget:new{
        text = _("Tap the picture to break the block you look at.\nHold the buttons below it to walk, look, jump, break and place blocks.\nThe world is saved when you stop the game."),
        face = Font:getFace("smallinfofont", clamp(math.floor(width / 40), 12, px(16))), width = text_w,
    })
    y = y + px(14)

    local installed, install_err = Proc.available()
    local note = (not installed) and install_err or state.error
    if note and note ~= "" then
        add(TextBoxWidget:new{
            text = note, face = Font:getFace("smallinfofont", clamp(math.floor(width / 44), 11, px(14))),
            width = text_w, bold = not installed,
        })
        y = y + px(14)
    end

    local button_w = math.min(math.floor(width * 0.78), px(420))
    local button_h = clamp(math.floor(height * 0.10), px(46), px(66))
    local button_y = math.min(y + px(6), height - button_h - px(50))
    children[#children + 1] = MLButton:new{
        title = _("Play"), width = button_w, height = button_h, primary = true,
        overlap_offset = { math.floor((width - button_w) / 2), button_y },
        callback = function()
            local ok, err = Proc.available()
            if not ok then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            state.screen, state.error = "game", nil
            requestRebuild(context)
        end,
    }
    children[#children + 1] = TextWidget:new{
        text = _("Midless by Sirvoid · MIT license"),
        face = Font:getFace("smallinfofont", clamp(math.floor(width / 52), 10, px(13))),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = text_w,
        overlap_offset = { margin, height - px(30) },
    }
    return newPane(width, height, children, { state = state })
end

-- -------------------------------------------------------------------- game ----
local function buildGame(state, context, width, height)
    local px = context.px or scale
    Game.context = context

    -- Start the game process unless it is already running for this instance (a rebuild
    -- of the pane must not restart it).
    if Game.running then
        Game.state = state -- a rebuild must never restart (and kill) the running game
    else
        local ok, err = Game:launch(state, context, width)
        if not ok then
            state.screen, state.error = "splash", err
            return buildSplash(state, context, width, height)
        end
    end

    local header_h = math.min(px(46), math.floor(height * 0.08))
    local pic_w, pic_h
    if Game.rfb then
        pic_w, pic_h = Game.rfb.w, Game.rfb.h
    else
        pic_w, pic_h = expectedPicture(width)
    end
    local game_h = math.min(pic_h, math.max(px(120), height - header_h - px(240)))
    local pad_h = math.max(0, height - header_h - game_h)

    local view = GameView:new{ width = width, height = game_h }
    view.expect_w, view.expect_h = pic_w, pic_h
    local pad = Pad:new{ width = width, height = pad_h }
    view.pad = pad
    Game:attach(view)

    local stop_w = math.min(px(96), math.floor(width * 0.26))
    local stop_h = math.min(px(34), header_h - px(6))
    local children = {
        Fill:new{ width = width, height = height, color = Blitbuffer.COLOR_WHITE },
        TextWidget:new{
            text = "Midless", face = Font:getFace("cfont", clamp(px(19), 14, 30)), bold = true,
            max_width = width - stop_w - px(30),
            overlap_offset = { px(12), math.floor((header_h - px(24)) / 2) },
        },
        MLButton:new{
            title = _("Stop"), width = stop_w, height = stop_h,
            overlap_offset = { width - stop_w - px(8), math.floor((header_h - stop_h) / 2) },
            callback = function() Game:leave(nil, true) end,
        },
        view,
        pad,
    }
    view.overlap_offset = { 0, header_h }
    pad.overlap_offset = { 0, header_h + game_h }

    local pane = newPane(width, height, children, { state = state, game_view = view })
    view.pane = pane
    pad.pane = pane
    if Device:hasKeys() then
        pane.key_events = {
            MidlessJump = { { "RPgFwd" }, { "LPgFwd" }, { "RPgBack" }, { "LPgBack" }, event = "MidlessJump" },
        }
    end
    return pane
end

-- ------------------------------------------------------------ public API ----
return {
    id = "midless",
    version = "1.0.0",
    title = "Midless",
    subtitle = "Voxel sandbox",
    symbol = "Ml",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        if state.screen == "game" then return buildGame(state, context, width, height) end
        return buildSplash(state, context, width, height)
    end,
    _test = {
        RFB = RFB,
        Proc = Proc,
        Game = Game,
        GameView = GameView,
        Pad = Pad,
        LAYOUT = LAYOUT,
        K = K,
        shq = shq,
        expectedPicture = expectedPicture,
        buildSplash = buildSplash,
        buildGame = buildGame,
    },
}
