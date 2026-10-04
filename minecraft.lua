--[[--
Minecraft 3D for AppDock.

A compact, offline voxel explorer for E-Ink displays. The world is a deterministic
height-field made from unit blocks. Its renderer uses a column-based voxel-space
projection so movement only redraws the game canvas, never the full AppDock pane.
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
local WORLD_SIZE = 24
local MAX_VIEW_DISTANCE = 14
local PLAYER_EYE_HEIGHT = 1.65
local WALK_DISTANCE = 0.64
local TURN_ANGLE = math.pi / 12
local MOVE_FRAMES = 4
local MOVE_FRAME_SECONDS = 0.045

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function wrapAngle(value) return value % TAU end

local function emptySizedWidget(width, height)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalSpan:new{ width = 0 },
    }
end

-- A fixed seed keeps the landscape exactly the same across refreshes, which is
-- important on E-Ink: only camera motion may change a game frame.
local function buildWorld()
    local world = { size = WORLD_SIZE, heights = {} }
    for z = 0, WORLD_SIZE - 1 do
        world.heights[z + 1] = {}
        for x = 0, WORLD_SIZE - 1 do
            -- Keep the floor low and discrete. The previous wave terrain made
            -- every ray hit a continuous gray wall, hiding the fact that this
            -- is a block game. Raised columns are deliberately sparse so that
            -- each projected cube keeps a visible seam.
            local height = 1
            if (x * 13 + z * 7) % 17 == 0 then height = 2 end
            if (x * 5 + z * 11) % 31 == 0 then height = 3 end
            if x >= 9 and x <= 13 and z >= 4 and z <= 7 then height = 1 end
            -- A recognizable stepped tower sits deeper in the starting view.
            if x == 17 and z == 16 then height = 4 end
            if x == 18 and z == 16 then height = 3 end
            if x == 17 and z == 17 then height = 5 end
            if x == 18 and z == 17 then height = 4 end
            world.heights[z + 1][x + 1] = clamp(height, 1, 8)
        end
    end
    return world
end

local function heightAt(world, x, z)
    if x < 0 or z < 0 or x >= world.size or z >= world.size then return 0 end
    return world.heights[z + 1][x + 1] or 0
end

local VoxelSession = {}
VoxelSession.__index = VoxelSession

function VoxelSession.new()
    local self = setmetatable({
        world = buildWorld(),
        player_x = 11.5,
        player_z = 5.5,
        yaw = 0,
        steps = 0,
        last_event = _("Bereit — erkunde die Blockwelt."),
        canvas = nil,
        motion = nil,
    }, VoxelSession)
    self._motionTick = function() self:tickMotion() end
    return self
end

function VoxelSession:groundHeightAtPlayer()
    return heightAt(self.world, math.floor(self.player_x), math.floor(self.player_z))
end

function VoxelSession:turn(direction)
    self.yaw = wrapAngle(self.yaw + direction * TURN_ANGLE)
    self.last_event = direction < 0 and _("Nach links gedreht.") or _("Nach rechts gedreht.")
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
                local base = tone >= 3 and Blitbuffer.COLOR_BLACK or (tone == 2 and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_LIGHT_GRAY)
                bb:paintRect(left, row, right - left, 1, base)
                -- Texture is intentionally procedural: no bitmap assets are
                -- needed, and the pattern remains crisp on one-bit E-Ink.
                if texture == "top" then
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

function VoxelCanvas:_drawVoxel(bb, points, top_tone, side_tone, phase)
    -- Draw fill first, then a one-pixel wireframe. The slanted edges are what
    -- the former rectangular implementation was missing.
    self:_fillPolygon(bb, points.top, top_tone, phase, "top")
    self:_fillPolygon(bb, points.side_a, side_tone, phase + 1, "side")
    self:_fillPolygon(bb, points.side_b, math.max(1, side_tone - 1), phase + 2, "side")
    for _, edge in ipairs({ points.top, points.side_a, points.side_b }) do
        for index = 1, #edge do self:_line(bb, edge[index], edge[index % #edge + 1], Blitbuffer.COLOR_BLACK) end
    end
end

function VoxelCanvas:_drawScene(bb, x, y)
    local width, height = self.width, self.height
    bb:paintRect(x, y, width, height, Blitbuffer.COLOR_WHITE)
    local session = self.session
    if not session then return end

    local horizon = math.floor(height * 0.40)
    local focal = math.max(width * 0.88, height * 1.20)
    local camera_y = session:groundHeightAtPlayer() + PLAYER_EYE_HEIGHT
    local sky_bottom = y + horizon
    bb:paintRect(x, sky_bottom, width, 1, Blitbuffer.COLOR_BLACK)
    -- Perspective floor guides make the vanishing point explicit between the
    -- individual blocks and cost only a few short fast-waveform lines.
    for line = 1, 5 do
        local line_y = math.floor(sky_bottom + (height - horizon) * (line / 6) ^ 1.65)
        bb:paintRect(x, line_y, width, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    local right = x + width
    local center_x = x + math.floor(width / 2)
    -- Painter's order: far cells first, near cells last. The grid is sampled
    -- by distance rings, but each cell is emitted once, as a complete cube.
    local emitted = {}
    local distance = MAX_VIEW_DISTANCE
    while distance >= 0.55 do
        local radius = math.floor(distance + 0.5)
        for world_z = math.max(0, math.floor(session.player_z - radius)), math.min(session.world.size - 1, math.floor(session.player_z + radius)) do
            for world_x = math.max(0, math.floor(session.player_x - radius)), math.min(session.world.size - 1, math.floor(session.player_x + radius)) do
                local dx, dz = world_x + 0.5 - session.player_x, world_z + 0.5 - session.player_z
                local depth = dx * math.sin(session.yaw) + dz * math.cos(session.yaw)
                local lateral = dx * math.cos(session.yaw) - dz * math.sin(session.yaw)
                local radial = math.sqrt(dx * dx + dz * dz)
                local key = world_x * 100 + world_z
                if depth > 0.4 and radial > distance - 0.8 and radial <= distance + 0.65 and not emitted[key] then
                    emitted[key] = true
                    local block_height = heightAt(session.world, world_x, world_z)
                    local cube_size = math.floor(focal / depth)
                    local project = function(px, pz, py)
                        return { self:_projectPoint(horizon, focal, camera_y, px, pz, py, session, x, y) }
                    end
                    local top_nw = project(world_x - 0.5, world_z - 0.5, block_height)
                    local top_ne = project(world_x + 0.5, world_z - 0.5, block_height)
                    local top_se = project(world_x + 0.5, world_z + 0.5, block_height)
                    local top_sw = project(world_x - 0.5, world_z + 0.5, block_height)
                    local bottom_nw = project(world_x - 0.5, world_z - 0.5, 0)
                    local bottom_ne = project(world_x + 0.5, world_z - 0.5, 0)
                    local bottom_se = project(world_x + 0.5, world_z + 0.5, 0)
                    local bottom_sw = project(world_x - 0.5, world_z + 0.5, 0)
                    local points = {
                        top = { top_nw, top_ne, top_se, top_sw },
                        side_a = math.sin(session.yaw) >= 0 and { top_nw, top_sw, bottom_sw, bottom_nw } or { top_ne, top_se, bottom_se, bottom_ne },
                        side_b = math.cos(session.yaw) >= 0 and { top_nw, top_ne, bottom_ne, bottom_nw } or { top_sw, top_se, bottom_se, bottom_sw },
                    }
                    local min_x, max_x, min_y, max_y = width + x, x, height + y, y
                    for _, face in pairs(points) do for _, point in ipairs(face) do
                        min_x, max_x = math.min(min_x, point[1]), math.max(max_x, point[1])
                        min_y, max_y = math.min(min_y, point[2]), math.max(max_y, point[2])
                    end end
                    if block_height > 0 and cube_size >= 3 and max_x > x and min_x < right and max_y > sky_bottom and min_y < y + height then
                        local tone = depth < 3 and 3 or (depth < 7 and 2 or 1)
                        local side_tone = ((world_x + world_z) % 2 == 0) and math.max(1, tone - 1) or tone
                        self:_drawVoxel(bb, points, tone, side_tone, world_x * 3 + world_z)
                    end
                end
            end
        end
        distance = distance - 0.8
    end

    local center_y = y + horizon
    bb:paintRect(center_x - 5, center_y - 1, 11, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(center_x - 1, center_y - 5, 2, 11, Blitbuffer.COLOR_BLACK)
end

function VoxelCanvas:paintTo(bb, x, y)
    local range = self.ges_events.TapMinecraftExplore[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    self._origin_x, self._origin_y = x, y
    self:_drawScene(bb, x, y)
end

function VoxelCanvas:refreshFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "fast", Geom:new{
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
    version = "1.4.0",
    title = "Minecraft 3D",
    subtitle = "Schnelle monochrome Voxelwelt",
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
        local button_w = math.max(px(30), math.floor((canvas_w - 3 * gap) / 4))
        local canvas = VoxelCanvas:new{ width = canvas_w, height = canvas_h, session = state.session }
        state.session.canvas = canvas
        local pane = WorldPane:new{ dimen = Geom:new{ w = width, h = height }, session = state.session, canvas = canvas }
        function pane:onDeactivate()
            if state.session.motion then
                state.session.motion = nil
                UIManager:unschedule(state.session._motionTick)
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
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = "MINECRAFT 3D", face = Font:getFace("cfont", px(18)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = canvas_w, overlap_offset = { margin, px(6) } },
            TextWidget:new{ text = _("Voxelwelt · schnelle regionale Aktualisierung"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = canvas_w, overlap_offset = { margin, px(29) } },
            canvas,
            NavButton:new{ title = _("Links"), width = button_w, height = controls_h, callback = function() canvas:act("left") end, overlap_offset = { margin, controls_y } },
            NavButton:new{ title = _("Vor"), width = button_w, height = controls_h, primary = true, callback = function() canvas:act("forward") end, overlap_offset = { margin + (button_w + gap), controls_y } },
            NavButton:new{ title = _("Zurück"), width = button_w, height = controls_h, callback = function() canvas:act("back") end, overlap_offset = { margin + (button_w + gap) * 2, controls_y } },
            NavButton:new{ title = _("Rechts"), width = button_w, height = controls_h, callback = function() canvas:act("right") end, overlap_offset = { margin + (button_w + gap) * 3, controls_y } },
            TextWidget:new{ text = _("Szene antippen: oben vor · unten zurück · Seiten drehen"), face = Font:getFace("smallinfofont", px(8)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = canvas_w, overlap_offset = { margin, height - px(14) } },
        }
        return pane
    end,
        _test = {
        VoxelSession = VoxelSession,
        VoxelCanvas = VoxelCanvas,
        buildWorld = buildWorld,
        heightAt = heightAt,
        WORLD_SIZE = WORLD_SIZE,
        WALK_DISTANCE = WALK_DISTANCE,
        TURN_ANGLE = TURN_ANGLE,
        MOVE_FRAMES = MOVE_FRAMES,
        MOVE_FRAME_SECONDS = MOVE_FRAME_SECONDS,
    },
}
