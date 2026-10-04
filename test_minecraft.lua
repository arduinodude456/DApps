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
    }
end
package.preload["device"] = function()
    return {
        screen = { scaleBySize = function(_, value) return value end },
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
assert(app.id == "minecraft" and app.version == "2.0.0" and app.logo == "other", "Minecraft metadata must be stable")
assert(app._test.WORLD_SIZE == 80 and app._test.MAX_VIEW_DISTANCE == 48 and app._test.RENDER_SCALE == 1, "Render constants must provide the full-resolution long view")
assert(app._test.MOVE_FRAMES == 4 and app._test.MOVE_FRAME_SECONDS < 0.05, "Movement must be animated at a fast-refresh cadence")

local world = app._test.buildWorld()
assert(world.size == 80 and #world.heights == 80 and #world.heights[1] == 80, "World must be a complete deterministic block grid")
assert(world.materials and world.materials[1][1], "World must contain block materials")
assert(app._test.heightAt(world, -1, 0) == 0 and app._test.heightAt(world, 0, -1) == 0, "Outside terrain must be empty")
assert(app._test.heightAt(world, 11, 5) == 1, "Starting terrace must remain walkable")

local session = app._test.VoxelSession.new()
local original_z = session.player_z
assert(session:move(1), "Player must walk forward on the starting terrace")
assert(session.player_z > original_z, "Forward at zero yaw must increase z")
local original_yaw = session.yaw
assert(session:turn(1) and session.yaw > original_yaw, "Turning right must change the camera heading")
assert(session:act("left") and session:act("back"), "Session actions must support navigation controls")
assert(session.motion and session.motion.frame == 0, "Interactive movement must begin as an animated step")
session:tickMotion()
assert(session.motion and session.motion.frame == 1, "Animated movement must advance one fast-refresh frame at a time")
assert(session:act("jump") and session.jump_frame == 0, "Jump action must start a jump animation")
session:tickJump()
assert(session.jump_frame == 1 and session.jump_offset > 0, "Jump animation must change camera height")

local canvas = app._test.VoxelCanvas:new{ width = 210, height = 126, session = session }
local swipe_yaw = session.yaw
assert(canvas:onSwipeMinecraftLook(nil, { direction = "east" }), "Horizontal swipes must turn the camera")
assert(session.yaw ~= swipe_yaw, "Swipe look must change yaw")
local original_pitch = session.pitch
assert(canvas:onSwipeMinecraftLook(nil, { direction = "north" }), "Vertical swipes must look up")
assert(session.pitch > original_pitch, "Swipe look must change pitch")
dirty_calls, repaint_calls = {}, 0
canvas._refresh_count = 0
local paint_calls = 0
canvas:paintTo({ paintRect = function() paint_calls = paint_calls + 1 end }, 17, 29)
assert(paint_calls > 100, "Voxel renderer must draw a substantial projected block scene")
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
assert(catalog:find("minecraft.lua | 2.0.0 | other", 1, true), "Minecraft must be published in the DApp catalog")
print("Minecraft 3D DApp test: OK")
