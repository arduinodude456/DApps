--[[--
Minecraft 3D for AppDock.

A compact, offline voxel sandbox for E-Ink and color displays. The world is a
deterministic block landscape with biomes, trees, villages and ore veins. Its
renderer uses a voxel-space DDA raycaster so movement only redraws the game
canvas, never the full AppDock pane. Every interactive redraw goes through
UIManager:setDirty(..., "waveform", region).

Version 4.0.1 fixes KOReader gesture dispatch for placing, mining and hotbar selection.
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
local BAYER4 = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
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
-- earth and wooden blocks do not collapse into black dithers on a 7-ink panel.
local SHADE_FACTORS = { 0, 0.72, 0.92, 1.05 }
local PLAYER_EYE_HEIGHT = 1.65
local WALK_DISTANCE = 0.64
local TURN_ANGLE = math.pi / 12
local MOVE_FRAMES = 4
local MOVE_FRAME_SECONDS = 0.045
local START_PLAYER_X = 48.5
local START_PLAYER_Z = 56.5
local START_YAW = math.pi / 2
-- Bedrock keeps 36 slots: the first nine are the hotbar.
local HOTBAR_SLOTS = 9
local INVENTORY_SLOTS = 36
local STACK_LIMIT = 64
local CRAFT_ROWS_PER_PAGE = 4
local CRAFT_PAGES_MAX = 4

-- A Minecraft-like sky is painted only on color displays. The monochrome path
-- keeps its crisp black/white behavior for fast E-Ink refreshes.
local SCENE_COLORS = {
    sky_top = { 62, 139, 211 }, sky_mid = { 119, 190, 229 },
    sky_horizon = { 188, 221, 232 }, cloud = { 246, 247, 238 },
    distant_ground = { 96, 134, 80 }, distant_ground_dark = { 52, 88, 48 },
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

-- Block catalogue --------------------------------------------------------------
-- Every block has a German label, a fast-refresh ink fallback for color panels,
-- a target RGB color for ordered dithering, an 8x8 procedural texture and -- for
-- natural blocks -- the item that drops when the block is mined.
local MATERIALS = {
    grass = { label = _("Grasblock"), color = "green", rgb = { 106, 170, 64 }, pattern = "grass", drop = "dirt" },
    dirt = { label = _("Erde"), color = "red", rgb = { 150, 113, 79 }, pattern = "dirt" },
    farmland = { label = _("Ackerboden"), color = "red", rgb = { 128, 94, 58 }, pattern = "farm" },
    stone = { label = _("Stein"), color = "blue", rgb = { 142, 142, 142 }, pattern = "stone", drop = "cobblestone" },
    cobblestone = { label = _("Bruchstein"), color = "blue", rgb = { 128, 128, 131 }, pattern = "cobble" },
    gravel = { label = _("Kies"), color = "blue", rgb = { 152, 143, 140 }, pattern = "gravel" },
    sand = { label = _("Sand"), color = "yellow", rgb = { 219, 207, 163 }, pattern = "sand" },
    sandstone = { label = _("Sandstein"), color = "yellow", rgb = { 216, 203, 155 }, pattern = "sandstone" },
    clay = { label = _("Ton"), color = "cyan", rgb = { 160, 166, 179 }, pattern = "clay" },
    bricks = { label = _("Ziegelsteine"), color = "red", rgb = { 168, 108, 90 }, pattern = "brick" },
    snow = { label = _("Schneeblock"), color = "cyan", rgb = { 240, 250, 250 }, pattern = "snow" },
    ice = { label = _("Eis"), color = "cyan", rgb = { 145, 183, 235 }, pattern = "ice" },
    water = { label = _("Wasser"), color = "blue", rgb = { 63, 118, 228 }, pattern = "water", liquid = true },
    lava = { label = _("Lava"), color = "red", rgb = { 207, 92, 20 }, pattern = "lava", liquid = true },
    bedrock = { label = _("Grundgestein"), color = "black", rgb = { 85, 85, 85 }, pattern = "bedrock" },
    obsidian = { label = _("Obsidian"), color = "black", rgb = { 26, 22, 36 }, pattern = "obsidian" },
    coal = { label = _("Steinkohle"), color = "black", rgb = { 42, 42, 42 }, pattern = "ore_coal" },
    iron = { label = _("Eisenerz"), color = "cyan", rgb = { 154, 155, 140 }, pattern = "ore_iron" },
    gold = { label = _("Golderz"), color = "yellow", rgb = { 214, 157, 38 }, pattern = "ore_gold" },
    diamond = { label = _("Diamanterz"), color = "cyan", rgb = { 92, 219, 213 }, pattern = "ore_diamond" },
    redstone = { label = _("Redstone-Erz"), color = "red", rgb = { 175, 32, 32 }, pattern = "ore_redstone" },
    wood = { label = _("Eichenstamm"), color = "red", rgb = { 172, 120, 62 }, pattern = "log" },
    wood_birch = { label = _("Birkenstamm"), color = "yellow", rgb = { 216, 211, 190 }, pattern = "log" },
    wood_spruce = { label = _("Fichtenstamm"), color = "red", rgb = { 120, 86, 48 }, pattern = "log" },
    wood_jungle = { label = _("Tropenholz"), color = "red", rgb = { 112, 80, 44 }, pattern = "log" },
    wood_acacia = { label = _("Akazienstamm"), color = "red", rgb = { 176, 106, 60 }, pattern = "log" },
    leaves = { label = _("Eichenlaub"), color = "green", rgb = { 58, 150, 60 }, pattern = "leaves", drop = "leaves" },
    leaves_birch = { label = _("Birkenlaub"), color = "green", rgb = { 106, 172, 69 }, pattern = "leaves" },
    leaves_spruce = { label = _("Fichtennadeln"), color = "cyan", rgb = { 54, 124, 80 }, pattern = "leaves" },
    leaves_jungle = { label = _("Tropenlaub"), color = "green", rgb = { 45, 178, 44 }, pattern = "leaves" },
    leaves_acacia = { label = _("Akazienlaub"), color = "green", rgb = { 115, 163, 61 }, pattern = "leaves" },
    planks = { label = _("Holzbretter"), color = "red", rgb = { 176, 143, 90 }, pattern = "planks" },
    glass = { label = _("Glas"), color = "cyan", rgb = { 218, 241, 243 }, pattern = "glass" },
    crafting_table = { label = _("Werkbank"), color = "red", rgb = { 142, 106, 62 }, pattern = "craft_table" },
    furnace = { label = _("Ofen"), color = "blue", rgb = { 118, 118, 118 }, pattern = "furnace" },
    cactus = { label = _("Kaktus"), color = "green", rgb = { 74, 140, 62 }, pattern = "cactus" },
    dead_bush = { label = _("Trockenbusch"), color = "yellow", rgb = { 148, 109, 58 }, pattern = "dead_bush" },
    wheat = { label = _("Weizen"), color = "yellow", rgb = { 208, 190, 90 }, pattern = "wheat" },
}

-- Display and crafting order: natural blocks, ores, wood, foliage, crafted blocks.
local MATERIAL_ORDER = {
    "grass", "dirt", "farmland", "cobblestone", "stone", "gravel", "sand", "sandstone",
    "clay", "bricks", "snow", "ice", "water", "lava", "obsidian", "bedrock",
    "coal", "iron", "gold", "diamond", "redstone",
    "wood", "wood_birch", "wood_spruce", "wood_jungle", "wood_acacia",
    "leaves", "leaves_birch", "leaves_spruce", "leaves_jungle", "leaves_acacia",
    "planks", "glass", "crafting_table", "furnace", "cactus", "dead_bush", "wheat",
}

local MATERIAL_COLORS, MATERIAL_TARGET_RGB, MATERIAL_LABELS, MATERIAL_PATTERNS, DROPS = {}, {}, {}, {}, {}
for id, definition in pairs(MATERIALS) do
    MATERIAL_COLORS[id] = definition.color
    MATERIAL_TARGET_RGB[id] = definition.rgb
    MATERIAL_LABELS[id] = definition.label
    MATERIAL_PATTERNS[id] = definition.pattern
    DROPS[id] = definition.drop or id
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
}

local PATTERN_VALUES = {}
for material, pattern_name in pairs(MATERIAL_PATTERNS) do
    local source = PATTERNS[pattern_name] or BASE_STONE_PATTERN
    local values = {}
    for index = 1, 64 do
        local digit = tonumber(source:sub(index, index))
        values[index] = digit or 2
    end
    PATTERN_VALUES[material] = values
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
    { result = { "crafting_table", 1 }, ingredients = { { "planks", 4 } } },
    { result = { "furnace", 1 }, ingredients = { { "cobblestone", 8 } } },
    { result = { "stone", 1 }, ingredients = { { "cobblestone", 1 }, { "coal", 1 } } },
    { result = { "glass", 1 }, ingredients = { { "sand", 1 }, { "coal", 1 } } },
    { result = { "sandstone", 1 }, ingredients = { { "sand", 4 } } },
    { result = { "bricks", 2 }, ingredients = { { "clay", 4 }, { "coal", 1 } } },
    { result = { "obsidian", 1 }, ingredients = { { "water", 1 }, { "lava", 1 } } },
    { result = { "ice", 2 }, ingredients = { { "water", 1 }, { "snow", 1 } } },
    { result = { "gravel", 2 }, ingredients = { { "cobblestone", 2 } } },
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

-- Nicht jede Minecraft-Struktur ist eine Säule. Diese Sparse-Map hält Blöcke
-- über dem Terrain (Bäume, Häuser, Pflanzen), damit Stämme, Blattkronen und
-- Gebäude wirklich aus einzelnen Voxeln bestehen und die Bodenhöhe nicht
-- künstlich mitwächst.
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
    ocean = { surface = "water", subsurface = "gravel", label = _("Ozean") },
    river = { surface = "water", subsurface = "sand", label = _("Fluss") },
    beach = { surface = "sand", subsurface = "sandstone", label = _("Strand") },
    plains = { surface = "grass", subsurface = "dirt", tree = "oak", tree_chance = 0.020, spacing = 7, label = _("Ebene") },
    forest = { surface = "grass", subsurface = "dirt", tree = "oak", tree_chance = 0.170, spacing = 5, label = _("Wald") },
    birch_forest = { surface = "grass", subsurface = "dirt", tree = "birch", tree_chance = 0.150, spacing = 5, label = _("Birkenwald") },
    taiga = { surface = "grass", subsurface = "dirt", tree = "spruce", tree_chance = 0.140, spacing = 5, label = _("Taiga") },
    snowy_plains = { surface = "snow", subsurface = "dirt", tree = "spruce", tree_chance = 0.030, spacing = 9, label = _("Schneefeld") },
    desert = { surface = "sand", subsurface = "sandstone", plant = "cactus", plant_chance = 0.022, spacing = 6, label = _("Wüste") },
    savanna = { surface = "grass", subsurface = "dirt", tree = "acacia", tree_chance = 0.055, spacing = 7, plant = "dead_bush", label = _("Savanne") },
    jungle = { surface = "grass", subsurface = "dirt", tree = "jungle", tree_chance = 0.230, spacing = 5, label = _("Dschungel") },
    mountains = { surface = "stone", subsurface = "stone", tree = "spruce", tree_chance = 0.030, spacing = 9, label = _("Berge") },
    swamp = { surface = "grass", subsurface = "clay", tree = "swamp_oak", tree_chance = 0.075, spacing = 6, label = _("Sumpf") },
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

local rebuildWorldBlocks
local placeVillage, placeHouse, findVillageSite
local heightAt, materialAt, biomeAt
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
    if x < 0 or z < 0 or x >= world.size or z >= world.size or level < 0 or level >= MAX_COLUMN_HEIGHT then return nil end
    local planes = world.block_planes
    if planes then
        local plane = planes[level + 1]
        return plane and plane[z * world.size + x + 1] or nil
    end
    return rawBlockAt(world, x, z, level)
end
-- Player session ---------------------------------------------------------------

local VoxelSession = {}
VoxelSession.__index = VoxelSession

local function newSlot(material, count)
    return { material = material, count = count }
end

-- Starting kit: the hotbar and the first storage slots hold the most useful
-- building blocks, so a fresh world can be explored and reshaped immediately.
local STARTING_KIT = {
    "grass", "dirt", "stone", "wood", "planks", "cobblestone", "sand", "glass", "bricks",
    "leaves", "snow", "ice", "sandstone", "clay", "gravel", "obsidian", "coal", "iron",
}
local STARTING_COUNTS = { 64, 64, 64, 64, 64, 64, 64, 32, 32, 32, 32, 16, 32, 32, 32, 16, 32, 16 }

local function startingSlots()
    local slots = {}
    for index, material in ipairs(STARTING_KIT) do
        if MATERIALS[material] then slots[index] = newSlot(material, STARTING_COUNTS[index] or 32) end
    end
    return slots
end

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
        crafting_open = false,
        craft_page = 1,
        held = nil,
        slots = startingSlots(),
        selected_slot = 1,
        tap_action = "place",
        color_enabled = true,
        view_height = nil,
    }, VoxelSession)
    self:syncDerived()
    self.view_height = self:walkHeight(player_x, player_z)
    self._motionTick = function() self:tickMotion() end
    self._jumpTick = function() self:tickJump() end
    return self
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
            self.last_event = _("Stapel abgelegt.")
            return "placed"
        end
        if item.material == self.held.material then
            local room = STACK_LIMIT - item.count
            if room <= 0 then
                self.last_event = _("Dieser Stapel ist voll.")
                return "full"
            end
            local moved = math.min(room, self.held.count)
            item.count = item.count + moved
            self.held.count = self.held.count - moved
            if self.held.count <= 0 then self.held = nil end
            self:syncDerived()
            self.last_event = _("Stapel zusammengeführt.")
            return "merged"
        end
        self.slots[slot], self.held = self.held, item
        self:syncDerived()
        self.last_event = _("Stapel getauscht.")
        return "swapped"
    end
    if item then
        self.held = item
        self.slots[slot] = nil
        self:syncDerived()
        self.last_event = _("Aufgenommen: ") .. materialLabel(item.material)
        return "picked"
    end
    self.last_event = _("Leerer Platz.")
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
    self.last_event = item and (materialLabel(item.material) .. " ×" .. item.count) or _("Dieser Hotbar-Platz ist leer.")
    return true
end

function VoxelSession:selectedMaterial()
    local item = self.slots[self.selected_slot]
    return item and item.material or nil
end

function VoxelSession:toggleInventory()
    self.inventory_open = not self.inventory_open
    if self.inventory_open then
        self.crafting_open = false
        self.last_event = _("Inventar geöffnet.")
    else
        self:returnHeld()
        self.last_event = _("Inventar geschlossen.")
    end
    return self.inventory_open
end

function VoxelSession:openCrafting()
    self:returnHeld()
    self.inventory_open, self.crafting_open = false, true
    self.craft_page = 1
    self.last_event = _("Werkbank geöffnet.")
    return true
end

function VoxelSession:closeOverlays()
    self:returnHeld()
    self.inventory_open, self.crafting_open = false, false
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
        self.last_event = _("Für dieses Rezept fehlen Zutaten.")
        return false
    end
    for _, ingredient in ipairs(recipe.ingredients) do self:takeMaterial(ingredient[1], ingredient[2]) end
    local leftover = self:addItem(recipe.result[1], recipe.result[2])
    self.last_event = leftover > 0
        and _("Das Ergebnis passt nicht mehr ins Inventar.")
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

function VoxelSession:walkHeight(x, z)
    local cell_x, cell_z = math.floor(x), math.floor(z)
    local world = self.world
    if cell_x < 0 or cell_z < 0 or cell_x >= world.size or cell_z >= world.size then return 0 end
    for level = MAX_COLUMN_HEIGHT - 1, 0, -1 do
        if blockAt(world, cell_x, cell_z, level) then return level + 1 end
    end
    return 0
end

function VoxelSession:groundHeightAtPlayer()
    if self.view_height then return self.view_height end
    return self:walkHeight(self.player_x, self.player_z)
end

function VoxelSession:biomeName()
    local biome = biomeAt(self.world, math.floor(self.player_x), math.floor(self.player_z))
    return (BIOMES[biome] and BIOMES[biome].label) or tostring(biome)
end

function VoxelSession:newWorld(seed)
    if self.motion then UIManager:unschedule(self._motionTick) end
    if self.jump_frame then UIManager:unschedule(self._jumpTick) end
    if seed == nil then self.seed = nextWorldSeed(self.seed) else self.seed = normalizeSeed(seed) end
    self.world = buildWorld(self.seed)
    self.player_x, self.player_z, self.yaw = findSpawn(self.world)
    self.pitch = 0
    self.motion, self.jump_frame, self.jump_offset = nil, nil, 0
    self.steps = 0
    self.view_height = self:walkHeight(self.player_x, self.player_z)
    self.last_event = _("Neue Welt erzeugt. Seed: ") .. tostring(self.seed)
    return true
end

function VoxelSession:mineBlock(target)
    if type(target) ~= "table" then self.last_event = _("Hier ist kein Block."); return false end
    local x, z, y = target.x, target.z, target.y
    if type(x) ~= "number" or type(z) ~= "number" or type(y) ~= "number"
        or x < 0 or z < 0 or x >= self.world.size or z >= self.world.size
        or y < 0 or y >= MAX_COLUMN_HEIGHT then
        self.last_event = _("Hier ist kein Block.")
        return false
    end
    local material = blockAt(self.world, x, z, y)
    if not material then self.last_event = _("Hier ist kein Block."); return false end
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
    local leftover = self:addItem(drop, 1)
    self.last_event = leftover > 0 and _("Das Inventar ist voll.") or (_("Abgebaut: ") .. materialLabel(drop))
    self.view_height = self:walkHeight(self.player_x, self.player_z)
    return true
end

function VoxelSession:placeBlock(target)
    if type(target) ~= "table" then self.last_event = _("Kein Ziel ausgewählt."); return false end
    -- Bedrock places against the touched face: the caller passes the tagged
    -- block and we fill the free cell in front of its normal. Plain x/y/z
    -- targets are accepted as well (that cell is then the destination).
    local x, z, y = target.place_x or target.x, target.place_z or target.z, target.place_y or target.y
    if type(x) ~= "number" or type(z) ~= "number" or type(y) ~= "number"
        or x < 1 or z < 1 or x >= self.world.size - 1 or z >= self.world.size - 1
        or y < 0 or y >= MAX_COLUMN_HEIGHT then
        self.last_event = _("Hier kann kein Block platziert werden.")
        return false
    end
    local item = self.slots[self.selected_slot]
    if not item or item.count <= 0 then
        self.last_event = _("In diesem Hotbar-Platz liegt kein Block.")
        return false
    end
    local material = item.material
    if blockAt(self.world, x, z, y) then self.last_event = _("Der Platz ist bereits belegt."); return false end
    -- Never trap the player inside a placed block, just like Bedrock.
    local cell_x, cell_z = math.floor(self.player_x), math.floor(self.player_z)
    local feet = math.floor(self:groundHeightAtPlayer())
    if x == cell_x and z == cell_z and (y == feet or y == feet + 1) then
        self.last_event = _("Hier stehst du selbst.")
        return false
    end
    self.world.extra_blocks = self.world.extra_blocks or {}
    self.world.removed_blocks = self.world.removed_blocks or {}
    local key = extraBlockKey(x, z, y)
    self.world.extra_blocks[key] = material
    self.world.removed_blocks[key] = nil
    rebuildBlockColumn(self.world, x, z)
    item.count = item.count - 1
    if item.count <= 0 then
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
    self.last_event = _("Gesetzt: ") .. materialLabel(material)
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

function VoxelSession:beginMove(direction)
    if self.motion then return false end
    local next_x = self.player_x + math.sin(self.yaw) * WALK_DISTANCE * direction
    local next_z = self.player_z + math.cos(self.yaw) * WALK_DISTANCE * direction
    -- Keep the camera away from the outside edge. It prevents rays crossing the
    -- world boundary from becoming a noisy, empty horizon.
    if next_x < 1 or next_z < 1 or next_x >= self.world.size - 1 or next_z >= self.world.size - 1 then
        self.last_event = _("Weltgrenze erreicht.")
        return false
    end
    local from_height = self:groundHeightAtPlayer()
    local to_height = self:walkHeight(next_x, next_z)
    local step = to_height - from_height
    if step > 2 then
        self.last_event = _("Dieser Block ist zu hoch.")
        return false
    end
    self.motion = {
        from_x = self.player_x, from_z = self.player_z,
        to_x = next_x, to_z = next_z,
        from_height = from_height, to_height = to_height,
        frame = 0,
    }
    self.steps = self.steps + 1
    self.last_event = direction > 0 and _("Vorwärts.") or _("Rückwärts.")
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
        self.view_height = self:walkHeight(self.player_x, self.player_z)
    else
        UIManager:scheduleIn(MOVE_FRAME_SECONDS, self._motionTick)
    end
end

-- A non-animated single step, used by tests and by explicit keyboard repeats.
function VoxelSession:move(direction)
    if not self:beginMove(direction) then return false end
    local motion = self.motion
    self.motion = nil
    UIManager:unschedule(self._motionTick)
    self.player_x, self.player_z = motion.to_x, motion.to_z
    self.view_height = self:walkHeight(self.player_x, self.player_z)
    return true
end

function VoxelSession:toggleTapAction()
    if self.tap_action == "place" then
        self.tap_action = "mine"
        self.last_event = _("Tippen baut ab, Halten setzt Blöcke.")
    else
        self.tap_action = "place"
        self.last_event = _("Tippen setzt Blöcke, Halten baut ab.")
    end
    return true
end

function VoxelSession:tapActionLabel()
    return self.tap_action == "place" and _("Tipp: Setzen") or _("Tipp: Abbauen")
end

function VoxelSession:tapAction(target)
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
        self.last_event = _("KOReader-Farbrendering ist ausgeschaltet oder nicht verfügbar.")
        return false
    end
    self.color_enabled = not self.color_enabled
    self.last_event = self.color_enabled and _("Farbrendering aktiviert.") or _("Monochromes Rendering aktiviert.")
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
}

function VoxelCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapMinecraftExplore = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeMinecraftLook = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        HoldMinecraftAction = { GestureRange:new{ ges = "hold", range = self.dimen } },
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
    local dx, dy = second[1] - first[1], second[2] - first[2]
    local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy))))
    local size = math.max(1, thickness or 1)
    for step = 0, steps do
        local ratio = step / steps
        bb:paintRect(math.floor(first[1] + dx * ratio), math.floor(first[2] + dy * ratio), size, size, Blitbuffer.COLOR_BLACK)
    end
end

-- The targeted block gets a Minecraft-style face outline around the crosshair.
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
                -- Every ink of the color path is resolved to a real color:
                -- scene names use their sky/ground tone and palette names use
                -- their printable RGB value (including the white ink).
                local rgb_ink = SCENE_COLORS[ink] and sceneColor(ink) or paletteColor(ink)
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
                -- A top face is one step brighter and a side face one step
                -- darker, but genuinely black texture pixels (coal, obsidian,
                -- ore spots) stay black and a side face never collapses into
                -- solid black: the previous shading turned every earth and wood
                -- side face into a black rectangle.
                if color_mode then
                    -- Color panels shape the surface with its dithered color: a
                    -- top face is one step brighter, but the base texture step
                    -- stays visible on side faces instead of collapsing into a
                    -- solid black surface.
                    if top then
                        if level > 0 then level = level + 1 end
                    elseif hit_side == 0 and level > 1 then
                        level = level - 1
                    end
                elseif hit_side == 0 and level > 1 then
                    -- Monochrome panels keep the raw texture density for tops so
                    -- a bright grass cap never turns into blank white paper.
                    level = level - 1
                end
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
                    -- Distant terrain is a two-tone dithered band: it reads as
                    -- ground and keeps the horizon line crisp, unlike a striped
                    -- pattern which looked like a printed texture artifact.
                    ink = dither_threshold < 7 and "distant_ground_dark" or "distant_ground"
                elseif sky_position < 0.27 then
                    ink = ((floor(rx / 11) + floor(ry / 5)) % 13 == 0) and "cloud" or "sky_top"
                elseif sky_position < 0.58 then
                    ink = ((floor(rx / 15) + floor(ry / 4)) % 17 == 0) and "cloud" or "sky_mid"
                else
                    ink = "sky_horizon"
                end
            elseif dir_y < 0 then
                -- Distant terrain as a mid-gray dither: on monochrome panels the
                -- sky stays light while the far ground stays visibly darker.
                ink = dither_threshold < 6 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
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
    self:_drawTargetOutline(bb, x, y, session)
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

function VoxelCanvas:pickBlock(screen_x, screen_y)
    local session = self.session
    if not session or not screen_x or not screen_y then return nil end
    local relative_x = clamp(screen_x - self._origin_x, 0, self.width - 1)
    local relative_y = clamp(screen_y - self._origin_y, 0, self.height - 1)
    local sample = session.color_enabled and colorRenderingEnabled() and COLOR_RENDER_SAMPLE or RENDER_SAMPLE
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
    local result = self.session:act(action, target)
    self:refreshFast()
    if self.hotbar and (action == "mine" or action == "place" or action == "tap" or action == "hold") then self.hotbar:refresh() end
    return result ~= false
end

function VoxelCanvas:onTapMinecraftExplore(first, second)
    local gesture = second or first
    if not gesture or not gesture.pos then return true end
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
    local gesture = second or first
    local pos = gesture and gesture.pos
    if not pos then return true end
    local target = self:pickBlock(pos.x, pos.y)
    if target then
        self:act("hold", target)
    end
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

function Joystick:onTapMinecraftJoystick(first, second) return self:_steer(second or first) end
function Joystick:onSwipeMinecraftJoystick(first, second)
    if not self.canvas then return false end
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

local Hotbar = InputContainer:extend{ session = nil, canvas = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0 }

function Hotbar:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftHotbar = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function Hotbar:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local range = self.ges_events.TapMinecraftHotbar[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    local slot_w = self.width / HOTBAR_SLOTS
    local session = self.session
    for slot = 1, HOTBAR_SLOTS do
        local left = x + math.floor((slot - 1) * slot_w)
        local right = x + math.floor(slot * slot_w)
        local cell_w = math.max(1, right - left)
        local sx = left + 1
        local selected = session and session.selected_slot == slot
        local item = session and session.slots[slot] or nil
        local material = item and item.material or nil
        bb:paintRect(sx, y + 1, math.max(1, cell_w - 2), self.height - 2, selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY)
        bb:paintRect(sx + 2, y + 3, math.max(1, cell_w - 6), math.max(1, self.height - 6), Blitbuffer.COLOR_WHITE)
        if material then
            local swatch = colorForMaterial(material)
            local swatch_size = math.min(scale(10), math.max(1, self.height - scale(10)))
            local swatch_x, swatch_y = sx + 4, y + math.floor((self.height - swatch_size) / 2)
            if session.color_enabled and colorRenderingEnabled() and bb.paintRectRGB32 then
                bb:paintRectRGB32(swatch_x, swatch_y, swatch_size, swatch_size, swatch)
            else
                bb:paintRect(swatch_x, swatch_y, swatch_size, swatch_size, swatch)
            end
            local label = TextWidget:new{
                text = abbreviationFor(material) .. tostring(item.count),
                face = Font:getFace("smallinfofont", math.max(scale(7), math.min(scale(9), self.height - scale(18)))),
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold = selected,
                max_width = math.max(scale(8), cell_w - swatch_size - scale(9)),
                padding = 0,
            }
            local label_size = label:getSize()
            label:paintTo(bb, math.min(right - label_size.w - 2, swatch_x + swatch_size + 2), y + math.floor((self.height - label_size.h) / 2))
        else
            local label = TextWidget:new{
                text = "-",
                face = Font:getFace("smallinfofont", math.max(scale(7), math.min(scale(9), self.height - scale(18)))),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                padding = 0,
            }
            label:paintTo(bb, sx + math.floor(cell_w / 2) - scale(2), y + math.floor((self.height - label:getSize().h) / 2))
        end
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
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
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

-- Inventory screen: 36 slots in four rows, Bedrock-style tap to move stacks.
local InventoryPanel = InputContainer:extend{ session = nil, canvas = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0 }

function InventoryPanel:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapMinecraftInventory = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function InventoryPanel:headerHeight() return scale(26) end
function InventoryPanel:footerHeight() return scale(20) end
function InventoryPanel:slotHeight()
    return math.max(scale(16), math.floor((self.height - self:headerHeight() - self:footerHeight() - scale(6)) / 4))
end
function InventoryPanel:slotWidth() return (self.width - scale(8)) / 9 end

function InventoryPanel:hitTest(local_x, local_y)
    local header_h, footer_h = self:headerHeight(), self:footerHeight()
    if local_y < header_h then
        local button_w = math.max(scale(30), math.floor((self.width - scale(12)) / 3))
        if local_x >= self.width - scale(4) - button_w and local_y > scale(2) then
            return { kind = "button", id = "close" }
        end
        if local_x >= self.width - scale(8) - button_w * 2 and local_y > scale(2) then
            return { kind = "button", id = "craft" }
        end
        return { kind = "header" }
    end
    if local_y >= self.height - footer_h then return { kind = "footer" } end
    local slot_h, slot_w = self:slotHeight(), self:slotWidth()
    local grid_y = header_h + scale(2)
    if local_y < grid_y + slot_h * 4 then
        local column = clamp(math.floor((local_x - scale(4)) / slot_w) + 1, 1, 9)
        local row = clamp(math.floor((local_y - grid_y) / slot_h) + 1, 1, 4)
        return { kind = "slot", slot = (row - 1) * 9 + column, row = row, column = column }
    end
    return { kind = "empty" }
end

function InventoryPanel:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    local session = self.session
    if not session or not session.inventory_open then return true end
    local range = self.ges_events.TapMinecraftInventory[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    local header_h, footer_h = self:headerHeight(), self:footerHeight()
    local slot_h, slot_w = self:slotHeight(), self:slotWidth()
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x, y, self.width, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + self.height - 2, self.width, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, 2, self.height, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + self.width - 2, y, 2, self.height, Blitbuffer.COLOR_BLACK)
    local title = TextWidget:new{
        text = _("INVENTAR") .. "  ·  " .. tostring(session.used_slots) .. "/" .. tostring(INVENTORY_SLOTS),
        face = Font:getFace("cfont", math.max(scale(8), scale(10))),
        fgcolor = Blitbuffer.COLOR_BLACK,
        bold = true,
        max_width = math.max(scale(40), self.width - scale(70)),
    }
    title:paintTo(bb, x + scale(5), y + scale(4))
    local button_w = math.max(scale(30), math.floor((self.width - scale(12)) / 3))
    local button_h = header_h - scale(6)
    local craft_x = self.width - scale(8) - button_w * 2
    local close_x = self.width - scale(4) - button_w
    bb:paintRect(x + craft_x, y + scale(3), button_w, button_h, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x + close_x, y + scale(3), button_w, button_h, Blitbuffer.COLOR_BLACK)
    local craft_label = TextWidget:new{
        text = _("Handwerk"),
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = button_w - scale(4),
    }
    craft_label:paintTo(bb, x + craft_x + scale(3), y + scale(6))
    local close_label = TextWidget:new{
        text = _("Fertig"),
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
        fgcolor = Blitbuffer.COLOR_WHITE,
        max_width = button_w - scale(4),
    }
    close_label:paintTo(bb, x + close_x + scale(4), y + scale(6))
    local grid_y = header_h + scale(2)
    for slot = 1, INVENTORY_SLOTS do
        local column = (slot - 1) % 9
        local row = math.floor((slot - 1) / 9)
        local sx = x + scale(4) + math.floor(column * slot_w)
        local sy = y + grid_y + row * slot_h
        local cell_w = math.max(scale(8), math.floor(slot_w) - scale(2))
        local cell_h = math.max(scale(8), slot_h - scale(2))
        local item = session.slots[slot]
        bb:paintRect(sx, sy, cell_w, cell_h, row == 0 and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE)
        bb:paintRect(sx, sy, cell_w, 1, Blitbuffer.COLOR_BLACK)
        bb:paintRect(sx, sy + cell_h - 1, cell_w, 1, Blitbuffer.COLOR_BLACK)
        bb:paintRect(sx, sy, 1, cell_h, Blitbuffer.COLOR_BLACK)
        bb:paintRect(sx + cell_w - 1, sy, 1, cell_h, Blitbuffer.COLOR_BLACK)
        if item then
            local swatch_size = math.max(scale(6), math.min(cell_w - scale(8), cell_h - scale(8)))
            local swatch = colorForMaterial(item.material)
            if session.color_enabled and colorRenderingEnabled() and bb.paintRectRGB32 then
                bb:paintRectRGB32(sx + scale(4), sy + scale(4), swatch_size, swatch_size, swatch)
            else
                bb:paintRect(sx + scale(4), sy + scale(4), swatch_size, swatch_size, swatch)
            end
            local count = TextWidget:new{
                text = tostring(item.count),
                face = Font:getFace("smallinfofont", math.max(scale(6), scale(7))),
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = cell_w - scale(4),
            }
            count:paintTo(bb, sx + math.max(scale(3), cell_w - count:getSize().w - scale(2)), sy + cell_h - scale(10))
        end
    end
    local status
    if session.held then
        status = _("In der Hand: ") .. materialLabel(session.held.material) .. " ×" .. session.held.count .. " — " .. _("Platz antippen zum Ablegen")
    else
        status = _("Stapel antippen, um ihn aufzunehmen; oben die Hotbar wählen")
    end
    local footer = TextWidget:new{
        text = status,
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = self.width - scale(8),
    }
    footer:paintTo(bb, x + scale(4), y + self.height - footer_h + scale(2))
    return true
end

function InventoryPanel:refresh()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "ui", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    if self.hotbar then self.hotbar:refresh() end
    if self.event_line then self.event_line:refresh() end
    return true
end

function InventoryPanel:onTapMinecraftInventory(first, second)
    local gesture = second or first
    local session = self.session
    if not session or not session.inventory_open then return false end
    local pos = gesture and gesture.pos
    if not pos then return true end
    local hit = self:hitTest(pos.x - self._origin_x, pos.y - self._origin_y)
    if hit.kind == "button" and hit.id == "close" then
        session:closeOverlays()
    elseif hit.kind == "button" and hit.id == "craft" then
        session:openCrafting()
        if self.crafting_panel then self.crafting_panel:refresh() end
    elseif hit.kind == "slot" then
        session:pickSlot(hit.slot)
    end
    self:refresh()
    if self.crafting_panel then self.crafting_panel:refresh() end
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
        text = _("WERKBANK") .. "  ·  " .. tostring(session.craft_page) .. "/" .. tostring(session:pageCount()),
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
        text = _("Zurück"),
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
                text = session:recipeLabel(entry.recipe) .. (craftable and "" or ("  ·  " .. _("Zutaten fehlen"))),
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
        text = _("◀ Seite"),
        face = Font:getFace("smallinfofont", math.max(scale(7), scale(8))),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = self.width / 2 - scale(8),
    }
    prev:paintTo(bb, x + scale(8), footer_y + scale(4))
    local next_label = TextWidget:new{
        text = _("Seite ▶"),
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
    version = "4.0.1",
    title = "Minecraft 3D",
    subtitle = "Biome, Dörfer, Inventar & Crafting",
    symbol = "M",
    logo = "minecraft",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or scale
        local margin, gap = px(9), px(5)
        local header_h, controls_h, hotbar_h = px(43), px(31), px(30)
        local canvas_h = math.max(px(76), height - header_h - controls_h - hotbar_h - px(33))
        local canvas_w = math.max(px(40), width - 2 * margin)
        local canvas_y = header_h
        local hotbar_y = canvas_y + canvas_h + gap
        local controls_y = hotbar_y + hotbar_h + gap
        local button_w = math.max(px(26), math.floor((canvas_w - 5 * gap) / 6))
        local joystick_size = math.min(px(76), math.floor(canvas_w * 0.22))
        local jump_w, jump_h = px(58), px(30)
        local world_button_w = math.max(px(8), math.min(px(38), math.floor(canvas_w * 0.22)))
        local header_gap = math.min(gap, math.floor(canvas_w * 0.04))
        local color_button_w = math.max(0, math.min(px(58), canvas_w - world_button_w - header_gap))
        local heading_w = math.max(px(1), canvas_w - color_button_w - world_button_w - header_gap - px(8))
        local heading_size = heading_w < px(105) and px(14) or px(18)
        local canvas = VoxelCanvas:new{ width = canvas_w, height = canvas_h, session = state.session }
        local hotbar = Hotbar:new{ width = canvas_w, height = hotbar_h, session = state.session }
        local event_line = EventLine:new{ width = canvas_w, height = px(13), session = state.session }
        local inventory_panel = InventoryPanel:new{ width = canvas_w, height = canvas_h, session = state.session, canvas = canvas }
        local crafting_panel = CraftingPanel:new{ width = canvas_w, height = canvas_h, session = state.session, canvas = canvas }
        inventory_panel.crafting_panel = crafting_panel
        inventory_panel.hotbar = hotbar
        inventory_panel.event_line = event_line
        crafting_panel.inventory_panel = inventory_panel
        crafting_panel.event_line = event_line
        hotbar.overlap_offset = { margin, hotbar_y }
        inventory_panel.overlap_offset = { margin, canvas_y }
        crafting_panel.overlap_offset = { margin, canvas_y }
        state.session.canvas = canvas
        canvas.hotbar = hotbar
        canvas.event_line = event_line
        -- Keep the widgets reachable for refresh calls and for the regression
        -- tests: overlays must repaint their own region, never the full pane.
        state.canvas, state.hotbar, state.event_line = canvas, hotbar, event_line
        state.inventory_panel, state.crafting_panel = inventory_panel, crafting_panel
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
        local mode_label = state.session:tapActionLabel()
        local hint_text = state.session.tap_action == "place"
            and _("Tippen: Block setzen · Halten: abbauen · Wischen: umsehen")
            or _("Tippen: abbauen · Halten: Block setzen · Wischen: umsehen")
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = "MINECRAFT 3D", face = Font:getFace("cfont", heading_size), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = heading_w, overlap_offset = { margin, px(6) } },
            TextWidget:new{ text = _("Seed: ") .. tostring(state.session.seed) .. " · " .. state.session:biomeName(), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = heading_w, overlap_offset = { margin, px(29) } },
            NavButton:new{ title = _("Farbe"), width = color_button_w, height = px(25), callback = function() canvas:act("color") end, overlap_offset = { margin + canvas_w - color_button_w, px(6) } },
            NavButton:new{ title = _("Welt"), width = world_button_w, height = px(25), callback = function() promptNewWorld(state, context) end, overlap_offset = { margin + canvas_w - color_button_w - header_gap - world_button_w, px(6) } },
            canvas,
            hotbar,
            joystick,
            NavButton:new{ title = _("Springen"), width = jump_w, height = jump_h, primary = true, callback = function() canvas:act("jump") end, overlap_offset = { margin + canvas_w - jump_w - px(8), canvas_y + canvas_h - jump_h - px(8) } },
            inventory_panel,
            crafting_panel,
            NavButton:new{ title = _("Links"), width = button_w, height = controls_h, callback = function() canvas:act("left") end, overlap_offset = { margin, controls_y } },
            NavButton:new{ title = _("Vor"), width = button_w, height = controls_h, primary = true, callback = function() canvas:act("forward") end, overlap_offset = { margin + (button_w + gap), controls_y } },
            NavButton:new{ title = _("Zurück"), width = button_w, height = controls_h, callback = function() canvas:act("back") end, overlap_offset = { margin + (button_w + gap) * 2, controls_y } },
            NavButton:new{ title = _("Rechts"), width = button_w, height = controls_h, callback = function() canvas:act("right") end, overlap_offset = { margin + (button_w + gap) * 3, controls_y } },
            NavButton:new{ title = _("Inventar"), width = button_w, height = controls_h, callback = function()
                canvas:act("inventory")
                inventory_panel:refresh()
            end, overlap_offset = { margin + (button_w + gap) * 4, controls_y } },
            NavButton:new{ title = mode_label, width = button_w, height = controls_h, callback = function()
                canvas:act("mode")
                if context.requestRebuild then context.requestRebuild("ui") end
            end, overlap_offset = { margin + (button_w + gap) * 5, controls_y } },
            event_line,
            TextWidget:new{ text = hint_text, face = Font:getFace("smallinfofont", px(8)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = canvas_w, overlap_offset = { margin, height - px(14) } },
        }
        event_line.overlap_offset = { margin, controls_y + controls_h + px(3) }
        return pane
    end,
    _test = {
        VoxelSession = VoxelSession,
        VoxelCanvas = VoxelCanvas,
        InventoryPanel = InventoryPanel,
        CraftingPanel = CraftingPanel,
        Hotbar = Hotbar,
        EventLine = EventLine,
        buildWorld = buildWorld,
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
        RECIPES = RECIPES,
        RECIPE_PAGES = RECIPE_PAGES,
        BIOMES = BIOMES,
        BIOME_ORDER = BIOME_ORDER,
        TREE_DEFS = TREE_DEFS,
        STARTING_KIT = STARTING_KIT,
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
        HOTBAR_SLOTS = HOTBAR_SLOTS,
        INVENTORY_SLOTS = INVENTORY_SLOTS,
        STACK_LIMIT = STACK_LIMIT,
        CRAFT_ROWS_PER_PAGE = CRAFT_ROWS_PER_PAGE,
        PLAYER_EYE_HEIGHT = PLAYER_EYE_HEIGHT,
    },
}
