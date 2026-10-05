--[[--
Minecraft 3D DApp test.

Run with: lua5.1 test_minecraft.lua

The color mock follows the working square.koplugin API: parse CSS hex with
Blitbuffer.colorFromString and paint RGB spans through paintRectRGB32.
]]--
local function class(base)
    base = base or {}
    base.__index = base
    function base:extend(child)
        child = child or {}
        child.__index = child
        setmetatable(child, { __index = self })
        return child
    end
    function base:new(args)
        local value = setmetatable(args or {}, self)
        if value.init then value:init() end
        return value
    end
    return base
end
local Widget = class({})
local InputContainer = Widget:extend({})
local dirty_calls, repaint_calls = {}, 0
local shown_widget
local InputDialog = Widget:extend({})
function InputDialog:getInputText() return self.input or "" end
function InputDialog:onShowKeyboard() self.keyboard_shown = true end
local InfoMessage = Widget:extend({})

-- Mutable device state, so one run can cover a color panel, a color panel with
-- KOReader's "Color rendering" switched off, and a grayscale panel.
local MOCK = {
    color_rendering = true,
    color_screen = true,
    buffer_is_rgb = true,
}

-- ctype-like constructor: callable, but type() is "table" (a real LuaJIT ctype
-- reports "cdata"). Either way it is *not* a Lua function.
local function ctypeLikeRGB32()
    return setmetatable({}, {
        __call = function(_, r, g, b, a) return { r = r, g = g, b = b, a = a, rgb32 = true } end,
    })
end
MOCK.rgb32_ctor = ctypeLikeRGB32()
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
    ffi.cdef[[typedef struct { uint8_t r; uint8_t g; uint8_t b; uint8_t alpha; uint8_t rgb32; } MinecraftTestRGB32;]]
    ffi.metatype("MinecraftTestRGB32", {
        __index = {
            getColorRGB32 = function(self) return self end,
            getR = function(self) return self.r end,
            getG = function(self) return self.g end,
            getB = function(self) return self.b end,
            getAlpha = function(self) return self.alpha end,
        },
        __eq = function(self, color)
            local c = color:getColorRGB32()
            return self.r == c:getR() and self.g == c:getG() and self.b == c:getB() and self.alpha == c:getAlpha()
        end,
        __tostring = function(self)
            if self.rgb32 == 1 then return string.format("rgb(%d,%d,%d)", self.r, self.g, self.b) end
            if self.r == 0 and self.g == 0 and self.b == 0 then return "black" end
            if self.r == 255 and self.g == 255 and self.b == 255 then return "white" end
            return string.format("gray(%d)", self.r)
        end,
    })
    MOCK.rgb32_ctor = ffi.typeof("MinecraftTestRGB32")
end

local function isRGBInk(ink)
    return (type(ink) == "cdata" and ink.rgb32 == 1) or (type(ink) == "table" and ink.rgb32 == true)
end

local function colorConstant(name, r, g, b)
    if ffi_ok then return MOCK.rgb32_ctor(r, g, b, 0xFF, 0) end
    return name
end
local COLOR_WHITE = colorConstant("white", 255, 255, 255)
local COLOR_BLACK = colorConstant("black", 0, 0, 0)
local COLOR_LIGHT_GRAY = colorConstant("light", 192, 192, 192)
local COLOR_DARK_GRAY = colorConstant("dark", 64, 64, 64)

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_WHITE = COLOR_WHITE,
        COLOR_BLACK = COLOR_BLACK,
        COLOR_LIGHT_GRAY = COLOR_LIGHT_GRAY,
        COLOR_DARK_GRAY = COLOR_DARK_GRAY,
        ColorRGB32 = MOCK.rgb32_ctor,
        colorFromString = function(hex)
            local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
            assert(r and g and b, "colorFromString expects a six-digit RGB hex string")
            return MOCK.rgb32_ctor(tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), 0xFF, 1)
        end,
    }
end
package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_, value) return value end,
            isColorEnabled = function() return MOCK.color_rendering end,
            isColorScreen = function() return MOCK.color_screen end,
            bb = { isRGB = function() return MOCK.buffer_is_rgb end },
        },
        input = { group = {} },
    }
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, value) return value end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, value) return value end } end
for _, module in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/horizontalspan",
    "ui/widget/overlapgroup",
    "ui/widget/textwidget",
}) do
    package.preload[module] = function() return InputContainer end
end
package.preload["ui/widget/inputdialog"] = function() return InputDialog end
package.preload["ui/widget/infomessage"] = function() return InfoMessage end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function() end,
        unschedule = function() end,
        widgetRepaint = function() repaint_calls = repaint_calls + 1 end,
        setDirty = function(_, _, waveform, region)
            dirty_calls[#dirty_calls + 1] = { waveform = waveform, region = region }
        end,
        forceRePaint = function() end,
        yieldToEPDC = function() end,
        show = function(_, widget) shown_widget = widget end,
        close = function(_, widget) if shown_widget == widget then shown_widget = nil end end,
    }
end

local app = dofile("minecraft.lua")
local test = app._test
assert(app.id == "minecraft" and app.version == "3.2.1" and app.logo == "minecraft", "Minecraft metadata must be stable")
assert(test.WORLD_SIZE == 80 and test.MAX_VIEW_DISTANCE == 24 and test.RENDER_SCALE == 1, "Render constants must provide the full-resolution long view")
assert(test.RENDER_COLS == 600 and test.RENDER_ROWS == 600 and test.RENDER_SAMPLE == 5, "Renderer must sample 5x5 output pixels per ray inside a 600x600 budget")
assert(test.COLOR_RENDER_SAMPLE == 3, "Color mode must use a faster ray grid while keeping texture dithering readable")
assert(test.MOVE_FRAMES == 4 and test.MOVE_FRAME_SECONDS < 0.05, "Movement must be animated at a fast-refresh cadence")

-- Color mode follows only KOReader's public screen setting; there is no separate
-- constructor or hardware capability probe inside the DApp.
assert(type(MOCK.rgb32_ctor) ~= "function", "Test double must model KOReader's non-function ColorRGB32")
local palette_count = 0
for _ in pairs(test.COLOR_PALETTE) do palette_count = palette_count + 1 end
assert(palette_count == 7, "Color mode must expose exactly seven palette colors")
local grass_rgb, water_rgb = test.colorForMaterial("grass"), test.colorForMaterial("water")
assert(isRGBInk(grass_rgb) and grass_rgb.r == 45 and grass_rgb.g == 170 and grass_rgb.b == 70, "Grass must use the RGB green palette color")
assert(isRGBInk(water_rgb) and water_rgb.r == 55 and water_rgb.g == 105 and water_rgb.b == 220, "Water must use the RGB blue palette color")
assert(test.paletteColor("green") == grass_rgb, "Palette colors must be cached so color spans can be merged")
local brown_mix = test.paletteMixForRGB(137, 90, 59)
assert(brown_mix.first ~= brown_mix.second and brown_mix.second_pixels > 0 and brown_mix.second_pixels < 16, "A brown target color must be approximated by dithering two of the seven fast inks")
assert(test.COLOR_PALETTE[brown_mix.first] and test.COLOR_PALETTE[brown_mix.second], "Dithered output must stay within the seven supported fast-refresh inks")
local dirt_texture_mix = test.paletteMixForMaterial("dirt", 1)
local brighter_dirt_texture_mix = test.paletteMixForMaterial("dirt", 2)
assert(brighter_dirt_texture_mix.second_pixels > dirt_texture_mix.second_pixels, "Different existing texture levels must produce different perceived color shades")

local standard_cols, standard_rows = test.renderGridFor(210, 126)
assert(standard_cols == 42 and standard_rows == 25, "A 210x126 pane must map to a 42x25 ray grid of 5x5 pixel cells")
local color_cols, color_rows = test.renderGridFor(210, 126, test.COLOR_RENDER_SAMPLE)
assert(color_cols == 70 and color_rows == 42, "Color mode must use 3x3 output pixels per ray")
local compact_cols, compact_rows = test.renderGridFor(39, 61)
assert(compact_cols == 7 and compact_rows == 12, "Compact panes must not oversample their assigned canvas")

local world = test.buildWorld()
assert(world.size == 80 and #world.heights == 80 and #world.heights[1] == 80, "World must be a complete deterministic block grid")
assert(world.materials and world.materials[1][1], "World must contain block materials")
assert(world.block_planes and test.blockAt(world, 0, 0, world.heights[1][1] - 1) == world.materials[1][1], "Cached voxel planes must preserve the visible surface block")
local function assertFlatBlockCacheMatches(world_to_check)
    assert(world_to_check.block_flat, "Worlds must build a contiguous renderer voxel cache")
    local size = world_to_check.size
    local stride, padding = world_to_check.block_flat_stride, world_to_check.block_flat_padding
    local plane_size = stride * stride
    assert(stride == size + padding * 2 and padding > 0, "Renderer cache must have a padded air border")
    for level = 0, test.MAX_COLUMN_HEIGHT - 1 do
        local plane = world_to_check.block_planes[level + 1]
        for z = 0, size - 1 do
            for x = 0, size - 1 do
                local index = z * size + x + 1
                local flat_index = level * plane_size + (z + padding) * stride + x + padding + 1
                local material = plane[index]
                assert(world_to_check.block_flat[flat_index] == (material or false), "Flat renderer cache must match the string material plane")
            end
        end
    end
    assert(world_to_check.block_flat[1] == false, "Padded world border must be empty")
end
assertFlatBlockCacheMatches(world)
assert(test.heightAt(world, -1, 0) == 0 and test.heightAt(world, 0, -1) == 0, "Outside terrain must be empty")
assert(test.heightAt(world, 11, 5) >= 1 and world.biomes[6][12], "Seeded biome world must remain walkable")
assert(test.parseWorldSeed(" 6789 ") == 6789 and test.parseWorldSeed("") == nil and test.parseWorldSeed("seed") == false, "Seed input must accept integers, leave blank for random, and reject invalid text")
local spawn_x, spawn_z, spawn_yaw, spawn_tree = test.findSpawn(world)
local spawn_material = world.materials[math.floor(spawn_z) + 1][math.floor(spawn_x) + 1]
assert(spawn_material ~= "wood" and spawn_material ~= "leaves", "The default spawn must not start inside a tree canopy")
assert(spawn_tree, "The default seed should select a tree to face")
local tree_dx, tree_dz = spawn_tree.x - spawn_x, spawn_tree.z - spawn_z
local tree_distance = math.sqrt(tree_dx * tree_dx + tree_dz * tree_dz)
assert(tree_distance >= 6 and tree_distance <= 20, "The default spawn should have a nearby visible trunk")
assert(test.hasClearTreeView(world, spawn_x, spawn_z, world.heights[math.floor(spawn_z) + 1][math.floor(spawn_x) + 1], spawn_tree, tree_distance), "The selected spawn-to-tree view must not be blocked by terrain")
local facing_dot = (tree_dx * math.sin(spawn_yaw) + tree_dz * math.cos(spawn_yaw)) / tree_distance
assert(facing_dot > 0.99, "The default spawn should face its visible tree")
local alternate_world = test.buildWorld(6789)
local alt_x, alt_z, alt_yaw, alt_tree = test.findSpawn(alternate_world)
assert(alt_tree, "The alternate seed should also select a visible tree")
local alt_dx, alt_dz = alt_tree.x - alt_x, alt_tree.z - alt_z
local alt_distance = math.sqrt(alt_dx * alt_dx + alt_dz * alt_dz)
assert(test.hasClearTreeView(alternate_world, alt_x, alt_z, alternate_world.heights[math.floor(alt_z) + 1][math.floor(alt_x) + 1], alt_tree, alt_distance)
    and (alt_dx * math.sin(alt_yaw) + alt_dz * math.cos(alt_yaw)) / alt_distance > 0.99, "Alternate seeds must also spawn facing an unobstructed tree")
local max_height = 0
local plains_tree_cells = 0
for z = 1, world.size do
    for x = 1, world.size do
        max_height = math.max(max_height, world.heights[z][x])
    end
end
for key, material in pairs(world.extra_blocks) do
    if material == "wood" or material == "leaves" then plains_tree_cells = plains_tree_cells + 1 end
end
assert(max_height <= test.MAX_COLUMN_HEIGHT, "Tree generation must not cascade into unbounded columns")
assert(plains_tree_cells > 0, "Seeded plains must retain their low-probability trees")
assert(plains_tree_cells > 10, "Trees must be made from freestanding blocks above the terrain")
local top_u, top_v = test.textureCoordinates("top", 3.25, 5.5, 9.75, 1)
local x_side_u, x_side_v = test.textureCoordinates("side", 3.25, 5.5, 9.75, 0)
local z_side_u, z_side_v = test.textureCoordinates("side", 3.25, 5.5, 9.75, 2)
assert(top_u == 0.25 and top_v == 0.75, "Top texture coordinates must use world X/Z")
assert(x_side_u == 0.75 and x_side_v == 0.5 and z_side_u == 0.25 and z_side_v == 0.5, "Side textures must use the horizontal axis tangent to the hit face")

local session = test.VoxelSession.new()
local original_x, original_z, original_yaw = session.player_x, session.player_z, session.yaw
assert(session:move(1), "Player must walk forward on the starting terrace")
assert(math.abs(session.player_x - (original_x + math.sin(original_yaw) * test.WALK_DISTANCE)) < 0.001 and math.abs(session.player_z - (original_z + math.cos(original_yaw) * test.WALK_DISTANCE)) < 0.001, "Forward movement must follow the camera heading")
assert(session:turn(1) and session.yaw > original_yaw, "Turning right must change the camera heading")
local place_session = test.VoxelSession.new()
place_session.player_x, place_session.player_z, place_session.yaw = 40.5, 40.5, 0
place_session.world.heights[43][41] = test.MAX_COLUMN_HEIGHT
place_session.world.materials[43][41] = "stone"
assert(not place_session:place() and place_session.world.heights[43][41] == test.MAX_COLUMN_HEIGHT, "Placing on a maximum-height column must not lower it")
local edit_session = test.VoxelSession.new(12345)
edit_session.player_x, edit_session.player_z, edit_session.yaw = 40.5, 40.5, 0
edit_session.world.heights[43][41], edit_session.world.materials[43][41] = 3, "grass"
test.rebuildWorldBlocks(edit_session.world)
assertFlatBlockCacheMatches(edit_session.world)
assert(edit_session:mine() and test.blockAt(edit_session.world, 40, 42, 1) == "grass" and test.blockAt(edit_session.world, 40, 42, 2) == nil, "Mining must update the cached top and remove the old voxel")
assertFlatBlockCacheMatches(edit_session.world)
edit_session:selectSlot(4)
assert(edit_session:place() and test.blockAt(edit_session.world, 40, 42, 2) == "wood", "Placing must update the cached voxel plane")
assertFlatBlockCacheMatches(edit_session.world)

local function flatSession()
    local flat = test.VoxelSession.new()
    flat.world.extra_blocks = {}
    for z = 1, flat.world.size do
        for x = 1, flat.world.size do
            flat.world.heights[z][x] = 1
            flat.world.materials[z][x] = "grass"
        end
    end
    test.rebuildWorldBlocks(flat.world)
    flat.player_x, flat.player_z, flat.yaw, flat.pitch = 40.5, 40.5, 0, 0
    return flat
end

--[[--
Phase 1: a color panel with KOReader's "Color rendering" switched on. This is
the configuration that stayed silently monochrome before the fix.
]]--
MOCK.color_rendering, MOCK.color_screen, MOCK.buffer_is_rgb = true, true, true
assert(test.colorRenderingEnabled(), "A color panel with KOReader color rendering on must offer color")
local color_session = flatSession()
color_session.color_enabled = true
local color_canvas = test.VoxelCanvas:new{ width = 210, height = 126, session = color_session }
local color_spans, rgb_spans, generic_rgb_spans, green_spans = 0, 0, 0, 0
local palette_inks_seen = {}
local function recordColorSpan(_, left, top, width, height, ink)
    color_spans = color_spans + 1
    if isRGBInk(ink) then
        generic_rgb_spans = generic_rgb_spans + 1
    end
    assert(width >= 1 and height >= 1, "Color spans must have a positive physical size")
    assert(left >= 17 and top >= 29 and left + width <= 227 and top + height <= 155, "Renderer must remain within the assigned canvas")
end
local function recordRGB32Span(_, left, top, width, height, ink)
    color_spans = color_spans + 1
    if isRGBInk(ink) then
        rgb_spans = rgb_spans + 1
        palette_inks_seen[ink.r .. "," .. ink.g .. "," .. ink.b] = true
        if ink.r == 45 and ink.g == 170 and ink.b == 70 then green_spans = green_spans + 1 end
    end
    assert(width >= 1 and height >= 1, "Color spans must have a positive physical size")
    assert(left >= 17 and top >= 29 and left + width <= 227 and top + height <= 155, "Renderer must remain within the assigned canvas")
end
-- Square uses this exact path: colorFromString(hex) + paintRectRGB32.
color_canvas:paintTo({ paintRect = recordColorSpan, paintRectRGB32 = recordRGB32Span }, 17, 29)
assert(color_spans > 10, "Color rendering must still paint the projected block scene")
assert(rgb_spans > 0, "Color rendering must paint RGB material colors on a color buffer")
assert(generic_rgb_spans == 0, "RGB material colors must not go through generic paintRect")
assert(green_spans > 0, "Grass texture must retain the RGB green palette ink among its dithered shades")
assert(palette_inks_seen["220,45,45"] and palette_inks_seen["45,170,70"], "Grass target RGB must be visibly approximated by dithering red and green fast inks")

-- The existing grass texture should now contain both palette-green and dither
-- pixels, rather than replacing every texture with one uniform material color.
local color_pixels = {}
for row = 0, 125 do
    color_pixels[row + 1] = {}
    for col = 0, 209 do color_pixels[row + 1][col + 1] = "white" end
end
local function recordColorPixels(_, left, top, width, height, ink)
    local pixel_value = isRGBInk(ink) and ink.r == 0 and ink.g == 0 and ink.b == 0 and "black" or (isRGBInk(ink) and "color" or tostring(ink))
    for row = math.max(0, top), math.min(125, top + height - 1) do
        for col = math.max(0, left), math.min(209, left + width - 1) do
            color_pixels[row + 1][col + 1] = pixel_value
        end
    end
end
test.VoxelCanvas:new{ width = 210, height = 126, session = color_session }:paintTo({ paintRect = recordColorPixels, paintRectRGB32 = recordColorPixels }, 0, 0)
local function countPixels(value, first_row, last_row)
    local count = 0
    for row = first_row, last_row do
        for col = 0, 209 do if color_pixels[row + 1][col + 1] == value then count = count + 1 end end
    end
    return count
end
assert(countPixels("color", 42, 125) > 8000, "Color ground must cover the lower view instead of collapsing into one edge row")
assert(countPixels("black", 42, 125) > 100, "Color mode must dither existing texture shades with fast black ink")
assert(countPixels("color", 0, 41) > 100, "The color sky must fill the view above the horizon")


--[[--
Phase 2: monochrome E-Ink. The dithered black/white renderer must stay intact
and the color button must not claim a color mode that the panel cannot show.
]]--
MOCK.color_rendering, MOCK.color_screen, MOCK.buffer_is_rgb = false, false, false
assert(not test.colorRenderingEnabled(), "A grayscale panel must use monochrome rendering")
assert(tostring(test.colorForMaterial("grass")) == "black", "With KOReader color rendering off, the palette must fall back to black")
local mono_session = flatSession()
assert(mono_session.color_enabled, "Color mode stays requested by default; only rendering falls back")
assert(not mono_session:act("color"), "A color toggle on a grayscale panel must report false")
assert(mono_session.last_event:find("KOReader-Farbrendering", 1, true), "A grayscale panel must stay monochrome without a color capability probe")
assert(not mono_session.color_enabled, "A refused color toggle must not report color as active")
local mono_pixels = {}
for row = 0, 125 do
    mono_pixels[row + 1] = {}
    for col = 0, 209 do mono_pixels[row + 1][col + 1] = "white" end
end
local mono_canvas = test.VoxelCanvas:new{ width = 210, height = 126, session = mono_session }
mono_canvas:paintTo({ paintRect = function(_, left, top, width, height, ink)
    assert(not isRGBInk(ink), "A grayscale panel must never receive RGB ink")
    for row = math.max(0, top), math.min(125, top + height - 1) do
        for col = math.max(0, left), math.min(209, left + width - 1) do
            mono_pixels[row + 1][col + 1] = tostring(ink)
        end
    end
end }, 0, 0)
local function monochromePixels(value, first_row, last_row)
    local count = 0
    for row = first_row, last_row do
        for col = 0, 209 do if mono_pixels[row + 1][col + 1] == value then count = count + 1 end end
    end
    return count
end
assert(monochromePixels("black", 42, 83) > 300 and monochromePixels("black", 84, 125) > 800, "Flat ground must project across the lower view instead of collapsing into one edge row")
assert(monochromePixels("black", 0, 41) == 0, "A level view must not dither sky ink above the horizon")

--[[--
Phase 3: a color panel whose KOReader "Color rendering" setting is off. The
renderer must follow the same public screen setting as Draw and say why.
]]--
MOCK.color_rendering, MOCK.color_screen, MOCK.buffer_is_rgb = false, true, false
local disabled_session = flatSession()
assert(not test.colorRenderingEnabled(), "KOReader's disabled color-rendering setting must disable color")
assert(not disabled_session:act("color"), "A refused color toggle must report false")
assert(disabled_session.last_event:find("KOReader", 1, true), "The hint must name KOReader's Color rendering setting")
assert(not disabled_session.color_enabled, "Color must stay off while KOReader's setting is off")

--[[--
Back to a working color panel: the interactive color action must toggle and the
canvas must report RGB ink again.
]]--
MOCK.color_rendering, MOCK.color_screen, MOCK.buffer_is_rgb = true, true, true
local toggle_session = flatSession()
toggle_session.color_enabled = false
assert(toggle_session:act("color") and toggle_session.color_enabled, "Color action must enable color rendering")
assert(toggle_session.last_event == "Farbrendering aktiviert.", "Enabling color must be reported")
assert(toggle_session:act("color") and not toggle_session.color_enabled, "Color action must switch back to monochrome")
assert(toggle_session.last_event == "Monochromes Rendering aktiviert.", "Disabling color must be reported")
assert(toggle_session:act("color") and toggle_session.color_enabled, "Color action must be repeatable")

local motion_session = flatSession()
assert(motion_session:act("left") and motion_session:act("back"), "Session actions must support navigation controls")
assert(motion_session.motion and motion_session.motion.frame == 0, "Interactive movement must begin as an animated step")
motion_session:tickMotion()
assert(motion_session.motion and motion_session.motion.frame == 1, "Animated movement must advance one fast-refresh frame at a time")
assert(motion_session:act("jump") and motion_session.jump_frame == 0, "Jump action must start a jump animation")
motion_session:tickJump()
assert(motion_session.jump_frame == 1 and motion_session.jump_offset > 0, "Jump animation must change camera height")

local canvas = test.VoxelCanvas:new{ width = 210, height = 126, session = motion_session }
local swipe_yaw = motion_session.yaw
assert(canvas:onSwipeMinecraftLook(nil, { direction = "east" }), "Horizontal swipes must turn the camera")
assert(motion_session.yaw ~= swipe_yaw, "Swipe look must change yaw")
local original_pitch = motion_session.pitch
assert(canvas:onSwipeMinecraftLook(nil, { direction = "north" }), "Vertical swipes must look up")
assert(motion_session.pitch > original_pitch, "Swipe look must change pitch")
dirty_calls, repaint_calls = {}, 0
canvas._refresh_count = 0
local paint_calls = 0
local function recordMotionPaint(_, left, top, width, height)
    paint_calls = paint_calls + 1
    assert(width >= 1 and height >= 1, "Renderer spans must have a positive physical size")
    assert(left >= 17 and top >= 29 and left + width <= 227 and top + height <= 155, "Renderer must remain within the assigned canvas")
end
canvas:paintTo({ paintRect = recordMotionPaint, paintRectRGB32 = recordMotionPaint }, 17, 29)
assert(paint_calls > 30, "Voxel renderer must draw a substantial projected block scene")
canvas._origin_x, canvas._origin_y = 17, 29
assert(canvas:refreshFast(), "The game canvas must support a direct fast refresh")
assert(repaint_calls == 1 and #dirty_calls == 1, "Fast refresh must repaint exactly the arena")
assert(dirty_calls[1].waveform == "fast", "Arena redraw must request KOReader's fast waveform")
assert(dirty_calls[1].region.x == 17 and dirty_calls[1].region.y == 29 and dirty_calls[1].region.w == 210 and dirty_calls[1].region.h == 126, "Fast refresh region must match the canvas only")

local pane_instance, rebuild_count = {}, 0
local pane_context = {
    dimen = { w = 600, h = 420 },
    px = function(value) return value end,
    requestRebuild = function() rebuild_count = rebuild_count + 1 end,
}
local pane = app.buildPane(pane_instance, pane_context)
assert(pane and pane.dimen.w == 600 and pane.dimen.h == 420, "Minecraft must build inside its assigned AppDock pane")
local world_button
for _, widget in ipairs(pane[1]) do
    if widget.title == "Welt" then world_button = widget; break end
end
assert(world_button and world_button.width > 0, "The pane must expose a world/seed control")
world_button.callback()
local seed_dialog = shown_widget
assert(seed_dialog and seed_dialog.title == "Neue Welt erzeugen" and seed_dialog.keyboard_shown, "World creation must prompt for a seed with the keyboard ready")
seed_dialog.input = "6789"
seed_dialog.buttons[1][2].callback()
assert(pane_instance.minecraft.session.seed == 6789 and pane_instance.minecraft.session.world.seed == 6789, "Creating a world with an entered seed must reproduce that seed")
assert(rebuild_count == 1 and shown_widget == nil, "Creating a seeded world must close the dialog and rebuild the pane")
local repeated_world = test.buildWorld(6789)
assert(repeated_world.heights[20][20] == pane_instance.minecraft.session.world.heights[20][20]
    and repeated_world.materials[30][30] == pane_instance.minecraft.session.world.materials[30][30], "The same seed must reproduce the same terrain")
world_button.callback()
local invalid_dialog = shown_widget
invalid_dialog.input = "not-a-number"
invalid_dialog.buttons[1][2].callback()
assert(pane_instance.minecraft.session.seed == 6789 and rebuild_count == 1 and shown_widget.text:find("ganze Zahl", 1, true), "Invalid seed input must explain the error without replacing the world")
world_button.callback()
seed_dialog = shown_widget
seed_dialog.input = ""
seed_dialog.buttons[1][2].callback()
assert(pane_instance.minecraft.session.seed ~= 6789 and rebuild_count == 2, "An empty seed must create a distinct random-seed world")
local split_pane = app.buildPane(pane_instance, {
    dimen = { w = 600, h = 350 },
    px = function(value) return value end,
    requestRebuild = pane_context.requestRebuild,
})
assert(split_pane and split_pane.dimen.w == 600 and split_pane.dimen.h == 350, "Minecraft must also fit a compact split pane")

local catalog = assert(io.open("dapps.txt", "rb")):read("*a")
assert(session.inventory and session.hotbar and session:selectedMaterial(), "Minecraft must provide inventory and hotbar state")
assert(catalog:find("minecraft.lua | 3.2.1 | minecraft", 1, true), "Minecraft must be published in the DApp catalog")
print("Minecraft 3D DApp test: OK")
