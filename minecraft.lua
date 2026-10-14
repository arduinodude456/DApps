--[[--
Minecraft 3D for AppDock.

A compact, offline voxel sandbox for E-Ink and color displays. The world is a
deterministic block landscape with biomes, trees, villages and ore veins. Its
renderer uses a voxel-space DDA raycaster so movement only redraws the game
canvas, never the full AppDock pane. Every interactive redraw goes through
UIManager:setDirty(..., "waveform", region).

Version 4.7.0 adds readable lighting, calmer textures, partial mob refreshes and a compact touch HUD. Version 4.7.1 adds a strict black/white E-Ink camera preview with the same ray count. Version 4.6.3 routes taps arriving at the world surface to the open inventory and blocks actions through covered controls. Version 4.6.2 registers the modal inventory tap range during pane initialization. Version 4.6.1 adds item labels and a full-name detail line. Version 4.6.0 adds Survival and Creative modes, world-list pagination and larger world-creation controls. Version 4.5.0 adds a time-of-day cycle, voxel mobs, torch lighting and a Bedrock-inspired UI refresh.
  * a real 36-slot inventory (9 hotbar + 27 storage) with stack limits,
    a Bedrock-style cursor stack, automatic refilling and block drops,
  * a crafting screen with Minecraft-like recipes and ingredient checks,
  * Bedrock-style block interaction: tapping touches the hit face, holding does
    the opposite action, and the targeted block shows a face outline,
  * a fuller Minecraft landscape: twelve biomes, biome-specific trees, desert
    cacti, villages with houses, a well, gravel paths and farm fields, boulders,
    rivers, beaches, oceans, snow caps and ore veins,
  * many more blocks, including cobblestone, planks, glass, bricks, clay,
    sandstone, ice, obsidian, bedrock, lava, farmland and five ore types.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local ok_datastorage, DataStorage = pcall(require, "datastorage")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ok_image_widget, ImageWidget = pcall(require, "ui/widget/imagewidget")

local source_path = debug.getinfo(1, "S").source or ""
local APP_DIR = source_path:sub(1, 1) == "@" and source_path:sub(2):match("(.+)/[^/]+$") or "."
local MINECRAFT_LOGO = APP_DIR .. "/assets/minecraft_logo.png"
local MINECRAFT_LOGO_EINK = APP_DIR .. "/assets/minecraft_logo_eink.png"

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

-- The AppStore installs one Lua file per DApp. Keep the small E-Ink logo
-- embedded as a fallback so the Splashscreen works even when repository
-- sidecar assets are not downloaded by an older AppStore implementation.
local EMBEDDED_MINECRAFT_LOGO_B64 = [[
iVBORw0KGgoAAAANSUhEUgAABQAAAADcCAYAAAAvIAwEAAAP3klEQVR42u3dW3bbOBIAUARHiwh3of2vQrvgMtwfmUwcx7ZI
CiCBqnv/ZrrnjATiUVUq0D/e3t7eSgDLshT+tq6r5wrWvjUGAACQMN97rxo6AAAAAIhLATCw2Tt7dCaBtQMAAMDr+V7N/OUB
AAAAIDodgMEpjgIAAADkpgAIAAAAAJM40uxVM35pE8NnBuveOgMAAMhCByAAAAAABKYAmIROHwAAAIAY9tZ5aqYvC+BAAAAA
IBsdgInMUgxQtAAAAABo52YIAAAAAOZyv98NQjCPx2PXv78sS1nXddO/e7M44k+Io5PDc53r2Zrn5ob1Zn5hbmBuYG5gbiC2
Z173+73b/Jj2CrBrojgEBAjmxvG98sgean4BAMyXIzAecTVXqBZYPiMXTxV2AQDIlmco8pgbAEdtraP4IyA4VAEAAAACm7IA
mLlLrNWvgzrtiD7PFYcBAAB5E7PplctWgwcQm4K/QAmw/wAwFnUKzuYKcGKjFQV0djpAAACA9rkCENuWekqN+KVs/DkoeAEA
AADR9Kh36ABMztVAGNso7/1UcDceAICYgbj5AvGFLwDacMEBxt8U/gEA4HrqFZyZ59VIX4Z5x9XVbhykADhbAAD6xB6uAE9C
kUgQbjwAAMT7AHBE6AKgosh2uivBOgcA5B2MSYEY84NXcz4dgAAAANCJAjHmByPMj2kKgN4RF3eMPVuMh/EwpgAAAP2E7QBU
RY/LszUeAAAAwL++arK6GRo+TpR1XV+eWHAVBdH2a9aYAgDA2B6Ph7g9cI7b4ibTFB2AikwAAABk5lUmcSnccYZq8djkP9pa
cFWYBQRoAAAAY/msXuOvALN5ski82/ILHoB9GYAc/IAIXG34AqAuM8gRSEi8AQAA5FT0yf2rQbF4v6L4ivXv8AYAnP8AzM8V
YA5RHAQAgD9c8QTsIYzkY92mzvRhyf0MdHeBdWfdAQCZiWdAbnaUDkAAgEECMwCAVygS85VQBUCdKn3oxDTfHVIAACB+B+by
vp5TZ/iQeDYAAAAQmSIxPefIzfCxxbIsZV1XGyEOSwDg/17t4nd+A4y3N8vRxh7Xo8IUAKNNrBbfx6K3aZB3DzDP7GfmCeYI
s8wxsWLstT56XmP+OWuwx0f3u6HLHwGxie6aNIzBJgoAAHI9gK2GLAAqNI1r77NRqEIAMy/r19oDwP4MwNz50e/XuVUPAQAA
zqG4A7nJXXHucab3f8vBFWALDM9GIIW1BwBiErBuILDhCoCu/wIAAADAce+7/0oJ0AHo1wLPxrgCAMCYRu/Cn/WWgNsNIB/f
yxVgAIE2ADi3JLQ+H2CfD+Jj918pgxUAXf+1sDBfAQAAgGM+K/6VMnkHoF+CmIliF8zNmQMAiCmMCcw6X10BxoLAXMO4AgAA
TO6r7r9SBioAuv4LzynKAADE5+YIYF+jNR2AFhQAAIA8yucGNhqxOee77r9SJi4A6oTC4WxMwFwDAACye1b8K2WQAqDrv7Eo
zsJ1FLsAEPcZk4jxiXG1doDXuALsUMWBaEwAAMRVBsF4Q1fqFn1s6f4rpZSbzRIABF8A4OwB2O5+v0+1t+kABOCfgwxAsg5g
rwbGtrX7r5QBCoDe/xeLwoFD2ZgAAAAgF+xrT/GvlAmvACswWUAAzh4AGP+865mnOJvjzkH5LeZsH64AQ8JgDACAsSmCxB8f
MT5w1N7uv1IuLgC6/gsImATCAOAME68B0NdUHYAOkLGDJc9HMAsAAADy5H6OdP+V4gowYLPHfAMAEO8Ah5zZDHW0+FfKhQVA
138Bch9eAOA8BawfOIcOQHAAAgAAAAN7pfuvlFJus3xRRZB/ef8fWZlvAAByki3/36PHjff73RVe0u4dkfK6GdbyJR2Arv8i
GALzDQAAgOde7f4rxRVggBB0RQLMI9qPNs4grDff074C/bQo/pUyyRVgi9+4eMYCE+wJxtV3Gn1/Mq7YK+0JPT6HvQX7ClHz
KdeAz3V6B6DrvwAAAADwvVbdf6W4Agxd6HQDAACgJV2RvKKa4IBDj4gU4gEA8S0wq5bdf6XoAAQAAADgAv6AzedaF/9KObkA
6P1/cP7GYWMHAEDMGp94G/jO0B2ADhMAAABeoTBGJOok8fXo/ivFFWAQYAAAAABNvFKk7VX8K+XEAqDrvwAAAAC8p4nmHMN2
AGprJTPz37gAAEiMxblAHj27/0pxBRgQuIJgHAD7P+Ju7FGEdkoB0PVfHLgAAABABiMWaXUAAhCOYjwA5E50xQYgfudvQxYA
tbMCAAJOAACy6H179jb7F4BoFMDzjEuLooP5AgAAOfMjP2J6RnvcPBIAAIB/E7cWJOj9xjfa2CrokN3j8dDg0NFwV4A9bGbe
rDAuxgUAAHEmcETPW7T+CAgAAAAANDZSk1vXAqD3/wEAALxGR9f4iTVYA4yumrxgDQAAQHQKqWCdZuYKMNikhqcwinkHAM5N
gAx63aats31gYB4KowJt8w4AcF6L78C6vl41IAACXgAAxJvMRy2FrVwBBhs3AAAADEEBu8+t2jrLBwUAAMkN8J4f0QF71TY3
AwECeBslAEC/WCZLvHhV3CZeBHjOFWCgC4VRAADYT0ET6KF5AdD1XwAAgLb8uIo5w1ciFo3N3/b1NR2AYMPGnAEAACBwDnfL
PgA9tKhUjzYuEb/TKONCLuYMAM65fDEjAFytaQHQ9V8AZk88oyafis/0tq5rmu8q5rXPAPYaznnW2X8UWpalWYzlCrDNyAbL
sHQAAIBzGwCcla+rWb840I+iMSCYAwDnCjAOHYBwkKuGAADjxliA9QQRtHr1SB3tA9lcYxaEFLkAAACQW7JHxCL2VXO4WrRk
W2ww+3qyfwKAZA8A9nAFGBAoAwBMwI/zABzVpADo+i8cE7HIJTAFAACAdlrU3S7pAFT0mGNsXFfsPzYAAAA98yi5C/LvuOt7
D1eAARAYGBsAgGl4XRDs93IB0PVfAASUAAAA/bxaf9MB2ICrsgAAAAB9uAb8uhr9C3Lt4vL+P2NjbIwNAAAA13qpAOj6LwAA
AHA2P4yT0St1OFeAAQAAYED+EjDQym3GzWskrvUB9hwAYMvZ2+Icfzwe8ioxDqTNhaKt8VZnwxaHOwBd/429qBy+AABcFf/p
VgKAtlwBhguCUb/a5hqbqMkZAAAA5zrakHdaAVDBQzIOMPp+DADAPOTSX1vX1SCYx3+5GWqAvhSngAy8HgZg/JhUwQzzOK9D
HYACvNiLqQULEpiRvQuYMe4CxCfwnu6/+I7U5U65AmzDQpBuPQAAwCwxO8xK8W9OZ9QJ/BGQiw8WxSAAAEDyKy8C6Gl3AdD1
X+AjBXGIvz4BAEYkh/jjY/df1G5A8e0x1WKk9SLyzAEAAAD62dug5wowQEej/TqlQA8A85/Dul8wd/jIu/+cEc/sKgC6/tt2
05SIe+YAAADyCLgmR89EByAADn8AAJjUd91/OgNj29Oo17UA6FeKfAm0Z27umDsAAESIT5mHXAJz+bnNBUDXf9seJjYoAADo
H3cj8YXIdPix1c0QCGg451kJaEDSAbOtCfEKQMz8RtyDuRzHsiybCsHdCoAeAgBcz3n8fdCI+WP+9Jk3xgesLfrb2v23rqtb
nWy7AmyiIEmA+ZNDaxQAAGBsvfI2fwV44mQerAkAAIB8P3Z79x97VQsPcFgDAMwV9/ghFsBe+NuWm7s6AOGEzUSBC0AyD4Ci
ALRwpPtPx6D48mkB0Pv/HCCSH8DeDAAghgLm1bwDUCEIAAAA+aTxoT2dfP9S0P7lWQOfK8AADiEAAJieAinm89e+LQC6/ktm
CjjGBwAAYBSvdv/pHsytaQdg1Gq7QkfO5258jI9xNj4AAAARuAIMAAAAMDDde9/TuPXLdzd565H/EQAAACgIGJ/RuNmB+fw5
HYAODQAAEIsbHxIWBJhDy+4/nYR5NSsA2oQcPoIp4wMAgNzJ+ABc56sbvXXPvwwguHtOgRQAZwYALejYc6a2yptdAQbAAQ/A
kMkKANBGkwKgLh4ASRgAAHJe8W87vbr/dBXG99nN3rrlX4LIm2qWQxAAAADIyRVg6ESBFAAAxK5yDY7QpWfNt17zdYQPYdIA
IIAGAADoQwcgcAk/HgAAkC1WhC10/9HCx1f81e/+ITiQAQBgXH58BDnrEZGLjK4Bf65aUCCAAgDEwYAciOvp/qMXV4BtgEgK
rA1zEQBwRgMQzPubvvWz/xIARqYYDQBkp4gcj+4/eq57HYA4aDCHgHQUkcF6xRyC7LwHMJfDBUBXHPHsAQAAGNVMdQvdf/Ty
+8Zvff8fgFyHDG0pIgMAII4FRuQKMABpKdgDgHMarqb7jzP2xnrm/xkOYeblV0EAAIBYvAcwj+r6r8kBAACt+eFYHoN1xnO6
/zjDsizlx8+fP98MBQAAAMC5RigAagzL4WYIAAAAAP7QmUc0/ggIAAAAwP9kK/4pduagAAgAAAAAgVWVXgAAAADdcMSd19UE
BwAAAIB4ftf8XAEGAAAA0svcHKUxLL7qYQMAAABALO9rffWrfwAAAACQgXoI0ed0NekBAAAAIC7vAAQAAADS0ghlHDI8y+qh
AwAAAMD8vqrp1b3/AwAAAABgHt9eAVYEBAAAAKJS9yDLfPYOQAAAAAAURAM/u+rhAwAAANmod5BJtSgAAAAAYE5b6nauAAMA
AACpaHQi21yuFgcAAAAAxLWrA1AREAAAAJiZ2obxyfisqokAAAAAAPPYW5/zDkAAAAAgBU1NZJ3H1YIBAAAAgLgOdwAqAgIA
AACzUMcwVpmfTTUhAAAAAGBsr9ThvAMQIPlBAAAA4mWIrVpEAAAAADCuV+tvdYQPAYC9GAAAxMnGjT7P4mYYTYqjlmUx4AAA
AACDa/YOQJXh63kGAAAAIE/GHP6oWlh43mBdAgAAEDe/qyN/OAAAAIAj1CeMIX9UQ4DNAKxDAAAA4uZ5dYYPydhj7nmD/QAA
AMTEMO78rRYbAAAAAMTV9QqwImAenjUAAADyU+PJmOPtHYAAAAAAcLGexdY684dnrDH2rMG+AAAA4mAYb+5WCxDPGgAAACAu
V4ABJqboDgAAYmNja3yfqSaLSeJZg/0BAACAuHlbjfilAAAAAIBfTr8CrAiYg+cMAACAHBTGmLfeAQjgQAEAAJBbBB7PatKY
LJ4zAAAAcmOIq1qgeM4AAAAA57iiVlKzfWEAhwsAAIh1IdOc9Q5AbMhgbQEAABDY5QVACaxxAwAAAHmxMTd+/VQTCM8YrEEA
AADi5mTVQOAZAwAAIL+EuLwDEAAAAAA6GaFgXQ2IieOzg70DAADEtRj/uONVDQwAAAAAtDVSjcsVYFIvALCOAABAHAzRVQva
ZgfYQwAAAIibe1UDhecLAACAPBLPIu74VAOG5wsAAAAQ14+3t7e30T/ksiyeVIlbMPN84fy9wLoDAEA+jLwizzz9D0kzglTR
VlrAAAAAAElFTkSuQmCC
]]
local LOGO_CACHE_FILE = (ok_datastorage and (DataStorage:getDataDir() .. "/appdock_minecraft/minecraft_logo_eink.png")) or "/tmp/appdock_minecraft_logo_eink.png"

local function decodeBase64(value)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    value = value:gsub("[^%w%+/=]", "")
    for index = 1, #value, 4 do
        local a, b, c, d = value:sub(index, index), value:sub(index + 1, index + 1), value:sub(index + 2, index + 2), value:sub(index + 3, index + 3)
        local n1 = alphabet:find(a, 1, true) or 1
        local n2 = alphabet:find(b, 1, true) or 1
        local n3 = c == "=" and 1 or (alphabet:find(c, 1, true) or 1)
        local n4 = d == "=" and 1 or (alphabet:find(d, 1, true) or 1)
        local triple = (n1 - 1) * 262144 + (n2 - 1) * 4096 + (n3 - 1) * 64 + (n4 - 1)
        out[#out + 1] = string.char(math.floor(triple / 65536) % 256)
        if c ~= "=" then out[#out + 1] = string.char(math.floor(triple / 256) % 256) end
        if d ~= "=" then out[#out + 1] = string.char(triple % 256) end
    end
    return table.concat(out)
end

local function ensureEmbeddedLogo()
    local file = io.open(LOGO_CACHE_FILE, "rb")
    if file then file:close(); return LOGO_CACHE_FILE end
    local directory = LOGO_CACHE_FILE:match("^(.+)/[^/]+$")
    if ok_lfs and directory and not lfs.attributes(directory) then lfs.mkdir(directory) end
    local payload = decodeBase64(EMBEDDED_MINECRAFT_LOGO_B64)
    file = io.open(LOGO_CACHE_FILE .. ".tmp", "wb")
    if not file then return nil end
    local ok = file:write(payload)
    file:close()
    if not ok or not os.rename(LOGO_CACHE_FILE .. ".tmp", LOGO_CACHE_FILE) then os.remove(LOGO_CACHE_FILE .. ".tmp"); return nil end
    return LOGO_CACHE_FILE
end

local Screen = Device.screen
local TAU = math.pi * 2
local WORLD_SIZE = 96
local WATER_LEVEL = 4
local MAX_TERRAIN_HEIGHT = 14
local MAX_COLUMN_HEIGHT = 20
local MAX_VIEW_DISTANCE = 24
local VOXEL_PADDING = MAX_VIEW_DISTANCE + 1
local MAX_WORLD_SEED = 2147483647
local RENDER_SCALE = 1
-- 600x600 output target. The renderer samples 5x5 output pixels as one logical
-- ray. This keeps the requested 600x600 canvas while reducing the expensive ray
-- casts to about 1/25 of full-resolution rendering.
local RENDER_COLS = 600
local RENDER_ROWS = 600
local RENDER_SAMPLE = 5
-- Color E-Ink panels do not benefit from a full-resolution ray per 2x2 cell.
-- 3x3 keeps block silhouettes and texture dithering readable while cutting the
-- hot DDA loop by roughly half on a typical AppDock pane.
local COLOR_RENDER_SAMPLE = 3
-- During a finger drag the view is a preview. The release frame switches back
-- to COLOR_RENDER_SAMPLE, while this coarser grid keeps camera feedback fluid.
local LIVE_RENDER_SAMPLE = 6
-- The E-Ink game view never switches to the expensive high-resolution path.
local MINECRAFT_RENDER_SAMPLE = LIVE_RENDER_SAMPLE
-- Same 8x8 ordered Bayer matrix used by AppDock YouTube's indexed-color
-- pipeline. We normalize it to the 0..15 coverage range at the hot render
-- site, keeping color transitions stable while avoiding per-pixel RGB math.
local BAYER8 = {
    { 0, 48, 12, 60, 3, 51, 15, 63 }, { 32, 16, 44, 28, 35, 19, 47, 31 },
    { 8, 56, 4, 52, 11, 59, 7, 55 }, { 40, 24, 36, 20, 43, 27, 39, 23 },
    { 2, 50, 14, 62, 1, 49, 13, 61 }, { 34, 18, 46, 30, 33, 17, 45, 29 },
    { 10, 58, 6, 54, 9, 57, 5, 53 }, { 42, 26, 38, 22, 41, 25, 37, 21 },
}
local COLOR_PALETTE = {
    black = { 0, 0, 0 },
    red = { 220, 45, 45 },
    green = { 45, 170, 70 },
    blue = { 55, 105, 220 },
    cyan = { 25, 175, 185 },
    magenta = { 195, 60, 175 },
    yellow = { 225, 185, 35 },
    -- Color panels can also print white, and without it snow, glass and clouds
    -- could only be approximated by a blue/yellow noise.
    white = { 245, 246, 240 },
}
local COLOR_PALETTE_ORDER = { "black", "red", "green", "blue", "cyan", "magenta", "yellow", "white" }
-- Texture level 0 stays black (coal, obsidian, ore spots); the remaining levels
-- render close to the block's real color with a slightly brighter top face, so
-- earth and wooden blocks do not collapse into black dithers on the 8-ink panel.
-- Keep the top bright and both side orientations visibly darker. The previous
-- close factors made a wooden top and its sides use almost the same ink
-- coverage, so the voxel read as a flat patch.
local SHADE_FACTORS = { 0, 0.78, 0.96, 1.08 }
local PLAYER_EYE_HEIGHT = 1.65
local WALK_DISTANCE = 0.64
local TURN_ANGLE = math.pi / 12
local MOVE_FRAMES = 4
local MOVE_FRAME_SECONDS = 0.045
-- Held movement repaints the complete voxel view, so do not let touch-pan
-- samples turn into display refreshes. Match one repeat to the full movement
-- animation duration instead of polling at the animation-frame rate.
local HELD_MOVE_SECONDS = MOVE_FRAMES * MOVE_FRAME_SECONDS
-- Mobile Bedrock look sensitivity: a normal thumb drag should turn the view
-- decisively, not require a full-screen swipe for a small camera movement.
local LOOK_YAW_PER_PIXEL = 0.014
local LOOK_PITCH_PER_PIXEL = 0.010
local START_PLAYER_X = 48.5
local START_PLAYER_Z = 56.5
local START_YAW = math.pi / 2
-- Bedrock keeps 36 slots: the first nine are the hotbar.
local HOTBAR_SLOTS = 9
local INVENTORY_SLOTS = 36
local STACK_LIMIT = 64
local CRAFT_ROWS_PER_PAGE = 4
local CRAFT_PAGES_MAX = 5
-- Time advances with player actions rather than an always-running redraw timer:
-- this keeps the day/night cycle responsive without wasting E-Ink refreshes.
local DAY_LENGTH_TICKS = 144
local DAY_TICK_PER_ACTION = 1
local MAX_MOBS = 18
local MOBS_PER_KIND = 4
local MAX_RENDERED_MOBS = 3
local AMBIENT_MOB_SECONDS = 1.25
local TORCH_LIGHT_RADIUS = 8

-- A Minecraft-like sky is painted on color displays. Monochrome rendering
-- uses native neutral gray levels, not enlarged per-ray ink dithering.
local SCENE_COLORS = {
    sky_top = { 62, 139, 211 }, sky_mid = { 119, 190, 229 },
    sky_horizon = { 188, 221, 232 }, cloud = { 246, 247, 238 },
    distant_ground = { 96, 134, 80 }, distant_ground_dark = { 52, 88, 48 },
    mono_ground = { 153, 153, 153 }, mono_night = { 68, 68, 68 }, mono_nether = { 102, 102, 102 },
}
local scene_rgb_colors = {}
local function sceneColor(name)
    local color = scene_rgb_colors[name]
    if not color then
        local rgb = SCENE_COLORS[name] or SCENE_COLORS.sky_top
        color = Blitbuffer.colorFromString(string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3]))
        scene_rgb_colors[name] = color
    end
    return color
end

-- Dynamic sky colors are named by their RGB value. This avoids comparing
-- Blitbuffer cdata values in the hot span merger while still caching colors.
local function dynamicSceneColor(prefix, red, green, blue)
    red = math.max(0, math.min(255, math.floor(red + 0.5)))
    green = math.max(0, math.min(255, math.floor(green + 0.5)))
    blue = math.max(0, math.min(255, math.floor(blue + 0.5)))
    local name = prefix .. "_" .. red .. "_" .. green .. "_" .. blue
    if not SCENE_COLORS[name] then SCENE_COLORS[name] = { red, green, blue } end
    return name
end

local function blendRGB(first, second, amount)
    return {
        first[1] + (second[1] - first[1]) * amount,
        first[2] + (second[2] - first[2]) * amount,
        first[3] + (second[3] - first[3]) * amount,
    }
end

local function scenePaletteForTime(time_of_day)
    local elevation = math.sin((time_of_day - 0.25) * TAU)
    local daylight = math.max(0, math.min(1, (elevation + 0.10) / 0.52))
    local dawn = math.max(0, math.min(1, 1 - math.abs(time_of_day - 0.27) / 0.14))
    local dusk = math.max(0, math.min(1, 1 - math.abs(time_of_day - 0.73) / 0.14))
    local warm = math.max(dawn, dusk)
    local night_top, night_mid, night_horizon = { 8, 18, 43 }, { 18, 39, 79 }, { 56, 75, 108 }
    local day_top, day_mid, day_horizon = SCENE_COLORS.sky_top, SCENE_COLORS.sky_mid, SCENE_COLORS.sky_horizon
    local top, mid, horizon = blendRGB(night_top, day_top, daylight), blendRGB(night_mid, day_mid, daylight), blendRGB(night_horizon, day_horizon, daylight)
    if warm > 0 then
        top = blendRGB(top, { 93, 56, 84 }, warm * 0.45)
        mid = blendRGB(mid, { 222, 133, 91 }, warm * 0.38)
        horizon = blendRGB(horizon, { 244, 181, 118 }, warm * 0.45)
    end
    local ground = blendRGB({ 20, 29, 32 }, SCENE_COLORS.distant_ground, daylight)
    local ground_dark = blendRGB({ 8, 14, 18 }, SCENE_COLORS.distant_ground_dark, daylight)
    return {
        daylight = daylight,
        top = dynamicSceneColor("sky_top", top[1], top[2], top[3]),
        mid = dynamicSceneColor("sky_mid", mid[1], mid[2], mid[3]),
        horizon = dynamicSceneColor("sky_horizon", horizon[1], horizon[2], horizon[3]),
        ground = dynamicSceneColor("ground", ground[1], ground[2], ground[3]),
        ground_dark = dynamicSceneColor("ground_dark", ground_dark[1], ground_dark[2], ground_dark[3]),
    }
end

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function trim(value) return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or "" end
local function wrapAngle(value) return value % TAU end

local function daylightForTime(time_of_day)
    -- 0.25 is sunrise, 0.50 noon, 0.75 sunset; the short shoulder keeps dawn
    -- and dusk readable on E-Ink instead of flipping between black and white.
    local elevation = math.sin((time_of_day - 0.25) * TAU)
    return clamp((elevation + 0.10) / 0.52, 0, 1), elevation
end

local function timeLabelFor(time_of_day)
    local daylight = daylightForTime(time_of_day)
    if daylight < 0.08 then return _("Night") end
    if time_of_day < 0.34 then return _("Sunrise") end
    if time_of_day > 0.66 then return _("Sunset") end
    return _("Day")
end

local function normalizeSeed(seed)
    seed = tonumber(seed)
    if not seed or seed ~= seed or seed == math.huge or seed == -math.huge then return 12345 end
    return math.floor(seed) % MAX_WORLD_SEED
end

local function nextWorldSeed(current_seed)
    local now = os.time and os.time() or 0
    local seed = math.floor((now * 31 + current_seed * 17 + 1) % MAX_WORLD_SEED)
    if seed == current_seed then seed = (seed + 7919) % MAX_WORLD_SEED end
    return seed
end

local function colorRenderingEnabled()
    -- No separate device/constructor probe. Use KOReader's own mode query like
    -- draw.lua; when it is false, the established monochrome renderer is used.
    return Screen:isColorEnabled()
end

-- Match square.koplugin exactly: parse palette strings with colorFromString
-- and send them to paintRectRGB32. Cache each parsed color so equal materials
-- continue to coalesce into renderer spans.
local rgb_colors = {}
local function paletteColor(name)
    local color = rgb_colors[name]
    -- Do not compare a cached LuaJIT cdata color to nil: KOReader's ColorRGB32
    -- __eq metamethod indexes its argument and crashes on that comparison.
    if not color then
        local rgb = COLOR_PALETTE[name] or COLOR_PALETTE.black
        local hex = string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3])
        color = Blitbuffer.colorFromString(hex)
        rgb_colors[name] = color
    end
    return color
end

-- Block catalogue --------------------------------------------------------------
-- Every block has a translated label, a compatibility palette fallback,
-- a target RGB color, an 8x8 procedural texture and -- for
-- natural blocks -- the item that drops when the block is mined.
local MATERIALS = {
    grass = { label = _("Grass Block"), color = "green", rgb = { 106, 170, 64 }, pattern = "grass", drop = "dirt" },
    dirt = { label = _("Dirt"), color = "red", rgb = { 150, 113, 79 }, pattern = "dirt" },
    farmland = { label = _("Farmland"), color = "red", rgb = { 128, 94, 58 }, pattern = "farm" },
    stone = { label = _("Stone"), color = "blue", rgb = { 142, 142, 142 }, pattern = "stone", drop = "cobblestone" },
    cobblestone = { label = _("Cobblestone"), color = "blue", rgb = { 128, 128, 131 }, pattern = "cobble" },
    gravel = { label = _("Gravel"), color = "blue", rgb = { 152, 143, 140 }, pattern = "gravel" },
    sand = { label = _("Sand"), color = "yellow", rgb = { 219, 207, 163 }, pattern = "sand" },
    sandstone = { label = _("Sandstone"), color = "yellow", rgb = { 216, 203, 155 }, pattern = "sandstone" },
    clay = { label = _("Clay"), color = "cyan", rgb = { 160, 166, 179 }, pattern = "clay" },
    bricks = { label = _("Bricks"), color = "red", rgb = { 168, 108, 90 }, pattern = "brick" },
    snow = { label = _("Snow Block"), color = "cyan", rgb = { 240, 250, 250 }, pattern = "snow" },
    ice = { label = _("Ice"), color = "cyan", rgb = { 145, 183, 235 }, pattern = "ice" },
    water = { label = _("Water"), color = "blue", rgb = { 63, 118, 228 }, pattern = "water", liquid = true },
    lava = { label = _("Lava"), color = "red", rgb = { 207, 92, 20 }, pattern = "lava", liquid = true },
    bedrock = { label = _("Bedrock"), color = "black", rgb = { 85, 85, 85 }, pattern = "bedrock" },
    obsidian = { label = _("Obsidian"), color = "black", rgb = { 26, 22, 36 }, pattern = "obsidian" },
    coal = { label = _("Coal"), color = "black", rgb = { 42, 42, 42 }, pattern = "ore_coal" },
    iron = { label = _("Iron Ore"), color = "cyan", rgb = { 154, 155, 140 }, pattern = "ore_iron" },
    gold = { label = _("Gold Ore"), color = "yellow", rgb = { 214, 157, 38 }, pattern = "ore_gold" },
    diamond = { label = _("Diamond Ore"), color = "cyan", rgb = { 92, 219, 213 }, pattern = "ore_diamond" },
    redstone = { label = _("Redstone Ore"), color = "red", rgb = { 175, 32, 32 }, pattern = "ore_redstone" },
    wood = { label = _("Oak Log"), color = "red", rgb = { 172, 120, 62 }, pattern = "log" },
    wood_birch = { label = _("Birch Log"), color = "yellow", rgb = { 216, 211, 190 }, pattern = "log" },
    wood_spruce = { label = _("Spruce Log"), color = "red", rgb = { 120, 86, 48 }, pattern = "log" },
    wood_jungle = { label = _("Jungle Log"), color = "red", rgb = { 112, 80, 44 }, pattern = "log" },
    wood_acacia = { label = _("Acacia Log"), color = "red", rgb = { 176, 106, 60 }, pattern = "log" },
    leaves = { label = _("Oak Leaves"), color = "green", rgb = { 58, 150, 60 }, pattern = "leaves", drop = "leaves" },
    leaves_birch = { label = _("Birch Leaves"), color = "green", rgb = { 106, 172, 69 }, pattern = "leaves" },
    leaves_spruce = { label = _("Spruce Leaves"), color = "cyan", rgb = { 54, 124, 80 }, pattern = "leaves" },
    leaves_jungle = { label = _("Jungle Leaves"), color = "green", rgb = { 45, 178, 44 }, pattern = "leaves" },
    leaves_acacia = { label = _("Acacia Leaves"), color = "green", rgb = { 115, 163, 61 }, pattern = "leaves" },
    planks = { label = _("Planks"), color = "red", rgb = { 176, 143, 90 }, pattern = "planks" },
    glass = { label = _("Glass"), color = "cyan", rgb = { 218, 241, 243 }, pattern = "glass" },
    crafting_table = { label = _("Crafting Table"), color = "red", rgb = { 142, 106, 62 }, pattern = "craft_table" },
    furnace = { label = _("Furnace"), color = "blue", rgb = { 118, 118, 118 }, pattern = "furnace" },
    cactus = { label = _("Cactus"), color = "green", rgb = { 74, 140, 62 }, pattern = "cactus" },
    dead_bush = { label = _("Dead Bush"), color = "yellow", rgb = { 148, 109, 58 }, pattern = "dead_bush" },
    wheat = { label = _("Wheat"), color = "yellow", rgb = { 208, 190, 90 }, pattern = "wheat" },
    bread = { label = _("Bread"), color = "yellow", rgb = { 194, 143, 72 }, pattern = "bread" },
    torch = { label = _("Torch"), color = "yellow", rgb = { 255, 185, 48 }, pattern = "torch", emissive = true },
    netherrack = { label = _("Netherrack"), color = "red", rgb = { 137, 54, 49 }, pattern = "netherrack", drop = "netherrack" },
    soul_sand = { label = _("Soul Sand"), color = "red", rgb = { 83, 55, 45 }, pattern = "soul_sand" },
    basalt = { label = _("Basalt"), color = "black", rgb = { 75, 73, 78 }, pattern = "basalt" },
    nether_bricks = { label = _("Nether Bricks"), color = "red", rgb = { 83, 34, 38 }, pattern = "nether_bricks" },
    nether_quartz_ore = { label = _("Nether Quartz Ore"), color = "white", rgb = { 221, 197, 181 }, pattern = "nether_quartz", drop = "nether_quartz_ore" },
    glowstone = { label = _("Glowstone"), color = "yellow", rgb = { 245, 190, 82 }, pattern = "glowstone", emissive = true },
    magma_block = { label = _("Magma Block"), color = "red", rgb = { 191, 67, 28 }, pattern = "magma" },
    portal = { label = _("Nether Portal"), color = "magenta", rgb = { 111, 38, 148 }, pattern = "portal", emissive = true },
    flint_and_steel = { label = _("Flint and Steel"), color = "black", rgb = { 105, 105, 108 }, pattern = "flint_and_steel", tool = true },
}

-- Display and crafting order: natural blocks, ores, wood, foliage, crafted blocks.
local MATERIAL_ORDER = {
    "grass", "dirt", "farmland", "cobblestone", "stone", "gravel", "sand", "sandstone",
    "clay", "bricks", "snow", "ice", "water", "lava", "obsidian", "bedrock",
    "coal", "iron", "gold", "diamond", "redstone",
    "wood", "wood_birch", "wood_spruce", "wood_jungle", "wood_acacia",
    "leaves", "leaves_birch", "leaves_spruce", "leaves_jungle", "leaves_acacia",
    "planks", "glass", "crafting_table", "furnace", "cactus", "dead_bush", "wheat", "torch",
    "netherrack", "soul_sand", "basalt", "nether_bricks", "nether_quartz_ore", "glowstone", "magma_block", "flint_and_steel", "bread",
}

local MATERIAL_COLORS, MATERIAL_TARGET_RGB, MATERIAL_LABELS, MATERIAL_PATTERNS, DROPS = {}, {}, {}, {}, {}
local MATERIAL_EDGE_IDS = {}
local next_edge_id = 1
for id, definition in pairs(MATERIALS) do
    MATERIAL_COLORS[id] = definition.color
    MATERIAL_TARGET_RGB[id] = definition.rgb
    MATERIAL_LABELS[id] = definition.label
    MATERIAL_PATTERNS[id] = definition.pattern
    DROPS[id] = definition.drop or id
    MATERIAL_EDGE_IDS[id] = next_edge_id
    next_edge_id = next_edge_id + 1
end

local function materialLabel(material)
    return MATERIAL_LABELS[material] or tostring(material)
end

local function colorForMaterial(material)
    if not colorRenderingEnabled() then return Blitbuffer.COLOR_BLACK end
    return paletteColor(MATERIAL_COLORS[material] or "black")
end

-- Approximate any target RGB color with a pair of the seven fast-refresh inks.
-- Bayer coverage chooses between them, creating intermediate perceived colors
-- without asking the panel to refresh unsupported RGB values.
local color_mix_cache = {}
local function paletteMixForRGB(target_r, target_g, target_b)
    target_r = clamp(math.floor(target_r + 0.5), 0, 255)
    target_g = clamp(math.floor(target_g + 0.5), 0, 255)
    target_b = clamp(math.floor(target_b + 0.5), 0, 255)
    local key = target_r .. ":" .. target_g .. ":" .. target_b
    local cached = color_mix_cache[key]
    if cached then return cached end

    local tr, tg, tb = target_r, target_g, target_b
    local best_error, best_first, best_second, best_amount = math.huge, "black", "black", 0
    for first_index = 1, #COLOR_PALETTE_ORDER do
        local first_name = COLOR_PALETTE_ORDER[first_index]
        local first = COLOR_PALETTE[first_name]
        for second_index = first_index, #COLOR_PALETTE_ORDER do
            local second_name = COLOR_PALETTE_ORDER[second_index]
            local second = COLOR_PALETTE[second_name]
            local dr, dg, db = second[1] - first[1], second[2] - first[2], second[3] - first[3]
            local length2 = dr * dr + dg * dg + db * db
            local amount = 0
            if length2 > 0 then
                amount = clamp(((tr - first[1]) * dr + (tg - first[2]) * dg + (tb - first[3]) * db) / length2, 0, 1)
            end
            local er = tr - (first[1] + dr * amount)
            local eg = tg - (first[2] + dg * amount)
            local eb = tb - (first[3] + db * amount)
            local error = er * er + eg * eg + eb * eb
            if error < best_error then
                best_error, best_first, best_second, best_amount = error, first_name, second_name, amount
            end
        end
    end
    cached = { first = best_first, second = best_second, second_pixels = math.floor(best_amount * 16 + 0.5) }
    color_mix_cache[key] = cached
    return cached
end

local material_mix_cache = {}
-- A free search over all ink pairs minimises the average colour, but it
-- sometimes finds that average with a green/magenta dither, which reads as
-- purple noise on paper. Blocks with a fixed character are therefore pinned:
-- greys use the neutral black/white pair, browns use red/green (the closest
-- printable brown) and dry plants use black/yellow. Level 0 always stays black
-- so ore spots, coal and obsidian keep their dark pixels.
local MATERIAL_MIX = {
    stone = { "black", "white" }, cobblestone = { "black", "white" },
    gravel = { "black", "white" }, clay = { "black", "white" },
    bedrock = { "black", "white" }, coal = { "black", "white" },
    dirt = { "red", "green" }, farmland = { "red", "green" },
    wood = { "red", "green" }, wood_spruce = { "red", "green" },
    wood_jungle = { "red", "green" }, wood_acacia = { "red", "green" },
    planks = { "red", "green" }, bricks = { "red", "green" },
    crafting_table = { "red", "green" }, dead_bush = { "black", "yellow" },
    torch = { "red", "yellow" },
    netherrack = { "black", "red" }, soul_sand = { "black", "red" },
    basalt = { "black", "white" }, nether_bricks = { "black", "red" },
    nether_quartz_ore = { "red", "white" }, glowstone = { "red", "yellow" },
    magma_block = { "red", "yellow" }, portal = { "black", "magenta" },
    flint_and_steel = { "black", "white" },
}
local function paletteMixForMaterial(material, level)
    local shades = material_mix_cache[material]
    local shade_index = level + 1
    if shades and shades[shade_index] then return shades[shade_index] end
    local source = MATERIAL_TARGET_RGB[material] or COLOR_PALETTE[MATERIAL_COLORS[material] or "black"]
    local factor = SHADE_FACTORS[level + 1] or 1
    local mix
    local pinned = MATERIAL_MIX[material]
    if pinned and level > 0 then
        local first, second = COLOR_PALETTE[pinned[1]], COLOR_PALETTE[pinned[2]]
        local dr, dg, db = second[1] - first[1], second[2] - first[2], second[3] - first[3]
        local length2 = dr * dr + dg * dg + db * db
        local amount = 0
        if length2 > 0 then
            local tr, tg, tb = source[1] * factor, source[2] * factor, source[3] * factor
            amount = clamp(((tr - first[1]) * dr + (tg - first[2]) * dg + (tb - first[3]) * db) / length2, 0, 1)
        end
        mix = { first = pinned[1], second = pinned[2], second_pixels = math.floor(amount * 16 + 0.5) }
    else
        mix = paletteMixForRGB(source[1] * factor, source[2] * factor, source[3] * factor)
    end
    shades = shades or {}
    shades[shade_index] = mix
    material_mix_cache[material] = shades
    return mix
end

-- All material and texture-level pairs are fixed; resolve them once at load so
-- the per-ray color path only performs two array lookups and a threshold test.
for material in pairs(MATERIAL_TARGET_RGB) do
    for level = 0, 3 do paletteMixForMaterial(material, level) end
end

-- Bound the DDA ray count while allowing each caller to select sampling density:
-- color mode uses finer cells for Bayer shading; monochrome uses fewer rays.
local function renderGridFor(width, height, sample)
    sample = sample or RENDER_SAMPLE
    local cols = math.max(1, math.min(RENDER_COLS, math.floor(width / sample)))
    local rows = math.max(1, math.min(RENDER_ROWS, math.floor(height / sample)))
    return cols, rows
end

local function emptySizedWidget(width, height)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalSpan:new{ width = 0 },
    }
end

-- Procedural 8x8 block textures ------------------------------------------------
-- Digits are perceived texture levels: 0 is solid black, 1 is mostly black,
-- 2 is mostly white and 3 is solid white. Color panels combine the level with
-- the material's dithered target color, so one pattern serves both modes.
local BASE_STONE_PATTERN = "11121111" .. "21111211" .. "11112111" .. "11211121" ..
    "11121111" .. "21112111" .. "11111211" .. "11211121"

local function orePattern(spot)
    local characters = {}
    for index = 1, 64 do characters[index] = BASE_STONE_PATTERN:sub(index, index) end
    for _, position in ipairs({ 11, 12, 20, 29, 30, 38, 45, 46, 54 }) do
        characters[position] = tostring(spot)
    end
    for _, position in ipairs({ 3, 25, 41, 58 }) do characters[position] = tostring(spot) end
    return table.concat(characters)
end

local PATTERNS = {
    grass = "23222332" .. "32232223" .. "22332222" .. "32233223" .. "23222332" .. "32232223" .. "22332232" .. "32233223",
    dirt = "11211121" .. "12111112" .. "11121111" .. "21112111" .. "11121121" .. "12111211" .. "11121111" .. "21112111",
    farm = "10111011" .. "11101111" .. "11011101" .. "01110111" .. "10111011" .. "11101111" .. "11011101" .. "01110111",
    stone = BASE_STONE_PATTERN,
    cobble = "32233222" .. "22322233" .. "23222323" .. "32223222" .. "22332223" .. "23223232" .. "32232222" .. "22323233",
    gravel = "21212211" .. "12211221" .. "21122122" .. "22121122" .. "12212212" .. "21221221" .. "22122112" .. "12211221",
    sand = "32223222" .. "22322232" .. "23222322" .. "32232223" .. "22322232" .. "23222322" .. "32223223" .. "22322232",
    sandstone = "33323332" .. "23332333" .. "33323332" .. "23332333" .. "33323332" .. "23332333" .. "33323332" .. "23332333",
    clay = "22232222" .. "22322223" .. "23222322" .. "32223222" .. "22322232" .. "23222323" .. "32232222" .. "22323222",
    brick = "11111111" .. "22222222" .. "11111211" .. "22222222" .. "11111111" .. "21122222" .. "11111111" .. "22222212",
    snow = "33333333" .. "33323333" .. "33333333" .. "33333233" .. "33333333" .. "33333333" .. "33333333" .. "33333333",
    ice = "22322232" .. "22232233" .. "23222322" .. "32223222" .. "22322232" .. "23222323" .. "32223222" .. "22322322",
    water = "12211222" .. "11221122" .. "12211222" .. "22112211" .. "12211222" .. "11221122" .. "12211221" .. "22112211",
    lava = "11111111" .. "11211121" .. "11111111" .. "12111112" .. "11111111" .. "11211121" .. "11111111" .. "12111112",
    bedrock = "12111211" .. "11121112" .. "21112111" .. "11211211" .. "12111211" .. "11121112" .. "21112111" .. "11211211",
    obsidian = "01100110" .. "10011001" .. "01100110" .. "10011001" .. "00110011" .. "11001100" .. "00110011" .. "11001100",
    ore_coal = orePattern(0),
    ore_iron = orePattern(1),
    ore_diamond = orePattern(2),
    ore_gold = orePattern(3),
    ore_redstone = orePattern(0),
    -- Bark and foliage keep the old blocky silhouettes, but avoid solid black
    -- pixels so a wood trunk and a tree crown stay recognizable brown/green
    -- instead of turning into black blobs on both panel types.
    log = "11221122" .. "11221122" .. "11221122" .. "12211221" .. "11221122" .. "11221122" .. "11221122" .. "12211221",
    leaves = "12111211" .. "21121112" .. "11221121" .. "12211121" .. "11122111" .. "21112112" .. "11211211" .. "12122111",
    planks = "21222212" .. "22221222" .. "22222222" .. "12222221" .. "21222222" .. "22222222" .. "22221222" .. "12222221",
    glass = "33333333" .. "32222223" .. "32222223" .. "32222223" .. "32222223" .. "32222223" .. "32222223" .. "33333333",
    craft_table = "11111111" .. "12222221" .. "12222221" .. "11111111" .. "12222221" .. "12222221" .. "12222221" .. "11111111",
    furnace = "33333333" .. "32222223" .. "32200223" .. "32200223" .. "32222223" .. "32222223" .. "33333333" .. "33333333",
    cactus = "11221122" .. "11121112" .. "11221122" .. "11121112" .. "11221122" .. "11121112" .. "11221122" .. "11121112",
    dead_bush = "10001100" .. "01000100" .. "00100100" .. "01010101" .. "00101010" .. "01000100" .. "00100010" .. "01000100",
    wheat = "21312131" .. "21312131" .. "21312131" .. "21312131" .. "21312131" .. "21312131" .. "21312131" .. "21312131",
    bread = "22222222" .. "22333222" .. "23333332" .. "23333332" .. "22333222" .. "22222222" .. "22222222" .. "22222222",
    torch = "00010000" .. "00130000" .. "00010000" .. "00010000" .. "00010000" .. "00010000" .. "00010000" .. "00010000",
    netherrack = "12111211" .. "21112112" .. "11211121" .. "12121111" .. "21111211" .. "11212111" .. "12111212" .. "21112111",
    soul_sand = "11011101" .. "11101110" .. "10111011" .. "01110111" .. "11011101" .. "11101110" .. "10111011" .. "01110111",
    basalt = BASE_STONE_PATTERN,
    nether_bricks = "11111111" .. "22222222" .. "11111211" .. "22222222" .. "11111111" .. "21122222" .. "11111111" .. "22222212",
    nether_quartz = orePattern(3),
    glowstone = "32323232" .. "23232323" .. "32333232" .. "23332323" .. "32323232" .. "23233223" .. "32323232" .. "23232323",
    magma = "11031103" .. "10311031" .. "03110311" .. "31103110" .. "11031103" .. "10311031" .. "03110311" .. "31103110",
    portal = "01232120" .. "12321201" .. "23212012" .. "32120123" .. "21201232" .. "12012321" .. "20123212" .. "01232120",
    flint_and_steel = "00000000" .. "00011000" .. "00122100" .. "01233210" .. "00122100" .. "00011000" .. "00000000" .. "00000000",
}

local PATTERN_VALUES, PATTERN_AVERAGES = {}, {}
for material, pattern_name in pairs(MATERIAL_PATTERNS) do
    local source = PATTERNS[pattern_name] or BASE_STONE_PATTERN
    local values = {}
    for index = 1, 64 do
        local digit = tonumber(source:sub(index, index))
        values[index] = digit or 2
    end
    PATTERN_VALUES[material] = values
    local total = 0
    for index = 1, 64 do total = total + values[index] end
    PATTERN_AVERAGES[material] = total / 64
end

-- The ray grid controls geometric resolution, not the palette's dither grid.
-- Emit real cached RGB / gray tones, like the sky already does. KOReader and
-- the display handle native ink conversion at physical-pixel resolution;
-- choosing one ink per 6x6 ray made every surface a coarse checkerboard.
local SURFACE_TONES = {}
for material, source in pairs(MATERIAL_TARGET_RGB) do
    local tones = { rgb = {}, mono = {} }
    local luminance = source[1] * 0.299 + source[2] * 0.587 + source[3] * 0.114
    for tone = 0, 15 do
        local factor = 0.30 + tone / 15 * 0.83
        tones.rgb[tone + 1] = dynamicSceneColor("block_" .. material, source[1] * factor, source[2] * factor, source[3] * factor)
        local gray = clamp(math.floor(48 + luminance * factor * 0.80 + 0.5), 0, 255)
        -- 16 native gray levels remain stable and cheap on monochrome E-Ink.
        gray = math.floor(gray / 17 + 0.5) * 17
        tones.mono[tone + 1] = dynamicSceneColor("gray", gray, gray, gray)
    end
    SURFACE_TONES[material] = tones
end

-- Crafting recipes -------------------------------------------------------------
-- Recipes convert blocks into blocks, so no new item type is needed. Every
-- ingredient and result is a placeable block of this world.
local RECIPES = {
    { result = { "planks", 4 }, ingredients = { { "wood", 1 } } },
    { result = { "planks", 4 }, ingredients = { { "wood_birch", 1 } } },
    { result = { "planks", 4 }, ingredients = { { "wood_spruce", 1 } } },
    { result = { "planks", 4 }, ingredients = { { "wood_jungle", 1 } } },
    { result = { "planks", 4 }, ingredients = { { "wood_acacia", 1 } } },
    { result = { "torch", 4 }, ingredients = { { "wood", 1 }, { "coal", 1 } } },
    { result = { "crafting_table", 1 }, ingredients = { { "planks", 4 } } },
    { result = { "furnace", 1 }, ingredients = { { "cobblestone", 8 } } },
    { result = { "stone", 1 }, ingredients = { { "cobblestone", 1 }, { "coal", 1 } } },
    { result = { "glass", 1 }, ingredients = { { "sand", 1 }, { "coal", 1 } } },
    { result = { "sandstone", 1 }, ingredients = { { "sand", 4 } } },
    { result = { "bricks", 2 }, ingredients = { { "clay", 4 }, { "coal", 1 } } },
    { result = { "obsidian", 1 }, ingredients = { { "water", 1 }, { "lava", 1 } } },
    { result = { "flint_and_steel", 1 }, ingredients = { { "iron", 1 }, { "gravel", 1 } } },
    { result = { "ice", 2 }, ingredients = { { "water", 1 }, { "snow", 1 } } },
    { result = { "gravel", 2 }, ingredients = { { "cobblestone", 2 } } },
    { result = { "bread", 1 }, ingredients = { { "wheat", 3 } } },
}
local RECIPE_PAGES = math.max(1, math.min(CRAFT_PAGES_MAX, math.ceil(#RECIPES / CRAFT_ROWS_PER_PAGE)))

-- World generation -------------------------------------------------------------

-- A fixed seed keeps the landscape exactly the same across refreshes, which is
-- important on E-Ink: only camera motion may change a game frame.
local function hash2(seed, x, z)
    local n = (seed * 1103515245 + x * 374761393 + z * 668265263) % 2147483647
    n = (n * 1274126177 + 1442695041) % 2147483647
    return n / 2147483647
end

local function noise2(seed, x, z, scale_value)
    local gx, gz = math.floor(x / scale_value), math.floor(z / scale_value)
    local tx, tz = (x % scale_value) / scale_value, (z % scale_value) / scale_value
    tx, tz = tx * tx * (3 - 2 * tx), tz * tz * (3 - 2 * tz)
    local a, b = hash2(seed, gx, gz), hash2(seed, gx + 1, gz)
    local c, d = hash2(seed, gx, gz + 1), hash2(seed, gx + 1, gz + 1)
    return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * tz
end

-- Not every Minecraft structure is a column. This sparse map stores blocks
-- above the terrain (trees, houses, plants), so trunks, leaf canopies and
-- buildings are made from individual voxels without inflating ground height.
local function extraBlockKey(x, z, level)
    return x .. ":" .. z .. ":" .. level
end

local function putExtraBlock(world, x, z, level, material)
    if x < 0 or z < 0 or x >= world.size or z >= world.size
        or level < 0 or level >= MAX_COLUMN_HEIGHT then return end
    local key = extraBlockKey(x, z, level)
    if not world.extra_blocks[key] then
        world.extra_blocks[key] = material
    end
end

local function putBox(world, x1, z1, y1, x2, z2, y2, material)
    for level = y1, y2 do
        for z = z1, z2 do
            for x = x1, x2 do putExtraBlock(world, x, z, level, material) end
        end
    end
end

-- Twelve Minecraft-like biomes. Each one carries its own surface and subsurface
-- blocks plus the tree or plant type that grows there.
local BIOMES = {
    ocean = { surface = "water", subsurface = "gravel", label = _("Ocean") },
    river = { surface = "water", subsurface = "sand", label = _("River") },
    beach = { surface = "sand", subsurface = "sandstone", label = _("Beach") },
    plains = { surface = "grass", subsurface = "dirt", tree = "oak", tree_chance = 0.020, spacing = 7, label = _("Plains") },
    forest = { surface = "grass", subsurface = "dirt", tree = "oak", tree_chance = 0.170, spacing = 5, label = _("Forest") },
    birch_forest = { surface = "grass", subsurface = "dirt", tree = "birch", tree_chance = 0.150, spacing = 5, label = _("Birch Forest") },
    taiga = { surface = "grass", subsurface = "dirt", tree = "spruce", tree_chance = 0.140, spacing = 5, label = _("Taiga") },
    snowy_plains = { surface = "snow", subsurface = "dirt", tree = "spruce", tree_chance = 0.030, spacing = 9, label = _("Snowy Plains") },
    desert = { surface = "sand", subsurface = "sandstone", plant = "cactus", plant_chance = 0.022, spacing = 6, label = _("Desert") },
    savanna = { surface = "grass", subsurface = "dirt", tree = "acacia", tree_chance = 0.055, spacing = 7, plant = "dead_bush", label = _("Savanna") },
    jungle = { surface = "grass", subsurface = "dirt", tree = "jungle", tree_chance = 0.230, spacing = 5, label = _("Jungle") },
    mountains = { surface = "stone", subsurface = "stone", tree = "spruce", tree_chance = 0.030, spacing = 9, label = _("Mountains") },
    swamp = { surface = "grass", subsurface = "clay", tree = "swamp_oak", tree_chance = 0.075, spacing = 6, label = _("Swamp") },
}
local BIOME_ORDER = { "ocean", "river", "beach", "plains", "forest", "birch_forest", "taiga", "snowy_plains", "desert", "savanna", "jungle", "mountains", "swamp" }

-- Tree shapes: trunk height, canopy radius and canopy silhouette per species.
local TREE_DEFS = {
    oak = { log = "wood", leaves = "leaves", trunk = 4, canopy = 2, shape = "round" },
    swamp_oak = { log = "wood", leaves = "leaves", trunk = 4, canopy = 2, shape = "round" },
    birch = { log = "wood_birch", leaves = "leaves_birch", trunk = 5, canopy = 2, shape = "round" },
    spruce = { log = "wood_spruce", leaves = "leaves_spruce", trunk = 6, canopy = 2, shape = "cone" },
    jungle = { log = "wood_jungle", leaves = "leaves_jungle", trunk = 7, canopy = 3, shape = "round" },
    acacia = { log = "wood_acacia", leaves = "leaves_acacia", trunk = 4, canopy = 3, shape = "flat" },
}

local function placeTree(world, x, z, ground, kind)
    local tree = TREE_DEFS[kind]
    if not tree then return end
    local trunk_top = ground + tree.trunk
    for level = ground, trunk_top - 1 do putExtraBlock(world, x, z, level, tree.log) end
    if tree.shape == "cone" then
        local radius = tree.canopy
        for level = trunk_top - 1, trunk_top + 1 do
            for dz = -radius, radius do
                for dx = -radius, radius do
                    if math.abs(dx) + math.abs(dz) <= radius then
                        if not (dx == 0 and dz == 0 and level < trunk_top) then
                            putExtraBlock(world, x + dx, z + dz, level, tree.leaves)
                        end
                    end
                end
            end
            radius = math.max(0, radius - 1)
        end
    elseif tree.shape == "flat" then
        for level = trunk_top, trunk_top + 1 do
            for dz = -tree.canopy, tree.canopy do
                for dx = -tree.canopy, tree.canopy do
                    if math.abs(dx) + math.abs(dz) <= tree.canopy + 1 and not (dx == 0 and dz == 0 and level == trunk_top) then
                        putExtraBlock(world, x + dx, z + dz, level, tree.leaves)
                    end
                end
            end
        end
        putExtraBlock(world, x + 1, z, trunk_top - 1, tree.log)
        putExtraBlock(world, x + 1, z + 1, trunk_top, tree.log)
    else
        for level = trunk_top - 2, trunk_top + 1 do
            local radius = tree.canopy
            if level == trunk_top - 2 then radius = radius + 1 end
            if level > trunk_top then radius = radius - 1 end
            for dz = -radius, radius do
                for dx = -radius, radius do
                    if dx * dx + dz * dz <= radius * radius + 1 then
                        if not (dx == 0 and dz == 0 and level < trunk_top) then
                            putExtraBlock(world, x + dx, z + dz, level, tree.leaves)
                        end
                    end
                end
            end
        end
    end
end

local function biomeFor(seed, x, z)
    local temperature = noise2(seed + 1700, x, z, 44) * 0.66 + noise2(seed + 33, x + 80, z - 31, 12) * 0.34
    local humidity = noise2(seed + 900, x, z, 36) * 0.70 + noise2(seed + 55, x - 40, z + 12, 9) * 0.30
    local rugged = noise2(seed + 2500, x, z, 46)
    local continent = noise2(seed + 4100, x, z, 62)
    local river = noise2(seed + 6100, x * 0.7, z * 0.7, 120)
    local biome
    if continent < 0.30 then
        biome = "ocean"
    elseif continent < 0.345 then
        biome = "beach"
    elseif math.abs(river - 0.5) < 0.022 and continent > 0.36 then
        biome = "river"
    elseif rugged > 0.78 then
        biome = "mountains"
    elseif temperature < 0.20 then
        biome = "snowy_plains"
    elseif temperature < 0.36 then
        biome = "taiga"
    elseif temperature > 0.76 and humidity < 0.36 then
        biome = "desert"
    elseif temperature > 0.68 and humidity < 0.52 then
        biome = "savanna"
    elseif humidity > 0.70 and temperature > 0.55 then
        biome = "jungle"
    elseif humidity > 0.72 then
        biome = "swamp"
    elseif humidity > 0.52 then
        biome = "forest"
    elseif humidity > 0.40 and temperature < 0.62 then
        biome = "birch_forest"
    else
        biome = "plains"
    end
    return biome, temperature, humidity, rugged, continent
end

local function terrainHeightFor(seed, x, z, biome)
    local broad = noise2(seed, x, z, 18)
    local detail = noise2(seed + 311, x, z - 7, 5)
    local fine = noise2(seed + 907, x, z + 21, 3)
    local height
    if biome == "ocean" or biome == "river" then
        height = WATER_LEVEL
    elseif biome == "beach" then
        height = WATER_LEVEL + 1
    elseif biome == "mountains" then
        height = 9 + math.floor(noise2(seed, x, z, 13) * 4 + fine * 2)
    elseif biome == "swamp" then
        height = WATER_LEVEL + math.floor(broad * 2)
        if noise2(seed + 77, x, z, 5) < 0.42 then height = math.min(height, WATER_LEVEL) end
    elseif biome == "desert" then
        height = 5 + math.floor(broad * 2 + fine)
    elseif biome == "savanna" then
        height = 5 + math.floor(broad * 1.5)
    else
        height = 5 + math.floor(broad * 2 + detail * 1.5)
    end
    return clamp(height, 1, MAX_TERRAIN_HEIGHT)
end

local function surfaceFor(seed, x, z, biome, height)
    local definition = BIOMES[biome] or BIOMES.plains
    local surface, subsurface = definition.surface, definition.subsurface
    if biome == "mountains" then
        if height >= 12 then surface = "snow" end
        if height < 12 and hash2(seed + 77, x, z) < 0.16 then surface = "gravel" end
    elseif biome == "snowy_plains" then
        if hash2(seed + 21, x, z) < 0.20 then surface = "ice" end
    end
    return surface, subsurface
end

local rebuildWorldBlocks, rebuildLightSources
local placeVillage, placeHouse, findVillageSite
local heightAt, materialAt, biomeAt

-- Mobs are deliberately entities rather than blocks. The world renderer keeps
-- block occlusion while these simple voxel animals can walk between columns.
local MOB_DEFS = {
    sheep = { label = _("Sheep"), biomes = { plains = true, forest = true, birch_forest = true, snowy_plains = true }, chance = 0.982, speed = 0.20, body = "white", face = "black" },
    cow = { label = _("Cow"), biomes = { plains = true, forest = true, savanna = true }, chance = 0.988, speed = 0.18, body = "red", face = "black" },
    pig = { label = _("Pig"), biomes = { plains = true, forest = true, savanna = true }, chance = 0.991, speed = 0.21, body = "magenta", face = "red" },
    zombie = { label = _("Zombie"), biomes = { plains = true, forest = true, birch_forest = true, taiga = true }, chance = 0.992, speed = 0.22, body = "green", face = "cyan", nocturnal = true },
}

local function mobCellIsClear(world, x, z)
    if x < 2 or z < 2 or x >= world.size - 2 or z >= world.size - 2 then return false end
    local surface = world.materials[z + 1] and world.materials[z + 1][x + 1]
    if surface == "water" or surface == "ice" or surface == "lava" then return false end
    local ground = world.heights[z + 1][x + 1]
    return not world.extra_blocks[extraBlockKey(x, z, ground)]
        and not world.extra_blocks[extraBlockKey(x, z, ground + 1)]
end

local function generateMobs(world, seed)
    local mobs, sites = {}, {}
    local ordered_kinds = { "sheep", "cow", "pig", "zombie" }
    for kind_index, kind in ipairs(ordered_kinds) do
        local definition, spawned = MOB_DEFS[kind], 0
        for z = 4, world.size - 5, 3 do
            for x = 4, world.size - 5, 3 do
                if #mobs >= MAX_MOBS then return mobs end
                if spawned >= MOBS_PER_KIND then break end
                local biome = world.biomes[z + 1][x + 1]
                local chance = hash2(seed + kind_index * 997, x, z)
                if definition.biomes[biome] and chance > definition.chance and mobCellIsClear(world, x, z) then
                    local clear = true
                    for _, site in ipairs(sites) do
                        if (site.x - x) ^ 2 + (site.z - z) ^ 2 < 36 then clear = false; break end
                    end
                    if clear then
                        sites[#sites + 1] = { x = x, z = z }
                        mobs[#mobs + 1] = {
                            kind = kind, x = x + 0.5, z = z + 0.5,
                            y = world.heights[z + 1][x + 1], heading = hash2(seed + kind_index * 211, x, z) * TAU,
                            phase = hash2(seed + kind_index * 313, x, z) * TAU,
                            gait = hash2(seed + kind_index * 419, x, z), walk_cycle = 0,
                            nocturnal = definition.nocturnal == true,
                        }
                        spawned = spawned + 1
                    end
                end
            end
        end
    end
    return mobs
end

local function buildWorld(seed)
    seed = normalizeSeed(seed)
    local world = {
        size = WORLD_SIZE, seed = seed, heights = {}, materials = {}, subsurfaces = {},
        biomes = {}, extra_blocks = {}, removed_blocks = {},
    }
    for z = 0, WORLD_SIZE - 1 do
        world.heights[z + 1], world.materials[z + 1], world.biomes[z + 1], world.subsurfaces[z + 1] = {}, {}, {}, {}
        for x = 0, WORLD_SIZE - 1 do
            local biome, _, _, rugged, _ = biomeFor(seed, x, z)
            local height = terrainHeightFor(seed, x, z, biome)
            local surface, subsurface = surfaceFor(seed, x, z, biome, height)
            if biome == "mountains" and height >= 12 then subsurface = "stone" end
            world.heights[z + 1][x + 1] = height
            world.materials[z + 1][x + 1] = surface
            world.biomes[z + 1][x + 1] = biome
            world.subsurfaces[z + 1][x + 1] = subsurface
        end
    end
    -- Trees are calculated from an immutable terrain snapshot. They are stored
    -- as real blocks above the ground instead of raising neighbouring terrain
    -- columns (the old approach made every tree look like a grass pillar).
    local terrain_heights = {}
    for z = 1, WORLD_SIZE do
        terrain_heights[z] = {}
        for x = 1, WORLD_SIZE do terrain_heights[z][x] = world.heights[z][x] end
    end
    local tree_sites = {}
    for z = 3, WORLD_SIZE - 4 do
        for x = 3, WORLD_SIZE - 4 do
            local biome = world.biomes[z + 1][x + 1]
            local definition = BIOMES[biome] or BIOMES.plains
            local surface = world.materials[z + 1][x + 1]
            if surface ~= "water" and surface ~= "ice" then
                local chance = hash2(seed + 11, x, z)
                local can_grow = definition.tree and chance < definition.tree_chance
                if can_grow then
                    local spacing = definition.spacing or 6
                    for _, site in ipairs(tree_sites) do
                        if math.abs(site.x - x) < spacing and math.abs(site.z - z) < spacing then
                            can_grow = false
                            break
                        end
                    end
                end
                if can_grow then
                    tree_sites[#tree_sites + 1] = { x = x, z = z, kind = definition.tree }
                    placeTree(world, x, z, terrain_heights[z + 1][x + 1], definition.tree)
                elseif definition.plant and chance > 0.90 then
                    local ground = terrain_heights[z + 1][x + 1]
                    if definition.plant == "cactus" then
                        local stalk = 1 + math.floor(hash2(seed + 313, x, z) * 3)
                        for level = ground, ground + stalk - 1 do putExtraBlock(world, x, z, level, "cactus") end
                    else
                        putExtraBlock(world, x, z, ground, "dead_bush")
                    end
                end
                -- Boulders make mountains and beaches look less synthesized.
                if (biome == "mountains" or biome == "beach") and hash2(seed + 811, x, z) > 0.995 then
                    local ground = terrain_heights[z + 1][x + 1]
                    local material = biome == "beach" and "cobblestone" or "gravel"
                    for dz = -1, 1 do
                        for dx = -1, 1 do
                            if math.abs(dx) + math.abs(dz) <= 1 then
                                putExtraBlock(world, x + dx, z + dz, ground, material)
                                if dx == 0 and dz == 0 then putExtraBlock(world, x, z, ground + 1, material) end
                            end
                        end
                    end
                end
            end
        end
    end
    world.village = placeVillage(world, seed)
    world.mobs = generateMobs(world, seed)
    if rebuildWorldBlocks then rebuildWorldBlocks(world) end
    return world
end

-- A village is the most recognisable Minecraft structure: houses around a
-- cobblestone well, connected by gravel paths, with a small farm next to it.
placeVillage = function(world, seed)
    local site = findVillageSite(world, seed)
    if not site then return nil end
    local cx, cz = site.x, site.z
    local ground = world.heights[cz + 1][cx + 1]
    -- Plaza: a small cobblestone square with a 2x2 water well and posts.
    for dz = -1, 1 do
        for dx = -1, 1 do
            world.heights[cz + dz + 1][cx + dx + 1] = ground
            world.materials[cz + dz + 1][cx + dx + 1] = (dx == 0 and dz == 0) and "water" or "cobblestone"
            world.subsurfaces[cz + dz + 1][cx + dx + 1] = "cobblestone"
        end
    end
    for _, corner in ipairs({ { -2, -2 }, { -2, 2 }, { 2, -2 }, { 2, 2 } }) do
        local px, pz = cx + corner[1], cz + corner[2]
        if px > 0 and pz > 0 and px < world.size - 1 and pz < world.size - 1 then
            world.heights[pz + 1][px + 1] = ground
            world.materials[pz + 1][px + 1] = "cobblestone"
            for level = ground, ground + 2 do putExtraBlock(world, px, pz, level, "wood") end
            -- Four small lamps make a village visible after sunset and establish
            -- that a torch is a real light-emitting voxel, not only an inventory item.
            putExtraBlock(world, px, pz, ground + 3, "torch")
        end
    end
    putBox(world, cx - 3, cz - 3, ground + 3, cx + 3, cz + 3, ground + 3, "planks")
    -- Four cottages around the well; unsuitable spots are simply skipped.
    local cottages = { { -9, -7 }, { 7, -7 }, { -9, 7 }, { 7, 7 } }
    for _, spot in ipairs(cottages) do
        placeHouse(world, cx + spot[1], cz + spot[2], (spot[2] < 0) and "south" or "north")
    end
    -- Gravel paths from the well to the cottage doors.
    for _, spot in ipairs(cottages) do
        local start_x, start_z = cx, cz
        local goal_x, goal_z = cx + spot[1], cz + spot[2]
        for step = 1, 12 do
            local px = start_x + math.floor((goal_x - start_x) * step / 12)
            local pz = start_z + math.floor((goal_z - start_z) * step / 12)
            if px > 0 and pz > 0 and px < world.size - 1 and pz < world.size - 1 then
                if world.materials[pz + 1][px + 1] == "grass" then
                    world.materials[pz + 1][px + 1] = "gravel"
                end
            end
        end
    end
    -- Farm plot: farmland with a water channel and wheat on top.
    local farm_x, farm_z = cx + 6, cz - 2
    for dz = 0, 3 do
        for dx = 0, 5 do
            local px, pz = farm_x + dx, farm_z + dz
            if px > 0 and pz > 0 and px < world.size - 1 and pz < world.size - 1 then
                local field_ground = world.heights[pz + 1][px + 1]
                if dx == 2 then
                    world.materials[pz + 1][px + 1] = "water"
                else
                    world.materials[pz + 1][px + 1] = "farmland"
                    if hash2(seed + 1900, px, pz) < 0.85 then
                        putExtraBlock(world, px, pz, field_ground, "wheat")
                    end
                end
                world.subsurfaces[pz + 1][px + 1] = "dirt"
            end
        end
    end
    return { x = cx, z = cz }
end

placeHouse = function(world, x, z, facing)
    if x < 3 or z < 3 or x > world.size - 4 or z > world.size - 4 then return false end
    local size = 2
    local heights = {}
    for dz = -size, size do
        for dx = -size, size do
            local h = world.heights[z + dz + 1][x + dx + 1]
            local material = world.materials[z + dz + 1][x + dx + 1]
            if material == "water" or material == "ice" then return false end
            heights[#heights + 1] = h
        end
    end
    local min_height, max_height = heights[1], heights[1]
    for _, value in ipairs(heights) do
        min_height, max_height = math.min(min_height, value), math.max(max_height, value)
    end
    if max_height - min_height > 1 then return false end
    local ground = heightAt(world, x, z)
    if ground < 1 or ground + 5 >= MAX_COLUMN_HEIGHT then return false end
    -- Floor, walls and windows on top of the levelled ground.
    for dz = -size, size do
        for dx = -size, size do
            local px, pz = x + dx, z + dz
            world.heights[pz + 1][px + 1] = ground
            world.subsurfaces[pz + 1][px + 1] = "dirt"
            if math.abs(dx) == size or math.abs(dz) == size then
                world.materials[pz + 1][px + 1] = "cobblestone"
            else
                world.materials[pz + 1][px + 1] = "planks"
            end
        end
    end
    local door_dz = facing == "south" and -size or size
    for level = ground + 1, ground + 3 do
        for dz = -size, size do
            for dx = -size, size do
                local wall = math.abs(dx) == size or math.abs(dz) == size
                if wall then
                    local door = dx == 0 and dz == door_dz and level <= ground + 2
                    local corner = math.abs(dx) == size and math.abs(dz) == size
                    local material = corner and "wood" or "planks"
                    if level == ground + 2 and not corner and ((dx + dz) % 2 == 0) then material = "glass" end
                    if not door then putExtraBlock(world, x + dx, z + dz, level, material) end
                end
            end
        end
    end
    -- Roof with a one-block overhang and a raised ridge.
    putBox(world, x - size - 1, z - size - 1, ground + 4, x + size + 1, z + size + 1, ground + 4, "planks")
    putBox(world, x - 1, z - 1, ground + 5, x + 1, z + 1, ground + 5, "wood")
    return true
end

findVillageSite = function(world, seed)
    local best_x, best_z, best_score
    local target = (world.size - 1) / 2 + (hash2(seed + 505, 7, 11) - 0.5) * 18
    local target_z = (world.size - 1) / 2 + (hash2(seed + 707, 3, 5) - 0.5) * 18
    for z = 14, world.size - 15, 2 do
        for x = 14, world.size - 15, 2 do
            local biome = world.biomes[z + 1][x + 1]
            if biome == "plains" or biome == "savanna" or biome == "forest" then
                local min_height, max_height, water = math.huge, -math.huge, false
                for dz = -8, 8, 4 do
                    for dx = -8, 8, 4 do
                        local height = world.heights[z + dz + 1][x + dx + 1]
                        local material = world.materials[z + dz + 1][x + dx + 1]
                        if material == "water" or material == "ice" then water = true end
                        min_height, max_height = math.min(min_height, height), math.max(max_height, height)
                    end
                end
                if not water and max_height - min_height <= 2 then
                    local score = math.abs(x - target) + math.abs(z - target_z) + (max_height - min_height) * 3
                    if not best_score or score < best_score then
                        best_x, best_z, best_score = x, z, score
                    end
                end
            end
        end
    end
    if not best_x then return nil end
    return { x = best_x, z = best_z }
end

local function yawToward(dx, dz)
    local angle
    if math.atan2 then
        angle = math.atan2(dx, dz)
    elseif dz == 0 then
        angle = dx >= 0 and math.pi / 2 or -math.pi / 2
    else
        angle = math.atan(dx / dz)
        if dz < 0 then angle = angle + (dx >= 0 and math.pi or -math.pi) end
    end
    return wrapAngle(angle)
end

local function hasClearTreeView(world, x, z, ground_height, trunk, distance)
    local camera_y = ground_height + PLAYER_EYE_HEIGHT
    local target_y = trunk.height - 0.25
    local sample_count = math.floor(distance * 2 - 4)
    for sample = 2, sample_count do
        local fraction = sample / (distance * 2)
        local sample_x = x + (trunk.x - x) * fraction
        local sample_z = z + (trunk.z - z) * fraction
        local column_x, column_z = math.floor(sample_x), math.floor(sample_z)
        local obstruction_height = world.heights[column_z + 1][column_x + 1]
        local ray_height = camera_y + (target_y - camera_y) * fraction
        if obstruction_height > ray_height then return false end
    end
    return true
end

-- Avoid spawning inside a tree canopy or a building. Prefer an open, walkable
-- cell with a nearby visible trunk; seeds without a suitable tree fall back to a
-- smooth, clear patch of terrain near the world center.
local function findSpawn(world)
    local size = world.size
    local trunks = {}
    for z = 3, size - 4 do
        for x = 3, size - 4 do
            local ground = world.heights[z + 1][x + 1]
            local material = world.materials[z + 1][x + 1]
            if material ~= "water" and material ~= "ice" and world.extra_blocks[extraBlockKey(x, z, ground)] == "wood" then
                trunks[#trunks + 1] = { x = x + 0.5, z = z + 0.5, height = ground + 4 }
            end
        end
    end
    -- Bucket trunks by an 8x8 grid so the spawn search stays linear.
    local buckets = {}
    for _, trunk in ipairs(trunks) do
        local key = math.floor(trunk.x / 8) .. ":" .. math.floor(trunk.z / 8)
        local bucket = buckets[key]
        if not bucket then buckets[key] = {}; bucket = buckets[key] end
        bucket[#bucket + 1] = trunk
    end

    local center = (size - 1) / 2
    local best_tree_spawn, best_open_spawn
    -- Precompute the columns that hold a structure block so the clear-view test
    -- stays a single lookup per cell instead of a sparse-map scan.
    local blocked = {}
    for key, material in pairs(world.extra_blocks) do
        if material == "wood" or material == "leaves" or material == "planks"
            or material == "glass" or material == "wood_birch" or material == "wood_spruce"
            or material == "wood_jungle" or material == "wood_acacia" then
            local column_x, column_z = key:match("^(%-?%d+):(%-?%d+):")
            if column_x then blocked[column_x .. ":" .. column_z] = true end
        end
    end
    for z = 4, size - 5 do
        local material_row = world.materials[z + 1]
        local height_row = world.heights[z + 1]
        for x = 4, size - 5 do
            local surface = material_row[x + 1]
            if surface == "grass" or surface == "sand" or surface == "snow" or surface == "gravel" then
                local clear = true
                for dz = -2, 2 do
                    local nearby = world.materials[z + dz + 1]
                    for dx = -2, 2 do
                        local material = nearby[x + dx + 1]
                        if material == "water" or material == "lava" then clear = false; break end
                    end
                    if not clear then break end
                end
                local occupied = false
                for dz = -2, 2 do
                    for dx = -2, 2 do
                        if blocked[(x + dx) .. ":" .. (z + dz)] then occupied = true; break end
                    end
                    if occupied then break end
                end
                if clear and not occupied then
                    local height = height_row[x + 1]
                    local roughness = 0
                    for dz = -1, 1 do
                        local neighbor_heights = world.heights[z + dz + 1]
                        for dx = -1, 1 do
                            roughness = math.max(roughness, math.abs(neighbor_heights[x + dx + 1] - height))
                        end
                    end
                    local center_distance = math.sqrt((x - center) ^ 2 + (z - center) ^ 2)
                    local open_score = center_distance + roughness * 2
                    if not best_open_spawn or open_score < best_open_spawn.score then
                        best_open_spawn = { x = x, z = z, score = open_score }
                    end

                    local nearest, nearest_distance2
                    local grid_x, grid_z = math.floor((x + 0.5) / 8), math.floor((z + 0.5) / 8)
                    for offset_z = -3, 3 do
                        for offset_x = -3, 3 do
                            for _, trunk in ipairs(buckets[(grid_x + offset_x) .. ":" .. (grid_z + offset_z)] or {}) do
                                local dx, dz = trunk.x - x, trunk.z - z
                                local distance2 = dx * dx + dz * dz
                                if distance2 >= 36 and distance2 <= 400
                                    and (not nearest_distance2 or distance2 < nearest_distance2) then
                                    local distance = math.sqrt(distance2)
                                    if hasClearTreeView(world, x + 0.5, z + 0.5, height, trunk, distance) then
                                        nearest, nearest_distance2 = trunk, distance2
                                    end
                                end
                            end
                        end
                    end
                    if nearest_distance2 then
                        local distance = math.sqrt(nearest_distance2)
                        local score = math.abs(distance - 10) + center_distance * 0.12 + roughness * 1.4
                        if not best_tree_spawn or score < best_tree_spawn.score then
                            best_tree_spawn = { x = x, z = z, tree = nearest, score = score }
                        end
                    end
                end
            end
        end
    end

    local spawn = best_tree_spawn or best_open_spawn
    if not spawn then return START_PLAYER_X, START_PLAYER_Z, START_YAW, nil end
    local yaw = spawn.tree and yawToward(spawn.tree.x - spawn.x - 0.5, spawn.tree.z - spawn.z - 0.5) or START_YAW
    return spawn.x + 0.5, spawn.z + 0.5, yaw, spawn.tree
end

heightAt = function(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return 0 end
    return world.heights[z + 1][x + 1] or 0
end

materialAt = function(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return "stone" end
    return (world.materials[z + 1] and world.materials[z + 1][x + 1]) or "grass"
end

biomeAt = function(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return "plains" end
    return (world.biomes[z + 1] and world.biomes[z + 1][x + 1]) or "plains"
end

local function textureCoordinates(face, hx, hy, hz, side)
    if face == "top" or side == 1 then return hx - math.floor(hx), hz - math.floor(hz) end
    if side == 0 then return hz - math.floor(hz), hy - math.floor(hy) end
    return hx - math.floor(hx), hy - math.floor(hy)
end

local function blockHash3(seed, x, z, level)
    local n = (seed * 1103515245 + x * 374761393 + z * 668265263 + level * 2246822519) % 2147483647
    n = (n * 1274126177 + 1442695041) % 2147483647
    return n
end

-- The renderer raycasts individual blocks, not just a column silhouette. Ore
-- veins are layered by depth like Minecraft: coal is everywhere, iron sits in
-- the middle layers, gold and diamond only appear close to bedrock.
local function rawBlockAt(world, x, z, level)
    if x < 0 or z < 0 or x >= world.size or z >= world.size or level < 0 then return nil end
    local key = extraBlockKey(x, z, level)
    local extra = world.extra_blocks and world.extra_blocks[key]
    if extra then return extra end
    if world.removed_blocks and world.removed_blocks[key] then return nil end
    if world.dimension == "nether" then
        local height = world.heights[z + 1][x + 1] or 0
        if level == 0 then return "bedrock" end
        if level == MAX_COLUMN_HEIGHT - 1 then return "bedrock" end
        if level == MAX_COLUMN_HEIGHT - 2 then return "netherrack" end
        if level == MAX_COLUMN_HEIGHT - 3 and blockHash3(world.seed or 1, x, z, level) % 23 == 0 then return "glowstone" end
        if level >= height then return nil end
        if level == height - 1 then return world.materials[z + 1][x + 1] or "netherrack" end
        if level >= height - 5 and blockHash3(world.seed or 1, x, z, level) % 71 < 4 then return "nether_quartz_ore" end
        if level == height - 2 and blockHash3(world.seed or 1, x, z, level) % 53 == 0 then return "magma_block" end
        return "netherrack"
    end
    local height = world.heights[z + 1][x + 1] or 0
    if level >= height then return nil end
    local surface = world.materials[z + 1][x + 1] or "grass"
    if level == height - 1 then return surface end
    if level == 0 then return "bedrock" end
    if surface == "water" or surface == "lava" then
        return level >= height - 2 and "gravel" or "stone"
    end
    local subsurface = (world.subsurfaces and world.subsurfaces[z + 1] and world.subsurfaces[z + 1][x + 1]) or "dirt"
    if level >= height - 4 then return subsurface end
    local ore = blockHash3(world.seed or 12345, x, z, level) % 200
    if level <= 2 then
        if ore < 4 then return "diamond" end
        if ore < 10 then return "gold" end
        if ore < 22 then return "iron" end
        if ore < 40 then return "coal" end
        if ore < 46 then return "redstone" end
    elseif level <= 6 then
        if ore < 3 then return "gold" end
        if ore < 12 then return "iron" end
        if ore < 30 then return "coal" end
        if ore < 36 then return "redstone" end
    else
        if ore < 5 then return "iron" end
        if ore < 18 then return "coal" end
    end
    return "stone"
end

rebuildLightSources = function(world)
    local sources = {}
    for key, material in pairs(world.extra_blocks or {}) do
        if MATERIALS[material] and MATERIALS[material].emissive then
            local x, z, level = key:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
            x, z, level = tonumber(x), tonumber(z), tonumber(level)
            if x and z and level then sources[#sources + 1] = { x = x + 0.5, z = z + 0.5, y = level + 0.58, strength = 1 } end
        end
    end
    world.light_sources = sources
end

rebuildWorldBlocks = function(world)
    local planes, size = {}, world.size
    local flat_stride = size + VOXEL_PADDING * 2
    local flat_plane_size = flat_stride * flat_stride
    local flat_blocks = {}
    for index = 1, flat_plane_size * MAX_COLUMN_HEIGHT do flat_blocks[index] = false end
    for level = 0, MAX_COLUMN_HEIGHT - 1 do
        local plane = {}
        for z = 0, size - 1 do
            local index = z * size
            for x = 0, size - 1 do
                local material = rawBlockAt(world, x, z, level)
                if material then plane[index + x + 1] = material end
                local padded_index = (z + VOXEL_PADDING) * flat_stride + x + VOXEL_PADDING + 1
                flat_blocks[level * flat_plane_size + padded_index] = material or false
            end
        end
        planes[level + 1] = plane
    end
    world.block_planes = planes
    world.block_flat = flat_blocks
    world.block_flat_stride = flat_stride
    world.block_flat_padding = VOXEL_PADDING
    rebuildLightSources(world)
end

local function rebuildBlockColumn(world, x, z)
    local planes, index = world.block_planes, z * world.size + x + 1
    if not planes then return end
    local flat_blocks = world.block_flat
    local flat_stride = world.block_flat_stride or world.size
    local flat_padding = world.block_flat_padding or 0
    local plane_size = flat_stride * flat_stride
    local flat_column_index = (z + flat_padding) * flat_stride + x + flat_padding + 1
    for level = 0, MAX_COLUMN_HEIGHT - 1 do
        local material = rawBlockAt(world, x, z, level)
        planes[level + 1][index] = material
        if flat_blocks then flat_blocks[level * plane_size + flat_column_index] = material or false end
    end
    rebuildLightSources(world)
end

local function blockAt(world, x, z, level)
    if x < 0 or z < 0 or x >= world.size or z >= world.size or level < 0 or level >= MAX_COLUMN_HEIGHT then return nil end
    local planes = world.block_planes
    if planes then
        local plane = planes[level + 1]
        return plane and plane[z * world.size + x + 1] or nil
    end
    return rawBlockAt(world, x, z, level)
end

local function frameBlockCoordinates(frame, across, up)
    if frame.axis == "x" then return frame.start + across, frame.plane, frame.base_y + up end
    return frame.plane, frame.start + across, frame.base_y + up
end

local function frameIsComplete(world, frame)
    for across = 0, 3 do
        for up = 0, 4 do
            local x, z, y = frameBlockCoordinates(frame, across, up)
            if across == 0 or across == 3 or up == 0 or up == 4 then
                if blockAt(world, x, z, y) ~= "obsidian" then return false end
            elseif blockAt(world, x, z, y) then
                return false
            end
        end
    end
    return true
end

local function findPortalFrame(world, target)
    if type(target) ~= "table" or type(target.x) ~= "number" or type(target.z) ~= "number" or type(target.y) ~= "number" then return nil end
    if blockAt(world, target.x, target.z, target.y) ~= "obsidian" then return nil end
    local candidates = {}
    for _, axis in ipairs({ "x", "z" }) do
        local coordinate = axis == "x" and target.x or target.z
        local plane = axis == "x" and target.z or target.x
        for start = coordinate - 3, coordinate do
            local across = coordinate - start
            for base_y = target.y - 4, target.y do
                local up = target.y - base_y
                local frame = { axis = axis, plane = plane, start = start, base_y = base_y }
                if across >= 0 and across <= 3 and up >= 0 and up <= 4
                    and (across == 0 or across == 3 or up == 0 or up == 4)
                    and frameIsComplete(world, frame) then
                    candidates[#candidates + 1] = frame
                end
            end
        end
    end
    return candidates[1]
end

local function portalCellCoordinates(frame, across, up)
    return frameBlockCoordinates(frame, across + 1, up + 1)
end

local function activatePortalFrame(world, frame)
    if not frame or not frameIsComplete(world, frame) then return false end
    if world.portal then
        local old = world.portal.frame
        if old and old.axis == frame.axis and old.plane == frame.plane and old.start == frame.start and old.base_y == frame.base_y then return true end
        return false
    end
    world.portal = { frame = { axis = frame.axis, plane = frame.plane, start = frame.start, base_y = frame.base_y } }
    for across = 0, 1 do
        for up = 0, 2 do
            local x, z, y = portalCellCoordinates(frame, across, up)
            world.extra_blocks[extraBlockKey(x, z, y)] = "portal"
            rebuildBlockColumn(world, x, z)
        end
    end
    return true
end

local function deactivatePortal(world)
    local frame = world and world.portal and world.portal.frame
    if not frame then return false end
    for across = 0, 1 do
        for up = 0, 2 do
            local x, z, y = portalCellCoordinates(frame, across, up)
            world.extra_blocks[extraBlockKey(x, z, y)] = nil
            rebuildBlockColumn(world, x, z)
        end
    end
    world.portal = nil
    return true
end

local function isPortalFrameBlock(frame, x, z, y)
    if not frame then return false end
    for across = 0, 3 do
        for up = 0, 4 do
            if across == 0 or across == 3 or up == 0 or up == 4 then
                local bx, bz, by = frameBlockCoordinates(frame, across, up)
                if bx == x and bz == z and by == y then return true end
            end
        end
    end
    return false
end

local function portalContains(frame, x, z)
    if not frame then return false end
    local cell_x, cell_z = math.floor(x), math.floor(z)
    if frame.axis == "x" then
        return cell_z == frame.plane and cell_x >= frame.start + 1 and cell_x <= frame.start + 2
    end
    return cell_x == frame.plane and cell_z >= frame.start + 1 and cell_z <= frame.start + 2
end

local function portalSpawn(frame, outward_sign)
    outward_sign = outward_sign or -1
    if frame.axis == "x" then
        return frame.start + 1.5, frame.plane + outward_sign * 1.5,
            outward_sign < 0 and 0 or math.pi
    end
    return frame.plane + outward_sign * 1.5, frame.start + 1.5,
        outward_sign < 0 and math.pi / 2 or math.pi * 1.5
end

local function buildNetherWorld(seed)
    seed = normalizeSeed(seed + 49381)
    local world = { size = WORLD_SIZE, seed = seed, dimension = "nether", heights = {}, materials = {},
        subsurfaces = {}, biomes = {}, extra_blocks = {}, removed_blocks = {}, mobs = {} }
    local pools = {
        { 14, 18, 4 }, { 76, 14, 5 }, { 16, 77, 4 }, { 77, 76, 5 },
        { 47, 16, 4 }, { 19, 48, 3 }, { 78, 49, 4 }, { 50, 81, 4 },
    }
    for z = 0, world.size - 1 do
        world.heights[z + 1], world.materials[z + 1], world.subsurfaces[z + 1], world.biomes[z + 1] = {}, {}, {}, {}
        for x = 0, world.size - 1 do
            local height = 4 + math.floor(hash2(seed + 1701, x, z) * 4)
            local patch = hash2(seed + 211, math.floor(x / 12), math.floor(z / 12))
            local surface = patch < 0.12 and "soul_sand" or (patch > 0.984 and "basalt" or "netherrack")
            if hash2(seed + 990, x, z) > 0.992 then surface = "magma_block" end
            if math.abs(x - 48) <= 6 and math.abs(z - 48) <= 6 then height, surface = 5, "netherrack" end
            for _, pool in ipairs(pools) do
                local dx, dz = x - pool[1], z - pool[2]
                local radius = pool[3] + (hash2(seed + 733, x, z) - 0.5) * 1.4
                if math.abs(x - 48) > 8 or math.abs(z - 48) > 8 then
                    if dx * dx + dz * dz < radius * radius then height, surface = 3, "lava"; break end
                end
            end
            world.heights[z + 1][x + 1] = height
            world.materials[z + 1][x + 1] = surface
            world.subsurfaces[z + 1][x + 1] = "netherrack"
            world.biomes[z + 1][x + 1] = patch < 0.12 and "soul_sand_valley" or (surface == "basalt" and "basalt_deltas" or "nether_wastes")
        end
    end
    -- Small ruined brick arches break up the wastes without filling the view with detail.
    for _, site in ipairs({ { 22, 24 }, { 73, 24 }, { 23, 72 }, { 74, 73 } }) do
        local cx, cz = site[1], site[2]
        for z = cz - 2, cz + 2 do
            for x = cx - 3, cx + 3 do
                if x > 2 and z > 2 and x < world.size - 3 and z < world.size - 3
                    and world.materials[z + 1][x + 1] ~= "lava" then
                    world.heights[z + 1][x + 1], world.materials[z + 1][x + 1] = 5, "netherrack"
                end
            end
        end
        for _, corner in ipairs({ { -2, -1 }, { -2, 1 }, { 2, -1 }, { 2, 1 } }) do
            local x, z = cx + corner[1], cz + corner[2]
            for y = 5, 7 do putExtraBlock(world, x, z, y, "nether_bricks") end
        end
        putExtraBlock(world, cx, cz - 1, 7, "nether_bricks")
        putExtraBlock(world, cx, cz, 7, "nether_bricks")
        putExtraBlock(world, cx, cz + 1, 7, "nether_bricks")
    end
    -- A few ceiling clusters read as glowstone without creating hundreds of costly light sources.
    for index = 1, 18 do
        local x = 5 + math.floor(hash2(seed + 5100, index, 2) * (world.size - 10))
        local z = 5 + math.floor(hash2(seed + 5200, index, 4) * (world.size - 10))
        if math.abs(x - 48) > 8 or math.abs(z - 48) > 8 then putExtraBlock(world, x, z, MAX_COLUMN_HEIGHT - 4, "glowstone") end
    end
    local frame = { axis = "x", plane = 48, start = 46, base_y = 5 }
    for across = 0, 3 do
        for up = 0, 4 do
            if across == 0 or across == 3 or up == 0 or up == 4 then
                local x, z, y = frameBlockCoordinates(frame, across, up)
                world.extra_blocks[extraBlockKey(x, z, y)] = "obsidian"
            end
        end
    end
    activatePortalFrame(world, frame)
    rebuildWorldBlocks(world)
    return world
end
-- Player session ---------------------------------------------------------------

local VoxelSession = {}
VoxelSession.__index = VoxelSession
VoxelSession.MAX_HEALTH, VoxelSession.MAX_HUNGER = 20, 20
function VoxelSession.normalizeGameMode(mode) return mode == "Creative" and "Creative" or "Survival" end
function VoxelSession.normalizeDifficulty(difficulty)
    return ({ Peaceful = true, Easy = true, Normal = true, Hard = true })[difficulty] and difficulty or "Normal"
end

local function newSlot(material, count)
    return { material = material, count = count }
end

-- A compact starter kit keeps Survival finite; Creative uses the catalogue.
local STARTING_KIT = { "planks", "dirt", "bread", "torch" }
local STARTING_COUNTS = { 16, 16, 4, 4 }
local function startingSlots(mode)
    local slots = {}
    if VoxelSession.normalizeGameMode(mode) == "Creative" then return slots end
    for index, material in ipairs(STARTING_KIT) do
        if MATERIALS[material] then slots[index] = newSlot(material, STARTING_COUNTS[index] or 1) end
    end
    return slots
end
function VoxelSession.new(seed, mode, difficulty)
    seed = normalizeSeed(seed)
    local world = buildWorld(seed)
    local player_x, player_z, yaw = findSpawn(world)
    local self = setmetatable({
        seed = seed,
        mode = VoxelSession.normalizeGameMode(mode),
        difficulty = VoxelSession.normalizeDifficulty(difficulty),
        health = VoxelSession.MAX_HEALTH,
        hunger = VoxelSession.MAX_HUNGER,
        hunger_clock = 0,
        healing_clock = 0,
        starvation_clock = 0,
        mob_attack_cooldown = 0,
        world = world,
        overworld_world = world,
        nether_world = nil,
        dimension = "overworld",
        overworld_portal_frame = nil,
        portal_cooldown = 0,
        player_x = player_x,
        player_z = player_z,
        yaw = yaw,
        pitch = 0,
        steps = 0,
        last_event = _("Ready — explore the block world."),
        canvas = nil,
        motion = nil,
        jump_offset = 0,
        jump_frame = nil,
        inventory_open = false,
        crafting_open = false,
        craft_page = 1,
        held = nil,
        slots = startingSlots(mode),
        selected_slot = 1,
        tap_action = "place",
        color_enabled = true,
        view_height = nil,
        -- Ambient world time continues while the gameplay pane is visible;
        -- terrain lighting refreshes at bounded intervals, not every mob tick.
        world_time = 0.31,
        world_ticks = 0,
        mob_clock = 0,
    }, VoxelSession)
    self:syncDerived()
    self.view_height = self:walkHeight(player_x, player_z)
    self._motionTick = function() self:tickMotion() end
    self._jumpTick = function() self:tickJump() end
    self._heldMoveTick = function() self:tickHeldMove() end
    self._ambientMobTick = function() self:tickAmbientMobs() end
    return self
end

function VoxelSession:timeOfDay()
    return (self.world_time or 0.31) % 1
end

function VoxelSession:daylight()
    return daylightForTime(self:timeOfDay())
end

function VoxelSession:timeLabel()
    return timeLabelFor(self:timeOfDay())
end

function VoxelSession:sunDirection()
    local time_of_day = self:timeOfDay()
    local _, elevation = daylightForTime(time_of_day)
    local azimuth = (time_of_day - 0.25) * TAU
    local horizontal = math.sqrt(math.max(0.001, 1 - elevation * elevation))
    return math.cos(azimuth) * horizontal, math.sin(azimuth) * horizontal, elevation
end

function VoxelSession:mobGroundAt(x, z)
    local cell_x, cell_z = math.floor(x), math.floor(z)
    local world = self.world
    if not mobCellIsClear(world, cell_x, cell_z) then return nil end
    return world.heights[cell_z + 1][cell_x + 1]
end

function VoxelSession:tickMobs()
    local world = self.world
    if not world or not world.mobs then return false end
    self.mob_clock = (self.mob_clock or 0) + 1
    local daylight = self:daylight()
    local hostile_enabled = self.mode == "Survival" and self.difficulty ~= "Peaceful"
    local changed = false
    for index, mob in ipairs(world.mobs) do
        local definition = MOB_DEFS[mob.kind]
        if definition then
            -- Mobs beyond the active ring retain their saved state but do not
            -- consume path, trig, or collision work.  The renderer uses the
            -- same 18-block ring, so they cannot visibly freeze at its edge.
            local player_dx, player_dz = self.player_x - mob.x, self.player_z - mob.z
            local nearby = player_dx * player_dx + player_dz * player_dz <= 324
            if nearby then
                local active = not mob.nocturnal or (daylight < 0.23 and (mob.kind ~= "zombie" or hostile_enabled))
                local old_x, old_z, old_y = mob.x, mob.z, mob.y
                local old_heading, old_cycle, old_bob = mob.heading, mob.walk_cycle, mob.head_bob
                if active then
                    local phase = (mob.phase or index) + self.mob_clock * (0.13 + (mob.gait or 0) * 0.05)
                    if mob.kind == "zombie" and hostile_enabled then
                        if math.abs(player_dx) + math.abs(player_dz) > 0.01 then
                            if math.atan2 then mob.heading = math.atan2(player_dx, player_dz)
                            elseif player_dz == 0 then mob.heading = player_dx >= 0 and math.pi / 2 or -math.pi / 2
                            else mob.heading = math.atan(player_dx / player_dz) + (player_dz < 0 and math.pi or 0) end
                        end
                    else
                        mob.heading = wrapAngle((mob.heading or phase) + math.sin(phase) * 0.10 + math.sin(phase * 0.41) * 0.035)
                    end
                    local speed = definition.speed * (0.72 + (mob.gait or 0) * 0.55)
                    local nx, nz = mob.x + math.sin(mob.heading) * speed, mob.z + math.cos(mob.heading) * speed
                    local next_ground = self:mobGroundAt(nx, nz)
                    if next_ground and math.abs(next_ground - (mob.y or next_ground)) <= 1 then
                        mob.x, mob.z, mob.y = nx, nz, next_ground
                    else
                        mob.heading = wrapAngle(mob.heading + math.pi * (0.55 + (mob.gait or 0) * 0.25))
                    end
                    mob.walk_cycle = (mob.walk_cycle or 0) + speed * 26
                end
                mob.head_bob = math.sin((mob.walk_cycle or 0) * 0.72) * (active and 0.035 or 0.012)
                if mob.kind == "zombie" and active and hostile_enabled and daylight < 0.23
                    and self.mob_attack_cooldown <= 0 and player_dx * player_dx + player_dz * player_dz <= 1.44 then
                    local damage = self.difficulty == "Easy" and 1 or (self.difficulty == "Hard" and 3 or 2)
                    self:takeDamage(damage, _("A zombie attacked you."))
                    self.mob_attack_cooldown = 8
                end
                if old_x ~= mob.x or old_z ~= mob.z or old_y ~= mob.y or old_heading ~= mob.heading
                    or old_cycle ~= mob.walk_cycle or old_bob ~= mob.head_bob then changed = true end
            elseif mob.head_bob ~= 0 then
                mob.head_bob = 0
                changed = true
            end
        end
    end
    self._mobs_dirty = self._mobs_dirty or changed
    return changed
end
function VoxelSession:takeDamage(amount, reason)
    if self.mode ~= "Survival" or self.difficulty == "Peaceful" then return false end
    self.health = math.max(0, (self.health or VoxelSession.MAX_HEALTH) - math.max(1, math.floor(tonumber(amount) or 1)))
    if self.health <= 0 then
        local died_in_nether = self.dimension == "nether"
        if died_in_nether then self.nether_world = self.world end
        self.world, self.dimension = self.overworld_world or self.world, "overworld"
        self.player_x, self.player_z, self.yaw = findSpawn(self.world)
        self.view_height = self:walkHeight(self.player_x, self.player_z)
        self.health, self.hunger = VoxelSession.MAX_HEALTH, 10
        self.motion, self.live_look, self.portal_cooldown = nil, false, 0
        self.last_event = _("You were defeated and respawned. Your inventory was kept.")
    else
        self.last_event = reason or _("You took damage.")
    end
    self:refreshWorldStatus()
    return true
end
function VoxelSession:eatSelectedFood()
    local item = self.slots[self.selected_slot]
    if not item or item.material ~= "bread" then
        self.last_event = _("Select bread to eat.")
        return false
    end
    if self.mode == "Creative" then
        self.last_event = _("Creative mode has no hunger.")
        return false
    end
    if self.hunger >= VoxelSession.MAX_HUNGER then
        self.last_event = _("You are not hungry yet.")
        return false
    end
    item.count = item.count - 1
    if item.count <= 0 then self.slots[self.selected_slot] = nil end
    self.hunger = math.min(VoxelSession.MAX_HUNGER, self.hunger + 7)
    self:syncDerived()
    self.last_event = _("Ate bread. Hunger restored.")
    self:refreshWorldStatus()
    return true
end
function VoxelSession:updateSurvival(amount)
    local old_health, old_hunger = self.health, self.hunger
    if self.mode ~= "Survival" then
        self.health, self.hunger = VoxelSession.MAX_HEALTH, VoxelSession.MAX_HUNGER
        return old_health ~= self.health or old_hunger ~= self.hunger
    end
    if self.difficulty == "Peaceful" then
        self.hunger = VoxelSession.MAX_HUNGER
        self.healing_clock = (self.healing_clock or 0) + amount
        if self.healing_clock >= 10 then
            self.healing_clock = self.healing_clock - 10
            self.health = math.min(VoxelSession.MAX_HEALTH, (self.health or VoxelSession.MAX_HEALTH) + 1)
        end
        self.hunger_clock, self.starvation_clock = 0, 0
        return old_health ~= self.health or old_hunger ~= self.hunger
    end
    self.hunger_clock = (self.hunger_clock or 0) + amount
    while self.hunger_clock >= 16 do
        self.hunger_clock = self.hunger_clock - 16
        self.hunger = math.max(0, (self.hunger or VoxelSession.MAX_HUNGER) - 1)
    end
    if self.hunger >= 18 and self.health < VoxelSession.MAX_HEALTH then
        self.healing_clock = (self.healing_clock or 0) + amount
        if self.healing_clock >= 12 then
            self.healing_clock = self.healing_clock - 12
            self.health = math.min(VoxelSession.MAX_HEALTH, self.health + 1)
            self.hunger = math.max(0, self.hunger - 1)
        end
    else
        self.healing_clock = 0
    end
    if self.hunger <= 0 then
        self.starvation_clock = (self.starvation_clock or 0) + amount
        if self.starvation_clock >= 12 then
            self.starvation_clock = self.starvation_clock - 12
            self:takeDamage(1, _("You are starving. Eat bread."))
        end
    else
        self.starvation_clock = 0
    end
    return old_health ~= self.health or old_hunger ~= self.hunger
end
function VoxelSession:advanceEnvironment(amount)
    amount = tonumber(amount) or DAY_TICK_PER_ACTION
    if amount <= 0 then return end
    self.world_ticks = (self.world_ticks or 0) + amount
    self.world_time = ((self.world_time or 0.31) + amount / DAY_LENGTH_TICKS) % 1
    self.portal_cooldown = math.max(0, (self.portal_cooldown or 0) - amount)
    self.mob_attack_cooldown = math.max(0, (self.mob_attack_cooldown or 0) - amount)
    local status_changed = self:updateSurvival(amount)
    self:tickMobs()
    if status_changed or self._last_status_time_label ~= self:timeLabel() then self:refreshWorldStatus() end
end

-- Ambient entities keep moving even when the player is standing still.
function VoxelSession:tickAmbientMobs()
    if not self.world then return end
    self:advanceEnvironment(0.55)
    local canvas = self.canvas
    -- A full E-Ink repaint during a finger pan, walk, jump, or modal competes
    -- with input and provides no useful intermediate frame.  Keep the dirty
    -- bit: the first idle ambient cycle (or normal scene draw) catches up.
    local cache = canvas and canvas._terrain_cache
    local lighting_changed = cache and (cache.tick_bucket ~= math.floor((self.world_ticks or 0) / 8)
        or cache.time_bucket ~= math.floor(self:timeOfDay() * 24))
    if canvas and (self._mobs_dirty or lighting_changed)
        and not self.inventory_open and not self.crafting_open
        and not self.motion and not self.jump_frame and not self.live_look then
        canvas._mob_refresh_request = true
        canvas:refreshFast()
    end
    UIManager:scheduleIn(AMBIENT_MOB_SECONDS, self._ambientMobTick)
end
function VoxelSession:startAmbientMobs()
    UIManager:unschedule(self._ambientMobTick)
    UIManager:scheduleIn(AMBIENT_MOB_SECONDS, self._ambientMobTick)
end

function VoxelSession:stopAmbientMobs()
    UIManager:unschedule(self._ambientMobTick)
end

-- Inventory -------------------------------------------------------------------

-- The hotbar and the material counters are derived views of the 36 real slots,
-- so existing callers keep working while every change flows through one model.
function VoxelSession:syncDerived()
    local hotbar = {}
    for slot = 1, HOTBAR_SLOTS do
        local item = self.slots[slot]
        hotbar[slot] = item and item.material or nil
    end
    self.hotbar = hotbar
    local counts = {}
    local used = 0
    for slot = 1, INVENTORY_SLOTS do
        local item = self.slots[slot]
        if item then
            counts[item.material] = (counts[item.material] or 0) + item.count
            used = used + 1
        end
    end
    if self.held then counts[self.held.material] = (counts[self.held.material] or 0) + self.held.count end
    self.inventory = counts
    self.used_slots = used
    return self.hotbar, self.inventory
end

function VoxelSession:countMaterial(material)
    local total = 0
    for slot = 1, INVENTORY_SLOTS do
        local item = self.slots[slot]
        if item and item.material == material then total = total + item.count end
    end
    return total
end

function VoxelSession:addItem(material, count)
    count = math.floor(tonumber(count) or 0)
    if not material or not MATERIALS[material] or count <= 0 then return count end
    local remaining = count
    for slot = 1, INVENTORY_SLOTS do
        local item = self.slots[slot]
        if item and item.material == material and item.count < STACK_LIMIT then
            local moved = math.min(STACK_LIMIT - item.count, remaining)
            item.count = item.count + moved
            remaining = remaining - moved
            if remaining <= 0 then break end
        end
    end
    for slot = 1, INVENTORY_SLOTS do
        if remaining <= 0 then break end
        if not self.slots[slot] then
            local moved = math.min(STACK_LIMIT, remaining)
            self.slots[slot] = newSlot(material, moved)
            remaining = remaining - moved
        end
    end
    self:syncDerived()
    return remaining
end

function VoxelSession:takeMaterial(material, count)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then return true end
    if self:countMaterial(material) < count then return false end
    local remaining = count
    -- Storage is consumed from the back so the hotbar stays ready for building.
    for slot = INVENTORY_SLOTS, 1, -1 do
        if remaining <= 0 then break end
        local item = self.slots[slot]
        if item and item.material == material then
            local taken = math.min(item.count, remaining)
            item.count = item.count - taken
            remaining = remaining - taken
            if item.count <= 0 then self.slots[slot] = nil end
        end
    end
    self:syncDerived()
    return true
end

-- Bedrock-style cursor stack: tap picks a stack up, the next tap stores it.
function VoxelSession:pickSlot(slot)
    slot = math.floor(tonumber(slot) or 0)
    if slot < 1 or slot > INVENTORY_SLOTS then return "invalid" end
    local item = self.slots[slot]
    if self.held then
        if not item then
            self.slots[slot], self.held = self.held, nil
            self:syncDerived()
            self.last_event = _("Stack placed.")
            return "placed"
        end
        if item.material == self.held.material then
            local room = STACK_LIMIT - item.count
            if room <= 0 then
                self.last_event = _("This stack is full.")
                return "full"
            end
            local moved = math.min(room, self.held.count)
            item.count = item.count + moved
            self.held.count = self.held.count - moved
            if self.held.count <= 0 then self.held = nil end
            self:syncDerived()
            self.last_event = _("Stacks merged.")
            return "merged"
        end
        self.slots[slot], self.held = self.held, item
        self:syncDerived()
        self.last_event = _("Stacks swapped.")
        return "swapped"
    end
    if item then
        self.held = item
        self.slots[slot] = nil
        self:syncDerived()
        self.last_event = _("Picked up: ") .. materialLabel(item.material)
        return "picked"
    end
    self.last_event = _("Empty slot.")
    return "empty"
end

function VoxelSession:returnHeld()
    if not self.held then return true end
    local leftover = self:addItem(self.held.material, self.held.count)
    if leftover <= 0 then
        self.held = nil
    else
        self.held.count = leftover
    end
    self:syncDerived()
    return self.held == nil
end

function VoxelSession:selectSlot(slot)
    slot = math.floor(tonumber(slot) or 0)
    if slot < 1 or slot > HOTBAR_SLOTS then return false end
    self.selected_slot = slot
    local item = self.slots[slot]
    self.last_event = item and (materialLabel(item.material) .. " ×" .. item.count) or _("This hotbar slot is empty.")
    return true
end

function VoxelSession:selectedMaterial()
    local item = self.slots[self.selected_slot]
    return item and item.material or nil
end

function VoxelSession:toggleInventory()
    self.inventory_open = not self.inventory_open
    if self.inventory_open then
        self:stopHeldMove()
        self.crafting_open = false
        local selected_item = self.slots[self.selected_slot]
        self.inventory_item_label = selected_item and materialLabel(selected_item.material) or nil
        self.last_event = _("Inventory opened.")
    else
        self:returnHeld()
        self.last_event = _("Inventory closed.")
        self:refreshWorldStatus()
    end
    return self.inventory_open
end

function VoxelSession:openCrafting()
    self:returnHeld()
    self.inventory_open, self.crafting_open = false, true
    self.craft_page = 1
    self.last_event = _("Crafting table opened.")
    return true
end

function VoxelSession:closeOverlays()
    self:returnHeld()
    self.inventory_open, self.crafting_open = false, false
    self:refreshWorldStatus()
    return true
end

-- Crafting --------------------------------------------------------------------

function VoxelSession:pageCount()
    return RECIPE_PAGES
end

function VoxelSession:recipesForPage(page)
    page = clamp(math.floor(tonumber(page) or 1), 1, RECIPE_PAGES)
    local list = {}
    local first = (page - 1) * CRAFT_ROWS_PER_PAGE + 1
    for index = first, math.min(#RECIPES, first + CRAFT_ROWS_PER_PAGE - 1) do
        list[#list + 1] = { index = index, recipe = RECIPES[index] }
    end
    return list
end

function VoxelSession:canCraft(recipe)
    if not recipe then return false end
    for _, ingredient in ipairs(recipe.ingredients) do
        if self:countMaterial(ingredient[1]) < ingredient[2] then return false end
    end
    return true
end

function VoxelSession:craft(index)
    index = math.floor(tonumber(index) or 0)
    local recipe = RECIPES[index]
    if not recipe then return false end
    if not self:canCraft(recipe) then
        self.last_event = _("This recipe is missing ingredients.")
        return false
    end
    for _, ingredient in ipairs(recipe.ingredients) do self:takeMaterial(ingredient[1], ingredient[2]) end
    local leftover = self:addItem(recipe.result[1], recipe.result[2])
    self.last_event = leftover > 0
        and _("The result no longer fits in the inventory.")
        or (materialLabel(recipe.result[1]) .. " ×" .. recipe.result[2] .. " " .. _("hergestellt."))
    return true
end

function VoxelSession:recipeLabel(recipe)
    if not recipe then return "" end
    local parts = {}
    for _, ingredient in ipairs(recipe.ingredients) do
        parts[#parts + 1] = MATERIAL_LABELS[ingredient[1]] .. " " .. self:countMaterial(ingredient[1]) .. "/" .. ingredient[2]
    end
    return materialLabel(recipe.result[1]) .. " ×" .. recipe.result[2] .. "  ·  " .. table.concat(parts, " + ")
end

-- World interaction ------------------------------------------------------------

function VoxelSession:ignitePortal(target)
    local item = self.slots[self.selected_slot]
    if not item or item.material ~= "flint_and_steel" then return false end
    local frame = findPortalFrame(self.world, target)
    if not frame then
        self.last_event = _("Build a complete 4x5 obsidian frame and use the lighter on it.")
        return false
    end
    if not activatePortalFrame(self.world, frame) then
        self.last_event = _("This world already has an active portal.")
        return false
    end
    if self.dimension == "overworld" then self.overworld_portal_frame = self.world.portal.frame end
    self.last_event = _("The Nether portal is active. Walk into it to travel.")
    return true
end

function VoxelSession:travelDimension(destination)
    if destination == self.dimension then return false end
    local frame
    if destination == "nether" and self.dimension == "overworld" then
        if not self.world.portal then return false end
        self.overworld_world = self.world
        self.overworld_portal_frame = self.world.portal.frame
        if not self.nether_world then self.nether_world = buildNetherWorld(self.seed) end
        self.world, self.dimension = self.nether_world, "nether"
        frame = self.world.portal.frame
    elseif destination == "overworld" and self.dimension == "nether" then
        self.nether_world = self.world
        self.world, self.dimension = self.overworld_world, "overworld"
        frame = self.overworld_portal_frame
    else
        return false
    end
    if not frame then return false end
    self.player_x, self.player_z, self.yaw = portalSpawn(frame, -1)
    self.motion, self.live_look = nil, false
    self.view_height = self:walkHeight(self.player_x, self.player_z)
    self.portal_cooldown = 0.55
    self.last_event = destination == "nether" and _("Entered The Nether.") or _("Returned to the Overworld.")
    self:refreshWorldStatus()
    if self.canvas then self.canvas:refreshFast() end
    return true
end

function VoxelSession:checkPortalTravel()
    if (self.portal_cooldown or 0) > 0 or not self.world.portal then return false end
    if not portalContains(self.world.portal.frame, self.player_x, self.player_z) then return false end
    return self:travelDimension(self.dimension == "overworld" and "nether" or "overworld")
end

function VoxelSession:statusText()
    local text = _("Seed: ") .. tostring(self.seed) .. " · " .. self:biomeName() .. " · " .. self:timeLabel() .. " · " .. _(self.mode)
    if self.mode == "Survival" then
        text = text .. " · HP " .. tostring(self.health or VoxelSession.MAX_HEALTH) .. "/20 · Food " .. tostring(self.hunger or VoxelSession.MAX_HUNGER) .. "/20"
    else
        text = text .. " · " .. _("Unlimited blocks")
    end
    return text
end
function VoxelSession:refreshWorldStatus()
    local widget = self.world_status_widget
    if not widget then return false end
    widget.text = self:statusText()
    self._last_status_time_label = self:timeLabel()
    if self.inventory_open or self.crafting_open then return false end
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    local x, y = widget._origin_x or 0, widget._origin_y or 0
    UIManager:widgetRepaint(widget, x, y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = x, y = y, w = widget._refresh_width or 200, h = widget._refresh_height or scale(16) })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    return true
end

function VoxelSession:walkHeight(x, z)
    local cell_x, cell_z = math.floor(x), math.floor(z)
    local world = self.world
    if cell_x < 0 or cell_z < 0 or cell_x >= world.size or cell_z >= world.size then return 0 end
    if world.portal and portalContains(world.portal.frame, x, z) then return world.portal.frame.base_y + 1 end
    for level = MAX_COLUMN_HEIGHT - 1, 0, -1 do
        local material = blockAt(world, cell_x, cell_z, level)
        if material and material ~= "portal" then return level + 1 end
    end
    return 0
end

function VoxelSession:groundHeightAtPlayer()
    if self.view_height then return self.view_height end
    return self:walkHeight(self.player_x, self.player_z)
end

function VoxelSession:biomeName()
    if self.dimension == "nether" then return _("The Nether") end
    local biome = biomeAt(self.world, math.floor(self.player_x), math.floor(self.player_z))
    return (BIOMES[biome] and BIOMES[biome].label) or tostring(biome)
end

function VoxelSession:newWorld(seed, mode, difficulty)
    if self.motion then UIManager:unschedule(self._motionTick) end
    if self.jump_frame then UIManager:unschedule(self._jumpTick) end
    self.mode = VoxelSession.normalizeGameMode(mode or self.mode)
    self.difficulty = VoxelSession.normalizeDifficulty(difficulty or self.difficulty)
    if seed == nil then self.seed = nextWorldSeed(self.seed) else self.seed = normalizeSeed(seed) end
    self.world = buildWorld(self.seed)
    self.overworld_world, self.nether_world = self.world, nil
    self.dimension, self.overworld_portal_frame, self.portal_cooldown = "overworld", nil, 0
    self.player_x, self.player_z, self.yaw = findSpawn(self.world)
    self.pitch = 0
    self.motion, self.jump_frame, self.jump_offset = nil, nil, 0
    self.steps = 0
    self.world_time, self.world_ticks, self.mob_clock = 0.31, 0, 0
    self.health, self.hunger = VoxelSession.MAX_HEALTH, VoxelSession.MAX_HUNGER
    self.hunger_clock, self.healing_clock, self.starvation_clock, self.mob_attack_cooldown = 0, 0, 0, 0
    self.slots, self.held, self.selected_slot = startingSlots(self.mode), nil, 1
    self:syncDerived()
    self.view_height = self:walkHeight(self.player_x, self.player_z)
    self.last_event = _("New ") .. _(self.mode) .. _(" world created. Seed: ") .. tostring(self.seed)
    return true
end

function VoxelSession:mineBlock(target)
    if self:selectedMaterial() == "flint_and_steel" then return self:ignitePortal(target) end
    if type(target) ~= "table" then self.last_event = _("There is no block here."); return false end
    local x, z, y = target.x, target.z, target.y
    if type(x) ~= "number" or type(z) ~= "number" or type(y) ~= "number"
        or x < 0 or z < 0 or x >= self.world.size or z >= self.world.size
        or y < 0 or y >= MAX_COLUMN_HEIGHT then
        self.last_event = _("There is no block here.")
        return false
    end
    local material = blockAt(self.world, x, z, y)
    if not material then self.last_event = _("There is no block here."); return false end
    if material == "portal" then self.last_event = _("Break the obsidian frame to deactivate the portal."); return false end
    if material == "obsidian" and self.world.portal and isPortalFrameBlock(self.world.portal.frame, x, z, y) then deactivatePortal(self.world) end
    local key = extraBlockKey(x, z, y)
    if self.world.extra_blocks[key] then
        self.world.extra_blocks[key] = nil
    else
        self.world.removed_blocks = self.world.removed_blocks or {}
        self.world.removed_blocks[key] = true
        local height = heightAt(self.world, x, z)
        if y == height - 1 then
            -- Lower the terrain cap and expose the block below it. Deeper holes
            -- stay individual removals inside the voxel map.
            local exposed = rawBlockAt(self.world, x, z, y - 1)
            self.world.heights[z + 1][x + 1] = y
            self.world.materials[z + 1][x + 1] = exposed or "stone"
            self.world.removed_blocks[key] = nil
        end
    end
    rebuildBlockColumn(self.world, x, z)
    local drop = DROPS[material] or material
    local leftover = self.mode == "Creative" and 0 or self:addItem(drop, 1)
    self.last_event = self.mode == "Creative" and (_("Removed: ") .. materialLabel(material))
        or (leftover > 0 and _("The inventory is full.") or (_("Mined: ") .. materialLabel(drop)))
    self.view_height = self:walkHeight(self.player_x, self.player_z)
    self:advanceEnvironment(0.55)
    return true
end

function VoxelSession:placeBlock(target)
    if type(target) ~= "table" then self.last_event = _("No target selected."); return false end
    -- Bedrock places against the touched face: the caller passes the tagged
    -- block and we fill the free cell in front of its normal. Plain x/y/z
    -- targets are accepted as well (that cell is then the destination).
    local x, z, y = target.place_x or target.x, target.place_z or target.z, target.place_y or target.y
    if type(x) ~= "number" or type(z) ~= "number" or type(y) ~= "number"
        or x < 1 or z < 1 or x >= self.world.size - 1 or z >= self.world.size - 1
        or y < 0 or y >= MAX_COLUMN_HEIGHT then
        self.last_event = _("A block cannot be placed here.")
        return false
    end
    local item = self.slots[self.selected_slot]
    if not item or item.count <= 0 then
        self.last_event = _("There is no block in this hotbar slot.")
        return false
    end
    local material = item.material
    if material == "bread" then return self:eatSelectedFood() end
    if material == "flint_and_steel" then return self:ignitePortal(target) end
    if self.dimension == "nether" and material == "water" then
        self.last_event = _("Water evaporates in The Nether.")
        return false
    end
    if blockAt(self.world, x, z, y) then self.last_event = _("This space is already occupied."); return false end
    -- Never trap the player inside a placed block, just like Bedrock.
    local cell_x, cell_z = math.floor(self.player_x), math.floor(self.player_z)
    local feet = math.floor(self:groundHeightAtPlayer())
    if x == cell_x and z == cell_z and (y == feet or y == feet + 1) then
        self.last_event = _("You are standing here.")
        return false
    end
    self.world.extra_blocks = self.world.extra_blocks or {}
    self.world.removed_blocks = self.world.removed_blocks or {}
    local key = extraBlockKey(x, z, y)
    self.world.extra_blocks[key] = material
    self.world.removed_blocks[key] = nil
    rebuildBlockColumn(self.world, x, z)
    if self.mode ~= "Creative" then item.count = item.count - 1 end
    if self.mode ~= "Creative" and item.count <= 0 then
        self.slots[self.selected_slot] = nil
        -- Bedrock moves the next matching stack into the emptied hand slot.
        for slot = HOTBAR_SLOTS + 1, INVENTORY_SLOTS do
            local other = self.slots[slot]
            if other and other.material == material then
                self.slots[self.selected_slot], self.slots[slot] = other, nil
                break
            end
        end
    end
    self:syncDerived()
    self.last_event = _("Placed: ") .. materialLabel(material)
    self:advanceEnvironment(0.55)
    return true
end

function VoxelSession:jump()
    if self.jump_frame then return false end
    self.jump_frame = 0
    self.last_event = _("Jump!")
    self:advanceEnvironment(0.25)
    UIManager:scheduleIn(MOVE_FRAME_SECONDS, self._jumpTick)
    return true
end

function VoxelSession:tickJump()
    if self.jump_frame == nil then return end
    self.jump_frame = self.jump_frame + 1
    local progress = self.jump_frame / 8
    self.jump_offset = math.max(0, math.sin(progress * math.pi) * 0.72)
    if self.canvas then self.canvas:refreshFast() end
    if self.jump_frame >= 8 then
        self.jump_frame, self.jump_offset = nil, 0
    else
        UIManager:scheduleIn(MOVE_FRAME_SECONDS, self._jumpTick)
    end
end

local function performHeldStep(session, action)
    local changed
    -- Finish each held forward/back step synchronously. This avoids a second
    -- repeat callback arriving while the animated motion is still in flight.
    if action == "forward" then
        changed = session:move(1)
    elseif action == "back" then
        changed = session:move(-1)
    else
        changed = session:act(action)
    end
    if changed and session.canvas then session.canvas:refreshFast() end
    return changed
end

function VoxelSession:tickHeldMove()
    local action = self.held_move_action
    if not action then return end
    performHeldStep(self, action)
    UIManager:scheduleIn(HELD_MOVE_SECONDS, self._heldMoveTick)
end

function VoxelSession:startHeldMove(action)
    if action ~= "forward" and action ~= "back" and action ~= "left" and action ~= "right" then return false end
    -- KOReader can report both hold and many pan samples for one continuous
    -- contact. The timer already owns repeats; re-starting the same direction
    -- here would synchronously move and redraw on every sample (and can crash
    -- slower E-Ink devices).
    if self.held_move_action == action then return true end
    UIManager:unschedule(self._heldMoveTick)
    self.held_move_action = action
    self.motion = nil
    UIManager:unschedule(self._motionTick)
    performHeldStep(self, action)
    UIManager:scheduleIn(HELD_MOVE_SECONDS, self._heldMoveTick)
    return true
end

function VoxelSession:stopHeldMove()
    self.held_move_action = nil
    UIManager:unschedule(self._heldMoveTick)
    -- A release must never leave a partially animated step armed for the next
    -- press. The next press starts from the current completed position.
    if self.motion then
        self.motion = nil
        self.live_look = false
        UIManager:unschedule(self._motionTick)
        self.view_height = self:walkHeight(self.player_x, self.player_z)
    end
end

function VoxelSession:turn(direction)
    self.yaw = wrapAngle(self.yaw + direction * TURN_ANGLE)
    self:advanceEnvironment(0.20)
    self.last_event = direction < 0 and _("Turned left.") or _("Turned right.")
    return true
end

function VoxelSession:lookVertical(direction)
    self.pitch = math.max(-1.35, math.min(1.35, self.pitch + direction * 0.14))
    self.last_event = direction > 0 and _("Looking up.") or _("Looking down.")
    return true
end

-- Finger-look uses the actual movement delta instead of quantising a swipe to
-- a fixed 20-degree turn. This is deliberately separate from the button-sized
-- turn/vertical controls so keyboard and D-pad behavior stay unchanged.
function VoxelSession:lookDelta(delta_x, delta_y)
    delta_x, delta_y = tonumber(delta_x) or 0, tonumber(delta_y) or 0
    if delta_x == 0 and delta_y == 0 then return false end
    self.yaw = wrapAngle(self.yaw + delta_x * LOOK_YAW_PER_PIXEL)
    self.pitch = math.max(-1.35, math.min(1.35, self.pitch - delta_y * LOOK_PITCH_PER_PIXEL))
    self.last_event = _("Look around")
    return true
end

local function numericMoveDirection(direction)
    if direction == "forward" then return 1 end
    if direction == "back" then return -1 end
    if type(direction) ~= "number" then return nil end
    if direction > 0 then return 1 end
    if direction < 0 then return -1 end
    return nil
end

function VoxelSession:beginMove(direction)
    direction = numericMoveDirection(direction)
    if not direction then return false end
    if self.motion then return false end
    local next_x = self.player_x + math.sin(self.yaw) * WALK_DISTANCE * direction
    local next_z = self.player_z + math.cos(self.yaw) * WALK_DISTANCE * direction
    -- Keep the camera away from the outside edge. It prevents rays crossing the
    -- world boundary from becoming a noisy, empty horizon.
    if next_x < 1 or next_z < 1 or next_x >= self.world.size - 1 or next_z >= self.world.size - 1 then
        self.last_event = _("World boundary reached.")
        return false
    end
    local to_height = self:walkHeight(next_x, next_z)
    if self.mode ~= "Creative" and blockAt(self.world, math.floor(next_x), math.floor(next_z), to_height - 1) == "lava" then
        self.last_event = _("Lava blocks the way — build a bridge.")
        return false
    end
    local from_height = self:groundHeightAtPlayer()
    local step = to_height - from_height
    if step > 2 then
        self.last_event = _("This block is too high.")
        return false
    end
    self.live_look = true
    self.motion = {
        from_x = self.player_x, from_z = self.player_z,
        to_x = next_x, to_z = next_z,
        from_height = from_height, to_height = to_height,
        frame = 0,
    }
    self.steps = self.steps + 1
    self:advanceEnvironment(DAY_TICK_PER_ACTION)
    self.last_event = direction > 0 and _("Forward.") or _("Backward.")
    -- Bedrock's default auto-jump climbs a two-block wall without a jump button.
    if step >= 2 then self:jump() end
    UIManager:unschedule(self._motionTick)
    UIManager:scheduleIn(MOVE_FRAME_SECONDS, self._motionTick)
    return true
end

function VoxelSession:tickMotion()
    local motion = self.motion
    if not motion then return end
    motion.frame = motion.frame + 1
    local t = math.min(1, motion.frame / MOVE_FRAMES)
    t = t * t * (3 - 2 * t)
    self.player_x = motion.from_x + (motion.to_x - motion.from_x) * t
    self.player_z = motion.from_z + (motion.to_z - motion.from_z) * t
    self.view_height = motion.from_height + (motion.to_height - motion.from_height) * t
    if self.canvas then self.canvas:refreshFast() end
    if motion.frame >= MOVE_FRAMES then
        self.motion = nil
        self.live_look = false
        self.view_height = self:walkHeight(self.player_x, self.player_z)
        if self:checkPortalTravel() then return end
        if self.canvas then self.canvas:refreshFast() end
    else
        UIManager:scheduleIn(MOVE_FRAME_SECONDS, self._motionTick)
    end
end

-- A non-animated single step, used by tests and by explicit keyboard repeats.
function VoxelSession:move(direction)
    direction = numericMoveDirection(direction)
    if not direction or not self:beginMove(direction) then return false end
    local motion = self.motion
    if not motion then return true end
    self.motion = nil
    self.live_look = false
    UIManager:unschedule(self._motionTick)
    self.player_x, self.player_z = motion.to_x, motion.to_z
    self.view_height = self:walkHeight(self.player_x, self.player_z)
    self:checkPortalTravel()
    return true
end

function VoxelSession:toggleTapAction()
    if self.tap_action == "place" then
        self.tap_action = "mine"
        self.last_event = _("Tap to mine, hold to place blocks.")
    else
        self.tap_action = "place"
        self.last_event = _("Tap to place blocks, hold to mine.")
    end
    return true
end

function VoxelSession:tapActionLabel()
    return self.tap_action == "place" and _("Tap: Place") or _("Tap: Mine")
end

function VoxelSession:tapAction(target)
    if self:selectedMaterial() == "flint_and_steel" then return self:ignitePortal(target) end
    if self:selectedMaterial() == "bread" then return self:eatSelectedFood() end
    if self.tap_action == "place" then return self:placeBlock(target) end
    return self:mineBlock(target)
end

function VoxelSession:holdAction(target)
    if self.tap_action == "place" then return self:mineBlock(target) end
    return self:placeBlock(target)
end

function VoxelSession:toggleColor()
    -- Do not probe the panel or constructor from inside the DApp. KOReader's
    -- standard setting is the sole switch; false means use monochrome.
    if not colorRenderingEnabled() then
        self.color_enabled = false
        self.last_event = _("KOReader color rendering is disabled or unavailable.")
        return false
    end
    self.color_enabled = not self.color_enabled
    self.last_event = self.color_enabled and _("Color rendering enabled.") or _("Monochrome rendering enabled.")
    return true
end

function VoxelSession:act(action, target)
    if action == "left" then return self:turn(-1) end
    if action == "right" then return self:turn(1) end
    if action == "forward" then return self:beginMove(1) end
    if action == "back" then return self:beginMove(-1) end
    if action == "jump" then return self:jump() end
    if action == "mine" then return self:mineBlock(target) end
    if action == "place" then return self:placeBlock(target) end
    if action == "tap" then return self:tapAction(target) end
    if action == "hold" then return self:holdAction(target) end
    if action == "inventory" then return self:toggleInventory() end
    if action == "crafting" then return self:openCrafting() end
    if action == "mode" then return self:toggleTapAction() end
    if action == "color" then return self:toggleColor() end
    return false
end

-- The renderer is a hard-edged per-ray voxel DDA. Each screen cell walks the
-- block grid, projects the hit surface and shades the material with its
-- procedural 8x8 texture level, so movement only redraws the game canvas.
local VoxelCanvas = InputContainer:extend{
    session = nil,
    width = nil,
    height = nil,
    dimen = nil,
    _origin_x = 0,
    _origin_y = 0,
    _look_pan_last = nil,
}

function VoxelCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapMinecraftExplore = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeMinecraftLook = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        PanMinecraftLook = { GestureRange:new{ ges = "pan", range = self.dimen, rate = 8 } },
        PanReleaseMinecraftLook = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        HoldMinecraftAction = { GestureRange:new{ ges = "hold", range = self.dimen } },
        HoldReleaseMinecraftAction = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
    }
end

function VoxelCanvas:projectPoint(wx, wz, wy, session, origin_x, origin_y)
    local camera_y = session:groundHeightAtPlayer() + PLAYER_EYE_HEIGHT + (session.jump_offset or 0)
    local dx, dz, dy = wx - session.player_x, wz - session.player_z, wy - camera_y
    local cp, sp = math.cos(session.pitch or 0), math.sin(session.pitch or 0)
    local cy, sy = math.cos(session.yaw), math.sin(session.yaw)
    local forward_x, forward_z, forward_y = sy * cp, cy * cp, sp
    local right_x, right_z = cy, -sy
    local up_x, up_z, up_y = -sy * sp, -cy * sp, cp
    local depth = dx * forward_x + dz * forward_z + dy * forward_y
    local lateral = dx * right_x + dz * right_z
    local vertical = dx * up_x + dz * up_z + dy * up_y
    if depth < 0.2 then depth = 0.2 end
    local focal = (self.width / 2) / math.tan(math.rad(90) / 2)
    return origin_x + self.width / 2 + lateral * focal / depth,
        origin_y + self.height / 2 - vertical * focal / depth
end

function VoxelCanvas:_stroke(bb, first, second, thickness)
    -- A thin selection line is UI, not another chunky terrain sample.
    local dx, dy = second[1] - first[1], second[2] - first[2]
    thickness = thickness or 2
    local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) / thickness))
    local ox, oy = self._origin_x or 0, self._origin_y or 0
    for step = 0, steps do
        local ratio = step / steps
        local px, py = math.floor(first[1] + dx * ratio), math.floor(first[2] + dy * ratio)
        local clip = self._mob_clip or { x = ox, y = oy, w = self.width, h = self.height }
        local left, top = math.max(px, clip.x), math.max(py, clip.y)
        local right, bottom = math.min(px + thickness, clip.x + clip.w), math.min(py + thickness, clip.y + clip.h)
        if right > left and bottom > top then bb:paintRect(left, top, right - left, bottom - top, Blitbuffer.COLOR_BLACK) end
    end
end

function VoxelCanvas:_fillProjectedFace(bb, points, ink, color_mode, origin_x, origin_y)
    -- projectPoint returns screen coordinates.  Convert them to this canvas'
    -- local raster grid, then add the canvas origin back to every paint.
    local cols, rows = renderGridFor(self.width, self.height, MINECRAFT_RENDER_SAMPLE)
    local cell_w, cell_h = self.width / cols, self.height / rows
    local ox, oy = origin_x or 0, origin_y or 0
    local grid = {}
    for _, point in ipairs(points) do
        grid[#grid + 1] = { x = (point[1] - ox) / cell_w, y = (point[2] - oy) / cell_h }
    end
    local min_y, max_y = grid[1].y, grid[1].y
    for _, point in ipairs(grid) do min_y, max_y = math.min(min_y, point.y), math.max(max_y, point.y) end
    for row = math.max(0, math.floor(min_y)), math.min(rows - 1, math.ceil(max_y) - 1) do
        local intersections = {}
        for index = 1, #grid do
            local a, b = grid[index], grid[index % #grid + 1]
            local scan_y = row + 0.5
            if (a.y <= scan_y and b.y > scan_y) or (b.y <= scan_y and a.y > scan_y) then
                local ratio = (scan_y - a.y) / (b.y - a.y)
                intersections[#intersections + 1] = a.x + (b.x - a.x) * ratio
            end
        end
        table.sort(intersections)
        for index = 1, #intersections - 1, 2 do
            local left, right = math.max(0, math.floor(intersections[index])), math.min(cols, math.ceil(intersections[index + 1]))
            local top, bottom = math.floor(row * cell_h), math.min(self.height, math.ceil((row + 1) * cell_h))
            if right > left and bottom > top then
                local px, py = ox + math.floor(left * cell_w), oy + top
                local pw, ph = math.floor(right * cell_w) - math.floor(left * cell_w), bottom - top
                local bounds = self._mob_draw_bounds
                if bounds then
                    bounds.x1, bounds.y1 = math.min(bounds.x1, px), math.min(bounds.y1, py)
                    bounds.x2, bounds.y2 = math.max(bounds.x2, px + pw), math.max(bounds.y2, py + ph)
                end
                local clip = self._mob_clip
                if clip then
                    local right_px, bottom_py = math.min(px + pw, clip.x + clip.w), math.min(py + ph, clip.y + clip.h)
                    px, py = math.max(px, clip.x), math.max(py, clip.y)
                    pw, ph = right_px - px, bottom_py - py
                end
                if pw > 0 and ph > 0 then
                    if color_mode and bb.paintRectRGB32 then bb:paintRectRGB32(px, py, pw, ph, ink)
                    else bb:paintRect(px, py, pw, ph, ink) end
                end
            end
        end
    end
end
local function mobInk(rgb, color_mode, brightness)
    local factor = brightness == "top" and 1 or (brightness == "side" and 0.90 or 0.80)
    if color_mode then return sceneColor(dynamicSceneColor("mob", rgb[1] * factor, rgb[2] * factor, rgb[3] * factor)) end
    local gray = math.floor(clamp((rgb[1] * 0.299 + rgb[2] * 0.587 + rgb[3] * 0.114) * factor, 34, 238) / 17 + 0.5) * 17
    return sceneColor(dynamicSceneColor("gray", gray, gray, gray))
end

local function mobShades(mob, color_mode, daylight)
    local body, face
    if mob.kind == "cow" then body, face = { 117, 86, 62 }, { 73, 59, 49 }
    elseif mob.kind == "pig" then body, face = { 225, 151, 162 }, { 237, 175, 178 }
    elseif mob.kind == "zombie" then body, face = { 81, 146, 76 }, { 76, 110, 145 }
    else body, face = { 238, 232, 213 }, { 93, 83, 72 } end
    return {
        top = mobInk(body, color_mode, "top"),
        side = mobInk(body, color_mode, "side"),
        front = mobInk(body, color_mode, "front"),
        face = mobInk(face, color_mode, "side"),
    }
end

function VoxelCanvas:_mobHasLineOfSight(session, mob)
    local world = session.world
    local ox, oz = session.player_x, session.player_z
    local oy = session:groundHeightAtPlayer() + PLAYER_EYE_HEIGHT + (session.jump_offset or 0)
    local tx, tz, ty = mob.x, mob.z, mob.y + 0.72
    local dx, dz, dy = tx - ox, tz - oz, ty - oy
    local distance = math.sqrt(dx * dx + dz * dz + dy * dy)
    if distance <= 0.1 then return true end
    local steps = math.max(2, math.ceil(distance * 3))
    -- Sample before the entity cell so a solid world voxel always hides a mob.
    for index = 1, steps - 1 do
        local fraction = index / steps
        if blockAt(world, math.floor(ox + dx * fraction), math.floor(oz + dz * fraction), math.floor(oy + dy * fraction)) then return false end
    end
    return true
end

function VoxelCanvas:_drawMobCuboid(bb, session, origin_x, origin_y, center_x, center_z, bottom, top, half_x, half_z, shades, color_mode)
    local function point(wx, wz, wy)
        local px, py = self:projectPoint(wx, wz, wy, session, origin_x, origin_y)
        return { px, py }
    end
    local camera_x = session.player_x >= center_x and 1 or -1
    local camera_z = session.player_z >= center_z and 1 or -1
    local top_face = { point(center_x-half_x, center_z-half_z, top), point(center_x+half_x, center_z-half_z, top), point(center_x+half_x, center_z+half_z, top), point(center_x-half_x, center_z+half_z, top) }
    local x_face = { point(center_x+camera_x*half_x, center_z-half_z, bottom), point(center_x+camera_x*half_x, center_z+half_z, bottom), point(center_x+camera_x*half_x, center_z+half_z, top), point(center_x+camera_x*half_x, center_z-half_z, top) }
    local z_face = { point(center_x-half_x, center_z+camera_z*half_z, bottom), point(center_x+half_x, center_z+camera_z*half_z, bottom), point(center_x+half_x, center_z+camera_z*half_z, top), point(center_x-half_x, center_z+camera_z*half_z, top) }
    self:_fillProjectedFace(bb, top_face, shades.top, color_mode, origin_x, origin_y)
    self:_fillProjectedFace(bb, x_face, shades.side, color_mode, origin_x, origin_y)
    self:_fillProjectedFace(bb, z_face, shades.front, color_mode, origin_x, origin_y)
    -- Three flat voxel faces carry the shape; outlining every edge on every
    -- limb caused hundreds of redundant E-Ink draw calls per nearby mob.
end


function VoxelCanvas:_drawMob(bb, x, y, session, mob, color_mode)
    local shades = mobShades(mob, color_mode, session:daylight())
    local definition = MOB_DEFS[mob.kind] or MOB_DEFS.sheep
    local body_x, body_z, base = mob.x, mob.z, mob.y
    local forward_x, forward_z = math.sin(mob.heading or 0), math.cos(mob.heading or 0)
    local side_x, side_z = -forward_z, forward_x
    if mob.kind == "zombie" then
        self:_drawMobCuboid(bb, session, x, y, body_x, body_z, base + 0.04, base + 0.92, 0.27, 0.20, shades, color_mode)
        self:_drawMobCuboid(bb, session, x, y, body_x, body_z, base + 0.92, base + 1.32, 0.24, 0.22, { top = shades.face, side = shades.face, front = shades.face }, color_mode)
        local stride = math.sin(mob.walk_cycle or 0) * 0.09
        for index, side in ipairs({ -1, 1 }) do
            self:_drawMobCuboid(bb, session, x, y, body_x + side_x * side * 0.14, body_z + side_z * side * 0.14, base, base + 0.47 + (index == 1 and stride or -stride), 0.07, 0.07, shades, color_mode)
            self:_drawMobCuboid(bb, session, x, y, body_x + side_x * side * 0.38 + forward_x * 0.03, body_z + side_z * side * 0.38 + forward_z * 0.03, base + 0.48, base + 0.92, 0.055, 0.055, shades, color_mode)
        end
        return
    end
    local is_cow = mob.kind == "cow"
    local is_pig = mob.kind == "pig"
    local body_half_x, body_half_z = is_cow and 0.50 or (is_pig and 0.45 or 0.46), is_cow and 0.34 or 0.32
    local body_top = base + (is_cow and 0.86 or 0.78)
    self:_drawMobCuboid(bb, session, x, y, body_x, body_z, base + 0.08, body_top, body_half_x, body_half_z, shades, color_mode)
    for index, pair in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
        local stride = math.sin((mob.walk_cycle or 0) + (index % 2) * math.pi) * 0.07
        self:_drawMobCuboid(bb, session, x, y,
            body_x + forward_x * pair[1] * 0.27 + side_x * pair[2] * 0.20,
            body_z + forward_z * pair[1] * 0.27 + side_z * pair[2] * 0.20,
            base - 0.02, base + 0.37 + stride, 0.075, 0.075, { top = shades.face, side = shades.face, front = shades.face }, color_mode)
    end
    local head_x, head_z = body_x + forward_x * (body_half_x + 0.13), body_z + forward_z * (body_half_x + 0.13)
    local head_bottom, head_top = base + 0.57 + (mob.head_bob or 0), base + (is_cow and 1.17 or 1.07) + (mob.head_bob or 0)
    self:_drawMobCuboid(bb, session, x, y, head_x, head_z, head_bottom, head_top, is_cow and 0.25 or 0.22, 0.22, { top = shades.face, side = shades.face, front = shades.face }, color_mode)
    if mob.kind == "sheep" then
        for _, side in ipairs({ -1, 1 }) do
            self:_drawMobCuboid(bb, session, x, y, head_x + side_x * side * 0.19, head_z + side_z * side * 0.19, head_top - 0.15, head_top + 0.09, 0.05, 0.05, { top = shades.face, side = shades.face, front = shades.face }, color_mode)
        end
    elseif is_cow then
        for _, side in ipairs({ -1, 1 }) do
            self:_drawMobCuboid(bb, session, x, y, head_x + side_x * side * 0.21, head_z + side_z * side * 0.21, head_top - 0.08, head_top + 0.13, 0.045, 0.045, shades, color_mode)
        end
    end
end

function VoxelCanvas:_visibleMobs(session)
    local world = session.world
    if not world or not world.mobs then return {} end
    local forward_x, forward_z = math.sin(session.yaw), math.cos(session.yaw)
    local right_x, right_z = math.cos(session.yaw), -math.sin(session.yaw)
    local daylight, nearest = session:daylight(), {}
    local select_limit, render_limit = MAX_MOBS, MAX_RENDERED_MOBS
    -- Bound candidates by the world population limit, not just the nearest
    -- six: occluded foreground animals must not hide visible animals behind.
    for order, mob in ipairs(world.mobs) do
        local dx, dz = mob.x - session.player_x, mob.z - session.player_z
        local depth, lateral = dx * forward_x + dz * forward_z, dx * right_x + dz * right_z
        if depth > 0.65 and dx * dx + dz * dz <= 324 and math.abs(lateral) < depth * 1.25
            and (not mob.nocturnal or daylight < 0.25)
            and (mob.kind ~= "zombie" or (session.mode == "Survival" and session.difficulty ~= "Peaceful")) then
            local entry, insert_at = { mob = mob, depth = depth, order = order }, #nearest + 1
            while insert_at > 1 and (depth < nearest[insert_at - 1].depth
                or (depth == nearest[insert_at - 1].depth and order < nearest[insert_at - 1].order)) do
                nearest[insert_at] = nearest[insert_at - 1]
                insert_at = insert_at - 1
            end
            nearest[insert_at] = entry
            if #nearest > select_limit then nearest[#nearest] = nil end
        end
    end
    local visible = {}
    for _, entry in ipairs(nearest) do
        if self:_mobHasLineOfSight(session, entry.mob) then
            visible[#visible + 1] = entry
            if #visible >= render_limit then break end
        end
    end
    -- Painter's order must be far to near, otherwise distant bodies cover the
    -- closer mob on the coarse E-Ink grid.
    table.sort(visible, function(a, b)
        return a.depth == b.depth and a.order > b.order or a.depth > b.depth
    end)
    return visible
end

function VoxelCanvas:_drawMobs(bb, x, y, session, color_mode, visible)
    visible = visible or self:_visibleMobs(session)
    self._mob_draw_bounds = { x1 = x + self.width, y1 = y + self.height, x2 = x, y2 = y }
    for _, entry in ipairs(visible) do self:_drawMob(bb, x, y, session, entry.mob, color_mode) end
    local bounds = self._mob_draw_bounds
    self._mob_draw_bounds = nil
    if bounds.x2 > bounds.x1 and bounds.y2 > bounds.y1 then
        self._mob_bounds = { x = bounds.x1, y = bounds.y1, w = bounds.x2 - bounds.x1, h = bounds.y2 - bounds.y1 }
    else
        self._mob_bounds = nil
    end
end
function VoxelCanvas:_drawTargetOutline(bb, x, y, session)
    local target = self:pickBlock(x + math.floor(self.width / 2), y + math.floor(self.height / 2))
    if not target then return end
    local normal_x, normal_y, normal_z = target.place_x - target.x, target.place_y - target.y, target.place_z - target.z
    local corners
    if normal_x ~= 0 then
        local face_x = normal_x > 0 and target.x + 1 or target.x
        corners = { { face_x, target.y, target.z }, { face_x, target.y + 1, target.z }, { face_x, target.y + 1, target.z + 1 }, { face_x, target.y, target.z + 1 } }
    elseif normal_z ~= 0 then
        local face_z = normal_z > 0 and target.z + 1 or target.z
        corners = { { target.x, target.y, face_z }, { target.x + 1, target.y, face_z }, { target.x + 1, target.y + 1, face_z }, { target.x, target.y + 1, face_z } }
    else
        local face_y = normal_y > 0 and target.y + 1 or target.y
        corners = { { target.x, face_y, target.z }, { target.x + 1, face_y, target.z }, { target.x + 1, face_y, target.z + 1 }, { target.x, face_y, target.z + 1 } }
    end
    local projected = {}
    for index = 1, 4 do
        local corner = corners[index]
        local screen_x, screen_y = self:projectPoint(corner[1], corner[3], corner[2], session, x, y)
        projected[index] = { screen_x, screen_y }
    end
    for index = 1, 4 do
        self:_stroke(bb, projected[index], projected[index % 4 + 1], 2)
    end
end

function VoxelCanvas:_drawCrosshair(bb, cx, cy)
    local clip = self._mob_clip
    local function line(x, y, w, h, ink)
        if clip then
            local right, bottom = math.min(x + w, clip.x + clip.w), math.min(y + h, clip.y + clip.h)
            x, y = math.max(x, clip.x), math.max(y, clip.y)
            w, h = right - x, bottom - y
        end
        if w > 0 and h > 0 then bb:paintRect(x, y, w, h, ink) end
    end
    line(cx - 6, cy - 1, 13, 3, Blitbuffer.COLOR_WHITE)
    line(cx - 1, cy - 6, 3, 13, Blitbuffer.COLOR_WHITE)
    line(cx - 5, cy, 11, 1, Blitbuffer.COLOR_BLACK)
    line(cx, cy - 5, 1, 11, Blitbuffer.COLOR_BLACK)
end

function VoxelCanvas:_drawScene(bb, x, y)
    local width, height, session = self.width, self.height, self.session
    local region, cache = self._mob_refresh_region, self._terrain_cache
    if region and cache and session and cache.world == session.world then
        self._mob_refresh_region = nil
        self._mob_clip = region
        for _, rect in ipairs(cache.rects) do
            local rx, ry = math.max(rect.x, region.x), math.max(rect.y, region.y)
            local rr, rb = math.min(rect.x + rect.w, region.x + region.w), math.min(rect.y + rect.h, region.y + region.h)
            if rr > rx and rb > ry then
                if rect.rgb and bb.paintRectRGB32 then bb:paintRectRGB32(rx, ry, rr - rx, rb - ry, rect.ink)
                else bb:paintRect(rx, ry, rr - rx, rb - ry, rect.ink) end
            end
        end
        local motion_preview = session.live_look or session.motion
        local color_mode = session.color_enabled and colorRenderingEnabled() and not motion_preview
        self:_drawMobs(bb, x, y, session, color_mode, self._mob_selected)
        self._mob_selected = nil
        local center_x, center_y = x + math.floor(width / 2), y + math.floor(height / 2)
        self:_drawCrosshair(bb, center_x, center_y)
        self:_drawTargetOutline(bb, x, y, session)
        self._mob_clip = nil
        session._mobs_dirty = false
        return
    end
    bb:paintRect(x, y, width, height, Blitbuffer.COLOR_WHITE)
    if not session then return end

    -- Fast E-Ink waveforms smear intermediate gray/RGB pixels. During a camera
    -- gesture render the exact same ray grid as a strict two-ink preview:
    -- identical geometry and ray count, but much cleaner transitions. The
    -- settled frame immediately returns to the normal color/gray material path.
    local motion_preview = session.live_look or session.motion
    local color_mode = session.color_enabled and colorRenderingEnabled() and not motion_preview
    local sample = MINECRAFT_RENDER_SAMPLE
    -- Geometry uses the same low-resolution grid in both display modes;
    -- native material tones do not require additional terrain rays.
    local cols, rows = renderGridFor(width, height, sample)
    local pixel_w, pixel_h = width / cols, height / rows
    -- The old 130° fisheye made the landscape look unlike Minecraft. A
    -- narrower 90° perspective gives recognizable block proportions.
    local fov = math.rad(90)
    local tan_half = math.tan(fov / 2)
    local aspect = height / width
    local floor, abs, min, max, sqrt = math.floor, math.abs, math.min, math.max, math.sqrt
    local world = session.world
    if not world.block_flat then rebuildWorldBlocks(world) end
    local voxel_flat, world_size = world.block_flat, world.size
    local flat_stride = world.block_flat_stride or world_size
    local flat_padding = world.block_flat_padding or 0
    local plane_size = flat_stride * flat_stride
    local player_x, player_z = session.player_x, session.player_z
    local pitch = session.pitch or 0
    local yaw = session.yaw
    local camera_y = session:groundHeightAtPlayer() + PLAYER_EYE_HEIGHT + (session.jump_offset or 0)
    local pattern_values = PATTERN_VALUES
    local scene_palette
    if world.dimension == "nether" then
        scene_palette = { daylight = 0.72, top = "black", mid = "magenta", horizon = "red",
            ground = "red", ground_dark = "black", cloud = "magenta" }
    else
        scene_palette = scenePaletteForTime(session:timeOfDay())
    end
    local daylight = scene_palette.daylight
    local light_cache, visible_lights = {}, {}
    for _, source in ipairs(world.light_sources or {}) do
        local dx, dz = source.x - player_x, source.z - player_z
        if dx * dx + dz * dz < (MAX_VIEW_DISTANCE + TORCH_LIGHT_RADIUS) ^ 2 then
            visible_lights[#visible_lights + 1] = source
        end
    end
    local function torchLightAt(wx, wz, wy)
        -- Cache illumination per half-block. Nearby rays share these cells;
        -- distant torches are rejected before the expensive square root.
        local key = floor(wx * 2) .. ":" .. floor(wz * 2) .. ":" .. floor(wy * 2)
        local cached = light_cache[key]
        if cached ~= nil then return cached end
        local strongest = 0
        for _, source in ipairs(visible_lights) do
            local dx, dz, dy = source.x - wx, source.z - wz, source.y - wy
            local distance2 = dx * dx + dz * dz + dy * dy
            if distance2 < TORCH_LIGHT_RADIUS * TORCH_LIGHT_RADIUS then
                strongest = max(strongest, (1 - sqrt(distance2) / TORCH_LIGHT_RADIUS) * (source.strength or 1))
            end
        end
        light_cache[key] = strongest
        return strongest
    end
    -- Camera directions depend on view geometry, not player position. Movement
    -- animates four redraws at the same yaw/pitch, so cache normalized rays and
    -- avoid repeating trigonometry plus one square root for every output cell.
    local ray_cache = self._ray_cache
    if not ray_cache or ray_cache.width ~= width or ray_cache.height ~= height
        or ray_cache.cols ~= cols or ray_cache.rows ~= rows
        or ray_cache.yaw ~= yaw or ray_cache.pitch ~= pitch then
        local reusable = ray_cache and ray_cache.width == width and ray_cache.height == height
            and ray_cache.cols == cols and ray_cache.rows == rows
        local ray_x = reusable and ray_cache.x or {}
        local ray_z = reusable and ray_cache.z or {}
        local ray_y = reusable and ray_cache.y or {}
        local delta_x = reusable and ray_cache.dx or {}
        local delta_z = reusable and ray_cache.dz or {}
        local delta_y = reusable and ray_cache.dy or {}
        local cp, sp = math.cos(pitch), math.sin(pitch)
        local cy, sy = math.cos(yaw), math.sin(yaw)
        local forward_x, forward_z, forward_y = sy * cp, cy * cp, sp
        local right_x, right_z = cy, -sy
        local up_x, up_z, up_y = -sy * sp, -cy * sp, cp
        for ry = 0, rows - 1 do
            local ny = (1 - (ry + 0.5) / rows * 2) * tan_half * aspect
            local row_x, row_z, row_y = up_x * ny, up_z * ny, up_y * ny
            for rx = 0, cols - 1 do
                local nx = ((rx + 0.5) / cols * 2 - 1) * tan_half
                local dir_x = forward_x + right_x * nx + row_x
                local dir_z = forward_z + right_z * nx + row_z
                local dir_y = forward_y + row_y
                local inverse_length = 1 / sqrt(dir_x * dir_x + dir_z * dir_z + dir_y * dir_y)
                local index = ry * cols + rx + 1
                dir_x, dir_z, dir_y = dir_x * inverse_length, dir_z * inverse_length, dir_y * inverse_length
                ray_x[index], ray_z[index], ray_y[index] = dir_x, dir_z, dir_y
                delta_x[index] = abs(dir_x) < 0.00001 and (dir_x < 0 and -1e30 or 1e30) or (1 / dir_x)
                delta_z[index] = abs(dir_z) < 0.00001 and (dir_z < 0 and -1e30 or 1e30) or (1 / dir_z)
                delta_y[index] = abs(dir_y) < 0.00001 and (dir_y < 0 and -1e30 or 1e30) or (1 / dir_y)
            end
        end
        ray_cache = { width = width, height = height, cols = cols, rows = rows, yaw = yaw, pitch = pitch,
            x = ray_x, z = ray_z, y = ray_y, dx = delta_x, dz = delta_z, dy = delta_y }
        self._ray_cache = ray_cache
    end
    local start_cell_x, start_cell_z, start_cell_y = floor(player_x), floor(player_z), floor(camera_y)
    local fraction_x, fraction_z, fraction_y = player_x - start_cell_x, player_z - start_cell_z, camera_y - start_cell_y
    local start_voxel_index = start_cell_y * plane_size
        + (start_cell_z + flat_padding) * flat_stride + start_cell_x + flat_padding + 1
    local ray_x, ray_z, ray_y = ray_cache.x, ray_cache.z, ray_cache.y
    local ray_dx, ray_dz, ray_dy = ray_cache.dx, ray_cache.dz, ray_cache.dy
    local terrain_spans = {}
    local function paintSpan(start_col, end_col, row, ink)
        -- Map both span boundaries independently. Deriving width from a
        -- rounded span length can leave one-pixel seams between neighbours.
        local left = x + floor(start_col * pixel_w)
        local right = x + floor(end_col * pixel_w)
        local top = y + floor(row * pixel_h)
        local bottom = y + floor((row + 1) * pixel_h)
        if right > left and bottom > top then
            if color_mode then
                -- Every ink of the color path is resolved to a real color:
                -- scene names use their sky/ground tone and palette names use
                -- their printable RGB value (including the white ink).
                local rgb_ink = SCENE_COLORS[ink] and sceneColor(ink) or paletteColor(ink)
                bb:paintRectRGB32(left, top, right - left, bottom - top, rgb_ink)
                terrain_spans[#terrain_spans + 1] = { x = left, y = top, w = right - left, h = bottom - top, ink = rgb_ink, rgb = true }
            else
                local mono_ink = SCENE_COLORS[ink] and sceneColor(ink) or ink
                bb:paintRect(left, top, right - left, bottom - top, mono_ink)
                terrain_spans[#terrain_spans + 1] = { x = left, y = top, w = right - left, h = bottom - top, ink = mono_ink }
            end
        end
    end
    -- Face tones, rather than thick black cell borders, carry voxel depth.
    for ry = 0, rows - 1 do
        local bayer_row = BAYER8[(ry % 8) + 1]
        local row_ink, row_start
        for rx = 0, cols - 1 do
            local bayer_col = rx % 8
            -- BAYER8 is 0..63 like AppDock YouTube; coverage in the material
            -- cache is 0..16, so normalize before the hot comparison.
            local dither_threshold = floor(bayer_row[bayer_col + 1] / 4)
            local index = ry * cols + rx + 1
            local dir_x, dir_z, dir_y = ray_x[index], ray_z[index], ray_y[index]
            local signed_delta_x, signed_delta_z, signed_delta_y = ray_dx[index], ray_dz[index], ray_dy[index]
            local cell_x, cell_z, cell_y = start_cell_x, start_cell_z, start_cell_y
            local voxel_index = start_voxel_index
            local step_x = signed_delta_x < 0 and -1 or 1
            local step_z = signed_delta_z < 0 and -1 or 1
            local step_y = signed_delta_y < 0 and -1 or 1
            local delta_x, delta_z, delta_y = abs(signed_delta_x), abs(signed_delta_z), abs(signed_delta_y)
            local next_x = step_x < 0 and fraction_x * delta_x or (1 - fraction_x) * delta_x
            local next_z = step_z < 0 and fraction_z * delta_z or (1 - fraction_z) * delta_z
            local next_y = step_y < 0 and fraction_y * delta_y or (1 - fraction_y) * delta_y
            local dist, side, bx, bz, by, hit_dist, hit_side, hit_material = 0, 0
            for ray_step = 1, 48 do
                local material
                if cell_y >= 0 and cell_y < MAX_COLUMN_HEIGHT then
                    material = voxel_flat[voxel_index]
                end
                if material then
                    bx, bz, by, hit_dist, hit_side, hit_material = cell_x, cell_z, cell_y, dist, side, material
                    break
                end
                if next_x < next_z and next_x < next_y then
                    dist, next_x, cell_x, side = next_x, next_x + delta_x, cell_x + step_x, 0
                    voxel_index = voxel_index + step_x
                elseif next_z < next_y then
                    dist, next_z, cell_z, side = next_z, next_z + delta_z, cell_z + step_z, 2
                    voxel_index = voxel_index + step_z * flat_stride
                else
                    dist, next_y, cell_y, side = next_y, next_y + delta_y, cell_y + step_y, 1
                    voxel_index = voxel_index + step_y * plane_size
                end
                if dist > MAX_VIEW_DISTANCE then break end
            end
            local ink
            if bx then
                local hx = player_x + dir_x * hit_dist
                local hy = camera_y + dir_y * hit_dist
                local hz = player_z + dir_z * hit_dist
                local top = hit_side == 1 and dir_y < 0
                local texture_material = hit_material
                -- Minecraft grass blocks have a green cap and brown dirt sides
                -- on both color and monochrome displays.
                if texture_material == "grass" and not top then texture_material = "dirt" end
                local pattern = pattern_values[texture_material] or pattern_values.stone
                local fu, fv
                if hit_side == 1 then
                    fu, fv = hx - floor(hx), hz - floor(hz)
                elseif hit_side == 0 then
                    fu, fv = hz - floor(hz), hy - floor(hy)
                else
                    fu, fv = hx - floor(hx), hy - floor(hy)
                end
                local u = max(0, min(7, floor(fu * 8)))
                local v = max(0, min(7, floor(fv * 8)))
                -- Green grass cap also wraps a little way down the sides.
                if hit_material == "grass" and not top and fv >= 0.80 then
                    texture_material, pattern = "grass", pattern_values.grass
                end
                local level = pattern[v * 8 + u + 1]
                -- Texture minification: distant 8x8 patterns otherwise alias
                -- into noisy checkerboards. Silhouettes keep the same low-res grid.
                if hit_dist > 7 then
                    local blend = min(1, (hit_dist - 7) / 7)
                    level = level + ((PATTERN_AVERAGES[texture_material] or 2) - level) * blend
                end
                local material_def = MATERIALS[hit_material]
                -- One gentle directional shade only. Night stays recognisable,
                -- but even unlit sides retain readable material and geometry.
                local face_light = top and 1 or (hit_side == 0 and 0.94 or 0.86)
                local daylight_light = (0.62 + daylight * 0.38) * face_light
                local torch_light = #visible_lights > 0 and torchLightAt(hx, hz, hy) or 0
                local light = (material_def and material_def.emissive) and 1 or max(torch_light, daylight_light)
                local texture_tone = 0.78 + level * 0.11
                local tone = max(0, min(15, floor((texture_tone * light - 0.30) / 0.83 * 15 + 0.5)))
                if color_mode then
                    ink = level == 0 and "black" or SURFACE_TONES[texture_material].rgb[tone + 1]
                elseif motion_preview then
                    -- Avoid gray buildup during fast waveform updates. Keep
                    -- texture detail only as a stable silhouette/value split.
                    ink = level == 0 or tone < 8 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
                else
                    ink = level == 0 and Blitbuffer.COLOR_BLACK or SURFACE_TONES[texture_material].mono[tone + 1]
                end
            elseif motion_preview then
                -- A white sky and black ground/horizon are reliable on fast
                -- waveforms and avoid the gray wash seen while panning.
                ink = dir_y < 0 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
            elseif color_mode then
                local sky_position = ry / math.max(1, rows - 1)
                if dir_y < 0 then
                    ink = dither_threshold < 7 and scene_palette.ground_dark or scene_palette.ground
                elseif daylight < 0.10 then
                    -- Stable stars leave the night recognisable without an animated sky.
                    ink = ((floor(rx / 7) + floor(ry / 5)) % 19 == 0) and "white" or scene_palette.top
                elseif sky_position < 0.27 then
                    ink = ((floor(rx / 11) + floor(ry / 5)) % 13 == 0) and "cloud" or scene_palette.top
                elseif sky_position < 0.58 then
                    ink = ((floor(rx / 15) + floor(ry / 4)) % 17 == 0) and "cloud" or scene_palette.mid
                else
                    ink = scene_palette.horizon
                end
            elseif dir_y < 0 then
                -- Native mid-gray keeps the far ground calm and distinct from sky.
                ink = "mono_ground"
            else
                -- Monochrome still signals night through a dense dark sky.
                ink = world.dimension == "nether"
                    and "mono_nether"
                    or (daylight < 0.10 and "mono_night" or Blitbuffer.COLOR_WHITE)
            end
            if rx == 0 then
                row_ink, row_start = ink, rx
            elseif ink ~= row_ink then
                paintSpan(row_start, rx, ry, row_ink)
                row_ink, row_start = ink, rx
            end
        end
        if row_ink then
            paintSpan(row_start, cols, ry, row_ink)
        end
    end
    self._terrain_cache = {
        rects = terrain_spans, world = world, block_flat = world.block_flat, light_sources = world.light_sources,
        x = x, y = y, width = width, height = height, player_x = player_x, player_z = player_z,
        yaw = yaw, pitch = pitch, jump_offset = session.jump_offset or 0, color_mode = color_mode,
        motion_preview = motion_preview,
        tick_bucket = floor((session.world_ticks or 0) / 8), time_bucket = floor((session:timeOfDay() or 0) * 24),
    }
    self:_drawMobs(bb, x, y, session, color_mode)
    local center_x, center_y = x + math.floor(width / 2), y + math.floor(height / 2)
    self:_drawCrosshair(bb, center_x, center_y)
    self:_drawTargetOutline(bb, x, y, session)
    session._mobs_dirty = false
end

function VoxelCanvas:paintTo(bb, x, y)
    local range = self.ges_events.TapMinecraftExplore[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    self._origin_x, self._origin_y = x, y
    self:_drawScene(bb, x, y)
end

function VoxelCanvas:refreshMobs()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    local session, cache = self.session, self._terrain_cache
    if not session or not cache or not session.world then return false end
    local world = session.world
    local time_bucket = math.floor((session:timeOfDay() or 0) * 24)
    if cache.world ~= world or cache.block_flat ~= world.block_flat or cache.light_sources ~= world.light_sources
        or cache.x ~= self._origin_x or cache.y ~= self._origin_y or cache.width ~= self.width or cache.height ~= self.height
        or cache.player_x ~= session.player_x or cache.player_z ~= session.player_z
        or cache.yaw ~= session.yaw or cache.pitch ~= (session.pitch or 0)
        or cache.jump_offset ~= (session.jump_offset or 0)
        or cache.color_mode ~= (session.color_enabled and colorRenderingEnabled())
        or cache.tick_bucket ~= math.floor((session.world_ticks or 0) / 8) or cache.time_bucket ~= time_bucket then return false end
    local old = self._mob_bounds
    local visible = self:_visibleMobs(session)
    if #visible == 0 and not old then
        session._mobs_dirty = false
        return true -- no visible change, so no paint and no E-Ink refresh
    end
    -- Project the full conservative silhouette, not a capped screen radius.
    -- Near-camera animals can span the canvas; a fixed 96px cap left trails.
    local x1, y1, x2, y2 = self._origin_x + self.width, self._origin_y + self.height, self._origin_x, self._origin_y
    for _, entry in ipairs(visible) do
        local mob = entry.mob
        for _, dx in ipairs({ -1.15, 1.15 }) do
            for _, dz in ipairs({ -1.15, 1.15 }) do
                for _, dy in ipairs({ -0.2, 1.8 }) do
                    local px, py = self:projectPoint(mob.x + dx, mob.z + dz, (mob.y or 0) + dy, session, self._origin_x, self._origin_y)
                    x1, y1, x2, y2 = math.min(x1, px - 8), math.min(y1, py - 8), math.max(x2, px + 8), math.max(y2, py + 8)
                end
            end
        end
    end
    self._mob_selected = visible
    if old then x1, y1, x2, y2 = math.min(x1, old.x), math.min(y1, old.y), math.max(x2, old.x + old.w), math.max(y2, old.y + old.h) end
    x1, y1 = math.max(self._origin_x, math.floor(x1)), math.max(self._origin_y, math.floor(y1))
    x2, y2 = math.min(self._origin_x + self.width, math.ceil(x2)), math.min(self._origin_y + self.height, math.ceil(y2))
    if x2 <= x1 or y2 <= y1 then
        self._mob_selected, session._mobs_dirty = nil, false
        return true
    end
    self._mob_refresh_region = { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "fast", Geom:new{ x = x1, y = y1, w = x2 - x1, h = y2 - y1 })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    return true
end

function VoxelCanvas:refreshFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    local session = self.session
    local overlay = session and session.inventory_open and self.inventory_panel
        or (session and session.crafting_open and self.crafting_panel)
    if overlay then
        local ox, oy = overlay._origin_x or 0, overlay._origin_y or 0
        UIManager:widgetRepaint(overlay, ox, oy)
        UIManager:setDirty(nil, "ui", Geom:new{ x = ox, y = oy, w = overlay.width, h = overlay.height })
        if UIManager.forceRePaint then UIManager:forceRePaint() end
        return true
    end
    if self._mob_refresh_request then
        self._mob_refresh_request = nil
        if self:refreshMobs() then return true end
    end
    self._refresh_count = (self._refresh_count or 0) + 1
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    local live_preview = self.session and (self.session.live_look or self.session.motion)
    -- Keep the fast waveform for the same frame cadence; the preview itself
    -- is now strict black/white, so no slower waveform is needed.
    local waveform = live_preview and "fast" or (self._refresh_count % 2 == 0 and "ui" or "fast")
    UIManager:setDirty(nil, waveform, Geom:new{
        x = self._origin_x, y = self._origin_y, w = self.width, h = self.height,
    })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    local function repaintControl(widget, fallback)
        if not widget then return end
        local ox, oy = widget._origin_x, widget._origin_y
        if type(ox) ~= "number" or type(oy) ~= "number" then ox, oy = fallback.x, fallback.y end
        UIManager:widgetRepaint(widget, ox, oy)
    end
    if self.control_dpad_widget and self.control_dpad_region then repaintControl(self.control_dpad_widget, self.control_dpad_region) end
    if self.control_jump_widget and self.control_jump_region then repaintControl(self.control_jump_widget, self.control_jump_region) end
    if not live_preview and UIManager.yieldToEPDC then UIManager:yieldToEPDC() end
    return true
end
function VoxelCanvas:pickBlock(screen_x, screen_y)
    local session = self.session
    if not session or not screen_x or not screen_y then return nil end
    local relative_x = clamp(screen_x - self._origin_x, 0, self.width - 1)
    local relative_y = clamp(screen_y - self._origin_y, 0, self.height - 1)
    local sample = MINECRAFT_RENDER_SAMPLE
    local cols, rows = renderGridFor(self.width, self.height, sample)
    local rx = math.min(cols - 1, math.floor(relative_x / self.width * cols))
    local ry = math.min(rows - 1, math.floor(relative_y / self.height * rows))
    local nx = ((rx + .5) / cols * 2 - 1) * math.tan(math.pi / 4)
    local ny = (1 - (ry + .5) / rows * 2) * math.tan(math.pi / 4) * self.height / self.width
    local cp, sp, cy, sy = math.cos(session.pitch or 0), math.sin(session.pitch or 0), math.cos(session.yaw), math.sin(session.yaw)
    local dir_x = sy * cp + cy * nx - sy * sp * ny
    local dir_z = cy * cp - sy * nx - cy * sp * ny
    local dir_y = sp + cp * ny
    local inverse_length = 1 / math.sqrt(dir_x * dir_x + dir_z * dir_z + dir_y * dir_y)
    dir_x, dir_z, dir_y = dir_x * inverse_length, dir_z * inverse_length, dir_y * inverse_length

    local world = session.world
    if not world.block_flat then rebuildWorldBlocks(world) end
    local origin_x, origin_z = session.player_x, session.player_z
    local origin_y = session:groundHeightAtPlayer() + PLAYER_EYE_HEIGHT + (session.jump_offset or 0)
    local cell_x, cell_z, cell_y = math.floor(origin_x), math.floor(origin_z), math.floor(origin_y)
    local fraction_x, fraction_z, fraction_y = origin_x - cell_x, origin_z - cell_z, origin_y - cell_y
    local step_x, step_z, step_y = dir_x < 0 and -1 or 1, dir_z < 0 and -1 or 1, dir_y < 0 and -1 or 1
    local delta_x = math.abs(dir_x) < .00001 and 1e30 or math.abs(1 / dir_x)
    local delta_z = math.abs(dir_z) < .00001 and 1e30 or math.abs(1 / dir_z)
    local delta_y = math.abs(dir_y) < .00001 and 1e30 or math.abs(1 / dir_y)
    local next_x = step_x < 0 and fraction_x * delta_x or (1 - fraction_x) * delta_x
    local next_z = step_z < 0 and fraction_z * delta_z or (1 - fraction_z) * delta_z
    local next_y = step_y < 0 and fraction_y * delta_y or (1 - fraction_y) * delta_y
    local distance, normal_x, normal_z, normal_y = 0, 0, 0, 0
    for _ = 1, 96 do
        if blockAt(world, cell_x, cell_z, cell_y) then
            if normal_x == 0 and normal_y == 0 and normal_z == 0 then return nil end
            return {
                x = cell_x, z = cell_z, y = cell_y,
                place_x = cell_x + normal_x,
                place_z = cell_z + normal_z,
                place_y = cell_y + normal_y,
            }
        end
        if next_x < next_z and next_x < next_y then
            distance, next_x, cell_x = next_x, next_x + delta_x, cell_x + step_x
            normal_x, normal_z, normal_y = -step_x, 0, 0
        elseif next_z < next_y then
            distance, next_z, cell_z = next_z, next_z + delta_z, cell_z + step_z
            normal_x, normal_z, normal_y = 0, -step_z, 0
        else
            distance, next_y, cell_y = next_y, next_y + delta_y, cell_y + step_y
            normal_x, normal_z, normal_y = 0, 0, -step_y
        end
        if distance > MAX_VIEW_DISTANCE then break end
    end
    return nil
end

function VoxelCanvas:act(action, target)
    if not self.session then return false end
    if (self.session.inventory_open or self.session.crafting_open) and action ~= "inventory" then return false end
    local result = self.session:act(action, target)
    self:refreshFast()
    if self.hotbar and (action == "mine" or action == "place" or action == "tap" or action == "hold") then self.hotbar:refresh() end
    return result ~= false
end

function VoxelCanvas:routeModalTap(first, second)
    local session = self.session
    if session and session.inventory_open and self.inventory_panel then
        self.inventory_panel:onTapMinecraftInventory(first, second)
        return true
    elseif session and session.crafting_open and self.crafting_panel then
        self.crafting_panel:onTapMinecraftCrafting(first, second)
        return true
    end
    return false
end

-- OverlapGroup dispatch order differs slightly between KOReader builds. Keep
-- the controls safe even when the full-canvas tap range receives the event
-- first: a control tap is routed to its action and can never place a block.
function VoxelCanvas:_controlActionAt(screen_x, screen_y)
    local dpad, jump = self.control_dpad_region, self.control_jump_region
    -- Use the origin captured by each widget's paintTo. OverlapGroup and
    -- widgetRepaint can apply a parent offset; the drawn pixels and the hitbox
    -- must always use the same final screen coordinates.
    if self.control_dpad_widget and type(self.control_dpad_widget._origin_x) == "number"
        and type(self.control_dpad_widget._origin_y) == "number" then
        dpad = { x = self.control_dpad_widget._origin_x, y = self.control_dpad_widget._origin_y,
            w = self.control_dpad_widget.width, h = self.control_dpad_widget.height }
    end
    if self.control_jump_widget and type(self.control_jump_widget._origin_x) == "number"
        and type(self.control_jump_widget._origin_y) == "number" then
        jump = { x = self.control_jump_widget._origin_x, y = self.control_jump_widget._origin_y,
            w = self.control_jump_widget.width, h = self.control_jump_widget.height }
    end
    if dpad and screen_x >= dpad.x and screen_x < dpad.x + dpad.w
        and screen_y >= dpad.y and screen_y < dpad.y + dpad.h then
        local cell = math.floor(dpad.w / 3)
        local x, y = screen_x - dpad.x, screen_y - dpad.y
        if x >= cell and x < cell * 2 and y < cell then return "forward" end
        if x < cell and y >= cell and y < cell * 2 then return "left" end
        if x >= cell * 2 and y >= cell and y < cell * 2 then return "right" end
        if x >= cell and x < cell * 2 and y >= cell * 2 then return "back" end
        return "none"
    end
    if jump and screen_x >= jump.x and screen_x < jump.x + jump.w
        and screen_y >= jump.y and screen_y < jump.y + jump.h then
        return "jump"
    end
    return nil
end

function VoxelCanvas:onTapMinecraftExplore(first, second)
    if self:routeModalTap(first, second) then return true end
    local gesture = second or first
    if not gesture or not gesture.pos then return true end
    local control_action = self:_controlActionAt(gesture.pos.x, gesture.pos.y)
    if control_action then
        self:act(control_action)
        return true
    end
    local target = self:pickBlock(gesture.pos.x, gesture.pos.y)
    if target then
        -- Bedrock: a tap interacts with the touched block face. Depending on the
        -- selected mode this either places or mines.
        self:act("tap", target)
        return true
    end
    -- Empty sky still doubles as a quiet direct controller: the upper centre
    -- walks forward, lower centre walks back, and side taps turn.
    local relative_x = gesture.pos.x - self._origin_x
    local relative_y = gesture.pos.y - self._origin_y
    if relative_x < self.width * 0.32 then
        self:act("left")
    elseif relative_x > self.width * 0.68 then
        self:act("right")
    elseif relative_y < self.height * 0.64 then
        self:act("forward")
    else
        self:act("back")
    end
    return true
end

function VoxelCanvas:onHoldMinecraftAction(first, second)
    if self.session and (self.session.inventory_open or self.session.crafting_open) then return true end
    local gesture = second or first
    local pos = gesture and gesture.pos
    if not pos then return true end
    local control_action = self:_controlActionAt(pos.x, pos.y)
    if control_action == "jump" then
        self:act("jump")
        return true
    elseif control_action and control_action ~= "none" then
        -- The canvas owns the larger mining hold range. Do not swallow a
        -- D-pad hold here: forward it to the repeat-movement timer.
        if self.session then self.session:startHeldMove(control_action) end
        return true
    end
    local target = self:pickBlock(pos.x, pos.y)
    if target then
        self:act("hold", target)
    end
    return true
end

function VoxelCanvas:_panLook(gesture, finish)
    if self.session and (self.session.inventory_open or self.session.crafting_open) then
        self._look_pan_last = nil
        return true
    end
    local pos = gesture and (gesture.pos or gesture)
    if not pos then return false end
    if self:_controlActionAt(pos.x, pos.y) then
        if finish then self._look_pan_last = nil end
        return true
    end
    self.session.live_look = true
    local previous = self._look_pan_last
    self._look_pan_last = { x = pos.x, y = pos.y }
    if previous and self.session:lookDelta((pos.x or 0) - (previous.x or 0), (pos.y or 0) - (previous.y or 0)) then
        self:refreshFast()
    end
    if finish then
        self._look_pan_last = nil
        self.session.live_look = false
        -- One clean, full-quality frame after the finger is released removes
        -- the preview grid without slowing any intermediate pan sample.
        self:refreshFast()
    end
    return true
end

function VoxelCanvas:onHoldReleaseMinecraftAction()
    if self.session then self.session:stopHeldMove() end
    return true
end

function VoxelCanvas:onPanMinecraftLook(first, second)
    return self:_panLook(second or first, false)
end

function VoxelCanvas:onPanReleaseMinecraftLook(first, second)
    return self:_panLook(second or first, true)
end

function VoxelCanvas:onSwipeMinecraftLook(first, second)
    local gesture = second or first
    if not self.session then return false end
    if self.session.inventory_open or self.session.crafting_open then return true end
    local direction = gesture and gesture.direction
    if direction == "west" then
        self.session:turn(-3)
    elseif direction == "east" then
        self.session:turn(3)
    elseif direction == "north" then
        self.session:lookVertical(1)
    elseif direction == "south" then
        self.session:lookVertical(-1)
    else
        return false
    end
    self:refreshFast()
    return true
end
-- On-screen controls -----------------------------------------------------------

local Joystick = InputContainer:extend{
    width = nil,
    height = nil,
    canvas = nil,
    dimen = nil,
    _origin_x = 0,
    _origin_y = 0,
}

function Joystick:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapMinecraftJoystick = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldMinecraftJoystick = { GestureRange:new{ ges = "hold", range = self.dimen } },
        HoldReleaseMinecraftJoystick = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
        PanMinecraftJoystick = { GestureRange:new{ ges = "pan", range = self.dimen, rate = 8 } },
        PanReleaseMinecraftJoystick = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        SwipeMinecraftJoystick = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

function Joystick:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local range = self.ges_events.TapMinecraftJoystick[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    local cell = math.floor(math.min(self.width, self.height) / 3)
    local function button(column, row, direction)
        local bx, by = x + column * cell + 1, y + row * cell + 1
        bb:paintRect(bx, by, cell - 2, cell - 2, Blitbuffer.COLOR_BLACK)
        bb:paintRect(bx + 1, by + 1, cell - 4, cell - 4, Blitbuffer.COLOR_LIGHT_GRAY)
        bb:paintRect(bx + 2, by + 2, cell - 6, 1, Blitbuffer.COLOR_WHITE)
        local cx, cy = bx + math.floor((cell - 2) / 2), by + math.floor((cell - 2) / 2)
        local radius = math.max(3, math.floor(cell * 0.19))
        for step = 0, radius do
            if direction == "up" then bb:paintRect(cx - step, cy - radius + step, step * 2 + 1, 1, Blitbuffer.COLOR_BLACK)
            elseif direction == "down" then bb:paintRect(cx - step, cy + radius - step, step * 2 + 1, 1, Blitbuffer.COLOR_BLACK)
            elseif direction == "left" then bb:paintRect(cx - radius + step, cy - step, 1, step * 2 + 1, Blitbuffer.COLOR_BLACK)
            else bb:paintRect(cx + radius - step, cy - step, 1, step * 2 + 1, Blitbuffer.COLOR_BLACK) end
        end
    end
    button(1, 0, "up"); button(0, 1, "left")
    button(2, 1, "right"); button(1, 2, "down")
    -- A quiet centre makes the four-way pad one coherent control.
    bb:paintRect(x + cell + 1, y + cell + 1, cell - 2, cell - 2, Blitbuffer.COLOR_LIGHT_GRAY)
    return true
end

function Joystick:_steer(gesture)
    local pos = gesture and gesture.pos
    if not pos or not self.canvas then return true end
    local size, cell = math.min(self.width, self.height), math.floor(math.min(self.width, self.height) / 3)
    local local_x, local_y = (pos.x or self._origin_x) - self._origin_x, (pos.y or self._origin_y) - self._origin_y
    local action
    if local_x >= cell and local_x < cell * 2 and local_y < cell then action = "forward"
    elseif local_x < cell and local_y >= cell and local_y < cell * 2 then action = "left"
    elseif local_x >= cell * 2 and local_y >= cell and local_y < cell * 2 then action = "right"
    elseif local_x >= cell and local_x < cell * 2 and local_y >= cell * 2 and local_y < size then action = "back" end
    if action then self.canvas:act(action) end
    return true
end

function Joystick:_heldAction(gesture)
    local pos = gesture and gesture.pos
    if not pos or not self.canvas then return nil end
    local cell = math.floor(math.min(self.width, self.height) / 3)
    local local_x, local_y = pos.x - self._origin_x, pos.y - self._origin_y
    if local_x >= cell and local_x < cell * 2 and local_y < cell then return "forward" end
    if local_x < cell and local_y >= cell and local_y < cell * 2 then return "left" end
    if local_x >= cell * 2 and local_y >= cell and local_y < cell * 2 then return "right" end
    if local_x >= cell and local_x < cell * 2 and local_y >= cell * 2 then return "back" end
    return nil
end

function Joystick:onHoldMinecraftJoystick(first, second)
    if self.canvas and self.canvas.session and (self.canvas.session.inventory_open or self.canvas.session.crafting_open) then return true end
    local action = self:_heldAction(second or first)
    if action and self.canvas and self.canvas.session then
        self.canvas.session:startHeldMove(action)
    end
    return true
end

function Joystick:onPanMinecraftJoystick(first, second)
    if self.canvas and self.canvas.session and (self.canvas.session.inventory_open or self.canvas.session.crafting_open) then
        self.canvas.session:stopHeldMove()
        return true
    end
    local action = self:_heldAction(second or first)
    local session = self.canvas and self.canvas.session
    if action and session then
        if session.held_move_action ~= action then session:startHeldMove(action) end
    elseif session and session.held_move_action then
        session:stopHeldMove()
    end
    return true
end

function Joystick:onPanReleaseMinecraftJoystick()
    if self.canvas and self.canvas.session then self.canvas.session:stopHeldMove() end
    return true
end

function Joystick:onHoldReleaseMinecraftJoystick()
    if self.canvas and self.canvas.session then self.canvas.session:stopHeldMove() end
    return true
end

function Joystick:onTapMinecraftJoystick(first, second)
    if self.canvas and self.canvas:routeModalTap(first, second) then return true end
    if self.canvas and self.canvas.session then self.canvas.session:stopHeldMove() end
    return self:_steer(second or first)
end
function Joystick:onSwipeMinecraftJoystick(first, second)
    if not self.canvas then return false end
    if self.canvas.session and (self.canvas.session.inventory_open or self.canvas.session.crafting_open) then return true end
    local gesture = second or first
    local direction = gesture and gesture.direction
    if direction == "west" then self.canvas:act("left")
    elseif direction == "east" then self.canvas:act("right")
    elseif direction == "north" then self.canvas:act("forward")
    elseif direction == "south" then self.canvas:act("back")
    else return false end
    return true
end

-- Every block label is abbreviated automatically so new materials appear in the
-- hotbar without a hand-maintained table.
local abbreviation_cache = {}
local function abbreviationFor(material)
    local cached = abbreviation_cache[material]
    if cached then return cached end
    local label = materialLabel(material)
    local abbreviation = string.upper(label:sub(1, 2))
    abbreviation = abbreviation:gsub("^SS", "St"):gsub("^BR", "Br")
    abbreviation_cache[material] = abbreviation
    return abbreviation
end

-- Pixel-art material icons and beveled slots give the compact E-Ink inventory a
-- recognizable Bedrock character without relying on external image assets.
local function paintBlockIcon(bb, x, y, size, material, session)
    local color_mode = session and session.color_enabled and colorRenderingEnabled() and bb.paintRectRGB32
    if material == "torch" then
        local unit = math.max(1, math.floor(size / 8))
        local cx = x + math.floor(size / 2)
        local shaft = color_mode and sceneColor(SURFACE_TONES.wood.rgb[14]) or Blitbuffer.COLOR_DARK_GRAY
        local flame = color_mode and sceneColor(SURFACE_TONES.torch.rgb[16]) or Blitbuffer.COLOR_LIGHT_GRAY
        if color_mode then
            bb:paintRectRGB32(cx - unit, y + unit * 3, unit * 2, math.max(1, size - unit * 3), shaft)
            bb:paintRectRGB32(cx - unit * 2, y, unit * 4, unit * 4, flame)
        else
            bb:paintRect(cx - unit, y + unit * 3, unit * 2, math.max(1, size - unit * 3), shaft)
            bb:paintRect(cx - unit * 2, y, unit * 4, unit * 4, Blitbuffer.COLOR_BLACK)
            bb:paintRect(cx - unit, y + unit, unit * 2, unit * 2, flame)
        end
        return
    end
    local pattern = PATTERN_VALUES[material] or PATTERN_VALUES.stone
    local pixels = 4
    local pixel = math.max(1, math.floor(size / pixels))
    for row = 0, pixels - 1 do
        for column = 0, pixels - 1 do
            local level = pattern[(row * 2) * 8 + column * 2 + 1] or 2
            local px, py = x + column * pixel, y + row * pixel
            local width = column == pixels - 1 and size - column * pixel or pixel
            local height = row == pixels - 1 and size - row * pixel or pixel
            local tones = SURFACE_TONES[material] or SURFACE_TONES.stone
            local tone = clamp(math.floor((0.78 + level * 0.11 - 0.30) / 0.83 * 15 + 0.5), 0, 15)
            if color_mode then
                bb:paintRectRGB32(px, py, width, height, level == 0 and paletteColor("black") or sceneColor(tones.rgb[tone + 1]))
            else
                bb:paintRect(px, py, width, height, level == 0 and Blitbuffer.COLOR_BLACK or sceneColor(tones.mono[tone + 1]))
            end
        end
    end
    -- A dark one-pixel base makes light blocks visible against a pale slot.
    bb:paintRect(x, y + size - 1, size, 1, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + size - 1, y, 1, size, Blitbuffer.COLOR_BLACK)
end

local function paintMinecraftSlot(bb, x, y, width, height, session, item, selected, number, compact)
    -- Everything, including the bevel, stays INSIDE the assigned slot.
    local border = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    bb:paintRect(x, y, width, height, border)
    bb:paintRect(x + 2, y + 2, math.max(1, width - 4), math.max(1, height - 4), Blitbuffer.COLOR_WHITE)
    if selected then
        bb:paintRect(x + 3, y + 3, math.max(1, width - 6), 2, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + 3, y + height - 5, math.max(1, width - 6), 2, Blitbuffer.COLOR_BLACK)
    end
    if item and width >= 12 and height >= 16 then
        local icon_size = math.max(4, math.min(width - 8, height - 14))
        paintBlockIcon(bb, x + math.floor((width - icon_size) / 2), y + 5, icon_size, item.material, session)
        local count = TextWidget:new{
            text = session and session.mode == "Creative" and "∞" or tostring(item.count),
            face = Font:getFace("smallinfofont", math.max(7, math.min(11, math.floor(height * 0.22)))),
            fgcolor = Blitbuffer.COLOR_BLACK, bold = true, padding = 0, max_width = math.max(1, width - 6),
        }
        local count_size = count:getSize()
        count:paintTo(bb, x + math.max(3, width - count_size.w - 4), y + math.max(3, height - count_size.h - 4))
    end
end

local Hotbar = InputContainer:extend{ session = nil, canvas = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0 }

function Hotbar:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftHotbar = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function Hotbar:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local range = self.ges_events.TapMinecraftHotbar[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    local session = self.session
    local slot_w = self.width / HOTBAR_SLOTS
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + 2, y + 2, math.max(1, self.width - 4), math.max(1, self.height - 4), Blitbuffer.COLOR_DARK_GRAY)
    for slot = 1, HOTBAR_SLOTS do
        local left = x + math.floor((slot - 1) * slot_w) + 2
        local right = x + math.floor(slot * slot_w) - 1
        local cell_w = math.max(1, right - left)
        local item = session and session.slots[slot] or nil
        paintMinecraftSlot(bb, left, y + 2, cell_w, math.max(1, self.height - 4), session, item, session and session.selected_slot == slot, slot, true)
    end
    return true
end

function Hotbar:refresh()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    return true
end

function Hotbar:onTapMinecraftHotbar(first, second)
    if self.canvas and self.canvas:routeModalTap(first, second) then return true end
    local gesture = second or first
    local pos = gesture and gesture.pos
    if not pos or not self.session then return true end
    local range = self.ges_events.TapMinecraftHotbar[1].range
    local origin_x = range.x or self._origin_x or 0
    local slot = math.floor((pos.x - origin_x) / (self.width / HOTBAR_SLOTS)) + 1
    if self.session:selectSlot(slot) then self:refresh() end
    return true
end

-- A single text line that reports the last action, so the player always sees
-- what a tap, a hold or a craft actually did.
local EventLine = InputContainer:extend{ session = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0 }

function EventLine:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {}
end

function EventLine:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local text = self.session and self.session.last_event or ""
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("smallinfofont", math.max(8, math.min(12, self.height - 2))),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = self.width,
    }
    label:paintTo(bb, x, y)
    return true
end

function EventLine:refresh()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    return true
end

-- Full-screen Bedrock-style inventory overlay with the item catalogue on the
-- left, category rail and a separate 2x2 crafting area on the right.
local InventoryPanel = InputContainer:extend{ session = nil, canvas = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0, active_category = 1 }
local INVENTORY_CATEGORIES = {
    { label = "Alle", icon = "stone" },
    { label = "Blöcke", icon = "planks" },
    { label = "Natur", icon = "leaves" },
    { label = "Licht", icon = "torch" },
    { label = "Erze", icon = "diamond" },
}

function InventoryPanel:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftInventory = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function InventoryPanel:layout()
    local margin = math.max(scale(5), math.floor(math.min(self.width, self.height) * 0.008))
    local rail_w = math.max(scale(36), math.min(scale(50), math.floor(self.width * 0.075)))
    local bar_h = math.max(scale(42), math.min(scale(58), math.floor(self.height * 0.065)))
    local outer_x, outer_y = margin, margin
    local outer_w = math.max(scale(120), self.width - margin * 2)
    local outer_h = math.max(scale(100), self.height - bar_h - margin * 3)
    local rail_x, rail_y = outer_x, outer_y
    local left_x = rail_x + rail_w + scale(4)
    local panels_w = math.max(scale(100), outer_w - rail_w - scale(10))
    local left_w = math.floor(panels_w * 0.51)
    local divider_w = math.max(3, scale(4))
    local right_x = left_x + left_w + divider_w
    local right_w = math.max(scale(80), outer_x + outer_w - right_x)
    local header_h = math.max(scale(34), math.min(scale(48), math.floor(outer_h * 0.065)))
    local search_h = math.max(scale(24), math.min(scale(34), math.floor(outer_h * 0.045)))
    local grid_x = left_x + scale(6)
    local grid_y = outer_y + header_h + search_h + scale(9)
    local grid_w = math.max(scale(72), left_w - scale(20))
    local material_count = #MATERIAL_ORDER
    local grid_columns = self.width < scale(450) and 4 or (self.width < scale(900) and 6 or 9)
    local shown_rows = math.max(1, math.ceil(material_count / grid_columns))
    local cell_w = math.max(scale(14), math.floor(grid_w / grid_columns))
    local grid_h = math.max(1, outer_y + outer_h - grid_y - scale(8))
    local cell_h = math.max(scale(24), math.min(scale(52), math.floor(grid_h / shown_rows)))
    local hotbar_w = math.min(math.floor(self.width * 0.62), scale(680))
    hotbar_w = math.max(math.min(self.width - 2 * margin, scale(220)), hotbar_w)
    local hotbar_x = math.floor((self.width - hotbar_w) / 2)
    local hotbar_y = self.height - margin - bar_h
    local craft_cell = math.max(scale(24), math.min(scale(72), math.floor(math.min(right_w * 0.30, outer_h * 0.12))))
    local craft_grid = craft_cell * 2 + scale(4)
    local craft_x = right_x + math.floor((right_w - craft_grid) / 2)
    local craft_y = outer_y + header_h + scale(10)
    local output_size = math.max(scale(30), math.min(scale(54), craft_cell))
    local output_x = right_x + math.floor((right_w - output_size) / 2)
    local output_y = outer_y + outer_h - output_size - scale(22)
    return {
        margin = margin, outer_x = outer_x, outer_y = outer_y, outer_w = outer_w, outer_h = outer_h,
        rail_x = rail_x, rail_y = rail_y, rail_w = rail_w, left_x = left_x, left_w = left_w,
        right_x = right_x, right_w = right_w, divider_w = divider_w, header_h = header_h, search_h = search_h,
        grid_x = grid_x, grid_y = grid_y, grid_w = grid_w, grid_columns = grid_columns,
        cell_w = cell_w, cell_h = cell_h, material_rows = shown_rows,
        hotbar_x = hotbar_x, hotbar_y = hotbar_y, hotbar_w = hotbar_w,
        bar_h = bar_h, craft_cell = craft_cell, craft_grid = craft_grid, craft_x = craft_x, craft_y = craft_y,
        output_x = output_x, output_y = output_y, output_size = output_size,
    }
end

function InventoryPanel:visibleMaterials()
    local result = {}
    for _, material in ipairs(MATERIAL_ORDER) do
        local include = self.active_category == 1 or self.active_category == 2
        if self.active_category == 3 then
            include = material:find("wood", 1, true) or material:find("leaves", 1, true)
                or material == "grass" or material == "sand" or material == "water" or material == "wheat"
                or material == "cactus" or material == "dead_bush"
        elseif self.active_category == 4 then
            include = material == "torch" or material == "glowstone" or material == "flint_and_steel"
                or material == "glass" or material:find("planks", 1, true)
                or material == "bricks" or material == "crafting_table" or material == "furnace"
        elseif self.active_category == 5 then
            include = material == "coal" or material == "iron" or material == "gold" or material == "diamond" or material == "redstone"
        end
        if include then result[#result + 1] = material end
    end
    return result
end

function InventoryPanel:hitTest(local_x, local_y)
    local layout = self:layout()
    if local_x >= self.width - layout.margin - scale(42) and local_y <= layout.outer_y + layout.header_h then return { kind = "close" } end
    if local_x >= layout.rail_x and local_x < layout.rail_x + layout.rail_w then
        for category = 1, #INVENTORY_CATEGORIES do
            local tab_y = layout.rail_y + scale(6) + (category - 1) * (layout.rail_w + scale(5))
            if local_y >= tab_y and local_y < tab_y + layout.rail_w then return { kind = "category", category = category } end
        end
    end
    if local_x >= layout.right_x and local_y >= layout.outer_y and local_y < layout.outer_y + layout.header_h then
        return { kind = "craft" }
    end
    if local_x >= layout.hotbar_x and local_x < layout.hotbar_x + layout.hotbar_w
        and local_y >= layout.hotbar_y and local_y < layout.hotbar_y + layout.bar_h then
        local slot_w = layout.hotbar_w / HOTBAR_SLOTS
        return { kind = "hotbar", slot = clamp(math.floor((local_x - layout.hotbar_x) / slot_w) + 1, 1, HOTBAR_SLOTS) }
    end
    if local_x >= layout.grid_x and local_x < layout.grid_x + layout.grid_w
        and local_y >= layout.grid_y and local_y < layout.grid_y + layout.material_rows * layout.cell_h then
        local column = math.floor((local_x - layout.grid_x) / layout.cell_w)
        local row = math.floor((local_y - layout.grid_y) / layout.cell_h)
        local material = self:visibleMaterials()[row * layout.grid_columns + column + 1]
        if material then return { kind = "material", material = material } end
    end
    return { kind = "empty" }
end

local function paintInventorySearchIcon(bb, x, y, size)
    local stroke = math.max(2, math.floor(size * 0.14))
    local ring = math.max(4, math.floor(size * 0.62))
    bb:paintRect(x, y, ring, stroke, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(x, y + ring - stroke, ring, stroke, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(x, y, stroke, ring, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(x + ring - stroke, y, stroke, ring, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(x + ring - stroke, y + ring - stroke, size - ring + stroke, stroke, Blitbuffer.COLOR_DARK_GRAY)
end

function InventoryPanel:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local session = self.session
    if not session or not session.inventory_open then return true end
    local range = self.ges_events.TapMinecraftInventory[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    local L = self:layout()
    -- Leave a slim strip of the world around the opaque panels, as in Bedrock.
    bb:paintRect(x + L.outer_x, y + L.outer_y, L.outer_w, L.outer_h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + L.left_x, y + L.outer_y + 2, L.left_w, L.outer_h - 4, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x + L.right_x, y + L.outer_y + 2, L.right_w, L.outer_h - 4, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x + L.left_x, y + L.outer_y + L.header_h, L.left_w, L.search_h, Blitbuffer.COLOR_WHITE)
    paintInventorySearchIcon(bb, x + L.left_x + scale(9), y + L.outer_y + scale(9), math.max(scale(18), L.header_h - scale(14)))
    local category_title = self.active_category == 1 and _("Alle Gegenstände") or _(INVENTORY_CATEGORIES[self.active_category].label)
    local heading = TextWidget:new{ text = session.mode == "Creative" and (category_title .. " · ∞") or category_title, face = Font:getFace("cfont", math.max(scale(10), math.floor(L.header_h * 0.40))), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = L.left_w - scale(56) }
    heading:paintTo(bb, x + L.left_x + scale(48), y + L.outer_y + math.floor((L.header_h - scale(12)) / 2))
    local search_y = y + L.outer_y + L.header_h
    bb:paintRect(x + L.left_x + scale(5), search_y + scale(3), L.left_w - scale(10), L.search_h - scale(5), Blitbuffer.COLOR_DARK_GRAY)
    paintInventorySearchIcon(bb, x + L.left_x + scale(10), search_y + scale(7), math.max(scale(12), L.search_h - scale(13)))
    local detail_text = session.inventory_item_label and (_("Ausgewählt: ") .. session.inventory_item_label) or _("Gegenstandsnamen stehen unter den Blöcken")
    local search_label = TextWidget:new{ text = detail_text, face = Font:getFace("smallinfofont", math.max(scale(7), math.floor(L.search_h * 0.30))), fgcolor = Blitbuffer.COLOR_WHITE, max_width = L.left_w - scale(38) }
    search_label:paintTo(bb, x + L.left_x + scale(34), search_y + scale(5))

    -- Category rail, with block-texture pictograms instead of fragile unicode glyphs.
    for category, definition in ipairs(INVENTORY_CATEGORIES) do
        local tab_y = L.rail_y + scale(6) + (category - 1) * (L.rail_w + scale(5))
        local fill = category == self.active_category and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_DARK_GRAY
        bb:paintRect(x + L.rail_x, y + tab_y, L.rail_w, L.rail_w, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x + L.rail_x + 2, y + tab_y + 2, L.rail_w - 4, L.rail_w - 4, fill)
        local icon = math.max(scale(12), math.floor(L.rail_w * 0.55))
        paintBlockIcon(bb, x + L.rail_x + math.floor((L.rail_w - icon) / 2), y + tab_y + math.floor((L.rail_w - icon) / 2), icon, definition.icon, session)
    end
    -- Small chest button at the bottom of the category rail, mirroring Bedrock.
    local chest_y = y + L.outer_y + L.outer_h - L.rail_w - scale(8)
    bb:paintRect(x + L.rail_x, chest_y, L.rail_w, L.rail_w, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + L.rail_x + 3, chest_y + 3, L.rail_w - 6, L.rail_w - 6, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x + L.rail_x + 9, chest_y + 12, L.rail_w - 18, L.rail_w - 21, Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(x + L.rail_x + math.floor(L.rail_w / 2) - 2, chest_y + 14, 4, 5, Blitbuffer.COLOR_WHITE)

    -- Scroll-like item grid. All catalog blocks are shown; owned counts stay
    -- accurate, while unowned entries remain browse-only rather than granting items.
    local materials = self:visibleMaterials()
    for index, material in ipairs(materials) do
        local row, column = math.floor((index - 1) / L.grid_columns), (index - 1) % L.grid_columns
        local sx = x + L.grid_x + column * L.cell_w
        local sy = y + L.grid_y + row * L.cell_h
        local cell_w, cell_h = math.max(1, L.cell_w - scale(2)), math.max(1, L.cell_h - scale(2))
        local owned_slot, count = nil, 0
        for slot = 1, INVENTORY_SLOTS do
            local item = session.slots[slot]
            if item and item.material == material then owned_slot, count = owned_slot or slot, count + item.count end
        end
        local selected = owned_slot == session.selected_slot
        paintMinecraftSlot(bb, sx, sy, cell_w, cell_h, session, nil, selected, nil, true)
        local item_name = TextWidget:new{ text = materialLabel(material), face = Font:getFace("smallinfofont", scale(8)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = math.max(scale(12), cell_w - scale(3) - (count > 0 and session.mode ~= "Creative" and scale(12) or 0)), padding = 0 }
        local name_size = item_name:getSize()
        local icon_size = math.max(scale(8), math.min(cell_w - scale(7), cell_h - name_size.h - scale(8)))
        paintBlockIcon(bb, sx + math.floor((cell_w - icon_size) / 2), sy + scale(2), icon_size, material, session)
        item_name:paintTo(bb, sx + scale(2), sy + cell_h - name_size.h - scale(1))
        if count > 0 and session.mode ~= "Creative" then
            local count_label = TextWidget:new{ text = tostring(count), face = Font:getFace("smallinfofont", math.max(scale(6), scale(7))), fgcolor = Blitbuffer.COLOR_BLACK, bold = true }
            local count_size = count_label:getSize()
            count_label:paintTo(bb, sx + cell_w - count_size.w - scale(2), sy + cell_h - count_size.h - scale(1))
        end
    end
    -- A narrow scrollbar visually anchors the catalogue column.
    local track_x = x + L.left_x + L.left_w - scale(5)
    bb:paintRect(track_x, y + L.grid_y, scale(3), math.max(scale(20), L.material_rows * L.cell_h), Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(track_x, y + L.grid_y, scale(3), math.max(scale(18), math.floor(L.cell_h * 1.6)), Blitbuffer.COLOR_WHITE)

    -- Right-hand crafting area: 2×2 grid, down-arrow, and result slot.
    local craft_title = TextWidget:new{ text = _("Handwerk"), face = Font:getFace("cfont", math.max(scale(11), math.floor(L.header_h * 0.42))), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = L.right_w - scale(16) }
    local title_size = craft_title:getSize()
    craft_title:paintTo(bb, x + L.right_x + math.floor((L.right_w - title_size.w) / 2), y + L.outer_y + scale(12))
    for row = 0, 1 do
        for column = 0, 1 do
            local sx = x + L.craft_x + column * (L.craft_cell + scale(4))
            local sy = y + L.craft_y + row * (L.craft_cell + scale(4))
            paintMinecraftSlot(bb, sx, sy, L.craft_cell, L.craft_cell, session, nil, false, nil, true)
        end
    end
    local arrow_cx = x + L.right_x + math.floor(L.right_w / 2)
    local arrow_y = y + L.outer_y + math.floor(L.outer_h * 0.56)
    local arrow_w = math.max(scale(12), math.floor(L.right_w * 0.045))
    bb:paintRect(arrow_cx - math.floor(arrow_w / 4), arrow_y, math.max(2, math.floor(arrow_w / 2)), math.max(scale(22), math.floor(L.outer_h * 0.055)), Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(arrow_cx - math.floor(arrow_w / 2), arrow_y + math.max(scale(14), math.floor(L.outer_h * 0.035)), arrow_w, math.max(scale(8), math.floor(L.outer_h * 0.018)), Blitbuffer.COLOR_LIGHT_GRAY)
    paintMinecraftSlot(bb, x + L.output_x, y + L.output_y, L.output_size, L.output_size, session, nil, false, nil, true)
    local close_x, close_y = x + self.width - L.margin - scale(38), y + L.outer_y + scale(2)
    bb:paintRect(close_x, close_y, scale(38), L.header_h - scale(3), Blitbuffer.COLOR_DARK_GRAY)
    local close_label = TextWidget:new{ text = "X", face = Font:getFace("cfont", math.max(scale(12), math.floor(L.header_h * 0.48))), fgcolor = Blitbuffer.COLOR_WHITE, bold = true }
    close_label:paintTo(bb, close_x + scale(12), close_y + scale(1))

    -- Nine persistent hotbar slots float at bottom center like the reference.
    local slot_w = L.hotbar_w / HOTBAR_SLOTS
    bb:paintRect(x + L.hotbar_x, y + L.hotbar_y, L.hotbar_w, L.bar_h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + L.hotbar_x + 3, y + L.hotbar_y + 3, L.hotbar_w - 6, L.bar_h - 6, Blitbuffer.COLOR_LIGHT_GRAY)
    for slot = 1, HOTBAR_SLOTS do
        local sx = x + L.hotbar_x + math.floor((slot - 1) * slot_w) + scale(2)
        local right = x + L.hotbar_x + math.floor(slot * slot_w) - scale(1)
        paintMinecraftSlot(bb, sx, y + L.hotbar_y + scale(3), math.max(scale(14), right - sx), L.bar_h - scale(6), session, session.slots[slot], slot == session.selected_slot, nil, true)
    end
    return true
end

function InventoryPanel:refresh()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    if not (self.session and self.session.inventory_open) then
        if self.canvas then self.canvas:refreshFast() end
        if self.hotbar then self.hotbar:refresh() end
        if self.event_line then self.event_line:refresh() end
        return true
    end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    return true
end

function InventoryPanel:onTapMinecraftInventory(first, second)
    local gesture = second or first
    local session = self.session
    if not session or not session.inventory_open then return false end
    local pos = gesture and gesture.pos
    if not pos then return true end
    local hit = self:hitTest(pos.x - self._origin_x, pos.y - self._origin_y)
    if hit.kind == "close" then
        session:closeOverlays()
        if self.canvas then self.canvas:refreshFast() end
    elseif hit.kind == "craft" then
        session:openCrafting()
        if self.crafting_panel then self.crafting_panel:refresh() end
        return true
    elseif hit.kind == "category" then
        self.active_category = hit.category
    elseif hit.kind == "hotbar" then
        session:selectSlot(hit.slot)
        local item = session.slots[hit.slot]
        session.inventory_item_label = item and materialLabel(item.material) or _("Leerer Platz")
    elseif hit.kind == "material" then
        session.inventory_item_label = materialLabel(hit.material)
        if session.mode == "Creative" then
            session.slots[session.selected_slot] = newSlot(hit.material, 1)
            session:syncDerived()
            session.last_event = materialLabel(hit.material) .. " · " .. _("unlimited")
        else
            local found
            for slot = 1, INVENTORY_SLOTS do
                local item = session.slots[slot]
                if item and item.material == hit.material then found = slot; break end
            end
            if found then session:pickSlot(found)
            else session.last_event = _("You don't have this item yet.") .. " " .. materialLabel(hit.material) end
        end
    end
    self:refresh()
    return true
end

-- Crafting screen: recipe pages with live ingredient counters.
local CraftingPanel = InputContainer:extend{ session = nil, canvas = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0 }

function CraftingPanel:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftCrafting = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function CraftingPanel:headerHeight() return scale(26) end
function CraftingPanel:footerHeight() return scale(22) end
function CraftingPanel:rowHeight()
    return math.max(scale(18), math.floor((self.height - self:headerHeight() - self:footerHeight() - scale(4)) / CRAFT_ROWS_PER_PAGE))
end

function CraftingPanel:hitTest(local_x, local_y)
    local header_h, footer_h = self:headerHeight(), self:footerHeight()
    local button_w = math.max(scale(30), math.floor((self.width - scale(12)) / 3))
    if local_y < header_h then
        if local_x >= self.width - scale(4) - button_w and local_y > scale(2) then return { kind = "button", id = "close" } end
        return { kind = "header" }
    end
    local row_h = self:rowHeight()
    if local_y < header_h + row_h * CRAFT_ROWS_PER_PAGE then
        local row = math.floor((local_y - header_h) / row_h) + 1
        local list = self.session and self.session:recipesForPage(self.session.craft_page) or {}
        local entry = list[row]
        if entry then return { kind = "recipe", index = entry.index, row = row } end
        return { kind = "empty" }
    end
    if local_y >= self.height - footer_h then
        if local_x < self.width / 2 then return { kind = "button", id = "prev" } end
        return { kind = "button", id = "next" }
    end
    return { kind = "empty" }
end

function CraftingPanel:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local session = self.session
    if not session or not session.crafting_open then return true end
    local range = self.ges_events.TapMinecraftCrafting[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    local header_h, footer_h = self:headerHeight(), self:footerHeight()
    local row_h = self:rowHeight()
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x, y, self.width, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + self.height - 2, self.width, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, 2, self.height, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + self.width - 2, y, 2, self.height, Blitbuffer.COLOR_BLACK)
    local title = TextWidget:new{
        text = _("CRAFTING") .. "  ·  " .. tostring(session.craft_page) .. "/" .. tostring(session:pageCount()),
        face = Font:getFace("cfont", math.max(scale(8), scale(10))),
        fgcolor = Blitbuffer.COLOR_BLACK,
        bold = true,
        max_width = math.max(scale(40), self.width - scale(70)),
    }
    title:paintTo(bb, x + scale(5), y + scale(4))
    local button_w = math.max(scale(30), math.floor((self.width - scale(12)) / 3))
    local close_x = self.width - scale(4) - button_w
    bb:paintRect(x + close_x, y + scale(3), button_w, header_h - scale(6), Blitbuffer.COLOR_BLACK)
    local close_label = TextWidget:new{
        text = _("Back"),
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
        fgcolor = Blitbuffer.COLOR_WHITE,
        max_width = button_w - scale(4),
    }
    close_label:paintTo(bb, x + close_x + scale(4), y + scale(6))
    local list = session:recipesForPage(session.craft_page)
    for row = 1, CRAFT_ROWS_PER_PAGE do
        local entry = list[row]
        local sy = y + header_h + (row - 1) * row_h
        bb:paintRect(x + scale(4), sy, self.width - scale(8), row_h - scale(2), Blitbuffer.COLOR_LIGHT_GRAY)
        if entry then
            local craftable = session:canCraft(entry.recipe)
            local label = TextWidget:new{
                text = session:recipeLabel(entry.recipe) .. (craftable and "" or ("  ·  " .. _("Ingredients missing"))),
                face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold = craftable,
                max_width = self.width - scale(12),
            }
            label:paintTo(bb, x + scale(7), sy + scale(3))
        end
    end
    local footer_y = y + self.height - footer_h
    bb:paintRect(x + scale(4), footer_y + scale(2), math.floor(self.width / 2) - scale(6), footer_h - scale(4), Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x + math.floor(self.width / 2) + scale(2), footer_y + scale(2), math.floor(self.width / 2) - scale(6), footer_h - scale(4), Blitbuffer.COLOR_LIGHT_GRAY)
    local prev = TextWidget:new{
        text = _("◀ Page"),
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = self.width / 2 - scale(8),
    }
    prev:paintTo(bb, x + scale(8), footer_y + scale(4))
    local next_label = TextWidget:new{
        text = _("Page ▶"),
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = self.width / 2 - scale(8),
    }
    next_label:paintTo(bb, x + math.floor(self.width / 2) + scale(6), footer_y + scale(4))
    return true
end

function CraftingPanel:refresh()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    if self.inventory_panel then self.inventory_panel:refresh() end
    if self.event_line then self.event_line:refresh() end
    return true
end

function CraftingPanel:onTapMinecraftCrafting(first, second)
    local gesture = second or first
    local session = self.session
    if not session or not session.crafting_open then return false end
    local pos = gesture and gesture.pos
    if not pos then return true end
    local hit = self:hitTest(pos.x - self._origin_x, pos.y - self._origin_y)
    if hit.kind == "button" then
        if hit.id == "close" then
            session:closeOverlays()
        elseif hit.id == "prev" then
            session.craft_page = session.craft_page > 1 and session.craft_page - 1 or session:pageCount()
        elseif hit.id == "next" then
            session.craft_page = session.craft_page < session:pageCount() and session.craft_page + 1 or 1
        end
    elseif hit.kind == "recipe" then
        session:craft(hit.index)
    end
    self:refresh()
    return true
end

local NavButton = InputContainer:extend{
    title = "",
    width = nil,
    height = nil,
    callback = nil,
    primary = false,
    dimen = nil,
}

function NavButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftNav = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function NavButton:paintTo(bb, x, y)
    local range = self.ges_events.TapMinecraftNav[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    -- Minecraft-style 3D bevel: a black lower-right shadow, pale upper edge,
    -- and a square face stay legible on both Carta and color E-Ink panels.
    local shadow = math.max(1, math.min(3, math.floor(self.height * 0.06)))
    local face = self.primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
    local text_color = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintRect(x + shadow, y + shadow, self.width - shadow, self.height - shadow, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, self.width - shadow, self.height - shadow, face)
    bb:paintRect(x + 2, y + 2, math.max(1, self.width - shadow - 4), 1, self.primary and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_WHITE)
    bb:paintRect(x + 2, y + 2, 1, math.max(1, self.height - shadow - 4), self.primary and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_WHITE)
    local label = TextWidget:new{
        text = self.title, face = Font:getFace("smallinfofont", math.max(8, math.min(14, math.floor(self.height * 0.34)))),
        fgcolor = text_color, bold = true, max_width = math.max(scale(12), self.width - shadow - scale(8)),
    }
    local size = label:getSize()
    label:paintTo(bb, x + math.floor((self.width - shadow - size.w) / 2), y + math.floor((self.height - shadow - size.h) / 2))
    return true
end

function NavButton:onTapMinecraftNav(first, second)
    if self.canvas and self.canvas:routeModalTap(first, second) then return true end
    if self.callback then self.callback() end
    return true
end

-- Compact Bedrock-style jump control: a bordered light button with a bold
-- upward arrow is more recognizable on both color and monochrome E-Ink than a
-- text-only navigation button.
local JumpControl = InputContainer:extend{
    title = "Jump",
    width = nil,
    height = nil,
    callback = nil,
    dimen = nil,
}

function JumpControl:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftJump = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function JumpControl:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local range = self.ges_events.TapMinecraftJump[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + 2, y + 2, self.width - 4, self.height - 4, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x + 3, y + 3, self.width - 6, 1, Blitbuffer.COLOR_WHITE)
    local cx, cy = x + math.floor(self.width / 2), y + math.floor(self.height * 0.34)
    local radius = math.max(4, math.min(10, math.floor(self.height * 0.14)))
    for step = 0, radius do
        bb:paintRect(cx - step, cy - radius + step, step * 2 + 1, 1, Blitbuffer.COLOR_BLACK)
    end
    bb:paintRect(cx - 2, cy, 5, radius, Blitbuffer.COLOR_BLACK)
    local label = TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", math.max(8, math.min(13, math.floor(self.height * 0.18)))),
        fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = self.width - 8 }
    local size = label:getSize()
    label:paintTo(bb, x + math.max(4, math.floor((self.width - size.w) / 2)), y + self.height - size.h - 7)
    return true
end

function JumpControl:onTapMinecraftJump(first, second)
    if self.canvas and self.canvas:routeModalTap(first, second) then return true end
    if self.callback then self.callback() end
    return true
end

local MenuBackdrop = InputContainer:extend{ width = nil, height = nil, dimen = nil }

function MenuBackdrop:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function MenuBackdrop:paintTo(bb, x, y)
    local color_mode = colorRenderingEnabled() and bb.paintRectRGB32
    local function fill(left, top, width, height, ink)
        if color_mode then bb:paintRectRGB32(left, top, width, height, paletteColor(ink)) else bb:paintRect(left, top, width, height, ink == "white" and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK) end
    end
    fill(x, y, self.width, self.height, "black")
    local horizon = math.floor(self.height * 0.58)
    fill(x + 3, y + 3, self.width - 6, math.max(1, horizon - 3), "blue")
    -- Pixel clouds/stars, distant hills and a blocky ground create a real game
    -- scene behind the logo instead of a flat dark-gray dialog.
    for column = 0, math.floor(self.width / 26) do
        local cloud_y = y + 12 + ((column * 17) % math.max(16, math.floor(horizon * 0.45)))
        if column % 3 ~= 1 then fill(x + column * 26 + 5, cloud_y, 14, 3, "white") end
    end
    for column = 0, math.floor(self.width / 18) do
        local hill = 9 + ((column * 11 + column * column) % 24)
        fill(x + column * 18, y + horizon - hill, 20, hill + 4, column % 2 == 0 and "green" or "cyan")
    end
    fill(x + 3, y + horizon, self.width - 6, self.height - horizon - 3, "green")
    for row = 0, math.floor((self.height - horizon) / 14) do
        for column = 0, math.floor(self.width / 20) do
            if (row + column * 3) % 5 == 0 then fill(x + column * 20 + 4, y + horizon + row * 14 + 6, 5, 3, "red") end
        end
    end
    return true
end

local WorldPane = InputContainer:extend{ session = nil, canvas = nil }

function WorldPane:_act(action)
    if self.canvas then self.canvas:act(action) end
    return true
end

function WorldPane:onMinecraftForward() return self:_act("forward") end
function WorldPane:onMinecraftBack() return self:_act("back") end
function WorldPane:onMinecraftLeft() return self:_act("left") end
function WorldPane:onMinecraftRight() return self:_act("right") end

local WorldStore = {}
WorldStore.WORLDS_PER_PAGE = 6

local function stateFor(instance)
    if instance.minecraft then return instance.minecraft end
    local state = {
        session = VoxelSession.new(),
        world_store = WorldStore.load(),
        screen = "splash",
        create = { name = "My World", seed = "", mode = "Survival", difficulty = "Normal", cheats = false },
    }
    instance.minecraft = state
    return state
end

local function parseWorldSeed(value)
    local text = tostring(value or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    if not text:match("^[+-]?%d+$") then return false end
    local seed = tonumber(text)
    if not seed or seed < -MAX_WORLD_SEED or seed >= MAX_WORLD_SEED then return false end
    return normalizeSeed(seed)
end

-- Local world catalogue. The generated terrain remains deterministic from the
-- seed, so the catalogue stays small and robust on an E-Ink device while still
-- offering several named save slots like Bedrock's world picker.
local WORLD_STORE_DIR = ok_datastorage and (DataStorage:getDataDir() .. "/appdock_minecraft") or "/tmp/appdock_minecraft"
local WORLD_STORE_FILE = WORLD_STORE_DIR .. "/worlds.lua"

local function serializeWorldValue(value, indent)
    indent = indent or ""
    if type(value) == "number" then return tostring(value) end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return "nil" end
    local out, deeper = { "{" }, indent .. "  "
    for _, item in ipairs(value) do out[#out + 1] = "\n" .. deeper .. serializeWorldValue(item, deeper) .. "," end
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local encoded = type(key) == "string" and (key:match("^[%a_][%w_]*$") and key or "[" .. string.format("%q", key) .. "]") or "[" .. tostring(key) .. "]"
        out[#out + 1] = "\n" .. deeper .. encoded .. " = " .. serializeWorldValue(value[key], deeper) .. ","
    end
    if #out > 1 then out[#out + 1] = "\n" .. indent end
    out[#out + 1] = "}"
    return table.concat(out)
end

function WorldStore.ensure()
    if not ok_lfs then return true end
    local attr = lfs.attributes(WORLD_STORE_DIR)
    return attr and attr.mode == "directory" or lfs.mkdir(WORLD_STORE_DIR)
end

function WorldStore.load()
    local data = { version = 1, worlds = {} }
    local chunk = loadfile(WORLD_STORE_FILE)
    if not chunk then return data end
    if setfenv then setfenv(chunk, {}) end
    local ok, loaded = pcall(chunk)
    if not ok or type(loaded) ~= "table" or loaded.version ~= 1 or type(loaded.worlds) ~= "table" then return data end
    for _, world in ipairs(loaded.worlds) do
        if type(world) == "table" and tostring(world.name or "") ~= "" and parseWorldSeed(world.seed) ~= false then
            data.worlds[#data.worlds + 1] = {
                id = tostring(world.id or #data.worlds + 1),
                name = tostring(world.name):sub(1, 40),
                seed = parseWorldSeed(world.seed) or normalizeSeed(0),
                mode = world.mode == "Creative" and "Creative" or "Survival",
                difficulty = ({ Peaceful = true, Easy = true, Normal = true, Hard = true })[world.difficulty] and world.difficulty or "Normal",
                cheats = world.cheats == true,
                created = tostring(world.created or os.date("%d.%m.%y")),
            }
            if #data.worlds >= 32 then break end
        end
    end
    return data
end

function WorldStore.save(data)
    if not WorldStore.ensure() then return false end
    local tmp = WORLD_STORE_FILE .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return false end
    local ok = file:write("return " .. serializeWorldValue(data) .. "\n")
    file:close()
    if not ok then os.remove(tmp); return false end
    local renamed = os.rename(tmp, WORLD_STORE_FILE)
    if not renamed then os.remove(tmp) end
    return renamed ~= nil
end

local function promptNewWorld(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Create New World"),
        input = tostring(state.session.seed),
        input_hint = _("Integer seed; empty = random seed"),
        buttons = {
            {
                { text = _("Abbrechen"), callback = function() UIManager:close(dialog) end },
                { text = _("Create"), is_enter_default = true, callback = function()
                    local seed = parseWorldSeed(dialog:getInputText())
                    if seed == false then
                        UIManager:show(InfoMessage:new{ text = _("Please enter an integer between -2147483647 and 2147483646.") })
                        return
                    end
                    UIManager:close(dialog)
                    state.session:newWorld(seed)
                    if context.requestRebuild then context.requestRebuild("ui") end
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function rebuildScreen(state, context, screen)
    state.screen = screen
    if context.requestRebuild then context.requestRebuild("ui") end
end

local function menuPane(state, context, width, height, title, subtitle, items)
    local pane = WorldPane:new{ dimen = Geom:new{ w = width, h = height }, session = state.session }
    local logo = nil
    if ok_image_widget and ImageWidget then
        local logo_file = ensureEmbeddedLogo() or MINECRAFT_LOGO_EINK
        local logo_candidates = { logo_file, MINECRAFT_LOGO_EINK, MINECRAFT_LOGO, "assets/minecraft_logo_eink.png", "assets/minecraft_logo.png" }
        for _, candidate in ipairs(logo_candidates) do
            local file = io.open(candidate, "rb")
            if file then file:close(); logo_file = candidate; break end
        end
        local ok, widget = pcall(function()
            return ImageWidget:new{ file = logo_file, width = math.min(width - 30, 470), height = math.max(42, math.floor(height * 0.13)), scale_factor = 0, overlap_offset = { 15, math.max(8, math.floor(height * 0.045)) } }
        end)
        if ok then logo = widget end
    end
    local children = {
        MenuBackdrop:new{ width = width, height = height },
        logo or TextWidget:new{ text = "MINECRAFT", face = Font:getFace("cfont", math.max(22, math.floor(width / 14))), fgcolor = Blitbuffer.COLOR_WHITE, bold = true, max_width = width - 20, overlap_offset = { 10, math.max(12, math.floor(height * 0.08)) } },
        TextWidget:new{ text = title, face = Font:getFace("cfont", math.max(16, math.floor(width / 24))), fgcolor = Blitbuffer.COLOR_WHITE, bold = true, max_width = width - 20, overlap_offset = { 10, math.max(55, math.floor(height * 0.20)) } },
        TextWidget:new{ text = subtitle or "", face = Font:getFace("smallinfofont", math.max(9, math.floor(width / 55))), fgcolor = Blitbuffer.COLOR_WHITE, max_width = width - 20, overlap_offset = { 10, math.max(78, math.floor(height * 0.28)) } },
    }
    for _, item in ipairs(items) do children[#children + 1] = item end
    pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, unpack(children) }
    return pane
end

local function menuButton(title, width, height, x, y, callback, primary)
    return NavButton:new{ title = title, width = width, height = height, primary = primary, callback = callback, overlap_offset = { x, y } }
end

local function buildSplashPane(state, context, width, height)
    local button_w = math.min(math.floor(width * 0.78), 420)
    local button_h = math.max(46, math.min(66, math.floor(height * 0.10)))
    local gap = math.max(8, math.floor(height * 0.024))
    local stack_h = button_h * 3 + gap * 2
    local x = math.floor((width - button_w) / 2)
    local y = math.max(0, math.min(math.floor(height * 0.42), height - stack_h - 12))
    return menuPane(state, context, width, height, _("SURVIVAL + CREATIVE"), _("Build. Explore. Choose your mode."), {
        menuButton(_("PLAY WORLD"), button_w, button_h, x, y, function() rebuildScreen(state, context, "worlds") end, true),
        menuButton(_("SETTINGS"), button_w, button_h, x, y + button_h + gap, function() rebuildScreen(state, context, "settings") end),
        menuButton(_("ABOUT"), button_w, button_h, x, y + 2 * (button_h + gap), function() rebuildScreen(state, context, "about") end),
    })
end

local function openSavedWorld(state, context, world)
    state.active_world = world
    state.session:newWorld(world.seed, world.mode, world.difficulty)
    rebuildScreen(state, context, "world")
end

WorldStore.pageCount = function(world_count)
    return math.max(1, math.ceil((tonumber(world_count) or 0) / WorldStore.WORLDS_PER_PAGE))
end
WorldStore.pageRange = function(world_count, page)
    local pages = WorldStore.pageCount(world_count)
    page = clamp(math.floor(tonumber(page) or 1), 1, pages)
    local first = (page - 1) * WorldStore.WORLDS_PER_PAGE + 1
    return page, first, math.min(tonumber(world_count) or 0, first + WorldStore.WORLDS_PER_PAGE - 1), pages
end
WorldStore.createMenuMetrics = function(width, height)
    local gap = clamp(math.floor(height * 0.015), 6, 10)
    local left = math.max(10, math.floor(width * 0.08))
    local button_w = math.min(420, width - 2 * left)
    local y = math.max(120, math.floor(height * 0.30))
    local row_h = clamp(math.floor((height - y - 12 - 5 * gap) / 6), 40, 64)
    return { gap = gap, left = left, button_w = button_w, y = y, row_h = row_h, footer_y = height - row_h - 12 }
end
local function buildWorldsPane(state, context, width, height)
    local gap = math.max(6, math.floor(width * 0.015))
    local worlds = state.world_store.worlds
    local page, first, last, pages = WorldStore.pageRange(#worlds, state.worlds_page)
    state.worlds_page = page
    local control_y, control_h = height - 40, 32
    local back_w = math.min(82, math.floor(width * 0.20))
    local nav_w = math.min(64, math.floor(width * 0.15))
    local prev_x = gap + back_w + gap
    local next_x = width - nav_w - gap
    local page_left, page_right = prev_x + nav_w + gap, next_x - gap
    local page_w = math.max(1, math.min(42, page_right - page_left))
    local page_x = math.floor((page_left + page_right - page_w) / 2)
    local create_w = math.min(260, width - 2 * gap)
    local list_top = math.floor(height * 0.39)
    local row_gap = math.max(4, math.floor(height * 0.012))
    local card_h = clamp(math.floor((control_y - list_top - 2 * row_gap) / 3 - row_gap), 38, 78)
    local card_w = math.floor((width - 3 * gap) / 2)
    local items = {
        menuButton(_("Create New World"), create_w, 46, width - create_w - gap, math.max(10, math.floor(height * 0.30)), function() rebuildScreen(state, context, "create") end, true),
        menuButton(_("Back"), back_w, control_h, gap, control_y, function() rebuildScreen(state, context, "splash") end),
        menuButton(_("Prev"), nav_w, control_h, prev_x, control_y, function()
            state.worlds_page = math.max(1, (state.worlds_page or 1) - 1)
            rebuildScreen(state, context, "worlds")
        end),
        TextWidget:new{ text = tostring(page) .. " / " .. tostring(pages), face = Font:getFace("smallinfofont", 12), fgcolor = Blitbuffer.COLOR_WHITE, max_width = page_w,
            overlap_offset = { page_x, control_y + 8 } },
        menuButton(_("Next"), nav_w, control_h, next_x, control_y, function()
            state.worlds_page = math.min(pages, (state.worlds_page or 1) + 1)
            rebuildScreen(state, context, "worlds")
        end),
    }
    if #worlds == 0 then
        items[#items + 1] = TextWidget:new{ text = _("No saved worlds yet."), face = Font:getFace("smallinfofont", 13), fgcolor = Blitbuffer.COLOR_WHITE, max_width = width - 2 * gap, overlap_offset = { gap, math.floor(height * 0.50) } }
    else
        for index = first, last do
            local world = worlds[index]
            local local_index = index - first
            local column, row = local_index % 2, math.floor(local_index / 2)
            local x, y = gap + column * (card_w + gap), list_top + row * (card_h + row_gap)
            local label = world.name .. "\n" .. world.mode .. " · " .. world.difficulty .. "\nSeed: " .. tostring(world.seed)
            items[#items + 1] = menuButton(label, card_w, card_h, x, y, function() openSavedWorld(state, context, world) end, false)
        end
    end
    return menuPane(state, context, width, height, _("Your Worlds"), _("Choose a world or create a new one."), items)
end

local function promptWorldField(state, context, field, title, hint)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(state.create[field] or ""),
        input_hint = hint,
        buttons = {
            {
                { text = _("Abbrechen"), callback = function() UIManager:close(dialog) end },
                { text = _("Apply"), is_enter_default = true, callback = function()
                    local value = trim(dialog:getInputText())
                    if value ~= "" then state.create[field] = value end
                    UIManager:close(dialog)
                    rebuildScreen(state, context, "create")
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function createWorld(state, context)
    if #state.world_store.worlds >= 32 then
        UIManager:show(InfoMessage:new{ text = _("World limit reached (32). Delete or replace a save before creating another world.") })
        return
    end
    local seed = parseWorldSeed(state.create.seed)
    if state.create.seed ~= "" and seed == false then
        UIManager:show(InfoMessage:new{ text = _("The seed must be a valid integer.") })
        return
    end
    seed = seed or nextWorldSeed(state.session.seed)
    local world = {
        id = tostring(#state.world_store.worlds + 1) .. "-" .. tostring(seed),
        name = trim(state.create.name) ~= "" and trim(state.create.name):sub(1, 40) or _("My World"),
        seed = seed,
        mode = state.create.mode,
        difficulty = state.create.difficulty,
        cheats = state.create.cheats,
        created = os.date("%d.%m.%y"),
    }
    state.world_store.worlds[#state.world_store.worlds + 1] = world
    state.worlds_page = math.ceil(#state.world_store.worlds / WorldStore.WORLDS_PER_PAGE)
    WorldStore.save(state.world_store)
    state.create.seed = ""
    openSavedWorld(state, context, world)
end

local function buildCreatePane(state, context, width, height)
    local layout = WorldStore.createMenuMetrics(width, height)
    local gap, left, row_h, button_w, y = layout.gap, layout.left, layout.row_h, layout.button_w, layout.y
    local create_w = math.floor((button_w - gap) * 0.60)
    local back_w = button_w - gap - create_w
    local items = {
        menuButton(_("Name: ") .. state.create.name, button_w, row_h, left, y, function() promptWorldField(state, context, "name", _("World Name"), _("e.g. My World")) end),
        menuButton(_("Seed: ") .. (state.create.seed ~= "" and state.create.seed or _("Random")), button_w, row_h, left, y + row_h + gap, function() promptWorldField(state, context, "seed", _("World Seed"), _("Empty = random seed")) end),
        menuButton(_("Game Mode: ") .. state.create.mode, button_w, row_h, left, y + 2 * (row_h + gap), function() state.create.mode = state.create.mode == "Survival" and "Creative" or "Survival"; rebuildScreen(state, context, "create") end),
        menuButton(_("Difficulty: ") .. state.create.difficulty, button_w, row_h, left, y + 3 * (row_h + gap), function()
            local order = { "Peaceful", "Easy", "Normal", "Hard" }
            for i, value in ipairs(order) do if value == state.create.difficulty then state.create.difficulty = order[i % #order + 1]; break end end
            rebuildScreen(state, context, "create")
        end),
        menuButton(_("Cheats: ") .. (state.create.cheats and _("On") or _("Off")), button_w, row_h, left, y + 4 * (row_h + gap), function() state.create.cheats = not state.create.cheats; rebuildScreen(state, context, "create") end),
        menuButton(_("Create"), create_w, row_h, left, layout.footer_y, function() createWorld(state, context) end, true),
        menuButton(_("Back"), back_w, row_h, left + create_w + gap, layout.footer_y, function() rebuildScreen(state, context, "worlds") end),
    }
    return menuPane(state, context, width, height, _("Create New World"), _("Set the name, seed, and game rules."), items)
end

local function buildSettingsPane(state, context, width, height)
    local button_w, button_h = math.min(360, math.floor(width * 0.66)), 42
    local x, y = math.floor((width - button_w) / 2), math.floor(height * 0.38)
    return menuPane(state, context, width, height, _("Settings"), _("Display and gameplay"), {
        menuButton(_("Color: ") .. (state.session.color_enabled and _("On") or _("Off")), button_w, button_h, x, y, function() state.session:toggleColor(); rebuildScreen(state, context, "settings") end),
        menuButton(_("Back"), button_w, button_h, x, y + button_h + 10, function() rebuildScreen(state, context, "splash") end),
    })
end

local function buildAboutPane(state, context, width, height)
    local button_w, button_h = math.min(360, math.floor(width * 0.66)), 42
    local x = math.floor((width - button_w) / 2)
    return menuPane(state, context, width, height, _("About the Game"), _("Offline voxel sandbox for AppDock"), {
        TextWidget:new{ text = _("Survival · Creative · Voxel Mobs · Day & Night · Nether Portals\n\nMinecraft 3D 4.7.1"), face = Font:getFace("smallinfofont", 13), fgcolor = Blitbuffer.COLOR_WHITE, max_width = button_w, overlap_offset = { x, math.floor(height * 0.37) } },
        menuButton(_("Back"), button_w, button_h, x, height - button_h - 18, function() rebuildScreen(state, context, "splash") end),
    })
end

return {
    id = "minecraft",
    version = "4.7.1",
    title = "Minecraft 3D",
    subtitle = "Survival, Creative & Nether Portals",
    symbol = "M",
    logo = "minecraft",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or scale
        if state.screen == "splash" then return buildSplashPane(state, context, width, height) end
        if state.screen == "worlds" then return buildWorldsPane(state, context, width, height) end
        if state.screen == "create" then return buildCreatePane(state, context, width, height) end
        if state.screen == "settings" then return buildSettingsPane(state, context, width, height) end
        if state.screen == "about" then return buildAboutPane(state, context, width, height) end
        local margin, gap = math.min(px(9), math.floor(width * 0.03)), math.max(2, px(5))
        local header_h = math.min(px(48), math.floor(height * 0.16))
        local canvas_w = width - 2 * margin
        -- A compact, opaque HUD below the world. It never needs to be redrawn
        -- by the voxel renderer and no duplicate movement toolbar steals space.
        local touch_band_h = math.min(px(126), math.max(px(96), math.floor(height * 0.22)))
        local hotbar_h = math.min(px(48), math.max(px(36), math.floor(canvas_w / HOTBAR_SLOTS)))
        local footer_h = math.min(px(20), math.floor(height * 0.06))
        local canvas_h = math.max(24, height - header_h - touch_band_h - hotbar_h - footer_h - gap * 3)
        local canvas_y = header_h
        local hotbar_y = canvas_y + canvas_h + gap
        local touch_band_y = hotbar_y + hotbar_h + gap
        local hotbar_w = math.min(canvas_w, HOTBAR_SLOTS * (hotbar_h + px(4)))
        local hotbar_x = math.floor((width - hotbar_w) / 2)
        local joystick_size = math.min(touch_band_h, math.floor(canvas_w * 0.29))
        joystick_size = math.floor(joystick_size / 3) * 3
        local jump_w = math.min(px(82), math.floor(canvas_w * 0.20))
        local jump_h = math.min(px(72), touch_band_h - 2)
        local action_x = margin + joystick_size + gap * 2
        local action_space = math.max(12, canvas_w - joystick_size - jump_w - gap * 4)
        local button_w = math.min(px(176), action_space)
        action_x = action_x + math.floor((action_space - button_w) / 2)
        local controls_h = math.max(16, math.min(px(38), math.floor((touch_band_h - gap) / 2)))
        local world_button_w = math.max(8, math.min(px(55), math.floor(canvas_w * 0.20)))
        local header_gap = gap
        local color_button_w = math.max(8, math.min(px(58), math.floor(canvas_w * 0.21)))
        local heading_w = math.max(1, canvas_w - color_button_w - world_button_w - header_gap * 2)
        local heading_size = heading_w < px(105) and px(12) or px(17)
        local canvas = VoxelCanvas:new{ width = canvas_w, height = canvas_h, session = state.session }
        local hotbar = Hotbar:new{ width = hotbar_w, height = hotbar_h, session = state.session }
        local event_line = EventLine:new{ width = canvas_w, height = footer_h, session = state.session }
        local inventory_panel = InventoryPanel:new{ width = width, height = height, session = state.session, canvas = canvas }
        local crafting_panel = CraftingPanel:new{ width = canvas_w, height = canvas_h, session = state.session, canvas = canvas }
        inventory_panel.crafting_panel = crafting_panel
        inventory_panel.hotbar = hotbar
        inventory_panel.event_line = event_line
        crafting_panel.inventory_panel = inventory_panel
        crafting_panel.event_line = event_line
        hotbar.overlap_offset = { hotbar_x, hotbar_y }
        inventory_panel.overlap_offset = { 0, 0 }
        crafting_panel.overlap_offset = { margin, canvas_y }
        state.session.canvas = canvas
        hotbar.canvas = canvas
        state.session:startAmbientMobs()
        canvas.hotbar = hotbar
        canvas.event_line = event_line
        canvas.inventory_panel = inventory_panel
        canvas.crafting_panel = crafting_panel
        -- Keep the widgets reachable for refresh calls and for the regression
        -- tests: overlays must repaint their own region, never the full pane.
        state.canvas, state.hotbar, state.event_line = canvas, hotbar, event_line
        state.inventory_panel, state.crafting_panel = inventory_panel, crafting_panel
        local pane = WorldPane:new{
            dimen = Geom:new{ w = width, h = height }, session = state.session, canvas = canvas,
            ges_events = { TapMinecraftModal = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = width, h = height } } } },
        }
        -- The modal overlay sits above the world canvas. Route a screen-sized
        -- tap range through the pane as a fallback so KOReader cannot deliver
        -- the tap to a covered canvas/joystick instead of the open inventory.
        function pane:onTapMinecraftModal(first, second)
            if not state.session.inventory_open then return false end
            return inventory_panel:onTapMinecraftInventory(first, second)
        end
        function pane:onDeactivate()
            state.session:stopAmbientMobs()
            state.session:stopHeldMove()
            if state.session.motion then
                state.session.motion = nil
                UIManager:unschedule(state.session._motionTick)
            end
            if state.session.jump_frame then
                state.session.jump_frame, state.session.jump_offset = nil, 0
                UIManager:unschedule(state.session._jumpTick)
            end
        end
        local groups = Device.input and Device.input.group or {}
        pane.key_events = {}
        if groups.Left then pane.key_events.MinecraftLeft = { { groups.Left }, event = "MinecraftLeft" } end
        if groups.Right then pane.key_events.MinecraftRight = { { groups.Right }, event = "MinecraftRight" } end
        if groups.Up then pane.key_events.MinecraftForward = { { groups.Up }, event = "MinecraftForward" } end
        if groups.Down then pane.key_events.MinecraftBack = { { groups.Down }, event = "MinecraftBack" } end
        if groups.Press then pane.key_events.MinecraftForwardPress = { { groups.Press }, event = "MinecraftForward" } end
        if groups.Select then pane.key_events.MinecraftForwardSelect = { { groups.Select }, event = "MinecraftForward" } end
        canvas.overlap_offset = { margin, canvas_y }
        local joystick = Joystick:new{ width = joystick_size, height = joystick_size, canvas = canvas }
        joystick.overlap_offset = { margin, touch_band_y + math.floor((touch_band_h - joystick_size) / 2) }
        state.joystick = joystick
        local jump = JumpControl:new{ title = _("Jump"), width = jump_w, height = jump_h, canvas = canvas, callback = function() canvas:act("jump") end }
        jump.overlap_offset = { margin + canvas_w - jump_w, touch_band_y + math.floor((touch_band_h - jump_h) / 2) }
        canvas.control_dpad_region = { x = joystick.overlap_offset[1], y = joystick.overlap_offset[2], w = joystick_size, h = joystick_size }
        canvas.control_jump_region = { x = jump.overlap_offset[1], y = jump.overlap_offset[2], w = jump_w, h = jump_h }
        canvas.control_dpad_widget, canvas.control_jump_widget = joystick, jump
        local mode_label = state.session:tapActionLabel()
        local world_status_widget = TextWidget:new{
            text = state.session:statusText(),
            face = Font:getFace("smallinfofont", px(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = canvas_w,
            overlap_offset = { margin, px(29) },
        }
        world_status_widget._origin_x, world_status_widget._origin_y = margin, px(29)
        world_status_widget._refresh_width, world_status_widget._refresh_height = canvas_w, math.max(1, header_h - px(29))
        state.session.world_status_widget = world_status_widget
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = "MINECRAFT 3D", face = Font:getFace("cfont", heading_size), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = heading_w, overlap_offset = { margin, px(6) } },
            world_status_widget,
            NavButton:new{ title = _("Color"), width = color_button_w, height = math.min(px(25), header_h - 2), canvas = canvas, callback = function() if not state.session.inventory_open and not state.session.crafting_open then canvas:act("color") end end, overlap_offset = { margin + canvas_w - color_button_w, px(6) } },
            NavButton:new{ title = _("Menu"), width = world_button_w, height = math.min(px(25), header_h - 2), canvas = canvas, callback = function() if not state.session.inventory_open and not state.session.crafting_open then WorldStore.save(state.world_store); rebuildScreen(state, context, "worlds") end end, overlap_offset = { margin + canvas_w - color_button_w - header_gap - world_button_w, px(6) } },
            canvas,
            hotbar,
            crafting_panel,
            -- Keep the touch controls last in the overlap stack. Inventory and
            -- crafting repaint the canvas-sized region while open; drawing the
            -- D-pad afterwards prevents them from visually covering it.
            joystick,
            jump,
            NavButton:new{ title = _("Inventory"), width = button_w, height = controls_h, canvas = canvas, callback = function()
                canvas:act("inventory")
                inventory_panel:refresh()
            end, overlap_offset = { action_x, touch_band_y + math.floor((touch_band_h - controls_h * 2 - gap) / 2) } },
            NavButton:new{ title = mode_label, width = button_w, height = controls_h, canvas = canvas, callback = function()
                canvas:act("mode")
                if context.requestRebuild then context.requestRebuild("ui") end
            end, overlap_offset = { action_x, touch_band_y + math.floor((touch_band_h - controls_h * 2 - gap) / 2) + controls_h + gap } },
            event_line,
            -- The inventory is the final opaque layer: mob and canvas repaints
            -- cannot appear over it while it is open.
            inventory_panel,
        }
        event_line.overlap_offset = { margin, height - footer_h }
        return pane
    end,
    _test = {
        VoxelSession = VoxelSession,
        WorldStore = WorldStore,
        worldPageCount = WorldStore.pageCount,
        worldPageRange = WorldStore.pageRange,
        createMenuMetrics = WorldStore.createMenuMetrics,
        VoxelCanvas = VoxelCanvas,
        Joystick = Joystick,
        JumpControl = JumpControl,
        InventoryPanel = InventoryPanel,
        CraftingPanel = CraftingPanel,
        Hotbar = Hotbar,
        EventLine = EventLine,
        NavButton = NavButton,
        buildWorld = buildWorld,
        buildNetherWorld = buildNetherWorld,
        buildWorldsPane = buildWorldsPane,
        buildCreatePane = buildCreatePane,
        findPortalFrame = findPortalFrame,
        activatePortalFrame = activatePortalFrame,
        deactivatePortal = deactivatePortal,
        portalContains = portalContains,
        findSpawn = findSpawn,
        findVillageSite = findVillageSite,
        hasClearTreeView = hasClearTreeView,
        blockAt = blockAt,
        rawBlockAt = rawBlockAt,
        heightAt = heightAt,
        materialAt = materialAt,
        biomeAt = biomeAt,
        extraBlockKey = extraBlockKey,
        rebuildWorldBlocks = rebuildWorldBlocks,
        parseWorldSeed = parseWorldSeed,
        ensureEmbeddedLogo = ensureEmbeddedLogo,
        renderGridFor = renderGridFor,
        textureCoordinates = textureCoordinates,
        colorForMaterial = colorForMaterial,
        materialLabel = materialLabel,
        paletteMixForRGB = paletteMixForRGB,
        paletteMixForMaterial = paletteMixForMaterial,
        colorRenderingEnabled = colorRenderingEnabled,
        paletteColor = paletteColor,
        abbreviationFor = abbreviationFor,
        COLOR_PALETTE = COLOR_PALETTE,
        MATERIALS = MATERIALS,
        MATERIAL_ORDER = MATERIAL_ORDER,
        MATERIAL_LABELS = MATERIAL_LABELS,
        DROPS = DROPS,
        PATTERNS = PATTERNS,
        PATTERN_VALUES = PATTERN_VALUES,
        PATTERN_AVERAGES = PATTERN_AVERAGES,
        SURFACE_TONES = SURFACE_TONES,
        RECIPES = RECIPES,
        RECIPE_PAGES = RECIPE_PAGES,
        BIOMES = BIOMES,
        BIOME_ORDER = BIOME_ORDER,
        MOB_DEFS = MOB_DEFS,
        generateMobs = generateMobs,
        rebuildLightSources = rebuildLightSources,
        daylightForTime = daylightForTime,
        scenePaletteForTime = scenePaletteForTime,
        TREE_DEFS = TREE_DEFS,
        STARTING_KIT = STARTING_KIT,
        STARTING_COUNTS = STARTING_COUNTS,
        WORLDS_PER_PAGE = WorldStore.WORLDS_PER_PAGE,
        MAX_HEALTH = VoxelSession.MAX_HEALTH,
        MAX_HUNGER = VoxelSession.MAX_HUNGER,
        WORLD_SIZE = WORLD_SIZE,
        WATER_LEVEL = WATER_LEVEL,
        MAX_TERRAIN_HEIGHT = MAX_TERRAIN_HEIGHT,
        MAX_COLUMN_HEIGHT = MAX_COLUMN_HEIGHT,
        MAX_VIEW_DISTANCE = MAX_VIEW_DISTANCE,
        RENDER_SCALE = RENDER_SCALE,
        RENDER_COLS = RENDER_COLS,
        RENDER_ROWS = RENDER_ROWS,
        RENDER_SAMPLE = RENDER_SAMPLE,
        COLOR_RENDER_SAMPLE = COLOR_RENDER_SAMPLE,
        WALK_DISTANCE = WALK_DISTANCE,
        TURN_ANGLE = TURN_ANGLE,
        MOVE_FRAMES = MOVE_FRAMES,
        MOVE_FRAME_SECONDS = MOVE_FRAME_SECONDS,
        HELD_MOVE_SECONDS = HELD_MOVE_SECONDS,
        DAY_LENGTH_TICKS = DAY_LENGTH_TICKS,
        MOBS_PER_KIND = MOBS_PER_KIND,
        AMBIENT_MOB_SECONDS = AMBIENT_MOB_SECONDS,
        MAX_MOBS = MAX_MOBS,
        MAX_RENDERED_MOBS = MAX_RENDERED_MOBS,
        numericMoveDirection = numericMoveDirection,
        HOTBAR_SLOTS = HOTBAR_SLOTS,
        INVENTORY_SLOTS = INVENTORY_SLOTS,
        STACK_LIMIT = STACK_LIMIT,
        CRAFT_ROWS_PER_PAGE = CRAFT_ROWS_PER_PAGE,
        PLAYER_EYE_HEIGHT = PLAYER_EYE_HEIGHT,
    },
}
