-- Deterministische Regressionen für den Mob-/E-Ink-Patch.
-- Ausführen: lua5.1 test_minecraft_performance.lua
-- Die Tests messen keine Wall-Clock-Zeit. Sie prüfen stattdessen harte Budgets,
-- repaint-Regionen, Scheduling und die Anzahl teurer Sichtprüfungen.

local function class()
    local C = {}
    function C:new(value)
        value = value or {}
        setmetatable(value, { __index = C })
        if value.init then value:init() end
        return value
    end
    function C:extend(proto)
        local E = class()
        setmetatable(E, { __index = C })
        for key, value in pairs(proto or {}) do E[key] = value end
        return E
    end
    return C
end
local function install(name, value) package.preload[name] = function() return value end end
local painted, scheduled, dirty_calls, repaint_calls = {}, {}, {}, 0
local function resetDraws() painted, dirty_calls, repaint_calls = {}, {}, 0 end
local function newBuffer()
    local bb = {}
    function bb:paintRect(x, y, w, h, ink) painted[#painted + 1] = { x = x, y = y, w = w, h = h, ink = ink } end
    function bb:paintRectRGB32(x, y, w, h, ink) painted[#painted + 1] = { x = x, y = y, w = w, h = h, ink = ink, rgb = true } end
    return bb
end

local Widget, Input = class(), class()
install("ffi/blitbuffer", {
    COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "darkgray", COLOR_LIGHT_GRAY = "lightgray",
    colorFromString = function(hex) return hex end,
})
install("device", { screen = { scaleBySize = function(_, n) return n end, isColorEnabled = function() return false end }, input = { group = {} } })
install("ui/font", { getFace = function() return {} end })
install("ui/geometry", { new = function(_, value) return value end })
install("ui/gesturerange", { new = function(_, value) return value end })
install("ui/widget/horizontalspan", Widget)
install("ui/widget/textwidget", Widget)
install("ui/widget/container/centercontainer", Widget)
install("ui/widget/container/framecontainer", Widget)
install("ui/widget/container/inputcontainer", Input)
install("ui/widget/overlapgroup", Widget)
install("ui/widget/container/widgetcontainer", Widget)
install("gettext", function(value) return value end)
local manager = {
    scheduleIn = function(_, delay, callback) scheduled[#scheduled + 1] = { delay = delay, callback = callback } end,
    unschedule = function() end,
    widgetRepaint = function(_, widget, x, y) repaint_calls = repaint_calls + 1 end,
    setDirty = function(_, widget, waveform, region) dirty_calls[#dirty_calls + 1] = { waveform = waveform, region = region } end,
    forceRePaint = function() end,
    yieldToEPDC = function() end,
    show = function() end, close = function() end,
}
install("ui/uimanager", manager)
install("ui/widget/inputdialog", Widget:extend{})
install("ui/widget/infomessage", Widget:extend{})
_G.unpack = table.unpack or unpack

local app = assert(loadfile(arg[1] or "minecraft.lua"))()
local test = assert(app._test, "minecraft.lua must expose _test helpers")
local VoxelSession, VoxelCanvas = test.VoxelSession, test.VoxelCanvas
assert(VoxelCanvas.refreshMobs, "partial mob refresh must exist")

local session = VoxelSession.new(24680)
local world = session.world
session.player_x, session.player_z, session.yaw, session.pitch = 20.5, 20.5, 0, 0
local function mob(kind, z)
    return { kind = kind or "sheep", x = 20.5, z = z, y = session:mobGroundAt(20.5, z) or 1, heading = 0, gait = 0, walk_cycle = 0 }
end

-- 1. Entferntere Mobs sind wirklich passiv: kein Ground-Lookup, keine Bewegung.
local far = mob("sheep", 39.6)
far.head_bob = 0.02
world.mobs = { far }
local old_ground, ground_calls = session.mobGroundAt, 0
session.mobGroundAt = function() ground_calls = ground_calls + 1; return 1 end
local far_x, far_z = far.x, far.z
session:tickMobs()
assert(ground_calls == 0 and far.x == far_x and far.z == far_z and far.head_bob == 0,
    "Mobs jenseits von 18 Blöcken müssen schlafen, ohne Collision-Work")
session.mobGroundAt = old_ground

-- 2. Sichtprüfungen bleiben auch bei einer Menge Mobs begrenzt; gemalt wird fern nach nah.
world.mobs = {}
for index = 1, 8 do world.mobs[index] = mob("sheep", 21.5 + index) end
local old_los, old_draw, los_calls, draw_order = VoxelCanvas._mobHasLineOfSight, VoxelCanvas._drawMob, 0, {}
VoxelCanvas._mobHasLineOfSight = function(_, _, entity) los_calls = los_calls + 1; return true end
VoxelCanvas._drawMob = function(_, _, _, _, _, entity) draw_order[#draw_order + 1] = entity.z end
local canvas = VoxelCanvas:new{ width = 210, height = 126, session = session }
canvas:_drawMobs(newBuffer(), 13, 7, session, false)
assert(#draw_order == test.MAX_RENDERED_MOBS and los_calls == test.MAX_RENDERED_MOBS,
    "Bei sichtbaren Mobs dürfen höchstens MAX_RENDERED_MOBS LOS-Tests/Draws stattfinden")
assert(draw_order[1] > draw_order[2] and draw_order[2] > draw_order[3],
    "Mob-Painter-Reihenfolge muss fern nach nah sein")
los_calls, draw_order = 0, {}
VoxelCanvas._mobHasLineOfSight = function() los_calls = los_calls + 1; return false end
canvas:_drawMobs(newBuffer(), 13, 7, session, false)
assert(los_calls == math.min(#world.mobs, test.MAX_MOBS), "Sichtprüfungen müssen am Weltpopulationslimit begrenzt bleiben")
los_calls, draw_order = 0, {}
VoxelCanvas._mobHasLineOfSight = function(_, _, entity) los_calls = los_calls + 1; return entity.z > 27.5 end
canvas:_drawMobs(newBuffer(), 13, 7, session, false)
assert(#draw_order == 2 and los_calls == 8, "Sechs verdeckte Tiere dürfen weiter entfernte sichtbare Mobs nicht verschwinden lassen")
VoxelCanvas._mobHasLineOfSight, VoxelCanvas._drawMob = old_los, old_draw

-- 3. Der Origin-Fix rastert projizierte Flächen relativ zum Canvas, malt aber absolut.
resetDraws()
canvas:_fillProjectedFace(newBuffer(), { { 43, 33 }, { 53, 33 }, { 53, 43 }, { 43, 43 } }, "black", false, 33, 23)
local first_x, first_y = painted[1] and painted[1].x, painted[1] and painted[1].y
resetDraws()
canvas:_fillProjectedFace(newBuffer(), { { 44, 34 }, { 54, 34 }, { 54, 44 }, { 44, 44 } }, "black", false, 34, 24)
assert(first_x and painted[1] and painted[1].x == first_x + 1 and painted[1].y == first_y + 1,
    "_fillProjectedFace muss lokal rastern und die Canvas-Origin wieder addieren")

-- 4. Der Ambient-Timer darf Touch/Bewegung/Modal nicht mit Repaints unterbrechen,
-- muss sich aber in jedem Fall deterministisch neu anmelden.
session.canvas = canvas
local old_advance, old_refresh = session.advanceEnvironment, canvas.refreshFast
session.advanceEnvironment = function(self) self._mobs_dirty = true end
canvas.refreshFast = function() error("gesperrter Ambient-Zustand darf nicht repainten") end
world.mobs = { mob("sheep", 24.5) }
for _, field in ipairs({ "live_look", "motion", "jump_frame", "inventory_open", "crafting_open" }) do
    scheduled = {}
    session.live_look, session.motion, session.jump_frame, session.inventory_open, session.crafting_open = false, nil, nil, false, false
    session[field] = field == "motion" and {} or (field == "jump_frame" and 1 or true)
    session:tickAmbientMobs()
    assert(#scheduled == 1 and scheduled[1].delay == test.AMBIENT_MOB_SECONDS,
        "Ambient-Timer muss auch bei " .. field .. " genau einmal weiterlaufen")
end
session.advanceEnvironment, canvas.refreshFast = old_advance, old_refresh
session.live_look, session.motion, session.jump_frame, session.inventory_open, session.crafting_open = false, nil, nil, false, false

-- 5. Im Idle-Fall nutzt der Timer eine Teilregion und _drawScene restauriert Terrain
-- aus Lua-Tabellen; der Repaint-Mock ruft paintTo wie KOReader auf.
world.mobs = { mob("sheep", 24.5) }
world.mobs[1].y = session:groundHeightAtPlayer()
canvas._mobHasLineOfSight = function() return true end
local buffer = newBuffer()
canvas:paintTo(buffer, 13, 7)
assert(canvas._terrain_cache and #canvas._terrain_cache.rects > 0, "Vollbild-Draw muss Terrainspans cachen")
manager.widgetRepaint = function(_, widget, x, y) repaint_calls = repaint_calls + 1; widget:paintTo(buffer, x, y) end
resetDraws()
session._mobs_dirty = true
canvas._mob_refresh_request = true
assert(canvas:refreshFast(), "Idle-Mob-Refresh muss behandelt werden")
local dirty = dirty_calls[#dirty_calls]
assert(dirty and dirty.region and dirty.region.w <= canvas.width and dirty.region.h <= canvas.height,
    "Mob-Refresh darf nur eine Canvas-Teilregion als dirty markieren")
assert(dirty.region.w < canvas.width or dirty.region.h < canvas.height,
    "Der Mob-Refresh darf nicht auf eine Vollbild-Region zurückfallen")
assert(canvas._mob_refresh_region == nil and session._mobs_dirty == false,
    "Teil-Draw muss die Pending-Region und Mob-Dirty-Flag bereinigen")
-- Every actual write, including the crosshair/outline, stays in the dirty patch.
for _, rect in ipairs(painted) do
    assert(rect.x >= dirty.region.x and rect.y >= dirty.region.y
        and rect.x + rect.w <= dirty.region.x + dirty.region.w
        and rect.y + rect.h <= dirty.region.y + dirty.region.h,
        "Teilupdates dürfen keine Pixel außerhalb der Refreshregion ändern")
end

-- Hidden/offscreen animals must neither paint nor request an E-Ink update.
world.mobs = { mob("sheep", 24.5) }
canvas._mobHasLineOfSight = function() return false end
canvas:paintTo(buffer, 13, 7)
resetDraws()
session._mobs_dirty, canvas._mob_refresh_request = true, true
assert(canvas:refreshFast() and repaint_calls == 0 and #dirty_calls == 0,
    "Unsichtbare Mobs dürfen keine Welt-Neuberechnung oder Display-Updates verursachen")
assert(not session._mobs_dirty, "Unveränderte Sicht muss das Mob-Dirty-Flag zurücksetzen")

-- A lighting bucket invalidates terrain even if there are no visible mobs.
world.mobs = {}
canvas:paintTo(buffer, 13, 7)
resetDraws()
session.world_ticks = session.world_ticks + 8
session:tickAmbientMobs()
assert(repaint_calls > 0 and #dirty_calls > 0
    and dirty_calls[#dirty_calls].region.w == canvas.width,
    "Tageszeit muss unabhängig von sichtbaren Mobs weiter aktualisieren")

-- Zombies do not appear in Creative or Peaceful.
world.mobs = { mob("zombie", 24.5) }
canvas._mobHasLineOfSight = function() return true end
session.world_time, session.mode, session.difficulty = 0, "Creative", "Normal"
assert(#canvas:_visibleMobs(session) == 0, "Creative darf keine feindlichen Mobs anzeigen")
session.mode, session.difficulty = "Survival", "Peaceful"
assert(#canvas:_visibleMobs(session) == 0, "Peaceful darf keine feindlichen Mobs anzeigen")
session.difficulty = "Normal"
assert(#canvas:_visibleMobs(session) == 1, "Survival muss nächtliche Zombies behalten")
-- Camera motion keeps the same color/gray material path; only the existing
-- fast waveform changes, so color dithering is not lost while panning.
session.live_look = true
session.color_enabled = true
require("device").screen.isColorEnabled = function() return true end
resetDraws()
canvas:paintTo(buffer, 13, 7)
assert(#painted > 0, "Bewegungsvorschau muss weiterhin den Renderpfad zeichnen")
local rgb_writes = 0
for _, rect in ipairs(painted) do if rect.rgb then rgb_writes = rgb_writes + 1 end end
assert(rgb_writes > 0, "Farb-E-Ink-Bewegung muss das Farbdithering beibehalten")
session.live_look = false

print("minecraft-performance-4.7.2-ok")
