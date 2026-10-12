--[[--
Regression test for Minecraft 3D 4.1.4.

Covers the world generator (biomes, trees, villages, ore layers), the renderer
(mono and color paths, ray cache reuse, local refresh regions), the 36-slot
Bedrock-style inventory, crafting, block mining/placing with drops, the
tap/hold interaction model, and the AppDock pane layout.

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

local Widget, Input = class(), class()
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
assert(app.id == "minecraft" and app.version == "4.4.1", "Minecraft 3D must publish the splash, world list and creation menus")
local embedded_logo = test.ensureEmbeddedLogo()
local embedded_file = assert(io.open(embedded_logo, "rb"), "The installed DApp must materialize its embedded logo")
assert(embedded_file:read(8) == "\137PNG\13\10\26\10", "The embedded logo must be a valid PNG")
embedded_file:close()

--[[--
Palette and dithering helpers
]]--
assert(test.paletteColor("red") == "#dc2d2d", "Palette colors must be parsed from the shared RGB table")
local mix = test.paletteMixForRGB(106, 170, 64)
assert(mix and mix.first and mix.second and mix.second_pixels >= 0 and mix.second_pixels <= 16, "Dither mixes must expose two inks and a coverage")
local again = test.paletteMixForRGB(106, 170, 64)
assert(again.first == mix.first and again.second == mix.second, "Equal colors must reuse the cached mix")
local level_mix = test.paletteMixForMaterial("grass", 2)
assert(level_mix and level_mix.first, "Material shading must resolve to a palette mix")
local grid_cols, grid_rows = test.renderGridFor(210, 126)
assert(grid_cols == 42 and grid_rows == 25, "The default render grid must sample 5x5 output pixels")
local color_cols, color_rows = test.renderGridFor(210, 126, test.COLOR_RENDER_SAMPLE)
assert(color_cols == 70 and color_rows == 42, "The color render grid must use the finer 3x3 sampling")
local u, v = test.textureCoordinates("top", 4.25, 3.5, 7.75, 1)
assert(math.abs(u - 0.25) < 0.001 and math.abs(v - 0.75) < 0.001, "Top faces must map to block-local texture coordinates")
assert(test.colorForMaterial("grass") == "black", "Without KOReader color mode the renderer must stay monochrome")
color_enabled = true
assert(test.colorForMaterial("grass") == "#2daa46", "With color mode enabled the grass ink must be the green palette entry")
color_enabled = false
assert(#test.MATERIAL_ORDER >= 35, "The block catalogue must offer at least 35 blocks")
for _, material in ipairs(test.MATERIAL_ORDER) do
    assert(test.MATERIALS[material], "Every ordered block must exist in the catalogue: " .. material)
    assert(test.PATTERN_VALUES[material] and #test.PATTERN_VALUES[material] == 64, "Every block needs a 64-pixel texture: " .. material)
    for _, level in ipairs(test.PATTERN_VALUES[material]) do
        assert(level >= 0 and level <= 3, "Texture levels must stay inside the four supported shades")
    end
    assert(test.DROPS[material], "Every block must define what it drops")
end
assert(test.DROPS.grass == "dirt" and test.DROPS.stone == "cobblestone" and test.DROPS.coal == "coal", "Natural blocks must drop their Minecraft-like items")

--[[--
World generation: biomes, trees, structures, ore layers
]]--
local session = test.VoxelSession.new(12345)
local world = session.world
assert(world.seed == 12345 and world.size == test.WORLD_SIZE, "The default world must use seed 12345")
assert(test.HELD_MOVE_SECONDS > 0 and test.HELD_MOVE_SECONDS <= 0.1,
    "Held D-pad movement must poll several times per second")
local held_act_calls = 0
local old_session_act = session.act
session.held_move_action, session.motion = "forward", nil
session.act = function(_, action) held_act_calls = held_act_calls + 1; assert(action == "forward") end
session:tickHeldMove()
assert(held_act_calls == 1 and scheduled[#scheduled].delay == test.HELD_MOVE_SECONDS,
    "Held D-pad movement must schedule its next repeat in a fraction of a second")
session.act, session.held_move_action = old_session_act, nil
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
local buffer = newBuffer()
canvas:paintTo(buffer, 0, 0)
assert(rgb_calls > 0 and rect_calls > 0, "The color renderer must paint material spans and the crosshair")
assert(paintedSum("rgb") >= 210 * 126, "The color renderer must cover the whole canvas")
local colors = paintedColors()
assert(colors["#3e8bd3"], "The color scene must paint a sky gradient")
assert(colors["#77bee5"], "The color scene must paint the upper sky band")
assert(colors["#608650"] and colors["#345830"], "The color scene must paint the dithered distant ground around the horizon")
session.pitch = 0.45
canvas:paintTo(buffer, 0, 0)
assert(paintedColors()["#bcdde8"], "Looking up must reveal the pale horizon band")
session.pitch = 0
local mix_ink = test.paletteColor(level_mix.first)
assert(colors[mix_ink], "Block colors must be dithered from the palette inks")
canvas:paintTo(buffer, 0, 0)
local cache = canvas._ray_cache
assert(cache and cache.x and #cache.x == cache.cols * cache.rows, "The renderer must build a reusable ray cache")
canvas:paintTo(buffer, 0, 0)
assert(canvas._ray_cache == cache, "Repainting with the same view must reuse the ray cache")
session:turn(1)
canvas:paintTo(buffer, 0, 0)
assert(canvas._ray_cache ~= cache, "Turning must rebuild the view-ray cache")

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

color_enabled = false
session.color_enabled = false
resetPixels()
canvas:paintTo(buffer, 0, 0)
assert(rgb_calls == 0, "The monochrome renderer must never use RGB paints")
assert(paintedSum("mono") >= 210 * 126, "The monochrome renderer must cover the whole canvas")
for _, rect in ipairs(painted) do
    assert(rect.ink == "black" or rect.ink == "white", "The monochrome renderer must stay black and white")
end

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
assert(session:countMaterial(placed_material) == before_count - 1, "The placed block was spent when it was placed")
assert(session:countMaterial(drop_material) == drop_before + 1, "Mining must add the block's dropped item (" .. drop_material .. ")")
session:toggleTapAction()
assert(session.tap_action == "mine", "The mode button must flip the tap action")
assert(session:tapActionLabel():find("Mine"), "The button label must describe the active mode")
session:toggleTapAction()
assert(session.tap_action == "place", "The mode button must be reversible")

--[[--
Inventory: stack limits, cursor stack, hotbar, drops
]]--
assert(session.slots[1].material == "grass" and session.slots[1].count > 0, "The starting kit must fill the hotbar")
assert(session.selected_slot == 1 and session:selectedMaterial() == "grass", "The first hotbar slot must be active")
assert(session.hotbar[1] == "grass" and session.inventory.grass == session:countMaterial("grass"), "Derived hotbar and counters must mirror the slots")
local used_slots = 0
for slot = 1, test.INVENTORY_SLOTS do if session.slots[slot] then used_slots = used_slots + 1 end end
assert(session.used_slots == used_slots and used_slots >= #test.STARTING_KIT, "The used-slot counter must match the occupied slots")
assert(session:addItem("gold", 100) == 0, "Stacks must be split across slots when they exceed the stack limit")
assert(session:countMaterial("gold") == 100, "All added items must be counted")
assert(session:addItem("gold", 1) == 0 and session:countMaterial("gold") == 101, "Fitting items must top up the existing stacks")
assert(session:addItem("gold", 27) == 0 and session:countMaterial("gold") == 128, "Partial stacks must fill up to the stack limit")
local injected = {}
for slot = 1, test.INVENTORY_SLOTS do
    if not session.slots[slot] then
        session.slots[slot] = { material = "dirt", count = test.STACK_LIMIT }
        injected[#injected + 1] = slot
    end
end
assert(session:addItem("gold", 5) == 5, "A completely full inventory must report the leftover")
for _, slot in ipairs(injected) do session.slots[slot] = nil end
session:syncDerived()
assert(session:takeMaterial("gold", 128), "Taking 128 gold must succeed")
assert(session:countMaterial("gold") == 0 and session:takeMaterial("gold", 1) == false, "Empty materials must not be taken")

assert(session:pickSlot(1) == "picked" and session.held.material == "grass" and session.slots[1] == nil, "Picking up must move the stack into the cursor")
assert(session.hotbar[1] == nil, "The hotbar must show an empty slot while its stack is held")
assert(session:pickSlot(10) == "swapped" and session.held.material == "leaves", "Storing onto a different stack must swap them")
assert(session.slots[10].material == "grass", "The swapped stack must land in the storage slot")
assert(session:pickSlot(10) == "swapped" and session.held.material == "grass", "Swapping back must restore the original order")
assert(session:pickSlot(1) == "placed" and session.slots[1].material == "grass", "Storing into an empty slot must place the stack there")
assert(session.held == nil, "The cursor must be empty after storing")
assert(session:pickSlot(36) == "empty", "Tapping an empty slot with an empty cursor must do nothing")

local sand_total = session:countMaterial("sand")
session.slots[20] = { material = "sand", count = 60 }
session.held = { material = "sand", count = 10 }
assert(session:pickSlot(21) == "placed" and session.slots[21].count == 10, "A held stack must be placeable into an empty slot")
session.held = { material = "sand", count = 10 }
assert(session:pickSlot(20) == "merged" and session.slots[20].count == 64 and session.held.count == 6,
    "Merging must fill the stack up to the limit and keep the rest in hand")
assert(session:returnHeld(), "Closing a screen must return the held stack")
assert(session:countMaterial("sand") == sand_total + 80 and session.held == nil, "Returned stacks must not lose items")
session:selectSlot(3)
assert(session.selected_slot == 3 and session:selectedMaterial() == "stone", "Selecting a hotbar slot must change the active block")

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

-- Placing refuses to trap the player and refills the emptied hand slot.
session:closeOverlays()
session.selected_slot = 4
assert(session:selectedMaterial() == "wood", "Slot four must hold wood")
local feet = math.floor(session:groundHeightAtPlayer())
assert(session:placeBlock{ x = math.floor(session.player_x), z = math.floor(session.player_z), y = feet } == false
    and session.last_event:find("standing"), "Blocks may not be placed inside the player")
for slot = 1, test.INVENTORY_SLOTS do
    if session.slots[slot] and session.slots[slot].material == "wood" then session.slots[slot] = nil end
end
session.slots[4] = { material = "wood", count = 1 }
session.slots[30] = { material = "wood", count = 9 }
session:syncDerived()
local headroom = session:walkHeight(session.player_x, session.player_z)
local free_x, free_z, attempt = math.floor(session.player_x) + 2, math.floor(session.player_z) + 2, 0
while test.blockAt(world, free_x, free_z, headroom) and attempt < 20 do free_x = free_x + 1; attempt = attempt + 1 end
assert(session:placeBlock{ x = free_x, z = free_z, y = headroom }, "Placing on a free face must succeed")
assert(session.slots[4] and session.slots[4].count == 9 and session.slots[30] == nil,
    "Bedrock refills the emptied hand slot from the next matching stack")
session.slots[4] = nil
session:syncDerived()
assert(session:placeBlock{ x = free_x, z = free_z, y = headroom + 1 } == false, "An empty hand must refuse placing")

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
Overlay screens: hit testing, paging, and local refresh
]]--
local inventory_panel = test.InventoryPanel:new{ width = 210, height = 126, session = session }
local crafting_panel = test.CraftingPanel:new{ width = 210, height = 126, session = session }
inventory_panel.crafting_panel = crafting_panel
crafting_panel.inventory_panel = inventory_panel
inventory_panel._origin_x, inventory_panel._origin_y = 5, 7
crafting_panel._origin_x, crafting_panel._origin_y = 5, 7
session:closeOverlays()
session:selectSlot(1)
assert(inventory_panel:hitTest(3, 3).kind == "header", "The inventory header must not be a slot")
assert(inventory_panel:hitTest(inventory_panel.width - 6, 6).kind == "button", "The close button must sit in the header corner")
local panel_button_w = math.max(30, math.floor((inventory_panel.width - 12) / 3))
local craft_button_x = inventory_panel.width - 8 - panel_button_w * 2
assert(inventory_panel:hitTest(craft_button_x + 2, 6).id == "craft", "The crafting button must sit next to the close button")
local slot_hit = inventory_panel:hitTest(4 + inventory_panel:slotWidth() * 8 + 2, inventory_panel:mainGridY() + 3)
assert(slot_hit.kind == "slot" and slot_hit.slot == 18 and slot_hit.row == 1, "The first storage row must map to slots 10-18")
local last_hit = inventory_panel:hitTest(4 + 2, inventory_panel:mainGridY() + inventory_panel:slotHeight() * 2 + 3)
assert(last_hit.slot == 28, "The first column of the last storage row must map to slot 28")
local hotbar_hit = inventory_panel:hitTest(4 + 2, inventory_panel:hotbarY() + 3)
assert(hotbar_hit.slot == 1 and hotbar_hit.row == 4, "The separated bottom row must map to hotbar slot 1")
assert(inventory_panel:hitTest(4, inventory_panel.height - 4).kind == "footer", "The held-stack hint must own the footer")

session:act("inventory")
assert(session.inventory_open, "The inventory command must open the overlay")
dirty_calls, repaint_calls = {}, 0
assert(inventory_panel:onTapMinecraftInventory{ pos = { x = 5 + 4 + 2, y = 7 + inventory_panel:hotbarY() + 3 } },
    "Tapping a slot must be handled")
assert(session.held and session.held.material == "grass", "Tapping the first slot must pick the stack up")
assert(repaint_calls >= 1 and dirty_calls[#dirty_calls].waveform == "ui", "Overlays must refresh their own region with a ui waveform")
assert(dirty_calls[#dirty_calls].region.w == 210 and dirty_calls[#dirty_calls].region.h == 126, "The overlay region must match the covered canvas")
assert(inventory_panel:onTapMinecraftInventory{ pos = { x = 5 + inventory_panel.width - 6, y = 7 + 6 } }, "Tapping close must be handled")
assert(session.inventory_open == false and session.held == nil, "Closing the inventory must return the held stack")
assert(inventory_panel:onTapMinecraftInventory{ pos = { x = 6, y = 6 } } == false, "A closed overlay must ignore taps")

session:act("crafting")
assert(session.crafting_open and session.craft_page == 1, "The crafting screen must open on the first page")
local recipe_hit = crafting_panel:hitTest(10, crafting_panel:headerHeight() + 3)
assert(recipe_hit.kind == "recipe" and recipe_hit.index == 1, "The first recipe row must map to the first recipe")
local footer_y = crafting_panel.height - crafting_panel:footerHeight() + 3
assert(crafting_panel:hitTest(10, footer_y).id == "prev" and crafting_panel:hitTest(crafting_panel.width - 10, footer_y).id == "next",
    "The footer must page through the recipes")
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
AppDock pane contract
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
local instance = {}
local context = { dimen = { w = 600, h = 748 }, px = function(value) return value end, requestRebuild = function() end }
local pane = app.buildPane(instance, context)
local state = instance.minecraft
assert(state and state.screen == "splash", "The app must start on the Minecraft splash screen")
assert(findButton(pane[1], "Play"), "The splash screen must expose a play button")
findButton(pane[1], "Play").callback()
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
findButton(pane[1], "Create").callback()
pane = app.buildPane(instance, context)
assert(state and state.session and state.canvas, "The pane must expose its Minecraft state")
assert(findWidget(pane[1], state.canvas) and findWidget(pane[1], state.hotbar), "The pane must embed the canvas and the hotbar")
assert(findWidget(pane[1], state.inventory_panel) and findWidget(pane[1], state.crafting_panel), "The pane must embed both overlays")
assert(findWidget(pane[1], state.event_line), "The pane must embed the action line")
assert(state.joystick, "The pane must expose the Bedrock-style D-pad")
local dpad_action
local old_dpad_act = state.canvas.act
state.canvas.act = function(_, action) dpad_action = action; return true end
state.joystick._origin_x, state.joystick._origin_y = 10, 20
assert(state.joystick:onTapMinecraftJoystick("TapMinecraftJoystick", {
    pos = { x = 10 + state.joystick.width / 2, y = 20 + 2 },
}), "The D-pad must accept the real two-argument tap callback")
assert(dpad_action == "forward", "The upper D-pad button must move forward")
local hold_started
state.joystick.canvas.session.startHeldMove = function(_, action) hold_started = action end
assert(state.joystick:onHoldMinecraftJoystick("HoldMinecraftJoystick", {
    pos = { x = 10 + state.joystick.width / 2, y = 20 + 2 },
}), "Holding the upper D-pad button must start repeated movement")
assert(hold_started == "forward", "Holding the upper D-pad button must repeat forward movement")
local hold_stopped = false
state.joystick.canvas.session.stopHeldMove = function() hold_stopped = true end
assert(state.joystick:onHoldReleaseMinecraftJoystick(), "Releasing a held D-pad button must be handled")
assert(hold_stopped, "Releasing a held D-pad button must stop repeated movement")
state.canvas.act = old_dpad_act
local old_control_pick = state.canvas.pickBlock
state.canvas.pickBlock = function() error("A control tap must not raycast for block placement") end
local jump_region = state.canvas.control_jump_region
assert(state.canvas:onTapMinecraftExplore("TapMinecraftExplore", {
    pos = { x = jump_region.x + jump_region.w / 2, y = jump_region.y + jump_region.h / 2 },
}), "A jump-button tap routed through the canvas must be handled")
assert(state.session.jump_frame ~= nil, "A jump-button tap must jump instead of placing a block")
state.session.jump_frame, state.session.jump_offset = nil, 0
state.canvas.pickBlock = old_control_pick
-- KOReader calls handlers as (event_arg, gesture). Verify the real dispatch
-- shape for canvas interaction and hotbar selection, not only direct helpers.
local old_pick, old_act = state.canvas.pickBlock, state.canvas.act
state.canvas.pickBlock = function(_, x, y)
    assert(x == 123 and y == 234, "The dispatched canvas gesture position must be forwarded")
    return { x = 2, z = 2, y = 1 }
end
state.canvas.act = function(_, action, target)
    assert(action == "tap" and target and target.x == 2, "A canvas tap must dispatch a tap action")
    return true
end
assert(state.canvas:onTapMinecraftExplore("TapMinecraftExplore", { pos = { x = 123, y = 234 } }),
    "The canvas must handle KOReader's two-argument tap callback")
state.canvas.act = function(_, action, target)
    assert(action == "hold" and target and target.x == 2, "A canvas hold must dispatch a hold action")
    return true
end
assert(state.canvas:onHoldMinecraftAction("HoldMinecraftAction", { pos = { x = 123, y = 234 } }),
    "The canvas must handle KOReader's two-argument hold callback")
state.canvas.pickBlock, state.canvas.act = old_pick, old_act
state.session:selectSlot(1)
assert(state.hotbar:onTapMinecraftHotbar("TapMinecraftHotbar", { pos = { x = state.hotbar._origin_x + state.hotbar.width / 2, y = state.hotbar._origin_y + 5 } }),
    "The hotbar must handle KOReader's two-argument selection callback")
assert(state.session.selected_slot == 5, "A dispatched hotbar tap must select the touched slot")
for _, title in ipairs({ "Color", "Menu", "Jump", "Left", "Forward", "Back", "Right", "Inventory", "Tap: Place" }) do
    assert(findButton(pane[1], title), "The pane must expose the " .. title .. " control")
end
assert(state.session:biomeName() ~= "", "The header must name the current biome")
findButton(pane[1], "Inventory").callback()
assert(state.session.inventory_open, "The inventory button must open the inventory")
assert(state.inventory_panel:onTapMinecraftInventory{ pos = { x = state.inventory_panel._origin_x + state.inventory_panel.width - 6, y = state.inventory_panel._origin_y + 6 } },
    "The pane inventory must close on request")
local mode_button = findButton(pane[1], "Tap: Place")
mode_button.callback()
assert(state.session.tap_action == "mine", "The mode button must switch to mining")
findButton(pane[1], "Forward").callback()
assert(state.session.motion, "The forward button must start a motion")
state.session.motion = nil
findButton(pane[1], "Jump").callback()
assert(state.session.jump_frame, "The jump button must start the jump animation")
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

-- The pane must also fit a compact split layout.
local compact = app.buildPane(instance, { dimen = { w = 600, h = 350 }, px = function(value) return value end, requestRebuild = function() end })
assert(compact and compact.dimen.h == 350 and compact[1], "Minecraft 3D must fit a compact pane")
assert(findButton(compact[1], "Inventory") and findButton(compact[1], "Color"), "The compact pane must keep its controls")

print("minecraft-4.4.1-ok")
