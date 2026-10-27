--[[--
Geometry Rush for AppDock (DApp).

Geometry Rush is a Geometry-Dash-like rhythm platformer (GeometryRush by volinskii1405-ui, C++17 +
raylib). The game itself runs as a native background process (/mnt/onboard/.adds/geodash/bin/geodash,
raylib software renderer) that publishes its picture through a loopback-only VNC server
(127.0.0.1:5963). This DApp starts that process, shows the picture inside an AppDock pane and sends
touch input back as key/mouse events.

Like the other DApps it exports { id, version, title, subtitle, symbol, buildPane } and draws into
the pane it is given. Game frames only repaint the game view (UIManager:widgetRepaint + a refresh of
the changed rectangle), never the whole AppDock pane.

Files expected on the device (installed by geodash.zip from AppDock Store > Games):
  /mnt/onboard/.adds/geodash/bin/geodash
  /mnt/onboard/.adds/geodash/home/levels/*.txt

Screens: splash (Play) -> game (full-size picture, no buttons: tapping the picture controls the game).
The game process only lives while the game pane is on screen: leaving the DApp, suspending the
device shuts it down and the pane returns to the splash screen.

Controls: tapping the picture sends a frame-safe click (jump in-game, selection in menus).
Page-turn buttons = jump.
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
local GD_DIR = os.getenv("GD_DIR") or "/mnt/onboard/.adds/geodash"
local GD_LOG = GD_DIR .. "/geodash.log"
local GD_HOME = GD_DIR .. "/home"            -- working dir: levels/, mylevels/, settings.txt
local VNC_HOST, VNC_PORT = "127.0.0.1", 5963 -- must match scripts/03-geodash.sh
-- Keep the native game and the VNC polling loop capped at 15 FPS.
local GAME_FPS = 15
local POLL_INTERVAL = 1 / GAME_FPS
local CONNECT_TIMEOUT = 20
local READ_TIMEOUT = 15      -- seconds a half-received message may take before the connection counts as dead
local HOLD_SAFETY = 2.5        -- seconds after which a held key is released even without a "release" event
local JUMP_PRESS_DURATION = 0.16 -- survive at least one 30-FPS game frame on quick e-ink taps
local BUTTON_FEEDBACK = true   -- redraw a control button while it is held
-- KOReader refresh mode for game frames: "fast" (A2, ghosty,
-- bad colours on Kaleido screens but the quickest).
local REFRESH_MODE = os.getenv("GD_REFRESH") or "fast"
-- The game picture is dithered before it is drawn: to the eight primaries
-- (000000 ffffff ff0000 00ff00 0000ff ff00ff ffff00 00ffff), or with GD_BW=1 to pure black/white.
-- Dithering is on in every refresh mode; GD_DITHER=0 switches it off (debugging only).
local DITHER = os.getenv("GD_DITHER") ~= "0"
-- Default: the eight primary colours. GD_BW=1 switches to pure black/white dithering.
local BW = os.getenv("GD_BW") == "1"
-- The real picture size is only known after the VNC handshake. Until then (and for the first
-- layout) a 16:9 picture is assumed; the pane is laid out again once the game is connected.
local PIC_GUESS_ASPECT = tonumber(os.getenv("GD_ASPECT")) or (16 / 9)
-- Render fewer source pixels on the software-rendered reader, then enlarge the
-- framebuffer with nearest-neighbour scaling to fill the pane. This keeps the
-- visible picture large while cutting VNC capture, dithering and copy work.
local MAX_SCALE = tonumber(os.getenv("GD_SCALE")) or 8
local SAT = tonumber(os.getenv("GD_SAT")) or 1.6          -- saturation boost before dithering (e-ink colours are pale)
local DITHER_AMP = tonumber(os.getenv("GD_DITHER_AMP")) or (BW and 4 or 2) -- dither strength (4 = full range, lower = purer colours)
-- Speed: the game shrinks its picture (integer factor) until it is at most PIC_OUT_W wide; fewer
-- pixels = faster dithering, transfer and e-ink refresh. FRAME_MS is the minimum time between two
-- frames the game publishes; it is derived from the fixed 15-FPS cap above.
-- Keep a larger source frame than the old 640 px default. On smaller readers
-- the frame is still fitted to the pane, while wider screens get a sharper
-- picture instead of an upscaled low-resolution stream.
local PIC_OUT_W = tonumber(os.getenv("GD_PIC_W")) or 720
local FRAME_MS = math.floor(1000 / GAME_FPS + 0.5)
-- Development FPS/read-out is intentionally disabled in the game view.
-- Do not draw the development statistics banner in the game view.
local SHOW_STATS = false
local BTN_UNIT = 30 -- compact controls leave more vertical room for the picture

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

-- Guess of the picture size before the VNC handshake: full width, assumed aspect ratio.
-- The real size comes from the VNC handshake.
local function expectedPicture(avail_w, avail_h)
    local w = math.max(2, avail_w)
    local h = math.max(2, math.floor(w / PIC_GUESS_ASPECT + 0.5))
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
    local p = GD_DIR .. "/bin/geodash"
    if fileExists(p) then return p end
end

function Proc.available()
    if not binaryPath() then
        return false, _("Geometry Rush is not installed. Install it from AppDock Store > Games.")
    end
    return true
end

-- SIGTERM first so the game can quit cleanly, SIGKILL only if it lingers (~2 s).
function Proc.stop()
    local pid = Proc.pid
    Proc.pid = nil
    os.execute("pkill -x geodash >/dev/null 2>&1")
    if pid then
        os.execute(string.format(
            "i=0; while [ -d /proc/%d ] && [ $i -lt 10 ]; do sleep 0.2; i=$((i+1)); done", pid))
    end
    os.execute("pkill -9 -x geodash >/dev/null 2>&1")
end

function Proc.start(out_w)
    Proc.stop()
    local exe = binaryPath()
    if not exe then return false end
    -- The VNC server binds to 127.0.0.1; some e-readers leave "lo" down, so bring it up.
    os.execute("ifconfig lo 127.0.0.1 netmask 255.0.0.0 up >/dev/null 2>&1 || ip link set lo up >/dev/null 2>&1")
    os.execute("mkdir -p " .. shq(GD_HOME))
    -- GD_OUT_W: the game picture is shrunk (integer factor) until it is at most this wide.
    local cmd = string.format(
        "(trap '' PIPE; cd %s && GD_OUT_W=%d GD_FRAME_MS=%d GD_FPS=%s GD_RSCALE=%s LD_LIBRARY_PATH=%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} %s; echo \"[geodash exit code $?]\") >%s 2>&1 & echo $!",
        shq(GD_HOME), math.min(out_w, PIC_OUT_W), FRAME_MS, GAME_FPS,
        shq(os.getenv("GD_RSCALE") or "auto"), shq(GD_DIR .. "/lib"), shq(exe), shq(GD_LOG))
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
    local f = io.open(GD_LOG, "rb")
    if not f then return "" end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - 700))
    local data = f:read("*a") or ""
    f:close()
    if size > 700 then data = data:gsub("^[^\n]*\n", "", 1) end
    return data
end

-- -------------------------------------------------------------- controls ----
-- X11 keysyms understood by geodash/gd_shim.cpp
local K = {
    Left = 0xFF51, Up = 0xFF52, Right = 0xFF53, Down = 0xFF54,
    Enter = 0xFF0D, Esc = 0xFF1B, Space = 0x20,
}
local function ch(c) return c:byte() end

-- Rows of buttons; every row is split evenly, "weight" makes a row taller.
-- All buttons are "hold = key held".
local LAYOUT = {
    { weight = 2, { "JUMP", K.Space } },
    { { "Esc", K.Esc }, { "Enter", K.Enter }, { "↑", K.Up }, { "↓", K.Down },
        { "Restart", ch("r") }, { "Pause", ch("p") } },
}
local LAYOUT_UNITS = 0
for _, row in ipairs(LAYOUT) do LAYOUT_UNITS = LAYOUT_UNITS + (row.weight or 1) end

-- ------------------------------------------------------------ game state ----
-- One game at a time: the process, the VNC connection and the timers live here, not in
-- the panes, because AppDock may rebuild the pane (buildPane) while the game is running.
local Stats = { frames = 0, rx = 0, draw = 0, lat = 0, gap = 0, since = nil, text = nil, cpu_ticks = nil }
-- lat = time from our update request until the frame was noticed (slow game -> high);
-- gap = longest pause between two UI ticks (e-ink refresh blocking the UI -> high);
-- cpu = CPU use of the game process (about 100 -> render-bound, low -> it is waiting on a timer).
local function gameCpuTicks()
    -- Proc.pid is the wrapper shell; the game itself is its child, so look it up by name once.
    if not Stats.gpid then
        local p = io.popen("pidof geodash 2>/dev/null")
        local out = p and p:read("*l")
        if p then p:close() end
        Stats.gpid = out and tonumber(out:match("%d+"))
    end
    if not Stats.gpid then return nil end
    local f = io.open("/proc/" .. Stats.gpid .. "/stat", "rb")
    if not f then Stats.gpid = nil; return nil end
    local data = f:read("*a") or ""
    f:close()
    local rest = data:match("%) (.*)$")
    if not rest then return nil end
    local i, ut, st = 0, nil, nil
    for field in rest:gmatch("%S+") do
        i = i + 1
        if i == 12 then ut = tonumber(field) elseif i == 13 then st = tonumber(field); break end
    end
    if ut and st then return ut + st end
end
-- Last "gd-stat:" line the native game process wrote to its log (game/end/push times in ms).
local function nativeStat()
    local f = io.open(GD_LOG, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - 600))
    local data = f:read("*a") or ""
    f:close()
    local last
    for line in data:gmatch("gd%-stat: ([^\n]+)") do last = line end
    return last
end
function Stats:record(rx, draw, lat)
    local now = gettime()
    self.since = self.since or now
    self.frames, self.rx, self.draw, self.lat = self.frames + 1, self.rx + rx, self.draw + draw, self.lat + lat
    local dt = now - self.since
    if dt >= 1 then
        local n = self.frames
        local cpu = ""
        local ticks = gameCpuTicks()
        if ticks and self.cpu_ticks then cpu = string.format(" | cpu %d%%", (ticks - self.cpu_ticks) / dt) end
        self.cpu_ticks = ticks
        self.native = nativeStat()
        self.text = string.format("%.1f fps | rx %d | draw %d | lat %d | gap %d ms%s",
            n / dt, self.rx / n * 1000, self.draw / n * 1000, self.lat / n * 1000, self.gap * 1000, cpu)
        logger.info("Geometry Rush: " .. self.text)
        self.frames, self.rx, self.draw, self.lat, self.gap, self.since = 0, 0, 0, 0, 0, now
    end
end
function Stats:tick(g) if g > self.gap then self.gap = g end end
function Stats:reset()
    self.frames, self.rx, self.draw, self.lat, self.gap, self.since, self.text, self.cpu_ticks, self.gpid = 0, 0, 0, 0, 0, nil, nil, nil, nil
end

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
    Stats:reset()
    self.last_poll, self.req_t = nil, nil
    self.state, self.context = state, context
    self:cancelStop()
    self:closeConn()
    os.execute("mkdir -p " .. shq(GD_HOME))
    if not Proc.start(out_w) then return false, _("Could not start Geometry Rush.") end
    self.running = true
    self.status = _("Starting Geometry Rush…")
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
        if view and not view.has_rfb then
            -- the pane was laid out before the real picture size was known: lay it out again
            requestRebuild(self.context)
        end
        return
    end
    if os.time() > self.connect_deadline then
        self:fail(_("Geometry Rush did not start.") .. "\n" .. logTail())
        return
    end
    UIManager:scheduleIn(0.4, self.connect_cb)
end

function Game:poll()
    if not self.running or not self.rfb then return end
    -- Process exactly one complete frame per UI tick. Draining six queued frames
    -- made dithering and widgetRepaint run back-to-back, creating a CPU backlog
    -- on the reader. The fast image path stays responsive by dropping old frames.
    local t0 = gettime()
    if self.last_poll then Stats:tick(t0 - self.last_poll) end
    self.last_poll = t0
    local ok, res = pcall(self.rfb.poll, self.rfb)
    local t1 = gettime()
    local req_t = self.req_t
    if not ok then
        logger.warn("Geometry Rush: " .. tostring(res))
        self:fail(_("Geometry Rush exited.") .. "\n" .. tostring(res) .. "\n" .. logTail())
        return
    end
    if res ~= nil then
        -- Request the next update after every complete response, including empty ones.
        pcall(self.rfb.requestUpdate, self.rfb, true)
        self.req_t = gettime()
    end
    if type(res) == "table" then
        local rx0, ry0, rx1, ry1 = self.rfb:toDisplay(res[1], res[2], res[3], res[4])
        local w, h = rx1 - rx0, ry1 - ry0
        local view = self.view
        if w > 0 and h > 0 and view and view.active then
            view:refreshRegion(rx0, ry0, w, h)
        end
        Stats:record(t1 - t0, gettime() - t1, math.max(0, t0 - (req_t or t0)))
    end
    if self.running and self.poll_cb then UIManager:scheduleIn(POLL_INTERVAL, self.poll_cb) end
end

function Game:sendKey(key, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.key, self.rfb, key, down)
    if not ok then
        logger.warn("Geometry Rush: " .. tostring(err))
        self:fail(_("Geometry Rush exited.") .. "\n" .. tostring(err) .. "\n" .. logTail())
    end
end

function Game:pulseKey(key, seconds)
    self:sendKey(key, true)
    UIManager:scheduleIn(seconds or JUMP_PRESS_DURATION, function() self:sendKey(key, false) end)
end

function Game:pointer(x, y, down)
    if not self.rfb then return end
    local ok, err = pcall(self.rfb.pointer, self.rfb, x, y, down and 1 or 0)
    if not ok then
        logger.warn("Geometry Rush: " .. tostring(err))
        self:fail(_("Geometry Rush exited.") .. "\n" .. tostring(err) .. "\n" .. logTail())
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
        local text = TextWidget:new{ text = Game.status or _("Starting Geometry Rush…"), face = self.status_face, max_width = self.width - 40 }
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
    return math.min(rfb.w - 1, math.floor(x * rfb.w / rfb.dw)), math.min(rfb.h - 1, math.floor(y * rfb.h / rfb.dh))
end

function GameView:onTouchGeodashGame(_arg, ges)
    local gx, gy = self:gamePos(ges.pos)
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
    UIManager:scheduleIn(JUMP_PRESS_DURATION, press.min_cb)
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
        UIManager:scheduleIn(JUMP_PRESS_DURATION, function() Game:pointer(gx, gy, false) end)
    end
    return true
end

-- --------------------------------------------------------------------- pad ----
-- The button grid below the picture (jump uses a short frame-safe pulse; other keys follow touch).
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
                label = def[1], key = def[2],
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
    if self.held[b] then return end
    self.held[b] = true
    Game:sendKey(b.key, true)
    -- safety net in case the "release" event never arrives
    local is_jump = b.key == K.Space
    b.timeout_cb = function() b.timeout_cb = nil; self:release(b, true) end
    UIManager:scheduleIn(is_jump and JUMP_PRESS_DURATION or HOLD_SAFETY, b.timeout_cb)
    self:redrawButton(b)
end

function Pad:release(b, force)
    if not self.held[b] then return end
    -- A quick jump tap must survive at least one game input frame.
    if b.key == K.Space and not force then return end
    self.held[b] = nil
    if b.timeout_cb then UIManager:unschedule(b.timeout_cb); b.timeout_cb = nil end
    Game:sendKey(b.key, false)
    self:redrawButton(b)
end

function Pad:pulse(b, seconds)
    self:press(b)
    if b.key == K.Space then return end -- press() schedules a frame-safe jump release
    UIManager:scheduleIn(seconds or 0.2, function() self:release(b) end)
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
        self:pulse(b, b.key == K.Space and JUMP_PRESS_DURATION or 0.2)
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
    if self.game_view and not Game.running and self.state and self.state.screen ~= "game" then
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

-- Page-turn buttons = jump (only while the game is on).
function GeodashPane:onGeodashJump()
    if not (Game.running and Game.rfb) then return false end
    Game:pulseKey(K.Space)
    return true
end

local function stateFor(instance)
    if instance.geodash then return instance.geodash end
    local state = { screen = "splash", error = nil }
    instance.geodash = state
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
        text = "Geometry Rush", face = Font:getFace("cfont", clamp(math.floor(width / 11), 28, px(54))),
        bold = true, max_width = text_w,
    })
    y = y + px(4)
    add(TextWidget:new{
        text = _("Rhythm platformer for your Kobo · 6 levels"),
        face = Font:getFace("smallinfofont", clamp(math.floor(width / 38), 12, px(17))), max_width = text_w,
    })
    y = y + px(18)
    add(TextBoxWidget:new{
        text = _("Tap the picture to jump over spikes and obstacles and to choose menu entries.\nThe page-turn buttons jump as well. Leave the app to stop the game."),
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
    local button_y = math.min(y + px(6), height - button_h - px(14) - px(50))
    children[#children + 1] = GDButton:new{
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
        text = _("GeometryRush by volinskii1405-ui · private use only"),
        face = Font:getFace("smallinfofont", clamp(math.floor(width / 52), 10, px(13))),
        fgcolor = Blitbuffer.COLOR_BLACK, max_width = text_w,
        overlap_offset = { margin, height - px(30) },
    }
    return newPane(width, height, children, { state = state })
end

-- -------------------------------------------------------------------- game ----
local function buildGame(state, context, width, height)
    Game.context = context

    -- Reserve a compact control pad below the picture. It includes the ESC button
    -- (and the existing jump/navigation controls) so the game can be exited without
    -- relying on a physical keyboard.
    local pad_h = math.min(scale(100), math.max(scale(72), math.floor(height * 0.30)))
    local game_avail = math.max(scale(40), height - pad_h)
    if Game.running then
        Game.state = state -- a rebuild must never restart (and kill) the running game
    else
        local ok, err = Game:launch(state, context, width)
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
    view.overlap_offset = { 0, math.floor((height - game_h) / 2) }

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
            GeodashJump = { { "RPgFwd" }, { "LPgFwd" }, { "RPgBack" }, { "LPgBack" }, event = "GeodashJump" },
        }
    end
    return pane
end

-- ------------------------------------------------------------ public API ----
return {
    id = "geodash",
    version = "2.0.0",
    title = "Geometry Rush",
    subtitle = "Rhythm platformer",
    symbol = "Gd",
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
        LAYOUT_UNITS = LAYOUT_UNITS,
        K = K,
        POLL_INTERVAL = POLL_INTERVAL,
        FRAME_MS = FRAME_MS,
        MAX_SCALE = MAX_SCALE,
        PIC_OUT_W = PIC_OUT_W,
        REFRESH_MODE = REFRESH_MODE,
        JUMP_PRESS_DURATION = JUMP_PRESS_DURATION,
        shq = shq,
        expectedPicture = expectedPicture,
        buildSplash = buildSplash,
        buildGame = buildGame,
    },
}
