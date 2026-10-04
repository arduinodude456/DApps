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

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_WHITE = "white",
        COLOR_BLACK = "black",
        COLOR_LIGHT_GRAY = "light",
        COLOR_DARK_GRAY = "dark",
        ColorRGB32 = function(r, g, b, a) return string.format("rgb:%d,%d,%d,%d", r, g, b, a) end,
    }
end
package.preload["device"] = function()
    return {
        screen = { scaleBySize = function(_, value) return value end, isColorEnabled = function() return true end },
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
    }
end

local app = dofile("minecraft.lua")
assert(app.id == "minecraft" and app.version == "2.8.0" and app.logo == "other", "Minecraft metadata must be stable")
assert(app._test.WORLD_SIZE == 80 and app._test.MAX_VIEW_DISTANCE == 48 and app._test.RENDER_SCALE == 1, "Render constants must provide the full-resolution long view")
assert(app._test.RENDER_COLS == 180 and app._test.RENDER_ROWS == 180, "Renderer must use the sharper 180x180 logical render budget")
assert(app._test.MOVE_FRAMES == 4 and app._test.MOVE_FRAME_SECONDS < 0.05, "Movement must be animated at a fast-refresh cadence")
local palette_count = 0
for _ in pairs(app._test.COLOR_PALETTE) do palette_count = palette_count + 1 end
assert(palette_count == 7, "Color mode must expose exactly seven palette colors")
assert(app._test.colorForMaterial("grass") == "rgb:45,170,70,255", "Grass must use the RGB green palette color")
assert(app._test.colorForMaterial("water") == "rgb:55,105,220,255", "Water must use the RGB blue palette color")

local standard_cols, standard_rows = app._test.renderGridFor(210, 126)
assert(standard_cols == 180 and standard_rows == 126, "A standard 210x126 pane must use all available rows of the 180x180 budget")
local compact_cols, compact_rows = app._test.renderGridFor(39, 61)
assert(compact_cols == 39 and compact_rows == 61, "Compact panes must not oversample their assigned canvas")

local world = app._test.buildWorld()
assert(world.size == 80 and #world.heights == 80 and #world.heights[1] == 80, "World must be a complete deterministic block grid")
assert(world.materials and world.materials[1][1], "World must contain block materials")
assert(app._test.heightAt(world, -1, 0) == 0 and app._test.heightAt(world, 0, -1) == 0, "Outside terrain must be empty")
assert(app._test.heightAt(world, 11, 5) >= 1 and world.biomes[6][12], "Seeded biome world must remain walkable")
local max_height = 0
local plains_tree_cells = 0
for z = 1, world.size do
    for x = 1, world.size do
        max_height = math.max(max_height, world.heights[z][x])
        if world.biomes[z][x] == "plains" and (world.materials[z][x] == "wood" or world.materials[z][x] == "leaves") then
            plains_tree_cells = plains_tree_cells + 1
        end
    end
end
assert(max_height <= app._test.MAX_COLUMN_HEIGHT, "Tree generation must not cascade into unbounded columns")
assert(plains_tree_cells > 0, "Seeded plains must retain their low-probability trees")
local top_u, top_v = app._test.textureCoordinates("top", 3.25, 5.5, 9.75, 1)
local x_side_u, x_side_v = app._test.textureCoordinates("side", 3.25, 5.5, 9.75, 0)
local z_side_u, z_side_v = app._test.textureCoordinates("side", 3.25, 5.5, 9.75, 2)
assert(top_u == 0.25 and top_v == 0.75, "Top texture coordinates must use world X/Z")
assert(x_side_u == 0.75 and x_side_v == 0.5 and z_side_u == 0.25 and z_side_v == 0.5, "Side textures must use the horizontal axis tangent to the hit face")

local session = app._test.VoxelSession.new()
local original_x, original_z, original_yaw = session.player_x, session.player_z, session.yaw
assert(session:move(1), "Player must walk forward on the starting terrace")
assert(math.abs(session.player_x - (original_x + math.sin(original_yaw) * app._test.WALK_DISTANCE)) < 0.001 and math.abs(session.player_z - (original_z + math.cos(original_yaw) * app._test.WALK_DISTANCE)) < 0.001, "Forward movement must follow the camera heading")
assert(session:turn(1) and session.yaw > original_yaw, "Turning right must change the camera heading")
local place_session = app._test.VoxelSession.new()
place_session.player_x, place_session.player_z, place_session.yaw = 40.5, 40.5, 0
place_session.world.heights[43][41] = app._test.MAX_COLUMN_HEIGHT
place_session.world.materials[43][41] = "stone"
assert(not place_session:place() and place_session.world.heights[43][41] == app._test.MAX_COLUMN_HEIGHT, "Placing on a maximum-height column must not lower it")
local motion_session = app._test.VoxelSession.new()
for z = 1, motion_session.world.size do
    for x = 1, motion_session.world.size do
        motion_session.world.heights[z][x] = 1
        motion_session.world.materials[z][x] = "grass"
    end
end
motion_session.player_x, motion_session.player_z, motion_session.yaw = 40.5, 40.5, 0
assert(not motion_session.color_enabled and motion_session:act("color") and motion_session.color_enabled, "Color action must toggle color rendering")
assert(motion_session:act("left") and motion_session:act("back"), "Session actions must support navigation controls")
assert(motion_session.motion and motion_session.motion.frame == 0, "Interactive movement must begin as an animated step")
motion_session:tickMotion()
assert(motion_session.motion and motion_session.motion.frame == 1, "Animated movement must advance one fast-refresh frame at a time")
assert(motion_session:act("jump") and motion_session.jump_frame == 0, "Jump action must start a jump animation")
motion_session:tickJump()
assert(motion_session.jump_frame == 1 and motion_session.jump_offset > 0, "Jump animation must change camera height")

local canvas = app._test.VoxelCanvas:new{ width = 210, height = 126, session = motion_session }
local swipe_yaw = motion_session.yaw
assert(canvas:onSwipeMinecraftLook(nil, { direction = "east" }), "Horizontal swipes must turn the camera")
assert(motion_session.yaw ~= swipe_yaw, "Swipe look must change yaw")
local original_pitch = motion_session.pitch
assert(canvas:onSwipeMinecraftLook(nil, { direction = "north" }), "Vertical swipes must look up")
assert(motion_session.pitch > original_pitch, "Swipe look must change pitch")
dirty_calls, repaint_calls = {}, 0
canvas._refresh_count = 0
local paint_calls = 0
local captured_color = false
canvas:paintTo({ paintRect = function(_, left, top, width, height, ink)
    paint_calls = paint_calls + 1
    if type(ink) == "string" and ink:match("^rgb:") then captured_color = true end
    assert(width >= 1 and height >= 1, "Renderer spans must have a positive physical size")
    assert(left >= 17 and top >= 29 and left + width <= 227 and top + height <= 155, "Renderer must remain within the assigned canvas")
end }, 17, 29)
assert(paint_calls > 100, "Voxel renderer must draw a substantial projected block scene")
assert(captured_color, "Color mode must paint RGB colors when color hardware is available")

local flat_session = app._test.VoxelSession.new()
for z = 1, flat_session.world.size do
    for x = 1, flat_session.world.size do
        flat_session.world.heights[z][x] = 1
        flat_session.world.materials[z][x] = "grass"
    end
end
flat_session.player_x, flat_session.player_z, flat_session.yaw, flat_session.pitch = 40.5, 40.5, 0, 0
local flat_pixels = {}
for row = 0, 125 do
    flat_pixels[row + 1] = {}
    for col = 0, 209 do flat_pixels[row + 1][col + 1] = "white" end
end
local flat_canvas = app._test.VoxelCanvas:new{ width = 210, height = 126, session = flat_session }
flat_canvas:paintTo({ paintRect = function(_, left, top, width, height, ink)
    for row = math.max(0, top), math.min(125, top + height - 1) do
        for col = math.max(0, left), math.min(209, left + width - 1) do flat_pixels[row + 1][col + 1] = ink end
    end
end }, 0, 0)
local function blackPixels(first_row, last_row)
    local count = 0
    for row = first_row, last_row do
        for col = 0, 209 do if flat_pixels[row + 1][col + 1] == "black" then count = count + 1 end end
    end
    return count
end
assert(blackPixels(42, 83) > 300 and blackPixels(84, 125) > 800, "Flat ground must project across the lower view instead of collapsing into one edge row")

canvas._origin_x, canvas._origin_y = 17, 29
assert(canvas:refreshFast(), "The game canvas must support a direct fast refresh")
assert(repaint_calls == 1 and #dirty_calls == 1, "Fast refresh must repaint exactly the arena")
assert(dirty_calls[1].waveform == "fast", "Arena redraw must request KOReader's fast waveform")
assert(dirty_calls[1].region.x == 17 and dirty_calls[1].region.y == 29 and dirty_calls[1].region.w == 210 and dirty_calls[1].region.h == 126, "Fast refresh region must match the canvas only")

local pane = app.buildPane({}, {
    dimen = { w = 600, h = 420 },
    px = function(value) return value end,
})
assert(pane and pane.dimen.w == 600 and pane.dimen.h == 420, "Minecraft must build inside its assigned AppDock pane")
local split_pane = app.buildPane({}, {
    dimen = { w = 600, h = 350 },
    px = function(value) return value end,
})
assert(split_pane and split_pane.dimen.w == 600 and split_pane.dimen.h == 350, "Minecraft must also fit a compact split pane")

local catalog = assert(io.open("dapps.txt", "rb")):read("*a")
assert(session.inventory and session.hotbar and session:selectedMaterial(), "Minecraft must provide inventory and hotbar state")
assert(catalog:find("minecraft.lua | 2.8.0 | other", 1, true), "Minecraft must be published in the DApp catalog")
print("Minecraft 3D DApp test: OK")
