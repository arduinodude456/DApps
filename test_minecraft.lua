--[[--
Regression test for Minecraft 3D 4.7.0.

Covers the world generator (biomes, trees, villages, ore layers), the
black-and-white and RGB render paths (including ray-cache reuse), Survival and
Creative inventory behavior, catalogue-and-slot modal routing, crafting,
block mining/placing with drops, touch interaction, and responsive AppDock
layouts.

Run with: lua5.1 test_minecraft.lua
]]--
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

local color_enabled, rect_calls, rgb_calls = false, 0, 0
local painted = {}
local function resetPixels()
    painted, rect_calls, rgb_calls = {}, 0, 0
end
local function newBuffer()
    local bb = {}
    function bb:paintRect(x, y, w, h, ink)
        rect_calls = rect_calls + 1
        painted[#painted + 1] = { kind = "mono", x = x, y = y, w = w, h = h, ink = ink }
    end
    function bb:paintRectRGB32(x, y, w, h, color)
        rgb_calls = rgb_calls + 1
        painted[#painted + 1] = { kind = "rgb", x = x, y = y, w = w, h = h, color = color }
    end
    return bb
end
local function paintedSum(kind)
    local total = 0
    for _, rect in ipairs(painted) do
        if rect.kind == kind then total = total + rect.w * rect.h end
    end
    return total
end
local function paintedColors()
    local set = {}
    for _, rect in ipairs(painted) do
        if rect.kind == "rgb" then set[rect.color] = true end
    end
    return set
end
local function hexChannels(color)
    if type(color) ~= "string" then return nil end
    local red, green, blue = color:match("^#(%x%x)(%x%x)(%x%x)$")
    if not red then return nil end
    return tonumber(red, 16), tonumber(green, 16), tonumber(blue, 16)
end

local Widget, Input = class(), class()
-- TextWidget is intentionally lightweight, but it must provide the KOReader
-- methods used by production drawing code.  This catches actual widget API
-- calls instead of silently accepting incomplete test doubles.
function Widget:getSize()
    local text = tostring(self.text or "")
    local width = math.max(1, #text * 6)
    if self.max_width then width = math.min(width, self.max_width) end
    return { w = width, h = self.height or 10 }
end
function Widget:paintTo(_, x, y)
    self._origin_x, self._origin_y = x or 0, y or 0
    return true
end
function Widget:setText(text)
    self.text = text
    return true
end
function Widget:getText() return self.text end
function Widget:free() self.freed = true end
install("ffi/blitbuffer", {
    COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "darkgray", COLOR_LIGHT_GRAY = "lightgray",
    colorFromString = function(hex) return hex end,
})
install("device", {
    screen = { scaleBySize = function(_, value) return value end, isColorEnabled = function() return color_enabled end },
    input = { group = {} },
})
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

local shown_widget, shown_list, dirty_calls, repaint_calls = nil, {}, {}, 0
local scheduled = {}
local InputDialog = Widget:extend({})
function InputDialog:getInputText() return self.input or "" end
function InputDialog:onShowKeyboard() self.keyboard_shown = true end
local InfoMessage = Widget:extend({})
install("ui/widget/inputdialog", InputDialog)
install("ui/widget/infomessage", InfoMessage)
install("ui/uimanager", {
    scheduleIn = function(_, delay, callback) scheduled[#scheduled + 1] = { delay = delay, callback = callback } end,
    unschedule = function() end,
    widgetRepaint = function() repaint_calls = repaint_calls + 1 end,
    setDirty = function(_, widget, waveform, region) dirty_calls[#dirty_calls + 1] = { widget = widget, waveform = waveform, region = region } end,
    forceRePaint = function() end,
    yieldToEPDC = function() end,
    show = function(_, widget) shown_widget = widget; shown_list[#shown_list + 1] = widget end,
    close = function(_, widget) if shown_widget == widget then shown_widget = nil end end,
})
_G.unpack = table.unpack or unpack

local app = assert(loadfile("minecraft.lua"))()
local test = app._test
assert(app.id == "minecraft" and app.version == "4.7.0", "Minecraft 3D 4.7.0 must publish the splash, world list and creation menus")
local embedded_logo = test.ensureEmbeddedLogo()
local embedded_file = assert(io.open(embedded_logo, "rb"), "The installed DApp must materialize its embedded logo")
assert(embedded_file:read(8) == "\137PNG\13\10\26\10", "The embedded logo must be a valid PNG")
embedded_file:close()

--[[--
Palette and dithering helpers
]]--
assert(test.paletteColor("red") == "#dc2d2d", "Palette colors must be parsed through the shared RGB table")
local mix = test.paletteMixForRGB(106, 170, 64)
assert(mix and mix.first and mix.second and mix.second_pixels >= 0 and mix.second_pixels <= 16,
    "Dither mixes must expose two printable inks and bounded coverage")
local again = test.paletteMixForRGB(106, 170, 64)
assert(again == mix, "Equal RGB targets must reuse the mix cache")
assert(type(test.SURFACE_TONES) == "table", "4.7.0 must publish the cached native RGB and grayscale surface tones")
local grid_cols, grid_rows = test.renderGridFor(210, 126)
assert(grid_cols > 0 and grid_rows > 0 and grid_cols <= 210 and grid_rows <= 126,
    "The render grid must remain bounded by the canvas")
local color_cols, color_rows = test.renderGridFor(210, 126, test.COLOR_RENDER_SAMPLE)
assert(color_cols >= grid_cols and color_rows >= grid_rows,
    "The color render grid must not be coarser than the default grid helper")
local u, v = test.textureCoordinates("top", 4.25, 3.5, 7.75, 1)
assert(math.abs(u - 0.25) < 0.001 and math.abs(v - 0.75) < 0.001,
    "Top faces must map to block-local texture coordinates")
assert(test.colorForMaterial("grass") == "black", "Without KOReader color mode the renderer must stay monochrome")
color_enabled = true
assert(test.colorForMaterial("grass") ~= "black", "With KOReader color mode a material must resolve to a color ink")
color_enabled = false
assert(#test.MATERIAL_ORDER >= 35, "The block catalogue must offer at least 35 blocks")
for _, material in ipairs(test.MATERIAL_ORDER) do
    assert(test.MATERIALS[material], "Every ordered block must exist in the catalogue: " .. material)
    assert(test.PATTERN_VALUES[material] and #test.PATTERN_VALUES[material] == 64, "Every block needs a 64-pixel texture: " .. material)
    for _, level in ipairs(test.PATTERN_VALUES[material]) do
        assert(level >= 0 and level <= 3, "Texture levels must stay inside the four supported shades")
    end
    assert(test.DROPS[material], "Every block must define what it drops")
    assert(type(test.PATTERN_AVERAGES[material]) == "number", "Every material must cache its texture average")
    local tones = test.SURFACE_TONES[material]
    assert(tones and #tones.rgb == 16 and #tones.mono == 16,
        "Every material must cache exactly 16 native RGB and monochrome tones")
    for tone = 1, 16 do
        assert(type(tones.rgb[tone]) == "string" and type(tones.mono[tone]) == "string",
            "Every cached surface tone must have RGB and monochrome identities")
        local red, green, blue = tones.mono[tone]:match("^gray_(%d+)_(%d+)_(%d+)$")
        assert(red and red == green and green == blue,
            "Cached monochrome material tones must have equal RGB channels")
    end
end
local grass_red, grass_green, grass_blue = test.SURFACE_TONES.grass.rgb[13]:match("^block_grass_(%d+)_(%d+)_(%d+)$")
grass_red, grass_green, grass_blue = tonumber(grass_red), tonumber(grass_green), tonumber(grass_blue)
assert(grass_red and grass_red >= 85 and grass_red <= 120
    and grass_green >= 145 and grass_green <= 185 and grass_blue >= 50 and grass_blue <= 80,
    "Grass must keep a native cached RGB tone around its 106/170/64 source color")
assert(test.DROPS.grass == "dirt" and test.DROPS.stone == "cobblestone" and test.DROPS.coal == "coal", "Natural blocks must drop their Minecraft-like items")

--[[--
World generation: biomes, trees, structures, ore layers
]]--
local session = test.VoxelSession.new(12345)
local world = session.world
assert(world.seed == 12345 and world.size == test.WORLD_SIZE, "The default world must use seed 12345")
assert(test.HELD_MOVE_SECONDS >= 0.15 and test.HELD_MOVE_SECONDS <= 0.25,
    "Held D-pad movement must not repaint the full voxel scene at the animation-frame rate")
local held_act_calls = 0
local old_session_act = session.act
local old_session_move = session.move
session.held_move_action, session.motion = "forward", nil
session.move = function(_, action) held_act_calls = held_act_calls + 1; assert(action == 1); return true end
session:tickHeldMove()
assert(held_act_calls == 1 and scheduled[#scheduled].delay == test.HELD_MOVE_SECONDS,
    "Held D-pad movement must schedule a rate-limited next step")
session.act, session.move, session.held_move_action = old_session_act, old_session_move, nil
local held_start_calls = 0
local old_session_canvas = session.canvas
session.move = function() held_start_calls = held_start_calls + 1; return true end
session.canvas = { refreshFast = function() end }
assert(session:startHeldMove("forward") and session:startHeldMove("forward"),
    "Repeated starts for one held D-pad direction must remain handled")
assert(held_start_calls == 1,
    "Duplicate hold notifications must not synchronously repeat movement or canvas refresh")
session:stopHeldMove()
session.move, session.canvas = old_session_move, old_session_canvas
local biome_names, biome_count = {}, 0
for z = 0, world.size - 1 do
    for x = 0, world.size - 1 do
        local biome = test.biomeAt(world, x, z)
        if not biome_names[biome] then biome_names[biome] = true; biome_count = biome_count + 1 end
        assert(test.BIOMES[biome], "Every world column must carry a known biome: " .. tostring(biome))
        local height = test.heightAt(world, x, z)
        assert(height >= 1 and height <= test.MAX_TERRAIN_HEIGHT, "Terrain heights must stay inside the generated band")
        assert(test.blockAt(world, x, z, height - 1), "The surface block must exist at the terrain cap")
        local above = test.blockAt(world, x, z, height)
        assert(above == nil or world.extra_blocks[test.extraBlockKey(x, z, height)] == above,
            "Above the terrain cap only structure blocks (trees, houses, plants) may sit")
        assert(test.blockAt(world, x, z, 0) == "bedrock", "Bedrock must line the world floor")
    end
end
assert(biome_count >= 5, "A seed must produce several biomes, got " .. biome_count)
local tree_blocks, plank_blocks, glass_blocks, wheat_blocks, cactus_blocks = 0, 0, 0, 0, 0
for _, material in pairs(world.extra_blocks) do
    if material == "wood" or material == "wood_birch" or material == "wood_spruce"
        or material == "wood_jungle" or material == "wood_acacia"
        or material == "leaves" or material == "leaves_birch" or material == "leaves_spruce"
        or material == "leaves_jungle" or material == "leaves_acacia" then
        tree_blocks = tree_blocks + 1
    end
    if material == "planks" then plank_blocks = plank_blocks + 1 end
    if material == "glass" then glass_blocks = glass_blocks + 1 end
    if material == "wheat" then wheat_blocks = wheat_blocks + 1 end
    if material == "cactus" then cactus_blocks = cactus_blocks + 1 end
end
assert(tree_blocks > 200, "Trees must be made of individual log and leaf blocks, got " .. tree_blocks)
assert(cactus_blocks + wheat_blocks > 0, "Plants must be placed as real blocks")

local ore_found = {}
for x = 20, 60, 7 do
    for z = 20, 60, 7 do
        for level = 0, 8 do
            local material = test.rawBlockAt(world, x, z, level)
            if material then ore_found[material] = (ore_found[material] or 0) + 1 end
        end
    end
end
assert((ore_found.coal or 0) > 0 and (ore_found.iron or 0) > 0, "Coal and iron veins must exist below the surface")
assert((ore_found.diamond or 0) > 0 or (ore_found.gold or 0) > 0, "Deep layers must hold precious ores")

local water_columns, sand_columns = 0, 0
for z = 0, world.size - 1 do
    for x = 0, world.size - 1 do
        local surface = test.materialAt(world, x, z)
        if surface == "water" then water_columns = water_columns + 1 end
        if surface == "sand" then sand_columns = sand_columns + 1 end
    end
end
assert(water_columns > 20, "Oceans, rivers and lakes must contain water columns, got " .. water_columns)
assert(sand_columns > 20, "Beaches and deserts must contain sand columns, got " .. sand_columns)

-- At least one tested seed must place a village with houses, a well and a farm.
local village_seed
for _, seed in ipairs({ 12345, 7, 4242, 2026, 99 }) do
    local candidate = test.VoxelSession.new(seed)
    local planks, glass, wheat, well = 0, 0, 0, false
    for _, material in pairs(candidate.world.extra_blocks) do
        if material == "planks" then planks = planks + 1 end
        if material == "glass" then glass = glass + 1 end
        if material == "wheat" then wheat = wheat + 1 end
    end
    local site = test.findVillageSite(candidate.world, seed)
    if site then
        local ground = test.heightAt(candidate.world, site.x, site.z)
        well = test.blockAt(candidate.world, site.x, site.z, ground - 1) == "water"
            and test.blockAt(candidate.world, site.x + 1, site.z, ground - 1) == "cobblestone"
    end
    local built = candidate.world.village
    local well_ok = false
    if built then
        local ground = test.heightAt(candidate.world, built.x, built.z)
        well_ok = test.blockAt(candidate.world, built.x, built.z, ground - 1) == "water"
            and test.blockAt(candidate.world, built.x + 1, built.z, ground - 1) == "cobblestone"
            and test.blockAt(candidate.world, built.x + 2, built.z + 2, ground + 2) ~= nil
    end
    if planks > 0 and glass > 0 and wheat > 0 and well_ok then
        village_seed = seed
        break
    end
end
assert(village_seed, "At least one seed must contain a village with houses, a well and a wheat farm")

--[[--
Spawn selection and the initial view
]]--
local spawn_x, spawn_z, yaw, spawn_tree = test.findSpawn(world)
session.player_x, session.player_z, session.yaw = spawn_x, spawn_z, yaw
assert(spawn_tree, "The default seed must place the player in front of a visible tree")
local spawn_distance = math.sqrt((spawn_tree.x - spawn_x) ^ 2 + (spawn_tree.z - spawn_z) ^ 2)
assert(spawn_distance >= 6 and spawn_distance <= 20, "The spawn tree must stay inside the intended distance band")
assert(test.hasClearTreeView(world, spawn_x, spawn_z, test.heightAt(world, math.floor(spawn_x), math.floor(spawn_z)), spawn_tree, spawn_distance), "The spawn view of the tree must be unobstructed")

--[[--
Renderer: color and monochrome paths, ray cache, refresh regions
]]--
local canvas = test.VoxelCanvas:new{ width = 210, height = 126, session = session }
session.canvas = canvas
color_enabled = true
session.color_enabled = true
session.world_time = .5 -- fixed daytime scene: stable sky and material checks
local buffer = newBuffer()
resetPixels()
canvas:paintTo(buffer, 0, 0)
assert(rgb_calls > 0 and rect_calls > 0, "The RGB renderer must paint scene spans and the monochrome crosshair")
assert(paintedSum("rgb") >= 210 * 126, "The RGB renderer must cover the whole canvas")
local colors, color_count = paintedColors(), 0
for _ in pairs(colors) do color_count = color_count + 1 end
assert(color_count >= 2, "The color scene must retain a multi-tone sky rather than collapse to one ink")
assert(next(colors) ~= nil, "The sky and world must issue RGB paints when color mode is enabled")
local rgb_area, black_rgb_area = paintedSum("rgb"), 0
for _, rect in ipairs(painted) do
    if rect.kind == "rgb" and rect.color == "#000000" then black_rgb_area = black_rgb_area + rect.w * rect.h end
end
assert(black_rgb_area * 5 < rgb_area,
    "Native material RGB tones must avoid the old coarse black-checkerboard coverage")
local cache = canvas._ray_cache
assert(cache and cache.x and #cache.x == cache.cols * cache.rows, "The renderer must build a reusable ray cache")
canvas:paintTo(buffer, 0, 0)
assert(canvas._ray_cache == cache, "Repainting an unchanged RGB view must reuse the ray cache")

-- The ray geometry is independent of output mode: switching B&W/RGB must not
-- allocate a second camera cache.  Do not pin material shade pixels here;
-- 4.7.0 deliberately changes face lighting while preserving the sky.
color_enabled = false
session.color_enabled = false
resetPixels()
canvas:paintTo(buffer, 0, 0)
assert(canvas._ray_cache == cache, "Switching from RGB to B&W must reuse the same view-ray cache")
assert(rgb_calls == 0, "The monochrome renderer must never use RGB paints")
assert(paintedSum("mono") >= 210 * 126, "The monochrome renderer must cover the whole canvas")
local mono_inks, mono_ink_count = {}, 0
local has_mid_gray = false
for _, rect in ipairs(painted) do
    if not mono_inks[rect.ink] then mono_inks[rect.ink] = true; mono_ink_count = mono_ink_count + 1 end
    local red, green, blue = hexChannels(rect.ink)
    if red then
        assert(red == green and green == blue, "Every monochrome painted hex tone must have equal RGB channels")
        if red > 0 and red < 255 then has_mid_gray = true end
    else
        assert(rect.ink == "black" or rect.ink == "white",
            "The monochrome renderer may only use named black/white or equal-channel gray tones")
    end
end
assert(mono_ink_count >= 3, "The monochrome renderer must use cached grayscale tones instead of coarse black/white holes")
assert(has_mid_gray, "The monochrome renderer must paint visible intermediate gray tones")

-- At night terrain remains dark but has multiple readable native tones, rather
-- than turning into a pure-black silhouette. Restore daytime afterwards so
-- gameplay tests retain their deterministic initial world.
color_enabled, session.color_enabled, session.world_time, session.pitch = true, true, 0, -0.65
resetPixels()
canvas:paintTo(buffer, 0, 0)
local night_colors, night_nonblack, night_dark = {}, 0, false
for _, rect in ipairs(painted) do
    if rect.kind == "rgb" then
        night_colors[rect.color] = true
        local red, green, blue = hexChannels(rect.color)
        if red and (red > 0 or green > 0 or blue > 0) then
            night_nonblack = night_nonblack + rect.w * rect.h
            if math.max(red, green, blue) < 130 then night_dark = true end
        end
    end
end
local night_color_count = 0
for _ in pairs(night_colors) do night_color_count = night_color_count + 1 end
assert(night_dark and night_color_count >= 2 and night_nonblack > 210 * 126 / 3,
    "Night terrain must remain dark but readable through non-black native RGB tones")
session.world_time, session.pitch = .5, 0
color_enabled, session.color_enabled = false, false
session:turn(1)
canvas:paintTo(buffer, 0, 0)
assert(canvas._ray_cache ~= cache, "Changing yaw must rebuild the view-ray cache")

resetPixels()
canvas:_stroke(buffer, { 2, 2 }, { 24, 2 }, 2)
for _, rect in ipairs(painted) do
    assert(rect.w <= 2 and rect.h <= 2, "Target selection strokes must stay thin two-pixel UI lines")
end

local torch_session = test.VoxelSession.new(31337)
torch_session.slots = { [1] = { material = "torch", count = 1 } }
torch_session:syncDerived()
local torch_hotbar = test.Hotbar:new{ width = 360, height = 48, session = torch_session }
resetPixels()
torch_hotbar:paintTo(buffer, 0, 0)
local torch_has_light, torch_is_solid_black = false, false
-- Slot one is x=2..39; its 29px icon starts at x=6, y=7. Only inspect calls
-- wholly inside this icon to avoid mistaking the hotbar frame for the torch.
for _, rect in ipairs(painted) do
    if rect.kind == "mono" and rect.x >= 6 and rect.y >= 7 and rect.x + rect.w <= 35 and rect.y + rect.h <= 36 then
        if rect.ink ~= "black" then torch_has_light = true end
        if rect.ink == "black" and rect.w * rect.h >= 29 * 29 * 0.75 then torch_is_solid_black = true end
    end
end
assert(torch_has_light and not torch_is_solid_black,
    "The torch icon must render an explicit flame and shaft, not a solid black block")

-- Bedrock-style live look: every pan sample applies only the finger delta,
-- rather than snapping to the old fixed-size swipe turn.
local old_refresh_fast, live_refreshes = canvas.refreshFast, 0
canvas.refreshFast = function() live_refreshes = live_refreshes + 1 end
local yaw_before, pitch_before = session.yaw, session.pitch
assert(canvas:onPanMinecraftLook("PanMinecraftLook", { pos = { x = 100, y = 100 } }), "A look pan must start tracking")
assert(session.live_look == true, "A live pan must switch to the fast preview renderer")
assert(canvas:onPanMinecraftLook("PanMinecraftLook", { pos = { x = 130, y = 80 } }), "A look pan must update continuously")
assert(session.yaw > yaw_before and session.pitch > pitch_before and live_refreshes == 1,
    "Finger movement must update yaw/pitch live and refresh the canvas")
assert(canvas:onPanReleaseMinecraftLook("PanReleaseMinecraftLook", { pos = { x = 130, y = 80 } }), "A look pan must release cleanly")
assert(canvas._look_pan_last == nil, "Pan release must clear the tracked finger position")
assert(session.live_look == false, "Pan release must restore the full-quality renderer")
canvas.refreshFast = old_refresh_fast

-- Movement animates four local fast refreshes and never a full-pane refresh.
dirty_calls, repaint_calls, scheduled = {}, 0, {}
assert(session:act("forward"), "Walking forward must start a motion")
assert(#scheduled == 1, "Motion must schedule its next frame")
for frame = 1, test.MOVE_FRAMES do
    local callback = scheduled[#scheduled].callback
    scheduled = {}
    callback()
end
assert(session.motion == nil, "The motion must finish after its frames")
assert(repaint_calls >= test.MOVE_FRAMES, "Motion must repaint the canvas locally")
for index, call in ipairs(dirty_calls) do
    if not (call.region and call.region.w == 210 and call.region.h == 126) then
        print("DEBUG dirty", index, call.waveform, tostring(call.region and call.region.w), tostring(call.region and call.region.h), tostring(call.region and call.region.x), tostring(call.region and call.region.y))
    end
    assert(call.region and call.region.w == 210 and call.region.h == 126, "Refresh regions must stay bound to the canvas")
end

--[[--
Bedrock-style interaction: the target face, tap versus hold
]]--
session.pitch = -0.75
local target = canvas:pickBlock(105, 63)
assert(target, "Looking down at the ground must resolve a target block")
assert(target.place_x == target.x and target.place_z == target.z and target.place_y == target.y + 1,
    "A floor hit must offer the block face above the surface")
assert(test.blockAt(world, target.place_x, target.place_z, target.place_y) == nil, "The place position must be free")

assert(session.tap_action == "place", "Bedrock's default tap action is placing blocks")
local placed_material = session:selectedMaterial()
local before_count = session:countMaterial(placed_material)
assert(session:tapAction(target), "Tapping a block face must place the selected block")
assert(test.blockAt(world, target.place_x, target.place_z, target.place_y) == placed_material, "The placed block must appear in the world")
assert(session:countMaterial(placed_material) == before_count - 1, "Placing must consume one block")
assert(session:tapAction(target) == false, "Placing onto an occupied spot must be refused")
assert(session.last_event:find("occupied"), "The refusal must be reported to the player")
local drop_material = test.DROPS[placed_material]
local drop_before = session:countMaterial(drop_material)
assert(session:holdAction{ x = target.place_x, z = target.place_z, y = target.place_y }, "Holding must mine the targeted block again")
assert(test.blockAt(world, target.place_x, target.place_z, target.place_y) == nil, "The held action must remove the block")
local expected_placed_count = before_count - 1 + (drop_material == placed_material and 1 or 0)
assert(session:countMaterial(placed_material) == expected_placed_count,
    "Placement must consume one item while mining restores it only when its drop matches the placed material")
assert(session:countMaterial(drop_material) == drop_before + 1, "Mining must add the block's dropped item (" .. drop_material .. ")")
session:toggleTapAction()
assert(session.tap_action == "mine", "The mode button must flip the tap action")
assert(session:tapActionLabel():find("Mine"), "The button label must describe the active mode")
session:toggleTapAction()
assert(session.tap_action == "place", "The mode button must be reversible")

--[[--
Inventory: finite Survival slots, cursor stack, Creative catalogue and drops
]]--
assert(session.mode == "Survival", "The default session must be Survival")
assert(session.slots[1].material == "planks" and session.slots[1].count > 0,
    "The 4.7.0 Survival starter kit must begin with planks")
assert(session.selected_slot == 1 and session:selectedMaterial() == "planks",
    "The first hotbar slot must select the planks starter stack")
assert(session.hotbar[1] == "planks" and session.inventory.planks == session:countMaterial("planks"),
    "Derived hotbar and counters must mirror the real slots")
local used_slots = 0
for slot = 1, test.INVENTORY_SLOTS do if session.slots[slot] then used_slots = used_slots + 1 end end
assert(session.used_slots == used_slots and used_slots >= #test.STARTING_KIT,
    "The used-slot counter must match the occupied Survival starter slots")
assert(session:addItem("gold", 100) == 0, "Stacks must split across slots when they exceed the stack limit")
assert(session:countMaterial("gold") == 100, "All added items must be counted")
assert(session:addItem("gold", 1) == 0 and session:countMaterial("gold") == 101,
    "Fitting items must top up existing stacks")
assert(session:addItem("gold", 27) == 0 and session:countMaterial("gold") == 128,
    "Partial stacks must fill to the stack limit")
local injected = {}
for slot = 1, test.INVENTORY_SLOTS do
    if not session.slots[slot] then
        session.slots[slot] = { material = "dirt", count = test.STACK_LIMIT }
        injected[#injected + 1] = slot
    end
end
assert(session:addItem("gold", 5) == 5, "A completely full Survival inventory must report leftovers")
for _, slot in ipairs(injected) do session.slots[slot] = nil end
session:syncDerived()
assert(session:takeMaterial("gold", 128), "Taking a complete material count must succeed")
assert(session:countMaterial("gold") == 0 and session:takeMaterial("gold", 1) == false,
    "Empty materials must not be taken")

assert(session:pickSlot(1) == "picked" and session.held.material == "planks" and session.slots[1] == nil,
    "Picking up must move the planks starter stack into the cursor")
assert(session.hotbar[1] == nil, "The derived hotbar must show an empty slot while its stack is held")
assert(session:pickSlot(2) == "swapped" and session.held.material == "dirt",
    "Picking a different occupied slot must swap its stack with the cursor")
assert(session.slots[2].material == "planks", "The swapped planks must land in the target slot")
assert(session:pickSlot(2) == "swapped" and session.held.material == "planks",
    "Swapping back must restore the original storage material")
assert(session:pickSlot(1) == "placed" and session.slots[1].material == "planks",
    "Storing the cursor stack into an empty slot must succeed")
assert(session.held == nil and session:pickSlot(36) == "empty",
    "An empty cursor tapping an empty slot must do nothing")

local initial_sand = session:countMaterial("sand")
session.slots[20], session.slots[21] = { material = "sand", count = 60 }, nil
session:syncDerived()
session.held = { material = "sand", count = 10 }
assert(session:pickSlot(21) == "placed" and session.slots[21].count == 10,
    "A held stack must be placeable in an empty slot")
session.held = { material = "sand", count = 10 }
assert(session:pickSlot(20) == "merged" and session.slots[20].count == 64 and session.held.count == 6,
    "Merging must stop at the stack limit and retain the remainder")
assert(session:returnHeld(), "Closing a screen must return the held stack")
assert(session:countMaterial("sand") == initial_sand + 80 and session.held == nil,
    "Returning the cursor stack must not lose items")
session:selectSlot(3)
assert(session.selected_slot == 3 and session:selectedMaterial() == "bread",
    "Selecting a hotbar slot must change the active starter item")

-- Mining a grass block exposes the block below and drops dirt.
local grass_x, grass_z
for z = 0, world.size - 1 do
    for x = 0, world.size - 1 do
        if test.materialAt(world, x, z) == "grass" then grass_x, grass_z = x, z; break end
    end
    if grass_x then break end
end
local grass_height = test.heightAt(world, grass_x, grass_z)
local dirt_before = session:countMaterial("dirt")
assert(session:mineBlock{ x = grass_x, z = grass_z, y = grass_height - 1 }, "Mining a grass block must succeed")
assert(test.blockAt(world, grass_x, grass_z, grass_height - 1) == nil, "The mined block must be gone")
assert(test.materialAt(world, grass_x, grass_z) == "dirt", "The block below must become the new surface")
assert(test.heightAt(world, grass_x, grass_z) == grass_height - 1, "Mining the top block must lower the column")
assert(session:countMaterial("dirt") == dirt_before + 1, "The grass block must drop dirt")
assert(session:mineBlock{ x = grass_x, z = grass_z, y = 200 } == false, "Out-of-range mining must be refused")
assert(session.last_event:find("no block"), "Invalid mining must be reported")

local log_target
for key, material in pairs(world.extra_blocks) do
    if material == "wood" then
        local x, z, level = key:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
        log_target = { x = tonumber(x), z = tonumber(z), y = tonumber(level) }
        break
    end
end
assert(log_target, "The world must contain tree trunks")
local wood_before = session:countMaterial("wood")
assert(session:mineBlock(log_target), "Trunk blocks must be mineable")
assert(test.blockAt(world, log_target.x, log_target.z, log_target.y) == nil, "Mined trunk blocks must vanish")
assert(session:countMaterial("wood") == wood_before + 1, "Trunks must drop wood")

-- Placing refuses to trap the player and refills an emptied selected slot.
session:closeOverlays()
session.selected_slot = 1
local feet = math.floor(session:groundHeightAtPlayer())
assert(session:placeBlock{ x = math.floor(session.player_x), z = math.floor(session.player_z), y = feet } == false
    and session.last_event:find("standing"), "Blocks may not be placed inside the player")
for slot = 1, test.INVENTORY_SLOTS do
    if session.slots[slot] and session.slots[slot].material == "planks" then session.slots[slot] = nil end
end
session.slots[1] = { material = "planks", count = 1 }
session.slots[30] = { material = "planks", count = 9 }
session:syncDerived()
local headroom = session:walkHeight(session.player_x, session.player_z)
local free_x, free_z, attempt = math.floor(session.player_x) + 2, math.floor(session.player_z) + 2, 0
while test.blockAt(world, free_x, free_z, headroom) and attempt < 20 do free_x = free_x + 1; attempt = attempt + 1 end
assert(session:placeBlock{ x = free_x, z = free_z, y = headroom }, "Placing on a free face must succeed")
assert(session.slots[1] and session.slots[1].count == 9 and session.slots[30] == nil,
    "Survival must refill an emptied hotbar slot from matching storage")
session.slots[1] = nil
session:syncDerived()
assert(session:placeBlock{ x = free_x, z = free_z, y = headroom + 1 } == false, "An empty hand must refuse placing")

-- Creative begins with no finite starter stacks; selecting a catalogue material
-- creates a usable unlimited stack and placement does not consume it.
local creative = test.VoxelSession.new(67890, "Creative", "Normal")
assert(creative.mode == "Creative" and creative:countMaterial("planks") == 0,
    "Creative must start without the finite Survival starter kit")
local creative_panel = test.InventoryPanel:new{ width = 600, height = 420, session = creative }
creative:toggleInventory()
local creative_layout = creative_panel:layout()
local creative_material = creative_panel:hitTest(creative_layout.grid_x + 2, creative_layout.grid_y + 2)
assert(creative_material.kind == "material", "The Creative catalogue grid must expose a material hit")
assert(creative_panel:onTapMinecraftInventory{ pos = { x = creative_layout.grid_x + 2, y = creative_layout.grid_y + 2 } },
    "Tapping a Creative catalogue material must be handled")
assert(creative:selectedMaterial() == creative_material.material and creative.slots[1].count == 1,
    "Creative catalogue selection must equip the selected material")
local creative_x, creative_z = 2, 2
local creative_y = creative:walkHeight(creative_x, creative_z)
local creative_count = creative:countMaterial(creative_material.material)
assert(creative:placeBlock{ x = creative_x, z = creative_z, y = creative_y }, "Creative must place a catalogue material")
assert(creative:countMaterial(creative_material.material) == creative_count,
    "Creative placement must not consume its equipped material")

--[[--
Crafting: recipes consume ingredients and respect availability
]]--
assert(session:addItem("wood", 8) == 0, "Wood must be available for the crafting checks")
local wood_before_craft = session:countMaterial("wood")
local planks_before = session:countMaterial("planks")
local planks_recipe = test.RECIPES[1]
assert(planks_recipe.result[1] == "planks" and planks_recipe.ingredients[1][1] == "wood", "The first recipe must turn logs into planks")
assert(session:canCraft(planks_recipe), "Available ingredients must satisfy the recipe")
assert(session:craft(1), "Crafting planks must succeed")
assert(session:countMaterial("wood") == wood_before_craft - 1, "Crafting must consume the ingredients")
assert(session:countMaterial("planks") == planks_before + 4, "Crafting must add the result to the inventory")
local obsidian_recipe
for index, recipe in ipairs(test.RECIPES) do
    if recipe.result[1] == "obsidian" then obsidian_recipe = index end
end
assert(obsidian_recipe, "The recipe list must contain the obsidian nod")
assert(session:canCraft(test.RECIPES[obsidian_recipe]) == false, "Missing ingredients must block a recipe")
assert(session:craft(obsidian_recipe) == false and session.last_event:find("missing"), "A blocked recipe must explain itself")
assert(session:craft(999) == false, "Unknown recipes must be refused")
for index = 1, #test.RECIPES do
    local recipe = test.RECIPES[index]
    assert(recipe.result and test.MATERIALS[recipe.result[1]], "Every recipe result must be a real block")
    assert(#recipe.ingredients >= 1, "Every recipe needs at least one ingredient")
    for _, ingredient in ipairs(recipe.ingredients) do
        assert(test.MATERIALS[ingredient[1]] and ingredient[2] > 0, "Every ingredient must be a real block with a positive amount")
    end
end
assert(session:pageCount() >= 2 and #session:recipesForPage(1) == test.CRAFT_ROWS_PER_PAGE, "Recipes must be paged four per screen")
assert(#session:recipesForPage(session:pageCount()) >= 1, "The last recipe page must not be empty")
local label = session:recipeLabel(test.RECIPES[1])
assert(label:find("Planks", 1, true) and label:find("/", 1, true), "Recipe rows must show the result and the ingredient counters")

--[[--
Catalogue inventory, crafting, modal routing, and local refresh
]]--
local inventory_panel = test.InventoryPanel:new{ width = 600, height = 748, session = session, canvas = canvas }
local crafting_panel = test.CraftingPanel:new{ width = 210, height = 126, session = session, canvas = canvas }
inventory_panel.crafting_panel, inventory_panel.hotbar = crafting_panel, nil
crafting_panel.inventory_panel = inventory_panel
inventory_panel._origin_x, inventory_panel._origin_y = 5, 7
crafting_panel._origin_x, crafting_panel._origin_y = 5, 7
session:closeOverlays()
local inventory_layout = inventory_panel:layout()
assert(inventory_layout.outer_x >= 0 and inventory_layout.outer_y >= 0
    and inventory_layout.outer_x + inventory_layout.outer_w <= inventory_panel.width
    and inventory_layout.hotbar_x >= 0 and inventory_layout.hotbar_x + inventory_layout.hotbar_w <= inventory_panel.width,
    "Inventory layout must keep its catalogue and centered slots inside the overlay")
assert(inventory_layout.grid_columns >= 4 and inventory_layout.cell_w > 0 and inventory_layout.cell_h > 0,
    "Inventory layout must provide a usable catalogue grid")
assert(inventory_panel:hitTest(inventory_panel.width - inventory_layout.margin - 1, inventory_layout.outer_y + 1).kind == "close",
    "The catalogue close control must be hit-testable")
local category_hit = inventory_panel:hitTest(inventory_layout.rail_x + 2, inventory_layout.rail_y + 8)
assert(category_hit.kind == "category" and category_hit.category == 1,
    "The category rail must route category selections")
local material_hit = inventory_panel:hitTest(inventory_layout.grid_x + 2, inventory_layout.grid_y + 2)
assert(material_hit.kind == "material" and test.MATERIALS[material_hit.material],
    "The catalogue grid must return an actual material")
local hotbar_hit = inventory_panel:hitTest(inventory_layout.hotbar_x + 2, inventory_layout.hotbar_y + 2)
assert(hotbar_hit.kind == "hotbar" and hotbar_hit.slot == 1,
    "The centered nine-slot hotbar must remain directly selectable")
assert(inventory_panel:hitTest(-1, -1).kind == "empty", "Outside the catalogue must not be actionable")

session:act("inventory")
assert(session.inventory_open, "The inventory command must open the modal catalogue")
dirty_calls, repaint_calls = {}, 0
assert(inventory_panel:onTapMinecraftInventory{ pos = { x = 5 + inventory_layout.hotbar_x + 2, y = 7 + inventory_layout.hotbar_y + 2 } },
    "Tapping a modal hotbar slot must be handled")
assert(session.selected_slot == 1, "Inventory hotbar routing must select the touched slot")
assert(repaint_calls >= 1 and dirty_calls[#dirty_calls].waveform == "ui",
    "Inventory interactions must refresh the modal region with the UI waveform")
assert(dirty_calls[#dirty_calls].region.w == 600 and dirty_calls[#dirty_calls].region.h == 748,
    "The inventory refresh must cover exactly its modal region")

-- A world-surface tap must reach the open inventory first, never raycast or act
-- on a covered voxel canvas.  This is the fallback used on KOReader builds with
-- differing overlap dispatch order.
canvas.inventory_panel = inventory_panel
local modal_raycasts = 0
local saved_pick = canvas.pickBlock
canvas.pickBlock = function() modal_raycasts = modal_raycasts + 1; return nil end
assert(canvas:onTapMinecraftExplore("TapMinecraftExplore", { pos = { x = 5 + inventory_layout.hotbar_x + 2, y = 7 + inventory_layout.hotbar_y + 2 } }),
    "A covered canvas tap must be consumed by the inventory modal")
assert(modal_raycasts == 0, "A covered canvas tap must not raycast the world")
canvas.pickBlock = saved_pick
assert(inventory_panel:onTapMinecraftInventory{ pos = { x = 5 + inventory_panel.width - inventory_layout.margin - 1, y = 7 + inventory_layout.outer_y + 1 } },
    "Tapping the inventory close control must be handled")
assert(session.inventory_open == false and session.held == nil, "Closing the inventory must return a held stack")
assert(inventory_panel:onTapMinecraftInventory{ pos = { x = 6, y = 6 } } == false,
    "A closed modal must ignore direct inventory taps")

session:act("crafting")
assert(session.crafting_open and session.craft_page == 1, "The crafting screen must open on the first page")
local recipe_hit = crafting_panel:hitTest(10, crafting_panel:headerHeight() + 3)
assert(recipe_hit.kind == "recipe" and recipe_hit.index == 1, "The first recipe row must map to the first recipe")
local footer_y = crafting_panel.height - crafting_panel:footerHeight() + 3
assert(crafting_panel:hitTest(10, footer_y).id == "prev" and crafting_panel:hitTest(crafting_panel.width - 10, footer_y).id == "next",
    "The crafting footer must page through recipes")
assert(crafting_panel:onTapMinecraftCrafting{ pos = { x = 5 + crafting_panel.width - 10, y = 7 + footer_y } }, "Paging forward must be handled")
assert(session.craft_page == 2, "Paging forward must advance the page")
assert(crafting_panel:onTapMinecraftCrafting{ pos = { x = 5 + 10, y = 7 + footer_y } }, "Paging back must be handled")
assert(session.craft_page == 1, "Paging back must return to the first page")
local planks_before_panel = session:countMaterial("planks")
assert(crafting_panel:onTapMinecraftCrafting{ pos = { x = 5 + 10, y = 7 + crafting_panel:headerHeight() + 3 } }, "Tapping a recipe must craft it")
assert(session:countMaterial("planks") >= planks_before_panel, "A crafted recipe must add its result")
assert(crafting_panel:onTapMinecraftCrafting{ pos = { x = 5 + crafting_panel.width - 6, y = 7 + 6 } }, "Closing the crafting screen must be handled")
assert(session.crafting_open == false, "The crafting screen must close")

--[[--
AppDock pane contract: 4.7.0 touch band, modal routing, and size boundaries
]]--
local function findButton(root, title)
    for _, widget in ipairs(root) do
        if widget.title == title then return widget end
    end
    return nil
end
local function findWidget(root, target)
    for _, widget in ipairs(root) do
        if widget == target then return true end
    end
    return false
end
local function insidePane(widget, width, height)
    local offset = widget and widget.overlap_offset
    if not offset then return false end
    return widget.width > 0 and widget.height > 0 and offset[1] >= 0 and offset[2] >= 0
        and offset[1] + widget.width <= width and offset[2] + widget.height <= height
end
local function touchBandBounds(dpad, jump, inventory_button, mode_button)
    local top = math.min(dpad.overlap_offset[2], jump.overlap_offset[2], inventory_button.overlap_offset[2], mode_button.overlap_offset[2])
    local bottom = math.max(dpad.overlap_offset[2] + dpad.height, jump.overlap_offset[2] + jump.height,
        inventory_button.overlap_offset[2] + inventory_button.height, mode_button.overlap_offset[2] + mode_button.height)
    return top, bottom
end
local function assertWorldLayout(width, height)
    local local_instance = {}
    local local_context = { dimen = { w = width, h = height }, px = function(value) return value end, requestRebuild = function() end }
    app.buildPane(local_instance, local_context)
    local local_state = local_instance.minecraft
    local_state.screen = "world"
    local local_pane = app.buildPane(local_instance, local_context)
    local group, local_canvas, local_hotbar = local_pane[1], local_state.canvas, local_state.hotbar
    local local_dpad = local_state.joystick
    local local_jump = findButton(group, "Jump")
    local local_inventory = findButton(group, "Inventory")
    local local_mode = findButton(group, "Tap: Place") or findButton(group, "Tap: Mine")
    assert(local_canvas and local_hotbar and local_dpad and local_jump and local_inventory and local_mode,
        string.format("Gameplay layout %dx%d must retain world, hotbar, D-pad, jump, Inventory and Tap controls", width, height))
    assert(insidePane(local_canvas, width, height) and insidePane(local_hotbar, width, height)
        and insidePane(local_dpad, width, height) and insidePane(local_jump, width, height)
        and insidePane(local_inventory, width, height) and insidePane(local_mode, width, height),
        string.format("Gameplay layout %dx%d must keep every interactive control inside the pane", width, height))
    assert(local_hotbar.height >= 36 and local_hotbar.height <= 48,
        string.format("Gameplay layout %dx%d must use the 36-48px enlarged hotbar", width, height))
    assert(math.abs((local_hotbar.overlap_offset[1] + local_hotbar.width / 2) - width / 2) <= 1,
        string.format("Gameplay layout %dx%d must center the hotbar", width, height))
    local touch_top, touch_bottom = touchBandBounds(local_dpad, local_jump, local_inventory, local_mode)
    -- The reserved band is at least 96px, but in narrow split panes its
    -- horizontally constrained D-pad may occupy less of that band.
    local min_touch_footprint = width >= 400 and 96 or 72
    assert(touch_bottom - touch_top >= min_touch_footprint and touch_bottom - touch_top <= 126,
        string.format("Gameplay layout %dx%d must keep an adaptive compact touch band", width, height))
    assert(local_canvas.overlap_offset[2] + local_canvas.height <= touch_top,
        string.format("Gameplay layout %dx%d must not let the world view paint into the touch band", width, height))
    for _, title in ipairs({ "Left", "Forward", "Back", "Right" }) do
        assert(not findButton(group, title), "4.7.0 must replace the separate " .. title .. " toolbar button with the D-pad")
    end
    return local_pane, local_state, local_context
end

local instance = {}
local context = { dimen = { w = 600, h = 748 }, px = function(value) return value end, requestRebuild = function() end }
local pane = app.buildPane(instance, context)
local state = instance.minecraft
assert(state and state.screen == "splash", "The app must start on the Minecraft splash screen")
assert(findButton(pane[1], "PLAY WORLD"), "The splash screen must expose a Play World button")
findButton(pane[1], "PLAY WORLD").callback()
pane = app.buildPane(instance, context)
assert(state.screen == "worlds", "Playing must open the saved-world list")
state.world_store.worlds = {}
assert(findButton(pane[1], "Create New World"), "The world list must expose world creation")
findButton(pane[1], "Create New World").callback()
pane = app.buildPane(instance, context)
assert(state.screen == "create", "New world must open the creation menu")
local seed_button = findButton(pane[1], "Seed: Random")
assert(seed_button, "The creation menu must expose the seed field")
seed_button.callback()
local seed_dialog = shown_widget
assert(seed_dialog and seed_dialog.title, "The seed field must open an input dialog")
seed_dialog.input = "777"
seed_dialog.buttons[1][2].callback()
pane = app.buildPane(instance, context)
assert(findButton(pane[1], "Game Mode: Survival"), "World creation must expose the Survival/Creative selector")
findButton(pane[1], "Create").callback()
pane = app.buildPane(instance, context)
assert(state and state.session and state.canvas, "The world pane must expose Minecraft state")
assert(findWidget(pane[1], state.canvas) and findWidget(pane[1], state.hotbar), "The pane must embed the world view and enlarged hotbar")
assert(findWidget(pane[1], state.inventory_panel) and findWidget(pane[1], state.crafting_panel), "The pane must embed both modal overlays")
assert(findWidget(pane[1], state.event_line), "The pane must embed the action line")
assert(state.joystick, "The pane must expose the D-pad")
local jump_button, inventory_button = findButton(pane[1], "Jump"), findButton(pane[1], "Inventory")
local mode_button = findButton(pane[1], "Tap: Place")
assert(jump_button and inventory_button and mode_button, "The touch band must expose Jump, Inventory and Tap: Place")
assertWorldLayout(600, 748)

local dpad_action
local old_dpad_act = state.canvas.act
state.canvas.act = function(_, action) dpad_action = action; return true end
state.joystick._origin_x, state.joystick._origin_y = 10, 20
assert(state.joystick:onTapMinecraftJoystick("TapMinecraftJoystick", { pos = { x = 10 + state.joystick.width / 2, y = 22 } }),
    "The D-pad must accept KOReader's two-argument tap callback")
assert(dpad_action == "forward", "The upper D-pad button must move forward")
local hold_started, hold_start_count = nil, 0
state.joystick.canvas.session.startHeldMove = function(session_for_hold, action)
    hold_started, hold_start_count = action, hold_start_count + 1
    session_for_hold.held_move_action = action
end
assert(state.joystick:onHoldMinecraftJoystick("HoldMinecraftJoystick", { pos = { x = 10 + state.joystick.width / 2, y = 22 } }),
    "Holding the upper D-pad button must start repeated movement")
assert(hold_started == "forward", "Holding the upper D-pad button must repeat forward movement")
for _ = 1, 8 do
    assert(state.joystick:onPanMinecraftJoystick("PanMinecraftJoystick", { pos = { x = 10 + state.joystick.width / 2, y = 22 } }),
        "Repeated pan samples while holding the same D-pad direction must be handled")
end
assert(hold_start_count == 1, "Repeated pan samples must not restart held movement")
local hold_stopped = false
state.joystick.canvas.session.stopHeldMove = function() hold_stopped = true end
assert(state.joystick:onHoldReleaseMinecraftJoystick(), "Releasing a held D-pad button must be handled")
assert(hold_stopped, "Releasing a held D-pad button must stop repeated movement")
state.canvas.act = old_dpad_act

local old_control_pick = state.canvas.pickBlock
state.canvas.pickBlock = function() error("A control tap must not raycast for block placement") end
local jump_region = state.canvas.control_jump_region
assert(state.canvas:onTapMinecraftExplore("TapMinecraftExplore", { pos = { x = jump_region.x + jump_region.w / 2, y = jump_region.y + jump_region.h / 2 } }),
    "A jump-button tap routed through the canvas must be handled")
assert(state.session.jump_frame ~= nil, "A jump-button tap must jump instead of placing a block")
state.session.jump_frame, state.session.jump_offset = nil, 0
state.canvas.pickBlock = old_control_pick

-- KOReader calls handlers as (event_arg, gesture). Verify the real dispatch
-- shape for the world surface and hotbar rather than only helper methods.
local old_pick, old_act = state.canvas.pickBlock, state.canvas.act
state.canvas.pickBlock = function(_, x, y)
    assert(x == 123 and y == 234, "The dispatched world gesture position must be forwarded")
    return { x = 2, z = 2, y = 1 }
end
state.canvas.act = function(_, action, target)
    assert(action == "tap" and target and target.x == 2, "A world tap must dispatch a tap action")
    return true
end
assert(state.canvas:onTapMinecraftExplore("TapMinecraftExplore", { pos = { x = 123, y = 234 } }),
    "The canvas must handle KOReader's two-argument tap callback")
state.canvas.act = function(_, action, target)
    assert(action == "hold" and target and target.x == 2, "A world hold must dispatch a hold action")
    return true
end
assert(state.canvas:onHoldMinecraftAction("HoldMinecraftAction", { pos = { x = 123, y = 234 } }),
    "The canvas must handle KOReader's two-argument hold callback")
state.canvas.pickBlock, state.canvas.act = old_pick, old_act
state.hotbar:paintTo(newBuffer(), state.hotbar.overlap_offset[1], state.hotbar.overlap_offset[2])
state.session:selectSlot(1)
assert(state.hotbar:onTapMinecraftHotbar("TapMinecraftHotbar", { pos = { x = state.hotbar._origin_x + state.hotbar.width / 2, y = state.hotbar._origin_y + 5 } }),
    "The enlarged hotbar must handle KOReader's two-argument selection callback")
assert(state.session.selected_slot == 5, "A dispatched hotbar tap must select the touched slot")
assert(state.session:biomeName() ~= "", "The header must name the current biome")

-- WorldPane's full-screen modal fallback must win over a covered canvas.
inventory_button.callback()
assert(state.session.inventory_open, "The touch-band Inventory button must open the catalogue modal")
local routed = 0
local original_inventory_tap = state.inventory_panel.onTapMinecraftInventory
state.inventory_panel.onTapMinecraftInventory = function(_, first, second)
    routed = routed + 1
    assert((second or first).pos, "The modal fallback must preserve the gesture")
    return true
end
assert(pane:onTapMinecraftModal("TapMinecraftModal", { pos = { x = 12, y = 12 } }),
    "The full-pane modal fallback must route covered taps")
assert(routed == 1, "The modal fallback must route exactly once")
state.inventory_panel.onTapMinecraftInventory = original_inventory_tap
state.session:closeOverlays()
mode_button.callback()
assert(state.session.tap_action == "mine", "The touch-band mode button must switch to mining")
pane = app.buildPane(instance, context)
assert(findButton(pane[1], "Tap: Mine"), "The rebuilt touch band must expose the current Tap action label")
jump_button = findButton(pane[1], "Jump")
jump_button.callback()
assert(state.session.jump_frame, "The Jump control must start the jump animation")
state.session.jump_frame, state.session.jump_offset = nil, 0

-- Menu returns to the saved-world list and the newly created world can be opened.
findButton(pane[1], "Menu").callback()
pane = app.buildPane(instance, context)
assert(state.screen == "worlds" and #state.world_store.worlds == 1, "The created world must be saved in the world list")
local saved_title = state.world_store.worlds[1].name .. "\nSurvival · Normal\nSeed: 777"
assert(findButton(pane[1], saved_title), "The world list must show the saved world card")
findButton(pane[1], saved_title).callback()
pane = app.buildPane(instance, context)
assert(state.screen == "world" and state.session.seed == 777, "A saved world card must reopen its seed")
assert(state.session.motion == nil, "Opening a saved world must not keep a running motion")
assert(test.parseWorldSeed("") == nil and test.parseWorldSeed("abc") == false and test.parseWorldSeed("42") == 42,
    "Seed parsing must accept integers, empty input and reject text")

-- Required compact and narrow layout bounds. A failure message names the exact
-- unsupported size instead of hiding overflow behind a generic pane assertion.
for _, dimen in ipairs({ { 600, 350 }, { 320, 480 }, { 200, 250 } }) do
    assertWorldLayout(dimen[1], dimen[2])
end

print("minecraft-4.7.0-ok")
