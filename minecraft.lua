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
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
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
local MAX_VIEW_DISTANCE = 24
local VOXEL_PADDING = MAX_VIEW_DISTANCE + 1
local MAX_WORLD_SEED = 2147483647
local RENDER_SCALE = 1
-- 600x600 output target. The renderer samples 5x5 output pixels as one
-- logical ray. This keeps the requested 600x600 canvas while reducing the
-- expensive ray casts to about 1/25 of full-resolution rendering.
local RENDER_COLS = 600
local RENDER_ROWS = 600
local RENDER_SAMPLE = 5
-- Color E-Ink panels do not benefit from a full-resolution ray per 2x2 cell.
-- 3x3 keeps block silhouettes and texture dithering readable while cutting the
-- hot DDA loop by roughly half on a typical AppDock pane.
local COLOR_RENDER_SAMPLE = 3
local BAYER4 = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
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
-- Intended material colors are richer than the seven inks supported by the
-- fast-refresh mode. The ordered dither below approximates them from that set.
local MATERIAL_TARGET_RGB = {
    grass = { 87, 156, 65 }, leaves = { 48, 136, 52 },
    dirt = { 137, 90, 59 }, wood = { 158, 106, 51 },
    stone = { 132, 132, 134 }, water = { 42, 94, 177 },
    snow = { 25, 175, 185 }, sand = { 188, 153, 72 },
    coal = { 0, 0, 0 }, iron = { 154, 155, 140 }, gold = { 214, 157, 38 },
}
local COLOR_PALETTE_ORDER = { "black", "red", "green", "blue", "cyan", "magenta", "yellow" }
local SHADE_FACTORS = { 0, 0.69, 0.875, 1 }
local PLAYER_EYE_HEIGHT = 1.65
local WALK_DISTANCE = 0.64
local TURN_ANGLE = math.pi / 12
local MOVE_FRAMES = 4
local MOVE_FRAME_SECONDS = 0.045
local START_PLAYER_X = 44.5
local START_PLAYER_Z = 52.5
local START_YAW = math.pi / 2

-- A Minecraft-like sky is painted only on color displays. The monochrome path
-- keeps its crisp black/white behavior for fast E-Ink refreshes.
local SCENE_COLORS = {
    sky_top = { 62, 139, 211 }, sky_mid = { 119, 190, 229 },
    sky_horizon = { 188, 221, 232 }, cloud = { 246, 247, 238 },
    distant_ground = { 83, 119, 71 },
}
local scene_rgb_colors = {}
local function sceneColor(name)
    local color = scene_rgb_colors[name]
    if not color then
        local rgb = SCENE_COLORS[name]
        color = Blitbuffer.colorFromString(string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3]))
        scene_rgb_colors[name] = color
    end
    return color
end

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function wrapAngle(value) return value % TAU end
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
local function paletteMixForMaterial(material, level)
    local shades = material_mix_cache[material]
    local shade_index = level + 1
    if shades and shades[shade_index] then return shades[shade_index] end
    local source = MATERIAL_TARGET_RGB[material] or COLOR_PALETTE[MATERIAL_COLORS[material] or "black"]
    local factor = SHADE_FACTORS[level + 1] or 1
    local mix = paletteMixForRGB(source[1] * factor, source[2] * factor, source[3] * factor)
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

-- Nicht jede Minecraft-Struktur ist eine Säule. Diese Sparse-Map hält Blöcke
-- über dem Terrain (aktuell Bäume), damit Stämme und Blattkronen wirklich aus
-- einzelnen Voxeln bestehen und die Bodenhöhe nicht künstlich mitwächst.
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

local rebuildWorldBlocks
local function buildWorld(seed)
    seed = normalizeSeed(seed)
    local world = { size = WORLD_SIZE, seed = seed, heights = {}, materials = {}, biomes = {}, extra_blocks = {} }
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
            if lake then height = math.max(2, math.min(height - 1, 4)) end
            local material = lake and "water" or (biome == "desert" and "sand" or (biome == "mountains" and "stone" or (biome == "tundra" and "snow" or "grass")))
            if not lake and height <= 5 and noise2(seed + 77, x, z, 7) < 0.16 then material = "sand" end
            world.heights[z + 1][x + 1] = clamp(height, 1, MAX_TERRAIN_HEIGHT)
            world.materials[z + 1][x + 1] = material
            world.biomes[z + 1][x + 1] = biome
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
    for z = 2, WORLD_SIZE - 3 do for x = 2, WORLD_SIZE - 3 do
        local biome = world.biomes[z + 1][x + 1]
        local chance = hash2(seed + 11, x, z)
        -- Minecraft forests are wooded, not solid walls of leaves. Select a
        -- sparse set of tree sites and keep a generous clearing around each.
        local can_grow = (biome == "forest" or biome == "taiga") and chance > 0.91
            or biome == "plains" and chance < 0.035
        if can_grow then
            local spacing = biome == "plains" and 7 or 6
            for _, site in ipairs(tree_sites) do
                if math.abs(site.x - x) < spacing and math.abs(site.z - z) < spacing then
                    can_grow = false
                    break
                end
            end
        end
        if can_grow then
            tree_sites[#tree_sites + 1] = { x = x, z = z }
            local h = terrain_heights[z + 1][x + 1]
            local trunk_height = math.min(MAX_COLUMN_HEIGHT - 1, h + 4)
            for level = h, trunk_height - 1 do putExtraBlock(world, x, z, level, "wood") end
            -- A stepped, cross-shaped canopy is recognisably Minecraft-like and
            -- leaves enough gaps to see the trunk and sky through it.
            for level = trunk_height - 2, trunk_height do
                local radius = level == trunk_height and 1 or 2
                for dz = -radius, radius do for dx = -radius, radius do
                    if math.abs(dx) + math.abs(dz) <= radius + 1
                        and not (level == trunk_height - 2 and dx == 0 and dz == 0) then
                        putExtraBlock(world, x + dx, z + dz, level, "leaves")
                    end
                end end
            end
        end
    end end
    -- Deterministische Landmarke: drei kleine Häuser geben der Welt einen
    -- sichtbaren Ort statt einer endlosen Ansammlung von Terrain-Säulen.
    local village_x = 15 + math.floor(hash2(seed + 500, 0, 0) * 35)
    local village_z = 15 + math.floor(hash2(seed + 700, 0, 0) * 35)
    for house = 0, 2 do
        local hx, hz = village_x + (house % 2) * 8, village_z + math.floor(house / 2) * 8
        if hx > 3 and hz > 3 and hx < WORLD_SIZE - 5 and hz < WORLD_SIZE - 5 then
            local biome = world.biomes[hz + 1][hx + 1]
            if biome ~= "mountains" and biome ~= "swamp" then
                local ground = world.heights[hz + 1][hx + 1]
                putBox(world, hx - 2, hz - 2, ground, hx + 2, hz + 2, ground, "stone")
                for level = ground + 1, ground + 3 do
                    for dz = -2, 2 do for dx = -2, 2 do
                        local wall = math.abs(dx) == 2 or math.abs(dz) == 2
                        local door = dx == 0 and dz == -2 and level <= ground + 2
                        if wall and not door then putExtraBlock(world, hx + dx, hz + dz, level, "wood") end
                    end end
                end
                putBox(world, hx - 3, hz - 2, ground + 4, hx + 3, hz + 2, ground + 4, "wood")
            end
        end
    end
    -- Kleine, billige Biome-Signaturen: Kakteen und Sumpfgras.
    for z = 3, WORLD_SIZE - 4 do for x = 3, WORLD_SIZE - 4 do
        local biome, chance = world.biomes[z + 1][x + 1], hash2(seed + 901, x, z)
        local ground = world.heights[z + 1][x + 1]
        if biome == "desert" and chance > 0.94 then
            putExtraBlock(world, x, z, ground, "wood")
            if chance > 0.975 then putExtraBlock(world, x, z, ground + 1, "wood") end
        elseif biome == "swamp" and chance > 0.90 then
            putExtraBlock(world, x, z, ground, "leaves")
        end
    end end
    if rebuildWorldBlocks then rebuildWorldBlocks(world) end
    return world
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

-- Avoid spawning inside a generated tree canopy. Prefer an open grass cell with
-- a nearby trunk in view; seeds without a suitable tree fall back to a smooth,
-- clear patch of terrain near the world center.
local function findSpawn(world)
    local size = world.size
    local trunks = {}
    for z = 2, size - 3 do for x = 2, size - 3 do
        local ground = world.heights[z + 1][x + 1]
        if world.extra_blocks[extraBlockKey(x, z, ground)] == "wood" then
            trunks[#trunks + 1] = { x = x + 0.5, z = z + 0.5, height = ground + 4 }
        end
    end end

    local center = (size - 1) / 2
    local best_tree_spawn, best_open_spawn
    for z = 3, size - 4 do
        local material_row = world.materials[z + 1]
        local height_row = world.heights[z + 1]
        for x = 3, size - 4 do
            if material_row[x + 1] == "grass" then
                local clear = true
                for dz = -2, 2 do
                    local nearby = world.materials[z + dz + 1]
                    for dx = -2, 2 do
                        local material = nearby[x + dx + 1]
                        if material == "wood" or material == "leaves" then clear = false; break end
                    end
                    if not clear then break end
                end
                if clear then
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
                    for _, trunk in ipairs(trunks) do
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
                    if nearest_distance2 and nearest_distance2 >= 36 and nearest_distance2 <= 400 then
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

local function heightAt(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return 0 end
    return world.heights[z + 1][x + 1] or 0
end

local function materialAt(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return "stone" end
    return (world.materials[z + 1] and world.materials[z + 1][x + 1]) or "grass"
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

-- The C program raycasts individual blocks, not just a column silhouette.
-- Keep its layered surface/dirt/stone/ore rule, then cache each voxel plane and
-- a padded linear view so the hot DDA loop avoids repeated table/hash lookups.
local function rawBlockAt(world, x, z, level)
    if x < 0 or z < 0 or x >= world.size or z >= world.size or level < 0 then return nil end
    local extra = world.extra_blocks and world.extra_blocks[extraBlockKey(x, z, level)]
    if extra then return extra end
    local height = world.heights[z + 1][x + 1] or 0
    if level >= height then return nil end
    local surface = world.materials[z + 1][x + 1] or "grass"
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
end

local function blockAt(world, x, z, level)
    if x < 0 or z < 0 or x >= world.size or z >= world.size or level < 0 then return nil end
    local planes = world.block_planes
    if planes then
        local plane = planes[level + 1]
        return plane and plane[z * world.size + x + 1] or nil
    end
    return rawBlockAt(world, x, z, level)
end

local VoxelSession = {}
VoxelSession.__index = VoxelSession

function VoxelSession.new(seed)
    seed = normalizeSeed(seed)
    local world = buildWorld(seed)
    local player_x, player_z, yaw = findSpawn(world)
    local self = setmetatable({
        seed = seed,
        world = world,
        player_x = player_x,
        player_z = player_z,
        yaw = yaw,
        pitch = 0,
        steps = 0,
        last_event = _("Bereit — erkunde die Blockwelt."),
        canvas = nil,
        motion = nil,
        jump_offset = 0,
        jump_frame = nil,
        inventory_open = false,
        color_enabled = true,
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
    if self.motion then UIManager:unschedule(self._motionTick) end
    if self.jump_frame then UIManager:unschedule(self._jumpTick) end
    if seed == nil then self.seed = nextWorldSeed(self.seed) else self.seed = normalizeSeed(seed) end
    self.world = buildWorld(self.seed)
    self.player_x, self.player_z, self.yaw = findSpawn(self.world)
    self.pitch = 0
    self.motion, self.jump_frame, self.jump_offset = nil, nil, 0
    self.steps, self.last_event = 0, _("Neue Welt erzeugt. Seed: ") .. tostring(self.seed)
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
    -- Do not probe the panel or constructor from inside the DApp. KOReader's
    -- standard setting is the sole switch; false means use monochrome.
    if not colorRenderingEnabled() then
        self.color_enabled = false
        self.last_event = _("KOReader-Farbrendering ist ausgeschaltet oder nicht verfügbar.")
        return false
    end
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
    rebuildBlockColumn(self.world, tx, tz)
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
    rebuildBlockColumn(self.world, tx, tz)
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

local PATTERN_VALUES = {}
do
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
    for name, pattern in pairs(patterns) do
        PATTERN_VALUES[name] = {}
        for index = 1, 64 do PATTERN_VALUES[name][index] = string.byte(pattern, index) - 48 end
    end
end

function VoxelCanvas:_drawScene(bb, x, y)
    local width, height, session = self.width, self.height, self.session
    bb:paintRect(x, y, width, height, Blitbuffer.COLOR_WHITE)
    if not session then return end

    local color_mode = session.color_enabled and colorRenderingEnabled()
    local sample = color_mode and COLOR_RENDER_SAMPLE or RENDER_SAMPLE
    -- The color path uses a finer grid so ordered shade dithering stays crisp;
    -- monochrome keeps the lower-cost 5x5 sampling and its existing textures.
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
    local function paintSpan(start_col, end_col, row, ink)
        -- Map both span boundaries independently. Deriving width from a
        -- rounded span length can leave one-pixel seams between neighbours.
        local left = x + floor(start_col * pixel_w)
        local right = x + floor(end_col * pixel_w)
        local top = y + floor(row * pixel_h)
        local bottom = y + floor((row + 1) * pixel_h)
        if right > left and bottom > top then
            if color_mode then
                local rgb_ink = ink == "white" and Blitbuffer.COLOR_WHITE
                    or (SCENE_COLORS[ink] and sceneColor(ink) or paletteColor(ink))
                bb:paintRectRGB32(left, top, right - left, bottom - top, rgb_ink)
            else
                bb:paintRect(left, top, right - left, bottom - top, ink)
            end
        end
    end
    for ry = 0, rows - 1 do
        local bayer_row = BAYER4[color_mode and (ry % 4) + 1 or (floor(ry / 2) % 4) + 1]
        local row_ink, row_start
        for rx = 0, cols - 1 do
            local bayer_col = color_mode and (rx % 4) or (floor(rx / 2) % 4)
            local dither_threshold = bayer_row[bayer_col + 1]
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
            local dist, side, bx, bz, hit_dist, hit_side, hit_material = 0, 0
            for ray_step = 1, 24 do
                local material
                if cell_y >= 0 and cell_y < MAX_COLUMN_HEIGHT then
                    material = voxel_flat[voxel_index]
                end
                if material then
                    bx, bz, hit_dist, hit_side, hit_material = cell_x, cell_z, dist, side, material
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
                local level = pattern[v * 8 + u + 1]
                if top then level = level + 1 end
                if hit_side == 0 then level = level - 1 end
                level = max(0, min(3, level))
                if color_mode then
                    local mix = material_mix_cache[texture_material][level + 1]
                    ink = dither_threshold < mix.second_pixels and mix.second or mix.first
                elseif level <= 0 then
                    ink = Blitbuffer.COLOR_BLACK
                elseif level == 1 then
                    ink = dither_threshold < 5 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
                elseif level == 2 then
                    ink = dither_threshold < 2 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
                else
                    ink = Blitbuffer.COLOR_WHITE
                end
                -- Do not replace an RGB material color with monochrome
                -- black/white shading. Keep the material color intact.
                if not color_mode and hit_side == 0 and (bx + bz) % 2 == 0 then
                    ink = ink == Blitbuffer.COLOR_BLACK and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                end
            elseif color_mode then
                -- Give the empty part of the view a blue gradient, a pale
                -- horizon and a few stable square clouds instead of a blank
                -- white canvas. This is the strongest visual cue for the
                -- Minecraft-like outdoor world.
                local sky_position = ry / math.max(1, rows - 1)
                if dir_y < 0 then
                    -- Keep a sparse dark pixel pattern at the far ground line;
                    -- it reads as the familiar Minecraft horizon on E-Ink
                    -- color panels without turning the whole distance black.
                    ink = ((rx + ry) % 6 == 0) and "black" or "distant_ground"
                elseif sky_position < 0.27 then
                    ink = ((floor(rx / 11) + floor(ry / 5)) % 13 == 0) and "cloud" or "sky_top"
                elseif sky_position < 0.58 then
                    ink = ((floor(rx / 15) + floor(ry / 4)) % 17 == 0) and "cloud" or "sky_mid"
                else
                    ink = "sky_horizon"
                end
            elseif dir_y < 0 and (ry + rx) % 6 == 0 then
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

local function parseWorldSeed(value)
    local text = tostring(value or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    if not text:match("^[+-]?%d+$") then return false end
    local seed = tonumber(text)
    if not seed or seed < -MAX_WORLD_SEED or seed >= MAX_WORLD_SEED then return false end
    return normalizeSeed(seed)
end

local function promptNewWorld(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Neue Welt erzeugen"),
        input = tostring(state.session.seed),
        input_hint = _("Seed als Ganzzahl; leer = neuer Zufalls-Seed"),
        buttons = {
            {
                { text = _("Abbrechen"), callback = function() UIManager:close(dialog) end },
                { text = _("Erstellen"), is_enter_default = true, callback = function()
                    local seed = parseWorldSeed(dialog:getInputText())
                    if seed == false then
                        UIManager:show(InfoMessage:new{ text = _("Bitte gib eine ganze Zahl zwischen -2147483647 und 2147483646 ein.") })
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

return {
    id = "minecraft",
    version = "3.2.1",
    title = "Minecraft 3D",
    subtitle = "Schnelle Voxelwelt · 7-Farben-Option",
    symbol = "M",
    logo = "minecraft",
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
        local world_button_w = math.max(px(8), math.min(px(38), math.floor(canvas_w * 0.22)))
        local header_gap = math.min(gap, math.floor(canvas_w * 0.04))
        local color_button_w = math.max(0, math.min(px(58), canvas_w - world_button_w - header_gap))
        local heading_w = math.max(px(1), canvas_w - color_button_w - world_button_w - header_gap - px(8))
        local heading_size = heading_w < px(105) and px(14) or px(18)
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
            TextWidget:new{ text = "MINECRAFT 3D", face = Font:getFace("cfont", heading_size), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = heading_w, overlap_offset = { margin, px(6) } },
            TextWidget:new{ text = _("Seed: ") .. tostring(state.session.seed), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = heading_w, overlap_offset = { margin, px(29) } },
            NavButton:new{ title = _("Farbe"), width = color_button_w, height = px(25), callback = function() canvas:act("color") end, overlap_offset = { margin + canvas_w - color_button_w, px(6) } },
            NavButton:new{ title = _("Welt"), width = world_button_w, height = px(25), callback = function() promptNewWorld(state, context) end, overlap_offset = { margin + canvas_w - color_button_w - header_gap - world_button_w, px(6) } },
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
        findSpawn = findSpawn,
        hasClearTreeView = hasClearTreeView,
        blockAt = blockAt,
        rebuildWorldBlocks = rebuildWorldBlocks,
        parseWorldSeed = parseWorldSeed,
        heightAt = heightAt,
        renderGridFor = renderGridFor,
        textureCoordinates = textureCoordinates,
        colorForMaterial = colorForMaterial,
        paletteMixForRGB = paletteMixForRGB,
        paletteMixForMaterial = paletteMixForMaterial,
        colorRenderingEnabled = colorRenderingEnabled,
        paletteColor = paletteColor,
        COLOR_PALETTE = COLOR_PALETTE,
        WORLD_SIZE = WORLD_SIZE,
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
    },
}
