--[[--
tic80 for AppDock (DApp).

TIC-80 is a fantasy computer (nesbox/TIC-80, MIT). It runs as a native background process
(/mnt/onboard/.adds/tic80/bin/tic80 = the TIC-80 libretro core driven by geodash/gd_shim.cpp)
that publishes its picture through a loopback-only VNC server (127.0.0.1:5963). This DApp starts
that process, shows the picture inside an AppDock pane and sends touch input back as key/mouse
events.

Like the other DApps it exports { id, version, title, subtitle, symbol, buildPane } and draws into
the pane it is given. Game frames only repaint the game view (UIManager:widgetRepaint + a refresh of
the changed rectangle), never the whole AppDock pane.

Files expected on the device (installed by the AppDock Store from tic80.zip; the store requires the
launcher convention <name>/bin/<name> for a catalog entry <name>.lua):
  /mnt/onboard/.adds/tic80/bin/tic80
  /mnt/onboard/.adds/tic80/lib/tic80_libretro.so
  /mnt/onboard/.adds/tic80/home/carts/*.tic        <- your carts

Screens: splash (Play / Download carts) -> cart list (skipped when there is only one cart) -> game
(picture + button pad). "Download carts" opens a store that lists tic80.com (category + sort) and saves
the chosen cart as <slug>.tic into the carts folder (needs Wi-Fi). The game process only lives while the game pane is on screen: leaving the
DApp, "Quit" or suspending the device shuts it down and the pane returns to the splash screen.

Controls: tapping the picture = touch pointer / mouse click (carts that use the mouse).
Buttons below the picture: arrows, A (Z), B (X), X (A), Y (S), Esc (TIC-80 menu), Enter (Start), Quit.
Page-turn buttons = A.
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
local bit = require("bit")
local ffi = require("ffi")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen
local gettime = require("socket").gettime

-- ---------------------------------------------------------------- config ----
local GD_DIR = os.getenv("GD_DIR") or "/mnt/onboard/.adds/tic80"
local GD_LOG = GD_DIR .. "/tic80.log"
local GD_HOME = GD_DIR .. "/home"                -- working dir of the process
local CARTS_DIR = GD_HOME .. "/carts"            -- *.tic files
local VNC_HOST, VNC_PORT = "127.0.0.1", 5963     -- must match scripts/03-geodash.sh
local GAME_FPS = 15                              -- the native process and the VNC polling are capped at this
local POLL_INTERVAL = 1 / GAME_FPS
local FRAME_MS = math.floor(1000 / GAME_FPS + 0.5)
local CONNECT_TIMEOUT = 20
local READ_TIMEOUT = 15          -- seconds a half-received message may take before the connection counts as dead
local HOLD_SAFETY = 2.5          -- seconds after which a held key is released even without a "release" event
local PRESS_DURATION = 0.16      -- minimum key/click length so quick e-ink taps are not lost between two frames
local BUTTON_FEEDBACK = true     -- redraw a control button while it is held
-- KOReader refresh mode for game frames: "fast" (A2, ghosty, bad colours on Kaleido screens but the quickest).
local REFRESH_MODE = os.getenv("GD_REFRESH") or "fast"
-- The picture is dithered before it is drawn: to the eight primaries, or with GD_BW=1 to pure black/white.
-- GD_DITHER=0 switches dithering off (debugging only).
local DITHER = os.getenv("GD_DITHER") ~= "0"
local BW = os.getenv("GD_BW") == "1"
local TIC_ASPECT = 240 / 136     -- TIC-80 screen; real size comes from the VNC handshake
local MAX_SCALE = tonumber(os.getenv("GD_SCALE")) or 8
local SAT = tonumber(os.getenv("GD_SAT")) or 1.6                       -- saturation boost before dithering
local DITHER_AMP = tonumber(os.getenv("GD_DITHER_AMP")) or (BW and 4 or 2)
local PIC_OUT_W = tonumber(os.getenv("GD_PIC_W")) or 720
local SHOW_STATS = false
local Stats = {}                 -- placeholder (statistics banner is disabled)
local BTN_UNIT = 40
-- Touch position correction, applied here in Lua before the position is sent to the game
-- (no rebuild of the native part needed). Percent of the picture size: 100 = unchanged,
-- 200 = the pointer is sent twice as far from the top-left corner. x and y separately.
-- Override with GD_PTR_SX / GD_PTR_SY.
local PTR_SX = tonumber(os.getenv("GD_PTR_SX")) or 100
local PTR_SY = tonumber(os.getenv("GD_PTR_SY")) or 100
-- Pointer mode: 1 = the core reads an absolute touch pointer, 0 = the core reads a relative mouse.
-- If taps land in the wrong place, try the other value (override with GD_TOUCH).
local PTR_TOUCH = tonumber(os.getenv("GD_TOUCH")) or 1

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

-- Guess of the picture size before the VNC handshake: full width, TIC-80 aspect ratio.
local function expectedPicture(avail_w, avail_h)
    local w = math.max(2, avail_w)
    local h = math.max(2, math.floor(w / TIC_ASPECT + 0.5))
    return w - w % 2, h - h % 2
end

-- Size on screen: the game picture scaled (nearest neighbour) to fill the given area.
local function fitPicture(sw, sh, avail_w, avail_h)
    local f = math.min(avail_w / sw, avail_h / sh, MAX_SCALE)
    f = math.max(f, 0.25)
    return math.max(8, math.floor(sw * f)), math.max(8, math.floor(sh * f))
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

-- 8x8 Bayer matrix -> thresholds (0..254): per colour channel (8 colours) or on the luminance (B/W).
local THRESH = ffi.new("uint8_t[64]")
do
    local m = { { 0 } }
    local n = 1
    local add = { { 0, 2 }, { 3, 1 } }
    for _ = 1, 3 do
        local m2 = {}
        for y = 0, 2 * n - 1 do
            m2[y + 1] = {}
            for x = 0, 2 * n - 1 do
                m2[y + 1][x + 1] = 4 * m[y % n + 1][x % n + 1] + add[math.floor(y / n) + 1][math.floor(x / n) + 1]
            end
        end
        m, n = m2, 2 * n
    end
    for y = 0, 7 do
        for x = 0, 7 do
            local t = math.floor(128 + (m[y + 1][x + 1] - 31.5) * DITHER_AMP)
            THRESH[y * 8 + x] = math.max(0, math.min(254, t))
        end
    end
end

-- Black/white only (0xAABBGGRR): the picture is turned into luminance and dithered with the
-- Bayer matrix, which is what the A2 waveform shows fastest.
local C_BLACK, C_WHITE = 0xFF000000, 0xFFFFFFFF
local band, arshift = bit.band, bit.arshift
-- Eight-colour palette (0xAABBGGRR): index = (r on) + 2*(g on) + 4*(b on).
local PALETTE = ffi.new("uint32_t[8]", {
    C_BLACK, 0xFF0000FF, 0xFF00FF00, 0xFF00FFFF,   -- black, red, green, yellow
    0xFFFF0000, 0xFFFF00FF, 0xFFFFFF00, C_WHITE,   -- blue, magenta, cyan, white
})
local SAT_FIX = math.floor(SAT * 256 + 0.5) -- saturation as 8.8 fixed point

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
    self:setDisplay(self.w, self.h)
end

-- The picture is kept in a buffer of its on-screen size (dw x dh); the game picture
-- (w x h) is scaled with nearest neighbour while it is copied in.
function RFB:setDisplay(dw, dh)
    if self.bb and self.dw == dw and self.dh == dh then return false end
    if self.bb then self.bb:free() end
    self.dw, self.dh = dw, dh
    self.xmap = ffi.new("int32_t[?]", dw)
    self.ymap = ffi.new("int32_t[?]", dh)
    for i = 0, dw - 1 do self.xmap[i] = math.min(self.w - 1, math.floor(i * self.w / dw)) end
    for i = 0, dh - 1 do self.ymap[i] = math.min(self.h - 1, math.floor(i * self.h / dh)) end
    self.bb = Blitbuffer.new(dw, dh, Blitbuffer.TYPE_BBRGB32)
    self.bb:fill(Blitbuffer.COLOR_BLACK)
    return true
end

-- Source rectangle -> on-screen rectangle.
function RFB:toDisplay(x0, y0, x1, y1)
    local dw, dh = self.dw, self.dh
    return math.max(0, math.floor(x0 * dw / self.w)), math.max(0, math.floor(y0 * dh / self.h)),
        math.min(dw, math.ceil(x1 * dw / self.w)), math.min(dh, math.ceil(y1 * dh / self.h))
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

-- Fast path: every source row is dithered ONCE (at game resolution, Bayer pattern) into a
-- row buffer and then expanded to screen size with plain 32-bit copies; identical screen
-- rows are copied with ffi.copy. Dithering per screen pixel was far too slow on the big picture.
local ROWBUF_N = 0
local ROWBUF = nil
function RFB:blit(x, y, w, h, data)
    local bb = self.bb
    local stride = bbStride(bb)
    local src = ffi.cast("const uint8_t*", data)
    local base = ffi.cast("uint8_t*", bb.data) -- bb.data points to ColorRGB32 structs, work on bytes
    local xmap, ymap = self.xmap, self.ymap
    local dx0, dy0, dx1, dy1 = self:toDisplay(x, y, x + w, y + h)
    if dx1 <= dx0 or dy1 <= dy0 then return end
    if ROWBUF_N < w then ROWBUF = ffi.new("uint32_t[?]", w); ROWBUF_N = w end
    local rowbuf = ROWBUF
    local last_sy, last_drow = -1, nil
    local span = (dx1 - dx0) * 4
    for dy = dy0, dy1 - 1 do
        local sy = ymap[dy]
        if sy >= y and sy < y + h then
            local drow = base + dy * stride
            if sy == last_sy and last_drow then
                ffi.copy(drow + dx0 * 4, last_drow + dx0 * 4, span)
            else
                local rowp = src + (sy - y) * w * 4
                if DITHER and BW then
                    local trow = THRESH + band(sy, 7) * 8
                    for i = 0, w - 1 do
                        local o = i * 4
                        -- luminance ~ 0.30 R + 0.59 G + 0.11 B
                        local l = (rowp[o] * 77 + rowp[o + 1] * 151 + rowp[o + 2] * 28) / 256
                        rowbuf[i] = l > trow[band(x + i, 7)] and C_WHITE or C_BLACK
                    end
                elseif DITHER then
                    local trow = THRESH + band(sy, 7) * 8
                    local pal = PALETTE
                    local sat = SAT_FIX
                    for i = 0, w - 1 do
                        local o = i * 4
                        local r, g, b = rowp[o], rowp[o + 1], rowp[o + 2]
                        local m = arshift((r + g + b) * 85, 8) -- ~ (r+g+b)/3
                        r = m + arshift((r - m) * sat, 8)
                        g = m + arshift((g - m) * sat, 8)
                        b = m + arshift((b - m) * sat, 8)
                        local t = trow[band(x + i, 7)]
                        rowbuf[i] = pal[(r > t and 1 or 0) + (g > t and 2 or 0) + (b > t and 4 or 0)]
                    end
                else
                    for i = 0, w - 1 do
                        local o = i * 4
                        rowbuf[i] = rowp[o] + rowp[o + 1] * 256 + rowp[o + 2] * 65536 + 4278190080
                    end
                end
                local d32 = ffi.cast("uint32_t*", drow)
                for dx = dx0, dx1 - 1 do
                    local sx = xmap[dx]
                    if sx >= x and sx < x + w then d32[dx] = rowbuf[sx - x] end
                end
                last_sy, last_drow = sy, drow
            end
        end
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
    local p = GD_DIR .. "/bin/tic80"
    if fileExists(p) then return p end
end

function Proc.available()
    if not binaryPath() then
        return false, _("TIC-80 is not installed. Install it from the AppDock Store (tic80.zip).")
    end
    if not fileExists(GD_DIR .. "/lib/tic80_libretro.so") then
        return false, _("TIC-80 core is missing: ") .. GD_DIR .. "/lib/tic80_libretro.so"
    end
    return true
end

-- true while something still accepts connections on the VNC port (an old game that is not gone yet)
local function vncPortOpen()
    local ok, res = pcall(function()
        local sock = require("socket").tcp()
        sock:settimeout(0.2)
        local c = sock:connect(VNC_HOST, VNC_PORT)
        sock:close()
        return c and true or false
    end)
    return ok and res or false
end

local function sleepSec(sec)
    os.execute(string.format("sleep %.1f", sec))
end

-- SIGTERM first so the game can quit cleanly, SIGKILL if it lingers (~2 s). Returns only when the
-- process is gone and the VNC port is free again, so a new game can never attach to the old one.
local function selfPid()
    local f = io.open("/proc/self/stat")
    if not f then return nil end
    local n = f:read("*n")
    f:close()
    return n
end

-- PIDs of the processes that listen on the VNC port (found via /proc, independent of the process name).
local function portOwnerPids()
    local inode
    local f = io.open("/proc/net/tcp")
    if f then
        for line in f:lines() do
            local port, st, ino = line:match("^%s*%d+:%s+%x+:(%x+)%s+%x+:%x+%s+(%x+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(%d+)")
            if port and tonumber(port, 16) == VNC_PORT and st == "0A" then inode = ino; break end
        end
        f:close()
    end
    local pids = {}
    if not inode or inode == "0" then return pids end
    local p = io.popen(string.format(
        "for d in /proc/[0-9]*; do ls -l \"$d/fd\" 2>/dev/null | grep -q 'socket:\\[%s\\]' && echo \"${d#/proc/}\"; done", inode))
    if p then
        for line in p:lines() do
            local n = tonumber(line)
            if n then pids[#pids + 1] = n end
        end
        p:close()
    end
    return pids
end

-- Sends a signal to every game process: the owner of the VNC port plus every process whose command
-- line contains the game binary path (independent of the process name).
local function signalGames(sig)
    pcall(function()
        local me = selfPid()
        local targets = {}
        for _i, n in ipairs(portOwnerPids()) do targets[n] = true end
        local lfs = require("libs/libkoreader-lfs")
        local exe = GD_DIR .. "/bin/tic80"
        for name in lfs.dir("/proc") do
            local n = tonumber(name)
            if n and n ~= me then
                local f = io.open("/proc/" .. name .. "/cmdline", "rb")
                if f then
                    local cmd = f:read("*a") or ""
                    f:close()
                    if cmd:find(exe, 1, true) then targets[n] = true end
                end
            end
        end
        targets[me or -1] = nil
        for n in pairs(targets) do
            os.execute(string.format("kill -%s %d >/dev/null 2>&1", sig, n))
        end
    end)
end

function Proc.stop()
    local pid = Proc.pid
    Proc.pid = nil
    signalGames("TERM")
    os.execute("pkill -x tic80 >/dev/null 2>&1; killall tic80 >/dev/null 2>&1")
    os.execute("i=0; while pgrep -x tic80 >/dev/null 2>&1 && [ $i -lt 10 ]; do sleep 0.2; i=$((i+1)); done")
    if pid then
        os.execute(string.format(
            "i=0; while [ -d /proc/%d ] && [ $i -lt 5 ]; do sleep 0.2; i=$((i+1)); done", pid))
        os.execute(string.format("kill -9 %d >/dev/null 2>&1", pid))
    end
    signalGames("KILL")
    os.execute("pkill -9 -x tic80 >/dev/null 2>&1; killall -9 tic80 >/dev/null 2>&1")
    local tries = 0
    while vncPortOpen() and tries < 15 do
        signalGames("KILL")
        os.execute("pkill -9 -x tic80 >/dev/null 2>&1")
        sleepSec(0.2)
        tries = tries + 1
    end
end

function Proc.start(cart, out_w, out_h)
    Proc.stop()
    local exe = binaryPath()
    if not exe or not cart then return false end
    -- The VNC server binds to 127.0.0.1; some e-readers leave "lo" down, so bring it up.
    os.execute("ifconfig lo 127.0.0.1 netmask 255.0.0.0 up >/dev/null 2>&1 || ip link set lo up >/dev/null 2>&1")
    os.execute("mkdir -p " .. shq(GD_HOME))
    -- GD_OUT_W/H: the TIC-80 picture (240x136) is enlarged by the biggest integer factor that fits.
    local cmd = string.format(
        "(trap '' PIPE; cd %s && TIC_CART=%s GD_OUT_W=%d GD_OUT_H=%d GD_FRAME_MS=%d GD_TOUCH=%d LD_LIBRARY_PATH=%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} %s; echo \"[tic80 exit code $?]\") >%s 2>&1 & echo $!",
        shq(GD_HOME), shq(cart), math.min(out_w, PIC_OUT_W), out_h, FRAME_MS, PTR_TOUCH,
        shq(GD_DIR .. "/lib"), shq(exe), shq(GD_LOG))
    pcall(function()
        local lf = io.open(GD_DIR .. "/launch.log", "a")
        if lf then
            lf:write(string.format("%s start cart=%s port_open_before=%s\n", os.date("%H:%M:%S"), tostring(cart), tostring(vncPortOpen())))
            lf:close()
        end
    end)
    local p = io.popen(cmd)
    if not p then return false end
    local pid = p:read("*l")
    p:close()
    Proc.pid = tonumber(pid)
    return Proc.pid ~= nil
end

local function logTail()
    local f = io.open(GD_LOG, "rb")
    if not f then return "" end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - 700))
    local data = f:read("*a") or ""
    f:close()
    if size > 700 then data = data:gsub("^[^\n]*\n", "", 1) end
    return data
end

-- *.tic files in CARTS_DIR, sorted by name.
local function listCarts()
    local carts = {}
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        for name in lfs.dir(CARTS_DIR) do
            if name:lower():match("%.tic$") then carts[#carts + 1] = name end
        end
    end)
    table.sort(carts, function(a, b) return a:lower() < b:lower() end)
    return carts
end

local function cartTitle(name) return (name:gsub("%.[tT][iI][cC]$", "")) end

-- ------------------------------------------------------------- cart store ----
-- Browses https://tic80.com/play/<category>/<sort>?page=N and downloads
-- https://tic80.com/cart/<hash>/<slug>.tic into CARTS_DIR.
local STORE_BASE = "https://tic80.com"
local STORE_CATS = {
    { id = "",          label = "All" },
    { id = "games",     label = "Games" },
    { id = "tech",      label = "Tech" },
    { id = "tools",     label = "Tools" },
    { id = "music",     label = "Music" },
    { id = "demoscene", label = "Demoscene" },
}
local STORE_SORTS = {
    { id = "top",    label = "Top rated" },
    { id = "new",    label = "New & popular" },
    { id = "recent", label = "Most recent" },
}
local HTTP_UA = "Mozilla/5.0 (KOReader AppDock tic80)"

local function htmlDecode(t)
    t = tostring(t or ""):gsub("<[^>]*>", "")
    t = t:gsub("&#(%d+);", function(n) n = tonumber(n); if n and n < 256 then return string.char(n) end end)
    t = t:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    return (t:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- GET url -> body string, or (nil, error). With file_path the body is streamed to that file instead.
-- Redirects are followed by hand (ssl.https answers "redirect not supported" when asked to follow them).
local function httpGet(url, file_path)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local urlmod = require("socket.url")
    local last_err = "network error"
    for _hop = 1, 6 do
        local parsed = urlmod.parse(url)
        if not parsed or not parsed.scheme then return nil, "bad url" end
        local lib = parsed.scheme == "https" and require("ssl.https") or require("socket.http")
        local chunks, fh = {}, nil
        local sink
        if file_path then
            fh = io.open(file_path, "wb")
            if not fh then return nil, _("Cannot write file.") end
            sink = socketutil.file_sink(fh)
        else
            sink = socketutil.table_sink(chunks)
        end
        socketutil:set_timeout(15, 90)
        local ok, r1, code, headers, status = pcall(function()
            return socket.skip(0, lib.request{
                url = url, method = "GET", sink = sink, redirect = false,
                headers = { ["User-Agent"] = HTTP_UA },
            })
        end)
        socketutil:reset_timeout()
        if fh then pcall(function() fh:close() end) end
        if not ok then
            if file_path then os.remove(file_path) end
            return nil, tostring(r1) .. " (" .. url .. ")"
        end
        -- lib.request returns (1, code, headers, status) with a sink, (nil, err) on failure
        if not r1 then
            if file_path then os.remove(file_path) end
            return nil, tostring(code or last_err) .. " (" .. url .. ")"
        end
        if type(code) == "number" and code >= 300 and code < 400 and headers and (headers.location or headers.Location) then
            url = urlmod.absolute(url, headers.location or headers.Location)
        elseif code == 200 then
            return file_path and true or table.concat(chunks)
        else
            if file_path then os.remove(file_path) end
            return nil, (type(code) == "number") and ("HTTP " .. code) or tostring(code or status or last_err)
        end
    end
    if file_path then os.remove(file_path) end
    return nil, _("Too many redirects.")
end

-- Parses a listing page: items with user, slug, title, hash (cover.gif url) and author.
local function parseStoreList(html)
    local items, seen = {}, {}
    local pos = 1
    local marks = {}
    while true do
        local s1, e1, href_user, href_slug = html:find('href=["\'][^"\']-/dev/([%w_%-%.]+)/([%w_%-%.]+)["\']', pos)
        if not s1 then break end
        marks[#marks + 1] = { s = s1, user = href_user, slug = href_slug }
        pos = e1 + 1
    end
    for i, m in ipairs(marks) do
        local seg = html:sub(m.s, (marks[i + 1] and marks[i + 1].s or #html + 1) - 1)
        local hash = seg:match("/cart/(%x%x%x%x%x%x%x%x+)/")
        local key = m.user .. "/" .. m.slug
        if not seen[key] and (hash or seg:match("<h2")) then
            seen[key] = true
            local title = htmlDecode(seg:match("<h[1-4][^>]*>(.-)</h[1-4]>") or m.slug)
            local author = seg:gsub("<h[1-4][^>]*>.-</h[1-4]>", ""):gsub("<[^>]*>", "\n"):match("\n%s*by%s+([^\n]+)")
            items[#items + 1] = {
                user = m.user, slug = m.slug, hash = hash, title = title ~= "" and title or m.slug,
                author = author and htmlDecode(author) or nil,
            }
        end
    end
    return items, html:find("SHOW MORE", 1, true) ~= nil
end

local function storeUrl(store, page)
    local cat = STORE_CATS[store.cat].id
    local path = "/play/" .. (cat ~= "" and (cat .. "/") or "") .. STORE_SORTS[store.sort].id
    return STORE_BASE .. path .. (page > 0 and ("?page=" .. page) or "")
end

-- Loads the next server page into store.items. Returns true or (nil, error).
local function storeLoadMore(store)
    local page = store.next_page or 0
    local body, err = httpGet(storeUrl(store, page))
    if not body then return nil, err end
    local items, more = parseStoreList(body)
    if #items == 0 and page == 0 then return nil, _("No carts found on tic80.com.") end
    local have = {}
    for _i, it in ipairs(store.items) do have[it.user .. "/" .. it.slug] = true end
    for _i, it in ipairs(items) do
        if not have[it.user .. "/" .. it.slug] then store.items[#store.items + 1] = it end
    end
    store.next_page = page + 1
    store.more = more and #items > 0
    return true
end

local function cartFileName(item)
    return (item.slug:gsub("[^%w_%-]", "_")) .. ".tic"
end

local function cartInstalled(item)
    return fileExists(CARTS_DIR .. "/" .. cartFileName(item))
end

-- Downloads a cart into CARTS_DIR. Returns true or (nil, error).
local function downloadCart(item)
    os.execute("mkdir -p " .. shq(CARTS_DIR))
    local hash = item.hash
    if not hash then -- fall back to the cart page
        local page, err = httpGet(STORE_BASE .. "/dev/" .. item.user .. "/" .. item.slug)
        if not page then return nil, err end
        hash = page:match("/cart/(%x%x%x%x%x%x%x%x+)/[^\"'%s]-%.tic")
        if not hash then return nil, _("Download link not found.") end
        item.hash = hash
    end
    local target = CARTS_DIR .. "/" .. cartFileName(item)
    local tmp = target .. ".part"
    local ok, err = httpGet(STORE_BASE .. "/cart/" .. hash .. "/" .. item.slug .. ".tic", tmp)
    if not ok then os.remove(tmp); return nil, err end
    local f = io.open(tmp, "rb")
    local size = f and f:seek("end") or 0
    if f then f:close() end
    if size < 32 then os.remove(tmp); return nil, _("Downloaded file is empty.") end
    os.remove(target)
    if not os.rename(tmp, target) then os.remove(tmp); return nil, _("Cannot save file.") end
    return true
end

-- -------------------------------------------------------------- controls ----
-- X11 keysyms understood by geodash/gd_shim.cpp (A/B/X/Y = TIC-80 keyboard defaults Z/X/A/S)
local K = {
    Left = 0xFF51, Up = 0xFF52, Right = 0xFF53, Down = 0xFF54,
    Enter = 0xFF0D, Esc = 0xFF1B, Space = 0x20,
}
local function ch(c) return c:byte() end

-- Rows of buttons; every row is split evenly, "weight" makes a row taller.
-- kind: nil = key held while touched, "close" = leaves the game.
local LAYOUT = {
    { weight = 2, { "←", K.Left }, { "↑", K.Up }, { "↓", K.Down }, { "→", K.Right } },
    { weight = 2, { "A", ch("z") }, { "B", ch("x") }, { "X", ch("a") }, { "Y", ch("s") } },
    { { "Esc", K.Esc }, { "Enter", K.Enter }, { "Quit", nil, "close" } },
}
local LAYOUT_UNITS = 0
for _, row in ipairs(LAYOUT) do LAYOUT_UNITS = LAYOUT_UNITS + (row.weight or 1) end

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

function Game:launch(state, context, out_w, out_h)
    self.state, self.context = state, context
    self:cancelStop()
    self:closeConn()
    os.execute("mkdir -p " .. shq(GD_HOME))
    if not Proc.start(state.cart, out_w, out_h) then return false, _("Could not start TIC-80.") end
    self.running = true
    self.cart = state.cart
    self.status = _("Starting TIC-80…")
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
        state.cart = nil
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
        if view and not view.has_rfb then
            -- the pane was laid out before the real picture size was known: lay it out again
            requestRebuild(self.context)
        end
        return
    end
    if os.time() > self.connect_deadline then
        self:fail(_("TIC-80 did not start.") .. "\n" .. logTail())
        return
    end
    UIManager:scheduleIn(0.4, self.connect_cb)
end

function Game:poll()
    if not self.running or not self.rfb then return end
    -- Process exactly one complete frame per UI tick; old frames are dropped instead of queued.
    local ok, res = pcall(self.rfb.poll, self.rfb)
    if not ok then
        logger.warn("TIC-80: " .. tostring(res))
        self:fail(_("TIC-80 exited.") .. "\n" .. tostring(res) .. "\n" .. logTail())
        return
    end
    if res ~= nil then
        -- Request the next update after every complete response, including empty ones.
        pcall(self.rfb.requestUpdate, self.rfb, true)
    end
    if type(res) == "table" then
        local rx0, ry0, rx1, ry1 = self.rfb:toDisplay(res[1], res[2], res[3], res[4])
        local w, h = rx1 - rx0, ry1 - ry0
        local view = self.view
        if w > 0 and h > 0 and view and view.active then
            view:refreshRegion(rx0, ry0, w, h)
        end
    end
    if self.running and self.poll_cb then UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb) end
end

function Game:sendKey(key, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.key, self.rfb, key, down)
    if not ok then
        logger.warn("TIC-80: " .. tostring(err))
        self:fail(_("TIC-80 exited.") .. "\n" .. tostring(err) .. "\n" .. logTail())
    end
end

function Game:pulseKey(key, seconds)
    self:sendKey(key, true)
    UIManager:scheduleIn(seconds or PRESS_DURATION, function() self:sendKey(key, false) end)
end

function Game:pointer(x, y, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.pointer, self.rfb, x, y, down and 1 or 0)
    if not ok then
        logger.warn("TIC-80: " .. tostring(err))
        self:fail(_("TIC-80 exited.") .. "\n" .. tostring(err) .. "\n" .. logTail())
    end
end

-- ------------------------------------------------------------ small widgets ----
local function paintBevel(bb, x, y, w, h, pressed)
    -- only black and white (no grey levels): white face with black frame, inverted when pressed
    local shadow = 2
    local bw, bh = w - shadow, h - shadow
    bb:paintRect(x + shadow, y + shadow, bw, bh, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, bw, bh, Blitbuffer.COLOR_BLACK)
    if not pressed then
        bb:paintRect(x + 2, y + 2, math.max(1, bw - 4), math.max(1, bh - 4), Blitbuffer.COLOR_WHITE)
    end
    return shadow
end

local Fill = InputContainer:extend{ width = nil, height = nil, color = nil, dimen = nil }

function Fill:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function Fill:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, self.color or Blitbuffer.COLOR_WHITE)
end

local GDButton = InputContainer:extend{
    title = "", width = nil, height = nil, callback = nil, primary = false, dimen = nil,
}

function GDButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.range = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { TapGeodashButton = { GestureRange:new{ ges = "tap", range = self.range } } }
end

function GDButton:paintTo(bb, x, y)
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

function GDButton:onTapGeodashButton()
    if self.callback then self.callback() end
    return true
end

-- --------------------------------------------------------------- game view ----
-- Shows the VNC picture. Tapping it sends a left click (jump in-game, menu selection otherwise).
local GameView = InputContainer:extend{ width = nil, height = nil, dimen = nil }

function GameView:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.range = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local screen_range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ptr_slot = {}
    self.tap_suppressed = nil
    self.ges_events = {
        TouchGeodashGame = { GestureRange:new{ ges = "touch", range = self.range } },
        ReleaseGeodashGame = { GestureRange:new{ ges = "release", range = screen_range } },
        TapGeodashGame = { GestureRange:new{ ges = "tap", range = self.range } },
    }
    self.status_face = Font:getFace("cfont", 22)
end

function GameView:pictureX()
    local rfb = Game.rfb
    if not rfb then return 0 end
    return math.max(0, math.floor((self.width - rfb.dw) / 2))
end

function GameView:paintTo(bb, x, y)
    self._ox, self._oy = x, y
    local r = self.range
    r.x, r.y, r.w, r.h = x, y, self.width, self.height
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local rfb = Game.rfb
    if rfb then
        local px0 = self:pictureX()
        bb:blitFrom(rfb.bb, x + px0, y, 0, 0, math.min(self.width - px0, rfb.dw), math.min(self.height, rfb.dh))
        if SHOW_STATS and Stats.text then
            if self._stat_str ~= Stats.text then
                if self._stat_w then self._stat_w:free() end
                self._stat_str = Stats.text
                self._stat_w = TextWidget:new{ text = Stats.text, face = Font:getFace("cfont", 16), bold = true }
            end
            local sz = self._stat_w:getSize()
            local box_w, box_h = sz.w + 8, sz.h + 4
            local w2
            if Stats.native then
                if self._nat_str ~= Stats.native then
                    if self._nat_w then self._nat_w:free() end
                    self._nat_str = Stats.native
                    self._nat_w = TextWidget:new{ text = Stats.native, face = Font:getFace("cfont", 16), bold = true }
                end
                w2 = self._nat_w
                local sz2 = w2:getSize()
                box_w, box_h = math.max(box_w, sz2.w + 8), box_h + sz2.h
            end
            bb:paintRect(x + px0, y, box_w, box_h, Blitbuffer.COLOR_WHITE)
            self._stat_w:paintTo(bb, x + px0 + 4, y + 2)
            if w2 then w2:paintTo(bb, x + px0 + 4, y + 2 + sz.h) end
        end
    else
        local text = TextWidget:new{ text = Game.status or _("Starting TIC-80…"), face = self.status_face, max_width = self.width - 40 }
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
    if x < 0 or y < 0 or x >= rfb.dw or y >= rfb.dh then return nil end
    -- back to game picture coordinates
    local gx = math.floor(x * rfb.w / rfb.dw * PTR_SX / 100)
    local gy = math.floor(y * rfb.h / rfb.dh * PTR_SY / 100)
    return clamp(gx, 0, rfb.w - 1), clamp(gy, 0, rfb.h - 1)
end

function GameView:onTouchGeodashGame(_arg, ges)
    local gx, gy = self:gamePos(ges.pos)
    -- DEBUG toast (remove when touch is fixed)
    pcall(function()
        local Notification = require("ui/widget/notification")
        local r = Game.rfb
        UIManager:show(Notification:new{
            text = string.format("pos %d,%d | ox %d oy %d | dw %d dh %d | w %d h %d | g %s,%s | sx %d sy %d",
                ges.pos.x, ges.pos.y, self._ox or -1, self._oy or -1,
                r and r.dw or -1, r and r.dh or -1, r and r.w or -1, r and r.h or -1,
                tostring(gx), tostring(gy), PTR_SX, PTR_SY),
            timeout = 3,
        })
    end)
    if not gx then return true end
    local slot = ges.slot or 0
    local press = { x = gx, y = gy, released = false, min_elapsed = false }
    self.ptr_slot[slot] = press
    local tap_token = {}
    self.tap_suppressed = tap_token
    UIManager:scheduleIn(0.5, function()
        if self.tap_suppressed == tap_token then self.tap_suppressed = nil end
    end)
    Game:pointer(gx, gy, true)
    press.min_cb = function()
        press.min_elapsed = true
        if press.released and self.ptr_slot[slot] == press then
            self.ptr_slot[slot] = nil
            if press.safety_cb then UIManager:unschedule(press.safety_cb) end
            Game:pointer(press.x, press.y, false)
        end
    end
    press.safety_cb = function()
        if self.ptr_slot[slot] == press then
            self.ptr_slot[slot] = nil
            Game:pointer(press.x, press.y, false)
        end
    end
    UIManager:scheduleIn(PRESS_DURATION, press.min_cb)
    UIManager:scheduleIn(HOLD_SAFETY, press.safety_cb)
    return true
end

function GameView:onReleaseGeodashGame(_arg, ges)
    local slot = ges.slot or 0
    local press = self.ptr_slot[slot]
    if not press then return false end
    local gx, gy = self:gamePos(ges.pos)
    if gx then press.x, press.y = gx, gy end
    press.released = true
    if press.min_elapsed then
        self.ptr_slot[slot] = nil
        if press.safety_cb then UIManager:unschedule(press.safety_cb) end
        Game:pointer(press.x, press.y, false)
    end
    return true
end

-- Fallback for devices/KOReader versions that do not deliver touch/release:
-- a plain tap becomes a short click.
function GameView:onTapGeodashGame(_arg, ges)
    local gx, gy = self:gamePos(ges.pos)
    local slot = ges.slot or 0
    local press = self.ptr_slot[slot]
    if not press then
        for candidate_slot, candidate in pairs(self.ptr_slot) do
            slot, press = candidate_slot, candidate
            break
        end
    end
    if press then
        press.released = true
        if press.min_elapsed and self.ptr_slot[slot] == press then
            self.ptr_slot[slot] = nil
            if press.safety_cb then UIManager:unschedule(press.safety_cb) end
            Game:pointer(press.x, press.y, false)
        end
        self.tap_suppressed = nil
        return true
    end
    if self.tap_suppressed then
        self.tap_suppressed = nil
        return true
    end
    if gx then
        -- The game samples input at 30 FPS; a very short tap can otherwise vanish
        -- between two polls. Start from a known-up state and hold for one frame.
        Game:pointer(gx, gy, false)
        Game:pointer(gx, gy, true)
        UIManager:scheduleIn(PRESS_DURATION, function() Game:pointer(gx, gy, false) end)
    end
    return true
end

-- --------------------------------------------------------------------- pad ----
-- The button grid below the picture (keys follow touch; "Quit" leaves the game).
local Pad = InputContainer:extend{ width = nil, height = nil, dimen = nil }

function Pad:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.range = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local screen_range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.held, self.by_slot, self.tap_suppressed = {}, {}, {}
    self.ges_events = {
        TouchGeodashPad = { GestureRange:new{ ges = "touch", range = self.range } },
        ReleaseGeodashPad = { GestureRange:new{ ges = "release", range = screen_range } },
        TapGeodashPad = { GestureRange:new{ ges = "tap", range = self.range } },
    }
    self:layoutButtons()
end

function Pad:layoutButtons()
    local sw = self.width
    self.buttons = {}
    local margin = scale(6)
    local avail = self.height - margin
    if avail < LAYOUT_UNITS * scale(14) then return end
    local unit = math.min(math.floor(avail / LAYOUT_UNITS), scale(BTN_UNIT))
    local y = margin
    for _, row in ipairs(LAYOUT) do
        local row_h = unit * (row.weight or 1)
        local face = Font:getFace("cfont", clamp(math.floor(row_h / (row.weight or 1) * 0.36 * (row.weight and 1.3 or 1)), 12, 30))
        local cell_w = math.floor((sw - margin * (#row + 1)) / #row)
        for i, def in ipairs(row) do
            self.buttons[#self.buttons + 1] = {
                label = def[1], key = def[2], kind = def[3],
                rect = { x = margin + (i - 1) * (cell_w + margin), y = y, w = cell_w, h = row_h - margin },
                text = TextWidget:new{ text = def[1], face = face, max_width = cell_w - 8, bold = true },
                text_inv = TextWidget:new{ text = def[1], face = face, max_width = cell_w - 8, bold = true, fgcolor = Blitbuffer.COLOR_WHITE },
            }
        end
        y = y + row_h
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
        local tw = pressed and b.text_inv or b.text
        local ts = tw:getSize()
        tw:paintTo(bb, x + br.x + math.floor((br.w - shadow - ts.w) / 2), y + br.y + math.floor((br.h - shadow - ts.h) / 2))
    end
end

-- Redraw one button right away (held / released) without touching the rest of the pane.
function Pad:redrawButton(b)
    if not BUTTON_FEEDBACK or not self._ox then return end
    local br = b.rect
    local region = Geom:new{ x = self._ox + br.x, y = self._oy + br.y, w = br.w, h = br.h }
    if UIManager.widgetRepaint then
        UIManager:widgetRepaint(self, self._ox, self._oy)
        UIManager:setDirty(nil, REFRESH_MODE, region)
    else
        UIManager:setDirty(self.pane or self, REFRESH_MODE, region)
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
    if b.kind == "close" then
        Game:leave(nil, true)
        return
    end
    if self.held[b] then return end
    self.held[b] = true
    Game:sendKey(b.key, true)
    -- safety net in case the "release" event never arrives
    b.timeout_cb = function() b.timeout_cb = nil; self:release(b, true) end
    UIManager:scheduleIn(HOLD_SAFETY, b.timeout_cb)
    self:redrawButton(b)
end

function Pad:release(b, force)
    if not self.held[b] then return end
    self.held[b] = nil
    if b.timeout_cb then UIManager:unschedule(b.timeout_cb); b.timeout_cb = nil end
    Game:sendKey(b.key, false)
    self:redrawButton(b)
end

function Pad:pulse(b, seconds)
    self:press(b)
    if b.kind == "close" then return end
    UIManager:scheduleIn(seconds or PRESS_DURATION, function() self:release(b) end)
end

function Pad:onTouchGeodashPad(_arg, ges)
    local b = self:buttonAt(ges.pos)
    if not b then return true end
    local tap_token = {}
    self.tap_suppressed[b] = tap_token
    UIManager:scheduleIn(0.5, function()
        if self.tap_suppressed[b] == tap_token then self.tap_suppressed[b] = nil end
    end)
    self.by_slot[ges.slot or 0] = b
    self:press(b)
    return true
end

function Pad:onReleaseGeodashPad(_arg, ges)
    local slot = ges.slot or 0
    local b = self.by_slot[slot]
    if not b then
        -- Fallback: slot does not match -> release everything that is held
        local any = false
        for hb in pairs(self.held) do
            self:release(hb)
            any = true
        end
        self.by_slot = {}
        return any
    end
    self.by_slot[slot] = nil
    self:release(b)
    return true
end

-- Fallback for devices/KOReader versions that do not deliver touch/release:
-- a plain tap becomes a short key press.
function Pad:onTapGeodashPad(_arg, ges)
    local b = self:buttonAt(ges.pos)
    if b and self.tap_suppressed[b] then
        self.tap_suppressed[b] = nil
    elseif b then
        self:pulse(b, 0.2)
    end
    return true
end

-- -------------------------------------------------------------------- pane ----
local GeodashPane = InputContainer:extend{ game_view = nil, state = nil }

-- AppDock calls this when the pane is left.
function GeodashPane:onDeactivate()
    if self.game_view then Game:detach(self.game_view) end
end

-- If the host re-shows this pane after the game was stopped, lay it out again (splash).
function GeodashPane:onActivate()
    if self.game_view and not Game.running and self.state and self.state.screen == "game" then
        self.state.screen = "splash"
        requestRebuild(Game.context)
    end
end

function GeodashPane:_stopForSystem(rebuild)
    if self.game_view and Game.view == self.game_view and Game.running then
        Game:leave(nil, rebuild)
    end
    return false -- let other widgets see the event as well
end
function GeodashPane:onSuspend() return self:_stopForSystem(true) end
function GeodashPane:onExit() return self:_stopForSystem(false) end
function GeodashPane:onRestart() return self:_stopForSystem(false) end
function GeodashPane:onPowerOff() return self:_stopForSystem(false) end
function GeodashPane:onReboot() return self:_stopForSystem(false) end

-- Page-turn buttons = button A (only while the game is on).
function GeodashPane:onGeodashA()
    if not (Game.running and Game.rfb) then return false end
    Game:pulseKey(ch("z"))
    return true
end

local function stateFor(instance)
    if instance.tic80 then return instance.tic80 end
    local state = { screen = "splash", error = nil, cart = nil, page = 1,
        store = { cat = 2, sort = 1, items = {}, next_page = 0, more = true, page = 1, loaded = false } }
    instance.tic80 = state
    return state
end

local function newPane(width, height, children, extra)
    local dimen = Geom:new{ w = width, h = height }
    local pane = GeodashPane:new{ dimen = dimen }
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
        text = "tic80", face = Font:getFace("cfont", clamp(math.floor(width / 11), 28, px(54))),
        bold = true, max_width = text_w,
    })
    y = y + px(4)
    add(TextWidget:new{
        text = _("TIC-80 fantasy computer for your Kobo"),
        face = Font:getFace("smallinfofont", clamp(math.floor(width / 38), 12, px(17))), max_width = text_w,
    })
    y = y + px(18)
    add(TextBoxWidget:new{
        text = _("Tap the picture for touch/mouse input. Use the buttons below the picture for arrows, A/B/X/Y, Esc and Enter.\nThe page-turn buttons press A. Leave the app or tap Quit to stop the game."),
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
    local button_gap = px(10)
    local button_y = math.min(y + px(6), height - 2 * button_h - button_gap - px(14) - px(50))
    children[#children + 1] = GDButton:new{
        title = _("Play"), width = button_w, height = button_h, primary = true,
        overlap_offset = { math.floor((width - button_w) / 2), button_y },
        callback = function()
            local ok, err = Proc.available()
            if not ok then
                UIManager:show(InfoMessage:new{ text = err })
                return
            end
            local carts = listCarts()
            if #carts == 0 then
                state.error = nil
                state.screen = "store"
                requestRebuild(context)
                return
            end
            state.error = nil
            if #carts == 1 then
                state.screen, state.cart = "game", CARTS_DIR .. "/" .. carts[1]
            else
                state.screen, state.page = "carts", 1
            end
            requestRebuild(context)
        end,
    }
    children[#children + 1] = GDButton:new{
        title = _("Download carts"), width = button_w, height = button_h,
        overlap_offset = { math.floor((width - button_w) / 2), button_y + button_h + button_gap },
        callback = function()
            state.error = nil
            state.screen = "store"
            requestRebuild(context)
        end,
    }
    children[#children + 1] = TextWidget:new{
        text = _("TIC-80 by Nesbox (MIT) · carts keep their own licences"),
        face = Font:getFace("smallinfofont", clamp(math.floor(width / 52), 10, px(13))),
        fgcolor = Blitbuffer.COLOR_BLACK, max_width = text_w,
        overlap_offset = { margin, height - px(30) },
    }
    return newPane(width, height, children, { state = state })
end

-- --------------------------------------------------------------- cart list ----
local function buildCarts(state, context, width, height)
    local px = context.px or scale
    local carts = listCarts()
    if #carts == 0 then
        state.screen = "splash"
        return buildSplash(state, context, width, height)
    end
    local children = { Fill:new{ width = width, height = height, color = Blitbuffer.COLOR_WHITE } }
    local margin = math.max(px(12), math.floor(width * 0.05))
    local inner_w = width - 2 * margin
    local y = math.max(px(14), math.floor(height * 0.03))
    local title = TextWidget:new{
        text = _("Choose a cart"), face = Font:getFace("cfont", clamp(math.floor(width / 16), 22, px(36))),
        bold = true, max_width = inner_w, overlap_offset = { margin, y },
    }
    children[#children + 1] = title
    y = y + title:getSize().h + px(10)

    local nav_h = clamp(math.floor(height * 0.08), px(40), px(56))
    local row_h = clamp(math.floor(height * 0.09), px(44), px(60))
    local gap = px(8)
    local list_h = height - y - 2 * nav_h - px(16) - 2 * gap
    local per_page = math.max(1, math.floor((list_h + gap) / (row_h + gap)))
    local pages = math.max(1, math.ceil(#carts / per_page))
    state.page = clamp(state.page or 1, 1, pages)
    local first = (state.page - 1) * per_page + 1
    for i = first, math.min(#carts, first + per_page - 1) do
        local name = carts[i]
        children[#children + 1] = GDButton:new{
            title = cartTitle(name), width = inner_w, height = row_h,
            overlap_offset = { margin, y },
            callback = function()
                state.screen, state.cart = "game", CARTS_DIR .. "/" .. name
                requestRebuild(context)
            end,
        }
        y = y + row_h + gap
    end

    local nav_y = height - nav_h - px(10)
    local nav_w = math.floor((inner_w - 2 * gap) / 3)
    children[#children + 1] = GDButton:new{
        title = _("+ Download more carts"), width = inner_w, height = nav_h,
        overlap_offset = { margin, nav_y - nav_h - gap },
        callback = function() state.screen = "store"; requestRebuild(context) end,
    }
    children[#children + 1] = GDButton:new{
        title = "←", width = nav_w, height = nav_h, overlap_offset = { margin, nav_y },
        callback = function()
            if state.page > 1 then state.page = state.page - 1; requestRebuild(context) end
        end,
    }
    children[#children + 1] = GDButton:new{
        title = _("Back"), width = nav_w, height = nav_h, overlap_offset = { margin + nav_w + gap, nav_y },
        callback = function() state.screen = "splash"; requestRebuild(context) end,
    }
    children[#children + 1] = GDButton:new{
        title = "→", width = nav_w, height = nav_h, overlap_offset = { margin + 2 * (nav_w + gap), nav_y },
        callback = function()
            if state.page < pages then state.page = state.page + 1; requestRebuild(context) end
        end,
    }
    return newPane(width, height, children, { state = state })
end

-- -------------------------------------------------------------- cart store ----
local function buildStore(state, context, width, height)
    local store = state.store
    local px = context.px or scale
    local children = { Fill:new{ width = width, height = height, color = Blitbuffer.COLOR_WHITE } }
    local margin = math.max(px(12), math.floor(width * 0.05))
    local inner_w = width - 2 * margin
    local gap = px(8)
    local y = math.max(px(14), math.floor(height * 0.03))
    local title = TextWidget:new{
        text = _("tic80.com carts"), face = Font:getFace("cfont", clamp(math.floor(width / 16), 22, px(36))),
        bold = true, max_width = inner_w, overlap_offset = { margin, y },
    }
    children[#children + 1] = title
    y = y + title:getSize().h + px(8)

    local nav_h = clamp(math.floor(height * 0.08), px(40), px(56))
    local row_h = clamp(math.floor(height * 0.09), px(44), px(60))

    local function reload()
        store.items, store.next_page, store.more, store.page, store.loaded, store.error = {}, 0, true, 1, false, nil
        requestRebuild(context)
    end
    local half = math.floor((inner_w - gap) / 2)
    children[#children + 1] = GDButton:new{
        title = STORE_CATS[store.cat].label, width = half, height = nav_h, overlap_offset = { margin, y },
        callback = function() store.cat = store.cat % #STORE_CATS + 1; reload() end,
    }
    children[#children + 1] = GDButton:new{
        title = STORE_SORTS[store.sort].label, width = half, height = nav_h,
        overlap_offset = { margin + half + gap, y },
        callback = function() store.sort = store.sort % #STORE_SORTS + 1; reload() end,
    }
    y = y + nav_h + gap

    -- first page is fetched on the first build of the screen (shows a short message while loading)
    if not store.loaded and not store.loading then
        store.loading = true
        UIManager:show(InfoMessage:new{ text = _("Loading carts…"), timeout = 1 })
        UIManager:scheduleIn(0.3, function()
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function()
                local ok, err = storeLoadMore(store)
                store.loading = false
                store.loaded = true
                store.error = (not ok) and err or nil
                requestRebuild(context)
            end)
        end)
        local wait = TextWidget:new{
            text = _("Loading…"), face = Font:getFace("smallinfofont", clamp(math.floor(width / 30), 14, px(20))),
            max_width = inner_w, overlap_offset = { margin, y + px(10) },
        }
        children[#children + 1] = wait
    elseif store.error and #store.items == 0 then
        children[#children + 1] = TextBoxWidget:new{
            text = _("Could not load tic80.com:") .. "\n" .. tostring(store.error),
            face = Font:getFace("smallinfofont", clamp(math.floor(width / 36), 12, px(16))),
            width = inner_w, overlap_offset = { margin, y + px(10) },
        }
    end

    local nav_y = height - nav_h - px(10)
    local list_h = nav_y - y - gap
    local per_page = math.max(1, math.floor((list_h + gap) / (row_h + gap)))
    local pages = math.max(1, math.ceil(#store.items / per_page))
    store.page = clamp(store.page or 1, 1, pages)
    local first = (store.page - 1) * per_page + 1
    for i = first, math.min(#store.items, first + per_page - 1) do
        local item = store.items[i]
        local installed = cartInstalled(item)
        local label = (installed and "✓ " or "") .. item.title .. (item.author and ("  ·  " .. item.author) or "")
        children[#children + 1] = GDButton:new{
            title = label, width = inner_w, height = row_h, overlap_offset = { margin, y },
            callback = function()
                if cartInstalled(item) then
                    UIManager:show(InfoMessage:new{ text = _("Already installed:") .. " " .. item.title })
                    return
                end
                UIManager:show(InfoMessage:new{ text = _("Downloading…") .. "\n" .. item.title, timeout = 1 })
                UIManager:scheduleIn(0.3, function()
                    local NetworkMgr = require("ui/network/manager")
                    NetworkMgr:runWhenOnline(function()
                        local ok, err = downloadCart(item)
                        if ok then
                            UIManager:show(InfoMessage:new{ text = _("Downloaded:") .. " " .. item.title, timeout = 2 })
                        else
                            UIManager:show(InfoMessage:new{ text = _("Download failed:") .. "\n" .. tostring(err) })
                        end
                        requestRebuild(context)
                    end)
                end)
            end,
        }
        y = y + row_h + gap
    end

    local nav_w = math.floor((inner_w - 2 * gap) / 3)
    children[#children + 1] = GDButton:new{
        title = "←", width = nav_w, height = nav_h, overlap_offset = { margin, nav_y },
        callback = function()
            if store.page > 1 then store.page = store.page - 1; requestRebuild(context) end
        end,
    }
    children[#children + 1] = GDButton:new{
        title = _("Back"), width = nav_w, height = nav_h, overlap_offset = { margin + nav_w + gap, nav_y },
        callback = function()
            state.screen = #listCarts() > 1 and "carts" or "splash"
            state.page = 1
            requestRebuild(context)
        end,
    }
    children[#children + 1] = GDButton:new{
        title = "→", width = nav_w, height = nav_h, overlap_offset = { margin + 2 * (nav_w + gap), nav_y },
        callback = function()
            if store.page < pages then
                store.page = store.page + 1
                requestRebuild(context)
            elseif store.more and not store.loading then
                UIManager:show(InfoMessage:new{ text = _("Loading more carts…"), timeout = 1 })
                UIManager:scheduleIn(0.3, function()
                    local NetworkMgr = require("ui/network/manager")
                    NetworkMgr:runWhenOnline(function()
                        local before = #store.items
                        local ok, err = storeLoadMore(store)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = tostring(err) })
                        elseif #store.items > before then
                            store.page = store.page + 1
                        end
                        requestRebuild(context)
                    end)
                end)
            end
        end,
    }
    return newPane(width, height, children, { state = state })
end

-- -------------------------------------------------------------------- game ----
local function buildGame(state, context, width, height)
    Game.context = context
    if not state.cart then
        state.screen = "splash"
        return buildSplash(state, context, width, height)
    end

    -- Reserve a button pad below the picture (arrows, A/B/X/Y, Esc/Enter/Quit).
    local pad_h = math.min(scale(LAYOUT_UNITS * BTN_UNIT + 12), math.max(scale(110), math.floor(height * 0.34)))
    local game_avail = math.max(scale(40), height - pad_h)
    if Game.running and Game.cart ~= state.cart then
        Game:shutdown() -- a different cart was chosen: never keep showing the old one
    end
    if Game.running then
        Game.state = state -- a rebuild must never restart (and kill) the running game
    else
        local ok, err = Game:launch(state, context, width, game_avail)
        if not ok then
            state.screen, state.error = "splash", err
            return buildSplash(state, context, width, height)
        end
    end

    local pic_w, pic_h
    if Game.rfb then
        local rfb = Game.rfb
        pic_w, pic_h = fitPicture(rfb.w, rfb.h, width, game_avail)
        if rfb:setDisplay(pic_w, pic_h) then
            pcall(rfb.requestUpdate, rfb, false) -- buffer was reset: ask for a full frame
        end
    else
        local sw, sh = expectedPicture(width, game_avail)
        pic_w, pic_h = fitPicture(sw, sh, width, game_avail)
    end
    local game_h = math.min(pic_h, game_avail)

    local view = GameView:new{ width = width, height = game_h }
    view.has_rfb = Game.rfb ~= nil
    Game:attach(view)
    view.overlap_offset = { 0, 0 }

    local children = {
        Fill:new{ width = width, height = height, color = Blitbuffer.COLOR_WHITE },
        view,
    }
    local pad = Pad:new{ width = width, height = pad_h }
    pad.overlap_offset = { 0, height - pad_h }
    children[#children + 1] = pad
    local pane = newPane(width, height, children, { state = state, game_view = view })
    view.pane = pane
    if Device:hasKeys() then
        pane.key_events = {
            GeodashA = { { "RPgFwd" }, { "LPgFwd" }, { "RPgBack" }, { "LPgBack" }, event = "GeodashA" },
        }
    end
    return pane
end

-- ------------------------------------------------------------ public API ----
return {
    id = "tic80",
    version = "1.1.0",
    title = "tic80",
    subtitle = "Fantasy computer",
    symbol = "T8",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        if state.screen == "game" then return buildGame(state, context, width, height) end
        if state.screen == "carts" then return buildCarts(state, context, width, height) end
        if state.screen == "store" then return buildStore(state, context, width, height) end
        return buildSplash(state, context, width, height)
    end,
    _test = {
        RFB = RFB,
        Proc = Proc,
        Game = Game,
        GameView = GameView,
        Pad = Pad,
        LAYOUT = LAYOUT,
        LAYOUT_UNITS = LAYOUT_UNITS,
        K = K,
        POLL_INTERVAL = POLL_INTERVAL,
        FRAME_MS = FRAME_MS,
        MAX_SCALE = MAX_SCALE,
        PIC_OUT_W = PIC_OUT_W,
        REFRESH_MODE = REFRESH_MODE,
        shq = shq,
        listCarts = listCarts,
        expectedPicture = expectedPicture,
        buildSplash = buildSplash,
        buildCarts = buildCarts,
        buildStore = buildStore,
        parseStoreList = parseStoreList,
        buildGame = buildGame,
    },
}
