--[[--
Minecraft 3D for AppDock.

A compact, offline voxel explorer for E-Ink and color displays. The world is a
deterministic height-field made from unit blocks. Its renderer uses a
column-based voxel-space projection so movement only redraws the game canvas,
never the full AppDock pane.
Every interactive redraw goes through UIManager:setDirty(..., "fast", region).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Screen = Device.screen
local TAU = math.pi * 2
local WORLD_SIZE = 80
local MAX_TERRAIN_HEIGHT = 14
local MAX_COLUMN_HEIGHT = 18
local MAX_VIEW_DISTANCE = 48
local RENDER_SCALE = 1
-- High detail budget for the renderer; compact panes still clamp this to
-- their actual canvas dimensions below.
local RENDER_COLS = 800
local RENDER_ROWS = 800
local COLOR_PALETTE = {
    black = { 0, 0, 0 },
    red = { 220, 45, 45 },
    green = { 45, 170, 70 },
    blue = { 55, 105, 220 },
    cyan = { 25, 175, 185 },
    magenta = { 195, 60, 175 },
    yellow = { 225, 185, 35 },
}
local MATERIAL_COLORS = {
    grass = "green", leaves = "green", dirt = "red", wood = "red",
    stone = "blue", water = "blue", snow = "cyan", sand = "yellow",
    coal = "black", iron = "cyan", gold = "yellow",
}
local PLAYER_EYE_HEIGHT = 1.65
local WALK_DISTANCE = 0.64
local TURN_ANGLE = math.pi / 12
local MOVE_FRAMES = 4
local MOVE_FRAME_SECONDS = 0.045
local START_PLAYER_X = 44.5
local START_PLAYER_Z = 52.5
local START_YAW = math.pi / 2

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function wrapAngle(value) return value % TAU end

local function colorHardwareAvailable()
    return type(Screen.isColorEnabled) == "function"
        and Screen:isColorEnabled()
        and type(Blitbuffer.ColorRGB32) == "function"
end

local function colorForMaterial(material)
    local rgb = COLOR_PALETTE[MATERIAL_COLORS[material] or "black"]
    if not colorHardwareAvailable() then return Blitbuffer.COLOR_BLACK end
    return Blitbuffer.ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF)
end

-- Render no more logical pixels than the assigned canvas can represent. This
-- avoids overdraw on compact split panes while retaining the 240x240 detail
-- budget on normal AppDock panes.
local function renderGridFor(width, height)
    local cols = math.max(1, math.min(RENDER_COLS, math.floor(width)))
    local rows = math.max(1, math.min(RENDER_ROWS, math.floor(height)))
    return cols, rows
end

local function emptySizedWidget(width, height)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalSpan:new{ width = 0 },
    }
end

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

local function buildWorld(seed)
    seed = tonumber(seed) or 12345
    local world = { size = WORLD_SIZE, seed = seed, heights = {}, materials = {}, biomes = {} }
    for z = 0, WORLD_SIZE - 1 do
        world.heights[z + 1], world.materials[z + 1], world.biomes[z + 1] = {}, {}, {}
        for x = 0, WORLD_SIZE - 1 do
            local temperature = noise2(seed + 1700, x, z, 26) * 0.72 + noise2(seed, x + 80, z - 31, 9) * 0.28
            local humidity = noise2(seed + 900, x, z, 22)
            local rugged = noise2(seed + 2500, x, z, 30)
            local biome = "plains"
            if rugged > 0.80 then biome = "mountains"
            elseif temperature < 0.18 then biome = "tundra"
            elseif temperature < 0.34 then biome = "taiga"
            elseif temperature > 0.78 and humidity < 0.35 then biome = "desert"
            elseif humidity > 0.78 then biome = "swamp"
            elseif humidity > 0.53 then biome = "forest" end
            local broad = noise2(seed, x, z, 18)
            local detail = noise2(seed + 311, x, z - 7, 5)
            local height = 3 + math.floor(broad * 3 + detail * 2)
            if biome == "mountains" then height = 8 + math.floor(noise2(seed, x, z, 11) * 9 + noise2(seed + 41, x, z + 7, 3) * 4)
            elseif biome == "tundra" then height = 5 + math.floor(broad * 3)
            elseif biome == "swamp" then height = 2 + math.floor(broad * 2) end
            local lake = (biome == "swamp" and noise2(seed + 77, x, z, 4) < 0.38)
                or (biome == "plains" and noise2(seed + 77, x, z, 7) < 0.12)
            if lake then height = math.max(1, height - 1) end
            local material = lake and "water" or (biome == "desert" and "sand" or (biome == "mountains" and "stone" or (biome == "tundra" and "snow" or "grass")))
            world.heights[z + 1][x + 1] = clamp(height, 1, MAX_TERRAIN_HEIGHT)
            world.materials[z + 1][x + 1] = material
            world.biomes[z + 1][x + 1] = biome
        end
    end
    -- Trees are calculated from an immutable terrain snapshot. Reading back
    -- previously raised crown cells turns leaves into tree roots and lets their
    -- height grow across the whole biome on every later iteration.
    local terrain_heights = {}
    for z = 1, WORLD_SIZE do
        terrain_heights[z] = {}
        for x = 1, WORLD_SIZE do terrain_heights[z][x] = world.heights[z][x] end
    end
    -- C's tree pass, adapted to the height-field renderer: trunks and crowns
    -- become visible stepped columns while keeping generation deterministic.
    for z = 2, WORLD_SIZE - 3 do for x = 2, WORLD_SIZE - 3 do
        local biome = world.biomes[z + 1][x + 1]
        local chance = hash2(seed + 11, x, z)
        local can_grow = (biome == "forest" or biome == "taiga") and chance > 0.72
            or biome == "plains" and chance < 0.12
        if can_grow then
            local h = terrain_heights[z + 1][x + 1]
            local trunk_height = math.min(MAX_COLUMN_HEIGHT, h + 3)
            if world.heights[z + 1][x + 1] <= trunk_height then
                world.heights[z + 1][x + 1], world.materials[z + 1][x + 1] = trunk_height, "wood"
            end
            local crown_height = math.min(MAX_COLUMN_HEIGHT, h + 4)
            for dz = -1, 1 do for dx = -1, 1 do
                if math.abs(dx) + math.abs(dz) > 0 and world.heights[z + dz + 1][x + dx + 1] < crown_height then
                    world.heights[z + dz + 1][x + dx + 1] = crown_height
                    world.materials[z + dz + 1][x + dx + 1] = "leaves"
                end
            end end
        end
    end end
    return world
end

local function heightAt(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return 0 end
    return world.heights[z + 1][x + 1] or 0
end

local function materialAt(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return "stone" end
    return (world.materials[z + 1] and world.materials[z + 1][x + 1]) or "grass"
end

local function textureCoordinates(face, hx, hy, hz, side)
    local function fraction(value) return value - math.floor(value) end
    if face == "top" or side == 1 then return fraction(hx), fraction(hz) end
    if side == 0 then return fraction(hz), fraction(hy) end
    return fraction(hx), fraction(hy)
end

local function blockHash3(seed, x, z, level)
    local n = (seed * 1103515245 + x * 374761393 + z * 668265263 + level * 2246822519) % 2147483647
    n = (n * 1274126177 + 1442695041) % 2147483647
    return n
end

-- The C program raycasts individual blocks, not just a column silhouette.
-- Keep the same layered rule in Lua so the DDA sees surface, dirt, stone and
-- sparse ore blocks at separate heights.
local function blockAt(world, x, z, level)
    if x < 0 or z < 0 or x >= world.size or z >= world.size or level < 0 then return nil end
    local height = heightAt(world, x, z)
    if level >= height then return nil end
    local surface = materialAt(world, x, z)
    if level == height - 1 then return surface end
    if surface == "wood" or surface == "leaves" then
        return level >= math.max(0, height - 3) and surface or "dirt"
    end
    if level == 0 then return "stone" end
    if level < height - 2 then
        local ore = blockHash3(world.seed or 12345, x, z, level) % 100
        if ore < 4 then return "coal" end
        if ore == 4 then return "iron" end
        if ore == 5 then return "gold" end
        return "stone"
    end
    return "dirt"
end

local VoxelSession = {}
VoxelSession.__index = VoxelSession

function VoxelSession.new(seed)
    local self = setmetatable({
        seed = tonumber(seed) or 12345,
        world = buildWorld(seed),
        player_x = START_PLAYER_X,
        player_z = START_PLAYER_Z,
        yaw = START_YAW,
        pitch = 0,
        steps = 0,
        last_event = _("Bereit — erkunde die Blockwelt."),
        canvas = nil,
        motion = nil,
        jump_offset = 0,
        jump_frame = nil,
        inventory_open = false,
        color_enabled = false,
        selected_slot = 1,
        inventory = { grass = 12, dirt = 8, stone = 6, wood = 3, leaves = 4, sand = 5, snow = 4 },
        hotbar = { "grass", "dirt", "stone", "wood", "leaves", "sand", "snow", "water", "grass" },
    }, VoxelSession)
    self._motionTick = function() self:tickMotion() end
    self._jumpTick = function() self:tickJump() end
    return self
end

function VoxelSession:groundHeightAtPlayer()
    return heightAt(self.world, math.floor(self.player_x), math.floor(self.player_z))
end

function VoxelSession:newWorld(seed)
    self.seed = tonumber(seed) or (self.seed + 1)
    self.world = buildWorld(self.seed)
    self.player_x, self.player_z, self.yaw, self.pitch = START_PLAYER_X, START_PLAYER_Z, START_YAW, 0
    self.steps, self.last_event = 0, _("Neue Welt erzeugt.")
    return true
end

function VoxelSession:selectedMaterial()
    return self.hotbar[self.selected_slot] or "grass"
end

function VoxelSession:selectSlot(slot)
    if slot >= 1 and slot <= #self.hotbar then self.selected_slot = slot; return true end
    return false
end

function VoxelSession:toggleInventory()
    self.inventory_open = not self.inventory_open
    self.last_event = self.inventory_open and _("Inventar geöffnet.") or _("Inventar geschlossen.")
    return true
end

function VoxelSession:toggleColor()
    self.color_enabled = not self.color_enabled
    self.last_event = self.color_enabled and _("Farbrendering aktiviert.") or _("Monochromes Rendering aktiviert.")
    return true
end

function VoxelSession:mine()
    local tx = math.floor(self.player_x + math.sin(self.yaw) * 1.6)
    local tz = math.floor(self.player_z + math.cos(self.yaw) * 1.6)
    local h = heightAt(self.world, tx, tz)
    if h <= 1 then self.last_event = _("Hier ist kein Block."); return false end
    local material = materialAt(self.world, tx, tz)
    self.world.heights[tz + 1][tx + 1] = h - 1
    self.world.materials[tz + 1][tx + 1] = h - 1 <= 1 and "grass" or material
    self.inventory[material] = (self.inventory[material] or 0) + 1
    self.last_event = _("Block abgebaut.")
    return true
end

function VoxelSession:place()
    local material = self:selectedMaterial()
    if (self.inventory[material] or 0) <= 0 then self.last_event = _("Inventar leer."); return false end
    local tx = math.floor(self.player_x + math.sin(self.yaw) * 1.6)
    local tz = math.floor(self.player_z + math.cos(self.yaw) * 1.6)
    if tx < 1 or tz < 1 or tx >= self.world.size - 1 or tz >= self.world.size - 1 then return false end
    local height = heightAt(self.world, tx, tz)
    if height >= MAX_COLUMN_HEIGHT then self.last_event = _("Dieser Block ist bereits maximal hoch."); return false end
    self.world.heights[tz + 1][tx + 1] = height + 1
    self.world.materials[tz + 1][tx + 1] = material
    self.inventory[material] = self.inventory[material] - 1
    self.last_event = _("Block platziert.")
    return true
end

function VoxelSession:jump()
    if self.jump_frame then return false end
    self.jump_frame = 0
    self.last_event = _("Sprung!")
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

function VoxelSession:turn(direction)
    self.yaw = wrapAngle(self.yaw + direction * TURN_ANGLE)
    self.last_event = direction < 0 and _("Nach links gedreht.") or _("Nach rechts gedreht.")
    return true
end

function VoxelSession:lookVertical(direction)
    self.pitch = math.max(-1.35, math.min(1.35, self.pitch + direction * 0.14))
    self.last_event = direction > 0 and _("Nach oben gesehen.") or _("Nach unten gesehen.")
    return true
end

function VoxelSession:move(direction)
    local next_x = self.player_x + math.sin(self.yaw) * WALK_DISTANCE * direction
    local next_z = self.player_z + math.cos(self.yaw) * WALK_DISTANCE * direction
    -- Keep the camera away from the outside edge. It prevents rays crossing the
    -- world boundary from becoming a noisy, empty horizon.
    if next_x < 1 or next_z < 1 or next_x >= self.world.size - 1 or next_z >= self.world.size - 1 then
        self.last_event = _("Weltgrenze erreicht.")
        return false
    end
    local from_height = self:groundHeightAtPlayer()
    local to_height = heightAt(self.world, math.floor(next_x), math.floor(next_z))
    if to_height > from_height + 1 then
        self.last_event = _("Dieser Block ist zu hoch.")
        return false
    end
    self.player_x, self.player_z = next_x, next_z
    self.steps = self.steps + 1
    self.last_event = direction > 0 and _("Vorwärts.") or _("Rückwärts.")
    return true
end

function VoxelSession:beginMove(direction)
    if self.motion then return false end
    local next_x = self.player_x + math.sin(self.yaw) * WALK_DISTANCE * direction
    local next_z = self.player_z + math.cos(self.yaw) * WALK_DISTANCE * direction
    if next_x < 1 or next_z < 1 or next_x >= self.world.size - 1 or next_z >= self.world.size - 1 then
        self.last_event = _("Weltgrenze erreicht.")
        return false
    end
    if heightAt(self.world, math.floor(next_x), math.floor(next_z)) > self:groundHeightAtPlayer() + 1 then
        self.last_event = _("Dieser Block ist zu hoch.")
        return false
    end
    self.motion = { from_x = self.player_x, from_z = self.player_z, to_x = next_x, to_z = next_z, frame = 0 }
    self.steps = self.steps + 1
    self.last_event = direction > 0 and _("Vorwärts.") or _("Rückwärts.")
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
    if self.canvas then self.canvas:refreshFast() end
    if motion.frame >= MOVE_FRAMES then
        self.motion = nil
    else
        UIManager:scheduleIn(MOVE_FRAME_SECONDS, self._motionTick)
    end
end

function VoxelSession:act(action)
    if action == "left" then return self:turn(-1) end
    if action == "right" then return self:turn(1) end
    if action == "forward" then return self:beginMove(1) end
    if action == "back" then return self:beginMove(-1) end
    if action == "jump" then return self:jump() end
    if action == "mine" then return self:mine() end
    if action == "place" then return self:place() end
    if action == "inventory" then return self:toggleInventory() end
    if action == "color" then return self:toggleColor() end
    return false
end

-- The renderer is a small first-person voxel raycaster. Each screen column walks
-- through grid cells, projects the top and bottom of the hit block, and shades
-- its two possible side directions differently. This creates real perspective,
-- visible wall faces and a floor vanishing point without a polygon allocator.
local VoxelCanvas = InputContainer:extend{
    session = nil,
    width = nil,
    height = nil,
    dimen = nil,
    _origin_x = 0,
    _origin_y = 0,
}

function VoxelCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapMinecraftExplore = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeMinecraftLook = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        HoldMinecraftMine = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function VoxelCanvas:_paintDitherBand(bb, left, top, width, height, tone, phase)
    if width <= 0 or height <= 0 then return end
    if tone >= 3 then
        bb:paintRect(left, top, width, height, Blitbuffer.COLOR_BLACK)
        return
    end
    -- A white base plus sparse rows survives true one-bit panels and avoids
    -- depending on a device-specific gray waveform.
    bb:paintRect(left, top, width, height, Blitbuffer.COLOR_WHITE)
    local spacing = tone == 2 and 2 or 4
    local bottom = top + height
    local row = top + (phase % spacing)
    while row < bottom do
        bb:paintRect(left, row, width, 1, Blitbuffer.COLOR_BLACK)
        row = row + spacing
    end
end

function VoxelCanvas:_project(horizon, focal, camera_y, world_y, distance, y)
    return math.floor(y + horizon + (camera_y - world_y) * focal / math.max(distance, 0.18))
end

function VoxelCanvas:_projectPoint(horizon, focal, camera_y, wx, wz, wy, session, x, y)
    local dx, dz = wx - session.player_x, wz - session.player_z
    local depth = dx * math.sin(session.yaw) + dz * math.cos(session.yaw)
    local lateral = dx * math.cos(session.yaw) - dz * math.sin(session.yaw)
    if depth < 0.18 then depth = 0.18 end
    return x + self.width / 2 + lateral * focal / depth,
        y + horizon + (camera_y - wy) * focal / depth
end

function VoxelCanvas:_fillPolygon(bb, points, tone, phase, texture)
    local min_y, max_y = points[1][2], points[1][2]
    for index = 2, #points do
        min_y, max_y = math.min(min_y, points[index][2]), math.max(max_y, points[index][2])
    end
    local edges = {}
    for row = math.floor(min_y), math.floor(max_y) do
        local intersections = {}
        for index = 1, #points do
            local first, second = points[index], points[index % #points + 1]
            if (first[2] <= row and second[2] > row) or (second[2] <= row and first[2] > row) then
                local ratio = (row - first[2]) / (second[2] - first[2])
                intersections[#intersections + 1] = first[1] + (second[1] - first[1]) * ratio
            end
        end
        table.sort(intersections)
        for index = 1, #intersections - 1, 2 do
            local left = math.floor(intersections[index])
            local right = math.ceil(intersections[index + 1])
            if right > left then
                -- Avoid gray washes: true black/white is slower to ghost and
                -- survives a fast waveform much better than gray fills.
                bb:paintRect(left, row, right - left, 1, Blitbuffer.COLOR_WHITE)
                -- Texture is intentionally procedural: no bitmap assets are
                -- needed, and the pattern remains crisp on one-bit E-Ink.
                if texture == "water" then
                    if (row + phase) % 5 == 0 then bb:paintRect(left, row, right - left, 1, Blitbuffer.COLOR_BLACK) end
                elseif texture == "leaves" then
                    for pixel = left + ((row + phase) % 5), right - 1, 7 do
                        bb:paintRect(pixel, row, 2, 1, Blitbuffer.COLOR_BLACK)
                    end
                elseif texture == "wood" then
                    for pixel = left + (phase % 6), right - 1, 8 do
                        bb:paintRect(pixel, row, 1, 1, Blitbuffer.COLOR_BLACK)
                    end
                elseif texture == "top" then
                    local offset = (row + phase) % 6
                    for pixel = left + offset, right - 1, 6 do
                        bb:paintRect(pixel, row, math.min(2, right - pixel), 1, Blitbuffer.COLOR_BLACK)
                    end
                    if (row + phase) % 5 == 0 then bb:paintRect(left, row, right - left, 1, Blitbuffer.COLOR_BLACK) end
                else
                    if (row + phase) % 8 == 0 then
                        bb:paintRect(left, row, right - left, 1, Blitbuffer.COLOR_BLACK)
                    else
                        local offset = (phase + math.floor(row / 8) * 7) % 15
                        for pixel = left + offset, right - 1, 15 do
                            bb:paintRect(pixel, row, 1, 1, Blitbuffer.COLOR_BLACK)
                        end
                    end
                end
            end
        end
    end
end

function VoxelCanvas:_line(bb, first, second, ink)
    local dx, dy = second[1] - first[1], second[2] - first[2]
    local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy))))
    for step = 0, steps do
        local ratio = step / steps
        bb:paintRect(math.floor(first[1] + dx * ratio), math.floor(first[2] + dy * ratio), 1, 1, ink)
    end
end

function VoxelCanvas:_drawVoxel(bb, points, top_tone, side_tone, phase, material)
    -- A voxel is closed on all six sides. Hidden faces are painted first so
    -- the visible side faces and the cap remain on top in the painter pass.
    self:_fillPolygon(bb, points.bottom, math.max(1, side_tone - 1), phase + 5, material)
    self:_fillPolygon(bb, points.back, math.max(1, side_tone - 1), phase + 4, material)
    self:_fillPolygon(bb, points.side_c, math.max(1, side_tone - 1), phase + 3, material)
    self:_fillPolygon(bb, points.side_d, side_tone, phase + 2, material)
    self:_fillPolygon(bb, points.side_a, side_tone, phase + 1, material)
    self:_fillPolygon(bb, points.side_b, math.max(1, side_tone - 1), phase + 2, material)
    self:_fillPolygon(bb, points.top, top_tone, phase, material == "water" and "water" or (material == "leaves" and "leaves" or "top"))
    for _, edge in ipairs({ points.top, points.side_a, points.side_b, points.side_c, points.side_d, points.back, points.bottom }) do
        for index = 1, #edge do self:_line(bb, edge[index], edge[index % #edge + 1], Blitbuffer.COLOR_BLACK) end
    end
end

function VoxelCanvas:_drawScene(bb, x, y)
    local width, height, session = self.width, self.height, self.session
    bb:paintRect(x, y, width, height, Blitbuffer.COLOR_WHITE)
    if not session then return end

    -- Port of PocketOS's compact DDA renderer: the image is deliberately
    -- rendered on a small logical grid and enlarged with nearest-neighbour
    -- spans. This is much cheaper and more stable on an E-Ink framebuffer than
    -- projecting hundreds of independent polygons.
    -- The 100x100 PocketOS grid is bounded by the real canvas. That prevents
    -- several logical rays from landing on the same E-Ink pixel in a compact
    -- pane, which otherwise causes noisy overdraw and incomplete refreshes.
    local cols, rows = renderGridFor(width, height)
    local pixel_w, pixel_h = width / cols, height / rows
    local fov = math.rad(130)
    local tan_half = math.tan(fov / 2)
    local aspect = height / width
    local floor, abs, min, max = math.floor, math.abs, math.min, math.max
    local world = session.world
    local player_x, player_z = session.player_x, session.player_z
    local pitch = session.pitch or 0
    local cp, sp = math.cos(pitch), math.sin(pitch)
    local cy, sy = math.cos(session.yaw), math.sin(session.yaw)
    -- Keep axes named: the DDA stores world space as X, Z, Y while Lua's
    -- positional vectors previously mixed Z and Y during ray assembly.
    local forward = { x = sy * cp, z = cy * cp, y = sp }
    local right = { x = cy, z = -sy, y = 0 }
    local up = { x = -sy * sp, z = -cy * sp, y = cp }
    local camera_y = session:groundHeightAtPlayer() + PLAYER_EYE_HEIGHT + (session.jump_offset or 0)
    local patterns = {
        grass = "1211121111112111111211111121111111112111111211111111211111111111",
        dirt = "1021101211100112112011011220101110112010111022100112111012010110",
        stone = "1120111011011210111120101101112011201110110111201112110110111021",
        wood = "1121111111211110111112111121111112111111111211111111211111111111",
        leaves = "1210121111121110112111211121111012111121111012111121110112111121",
        water = "1221122211221122122211221122122211221122211221122122211221122122",
        sand = "2221222222221222222122222221222222221222221222222222122222222222",
        snow = "2222222222222222222222222222222222222222222222222222222222222222",
        coal = "1110111111111110111111111011111111110111111111111011111111111111",
        iron = "1120111111111111112011111111111111111120111111111111111120111111",
        gold = "1112111111111111111112111111111111111111112111111111111111112111",
    }
    local pattern_values = {}
    for name, pattern in pairs(patterns) do
        pattern_values[name] = {}
        for index = 1, 64 do pattern_values[name][index] = string.byte(pattern, index) - 48 end
    end
    local bayer4 = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
    local function blockInk(material, face, hx, hy, hz, side, screen_x, screen_y)
        if session.color_enabled and colorHardwareAvailable() then
            return colorForMaterial(material)
        end
        if material == "grass" and face ~= "top" then material = "dirt" end
        local pattern = pattern_values[material] or pattern_values.stone
        local fu, fv = textureCoordinates(face, hx, hy, hz, side)
        local u = max(0, min(7, floor(fu * 8)))
        local v = max(0, min(7, floor(fv * 8)))
        local level = pattern[v * 8 + u + 1]
        if face == "top" then level = level + 1 end
        if side == 0 then level = level - 1 end
        level = max(0, min(3, level))
        -- Convert the four texture luminances into deterministic 1-bit ink.
        -- This is the ordered Bayer pattern used instead of gray fills: it is
        -- crisp on E-Ink and does not accumulate a broad gray ghost.
        -- On a real E-Ink panel a one-pixel Bayer pattern becomes a gray
        -- haze. Use 2x2 ink cells while keeping the full 480x320 ray grid.
        local threshold = bayer4[(floor((screen_y or 0) / 2) % 4) + 1][(floor((screen_x or 0) / 2) % 4) + 1]
        if level <= 0 then return Blitbuffer.COLOR_BLACK end
        if level == 1 then return threshold < 5 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE end
        if level == 2 then return threshold < 2 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE end
        return Blitbuffer.COLOR_WHITE
    end
    local col_x, col_z, row_x, row_z, row_y = {}, {}, {}, {}, {}
    for rx = 0, cols - 1 do
        local nx = ((rx + 0.5) / cols * 2 - 1) * tan_half
        col_x[rx], col_z[rx] = right.x * nx, right.z * nx
    end
    for ry = 0, rows - 1 do
        local ny = (1 - (ry + 0.5) / rows * 2) * tan_half * aspect
        row_x[ry], row_z[ry], row_y[ry] = up.x * ny, up.z * ny, up.y * ny
    end
    local function cast(ray_x, ray_z, ray_y)
        local cell_x, cell_z, cell_y = floor(player_x), floor(player_z), floor(camera_y)
        local delta_x = abs(ray_x) < 0.00001 and 1e30 or abs(1 / ray_x)
        local delta_z = abs(ray_z) < 0.00001 and 1e30 or abs(1 / ray_z)
        local delta_y = abs(ray_y) < 0.00001 and 1e30 or abs(1 / ray_y)
        local step_x = ray_x < 0 and -1 or 1
        local step_z = ray_z < 0 and -1 or 1
        local step_y = ray_y < 0 and -1 or 1
        local next_x = ray_x < 0 and (player_x - cell_x) * delta_x or (cell_x + 1 - player_x) * delta_x
        local next_z = ray_z < 0 and (player_z - cell_z) * delta_z or (cell_z + 1 - player_z) * delta_z
        local next_y = ray_y < 0 and (camera_y - cell_y) * delta_y or (cell_y + 1 - camera_y) * delta_y
        local dist, side = 0, 0
        for ray_step = 1, 96 do
            local material = blockAt(world, cell_x, cell_z, cell_y)
            if material then
                return cell_x, cell_z, cell_y, dist, side, ray_x, ray_z, ray_y, material
            end
            if next_x < next_z and next_x < next_y then
                dist, next_x, cell_x, side = next_x, next_x + delta_x, cell_x + step_x, 0
            elseif next_z < next_y then
                dist, next_z, cell_z, side = next_z, next_z + delta_z, cell_z + step_z, 2
            else
                dist, next_y, cell_y, side = next_y, next_y + delta_y, cell_y + step_y, 1
            end
            if dist > MAX_VIEW_DISTANCE then break end
        end
        return nil
    end
    local function paintSpan(start_col, end_col, row, ink)
        -- Map both span boundaries independently. Deriving width from a
        -- rounded span length can leave one-pixel seams between neighbours.
        local left = x + floor(start_col * pixel_w)
        local right = x + floor(end_col * pixel_w)
        local top = y + floor(row * pixel_h)
        local bottom = y + floor((row + 1) * pixel_h)
        if right > left and bottom > top then
            bb:paintRect(left, top, right - left, bottom - top, ink)
        end
    end
    for ry = 0, rows - 1 do
        local row_ink, row_start
        for rx = 0, cols - 1 do
            -- Same column/row decomposition as PocketOS: the horizontal part
            -- is prepared once per column and the vertical part once per row.
            local ray_x = forward.x + col_x[rx] + row_x[ry]
            local ray_z = forward.z + col_z[rx] + row_z[ry]
            local ray_y = forward.y + row_y[ry]
            local inverse_length = 1 / math.sqrt(ray_x * ray_x + ray_z * ray_z + ray_y * ray_y)
            ray_x, ray_z, ray_y = ray_x * inverse_length, ray_z * inverse_length, ray_y * inverse_length
            local bx, bz, by, dist, side, hit_x, hit_z, hit_y, hit_material = cast(ray_x, ray_z, ray_y)
            local ink
            if bx then
                local hx = player_x + hit_x * dist
                local hy = camera_y + hit_y * dist
                local hz = player_z + hit_z * dist
                local top = side == 1 and hit_y < 0
                ink = blockInk(hit_material, top and "top" or "side", hx, hy, hz, side, rx, ry)
                if side == 0 and (bx + bz) % 2 == 0 then ink = ink == Blitbuffer.COLOR_BLACK and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK end
            elseif ray_y < 0 and (ry + rx) % 6 == 0 then
                ink = Blitbuffer.COLOR_BLACK
            else
                ink = Blitbuffer.COLOR_WHITE
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
    local center_x, center_y = x + math.floor(width / 2), y + math.floor(height / 2)
    bb:paintRect(center_x - 5, center_y, 11, 1, Blitbuffer.COLOR_BLACK)
    bb:paintRect(center_x, center_y - 5, 1, 11, Blitbuffer.COLOR_BLACK)
end

function VoxelCanvas:paintTo(bb, x, y)
    local range = self.ges_events.TapMinecraftExplore[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    self._origin_x, self._origin_y = x, y
    self:_drawScene(bb, x, y)
end

function VoxelCanvas:refreshFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    self._refresh_count = (self._refresh_count or 0) + 1
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    -- Fast waveforms are intentionally used for motion, but they accumulate
    -- ghosting on E-Ink. Every second step gets a clean UI waveform for the
    -- same local region; it is still not a fullscreen refresh.
    local waveform = self._refresh_count % 2 == 0 and "ui" or "fast"
    UIManager:setDirty(nil, waveform, Geom:new{
        x = self._origin_x,
        y = self._origin_y,
        w = self.width,
        h = self.height,
    })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    if UIManager.yieldToEPDC then UIManager:yieldToEPDC() end
    return true
end

function VoxelCanvas:act(action)
    if not self.session then return false end
    self.session:act(action)
    self:refreshFast()
    return true
end

function VoxelCanvas:onTapMinecraftExplore(gesture)
    -- A tap inside the scene works as a quiet direct controller: the upper
    -- centre walks forward, lower centre walks back, and side taps turn.
    if not gesture or not gesture.pos then return true end
    local relative_x = gesture.pos.x - self._origin_x
    local relative_y = gesture.pos.y - self._origin_y
    if relative_x > self.width * 0.36 and relative_x < self.width * 0.64 and relative_y > self.height * 0.64 then
        self:act("place")
    elseif relative_x < self.width * 0.32 then
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

function VoxelCanvas:onHoldMinecraftMine()
    self:act("mine")
    return true
end

function VoxelCanvas:onSwipeMinecraftLook(_, gesture)
    if not self.session then return false end
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
        SwipeMinecraftJoystick = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

function Joystick:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local range = self.ges_events.TapMinecraftJoystick[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    local size = math.min(self.width, self.height)
    bb:paintRect(x + 1, y + 1, size - 2, size - 2, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x, y, size, 1, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + size - 1, size, 1, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, 1, size, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + size - 1, y, 1, size, Blitbuffer.COLOR_BLACK)
    local cx, cy = x + math.floor(size / 2), y + math.floor(size / 2)
    bb:paintRect(cx - 2, cy - 2, 5, 5, Blitbuffer.COLOR_BLACK)
    return true
end

function Joystick:_steer(gesture)
    local pos = gesture and gesture.pos
    if not pos or not self.canvas then return true end
    local dx = (pos.x or self._origin_x) - (self._origin_x + self.width / 2)
    local dy = (pos.y or self._origin_y) - (self._origin_y + self.height / 2)
    if math.abs(dx) > math.abs(dy) then
        self.canvas:act(dx < 0 and "left" or "right")
    elseif math.abs(dy) > self.height * 0.15 then
        self.canvas:act(dy < 0 and "forward" or "back")
    end
    return true
end

function Joystick:onTapMinecraftJoystick(gesture) return self:_steer(gesture) end
function Joystick:onSwipeMinecraftJoystick(_, gesture)
    if not self.canvas then return false end
    local direction = gesture and gesture.direction
    if direction == "west" then self.canvas:act("left")
    elseif direction == "east" then self.canvas:act("right")
    elseif direction == "north" then self.canvas:act("forward")
    elseif direction == "south" then self.canvas:act("back")
    else return false end
    return true
end

local Hotbar = InputContainer:extend{ session = nil, width = nil, height = nil, dimen = nil }
function Hotbar:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftHotbar = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Hotbar:paintTo(bb, x, y)
    local range = self.ges_events.TapMinecraftHotbar[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    local slot_w = math.max(1, math.floor(self.width / 9))
    for slot = 1, 9 do
        local sx = x + (slot - 1) * slot_w + 1
        local selected = self.session and self.session.selected_slot == slot
        bb:paintRect(sx, y + 1, slot_w - 2, self.height - 2, selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY)
        bb:paintRect(sx + 3, y + 3, math.max(1, slot_w - 8), math.max(1, self.height - 8), selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_DARK_GRAY)
    end
    return true
end
function Hotbar:onTapMinecraftHotbar(gesture)
    local pos = gesture and gesture.pos
    if not pos or not self.session then return true end
    local slot = math.floor((pos.x - self.ges_events.TapMinecraftHotbar[1].range.x) / (self.width / 9)) + 1
    self.session:selectSlot(slot)
    return true
end

local InventoryPanel = InputContainer:extend{ session = nil, width = nil, height = nil, dimen = nil }
function InventoryPanel:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftInventory = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function InventoryPanel:paintTo(bb, x, y)
    if not self.session or not self.session.inventory_open then return true end
    local range = self.ges_events.TapMinecraftInventory[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    bb:paintRect(x + 8, y + 8, self.width - 16, self.height - 16, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x + 8, y + 8, self.width - 16, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + 8, y + self.height - 10, self.width - 16, 2, Blitbuffer.COLOR_BLACK)
    for slot = 1, 9 do
        local sx = x + 18 + (slot - 1) * math.floor((self.width - 36) / 9)
        bb:paintRect(sx, y + 32, math.max(8, math.floor((self.width - 44) / 9)), 26, Blitbuffer.COLOR_LIGHT_GRAY)
        if self.session.selected_slot == slot then bb:paintRect(sx, y + 32, 2, 26, Blitbuffer.COLOR_BLACK) end
    end
    return true
end
function InventoryPanel:onTapMinecraftInventory(gesture)
    if not self.session or not self.session.inventory_open then return false end
    local pos = gesture and gesture.pos
    if pos and pos.y < 34 then self.session:toggleInventory(); return true end
    if pos and pos.y > 32 and pos.y < 65 then
        local slot = math.floor((pos.x - 18) / ((self.width - 36) / 9)) + 1
        self.session:selectSlot(slot)
    end
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
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        bordersize = 0,
        radius = math.max(3, math.floor(self.height * 0.22)),
        background = self.primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = self.dimen,
            TextWidget:new{
                text = self.title,
                face = Font:getFace("smallinfofont", math.max(scale(9), math.floor(self.height * 0.32))),
                fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                bold = true,
                max_width = self.width - scale(6),
            },
        },
    }
    self.ges_events = { TapMinecraftNav = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function NavButton:paintTo(bb, x, y)
    local range = self.ges_events.TapMinecraftNav[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function NavButton:onTapMinecraftNav()
    if self.callback then self.callback() end
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

local function stateFor(instance)
    if instance.minecraft then return instance.minecraft end
    local state = { session = VoxelSession.new() }
    instance.minecraft = state
    return state
end

return {
    id = "minecraft",
    version = "2.8.2",
    title = "Minecraft 3D",
    subtitle = "Schnelle Voxelwelt · 7-Farben-Option",
    symbol = "M",
    logo = "other",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or scale
        local margin, gap = px(9), px(5)
        local header_h, controls_h = px(43), px(31)
        local canvas_h = math.max(px(76), height - header_h - controls_h - px(27))
        local canvas_w = math.max(px(40), width - 2 * margin)
        local canvas_y = header_h
        local controls_y = canvas_y + canvas_h + gap
        local button_w = math.max(px(30), math.floor((canvas_w - 4 * gap) / 5))
        local joystick_size = math.min(px(76), math.floor(canvas_w * 0.22))
        local jump_w, jump_h = px(58), px(30)
        local color_button_w = math.min(px(58), canvas_w)
        local canvas = VoxelCanvas:new{ width = canvas_w, height = canvas_h, session = state.session }
        local hotbar = Hotbar:new{ width = canvas_w, height = px(30), session = state.session }
        local inventory_panel = InventoryPanel:new{ width = canvas_w, height = canvas_h, session = state.session }
        hotbar.overlap_offset = { margin, canvas_y + px(5) }
        inventory_panel.overlap_offset = { margin, canvas_y }
        state.session.canvas = canvas
        local pane = WorldPane:new{ dimen = Geom:new{ w = width, h = height }, session = state.session, canvas = canvas }
        function pane:onDeactivate()
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
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = "MINECRAFT 3D", face = Font:getFace("cfont", px(18)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = math.max(px(40), canvas_w - color_button_w - px(8)), overlap_offset = { margin, px(6) } },
            TextWidget:new{ text = _("Voxelwelt · monochrom oder 7 Farben"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = math.max(px(40), canvas_w - color_button_w - px(8)), overlap_offset = { margin, px(29) } },
            NavButton:new{ title = _("Farbe"), width = color_button_w, height = px(25), callback = function() canvas:act("color") end, overlap_offset = { margin + canvas_w - color_button_w, px(6) } },
            canvas,
            hotbar,
            joystick,
            inventory_panel,
            NavButton:new{ title = _("Springen"), width = jump_w, height = jump_h, primary = true, callback = function() canvas:act("jump") end, overlap_offset = { margin + canvas_w - jump_w - px(8), canvas_y + canvas_h - jump_h - px(8) } },
            NavButton:new{ title = _("Links"), width = button_w, height = controls_h, callback = function() canvas:act("left") end, overlap_offset = { margin, controls_y } },
            NavButton:new{ title = _("Vor"), width = button_w, height = controls_h, primary = true, callback = function() canvas:act("forward") end, overlap_offset = { margin + (button_w + gap), controls_y } },
            NavButton:new{ title = _("Zurück"), width = button_w, height = controls_h, callback = function() canvas:act("back") end, overlap_offset = { margin + (button_w + gap) * 2, controls_y } },
            NavButton:new{ title = _("Rechts"), width = button_w, height = controls_h, callback = function() canvas:act("right") end, overlap_offset = { margin + (button_w + gap) * 3, controls_y } },
            NavButton:new{ title = _("Inventar"), width = button_w, height = controls_h, callback = function() canvas:act("inventory") end, overlap_offset = { margin + (button_w + gap) * 4, controls_y } },
            TextWidget:new{ text = _("Joystick bewegen · wischen zum Umsehen · Springen"), face = Font:getFace("smallinfofont", px(8)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = canvas_w, overlap_offset = { margin, height - px(14) } },
        }
        return pane
    end,
    _test = {
        VoxelSession = VoxelSession,
        VoxelCanvas = VoxelCanvas,
        buildWorld = buildWorld,
        heightAt = heightAt,
        renderGridFor = renderGridFor,
        textureCoordinates = textureCoordinates,
        colorForMaterial = colorForMaterial,
        COLOR_PALETTE = COLOR_PALETTE,
        WORLD_SIZE = WORLD_SIZE,
        MAX_COLUMN_HEIGHT = MAX_COLUMN_HEIGHT,
        MAX_VIEW_DISTANCE = MAX_VIEW_DISTANCE,
        RENDER_SCALE = RENDER_SCALE,
        RENDER_COLS = RENDER_COLS,
        RENDER_ROWS = RENDER_ROWS,
        WALK_DISTANCE = WALK_DISTANCE,
        TURN_ANGLE = TURN_ANGLE,
        MOVE_FRAMES = MOVE_FRAMES,
        MOVE_FRAME_SECONDS = MOVE_FRAME_SECONDS,
    },
}
