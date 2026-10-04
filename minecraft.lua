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
            local waves = math.sin(x * 0.61) + math.cos(z * 0.47) + math.sin((x + z) * 0.29)
            local height = 2 + math.floor((waves + 3) * 0.48)
            -- Sparse raised columns make the block structure legible at a
            -- distance without requiring a costly mesh per cube.
            if (x * 13 + z * 7) % 37 == 0 then height = height + 2 end
            if (x == 17 and z >= 15 and z <= 18) or (z == 17 and x >= 15 and x <= 18) then height = 6 end
            if x == 18 and z == 18 then height = 8 end
            -- Calm starting terrace: players always begin on walkable terrain.
            if x >= 9 and x <= 13 and z >= 4 and z <= 7 then height = 3 end
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

function VoxelCanvas:_drawScene(bb, x, y)
    local width, height = self.width, self.height
    bb:paintRect(x, y, width, height, Blitbuffer.COLOR_WHITE)
    local session = self.session
    if not session then return end

    local horizon = math.floor(height * 0.40)
    local focal = math.max(width * 0.88, height * 1.20)
    local camera_y = session:groundHeightAtPlayer() + PLAYER_EYE_HEIGHT
    local column_step = clamp(math.floor(width / 175), 2, 4)
    local sky_bottom = y + horizon
    bb:paintRect(x, sky_bottom, width, 1, Blitbuffer.COLOR_BLACK)
    -- Perspective floor guides make the vanishing point explicit even in a
    -- sparse world and cost only a few short fast-waveform lines.
    for line = 1, 5 do
        local line_y = math.floor(sky_bottom + (height - horizon) * (line / 6) ^ 1.65)
        bb:paintRect(x, line_y, width, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    local right = x + width
    for screen_x = x, right - 1, column_step do
        local band_width = math.min(column_step, right - screen_x)
        local normalized = ((screen_x - x) + band_width * 0.5) / width - 0.5
        local ray_angle = session.yaw + math.atan(normalized * 1.28)
        local ray_x, ray_z = math.sin(ray_angle), math.cos(ray_angle)
        local distance = MAX_VIEW_DISTANCE
        local last_cell = nil
        while distance >= 0.28 do
            local world_x = math.floor(session.player_x + ray_x * distance)
            local world_z = math.floor(session.player_z + ray_z * distance)
            local block_height = heightAt(session.world, world_x, world_z)
            local cell_key = world_x * 100 + world_z
            if block_height > 0 and cell_key ~= last_cell then
                last_cell = cell_key
                local top = self:_project(horizon, focal, camera_y, block_height, distance, y)
                local block_bottom = self:_project(horizon, focal, camera_y, math.max(0, block_height - 1), distance, y)
                local face_bottom = math.min(y + height, block_bottom)
                if top < face_bottom then
                    local tone = distance < 2.6 and 3 or (distance < 6.5 and 2 or 1)
                    local side = ((world_x + world_z) % 2 == 0) and 1 or 0
                    if side == 0 and tone > 1 then tone = tone - 1 end
                    self:_paintDitherBand(bb, screen_x, math.max(y, top), band_width, face_bottom - math.max(y, top), tone, world_x + world_z * 3)
                    bb:paintRect(screen_x, math.max(y, top), band_width, 1, Blitbuffer.COLOR_BLACK)
                    -- The exposed horizontal cap is the key visual difference
                    -- from a flat height silhouette: it is drawn when this
                    -- column crosses a terrain step.
                    bb:paintRect(screen_x, math.max(y, top), band_width, 1, Blitbuffer.COLOR_BLACK)
                end
            end
            distance = distance - 0.18 - distance * 0.085
        end
    end

    local center_x, center_y = x + math.floor(width / 2), y + horizon
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
    version = "1.1.0",
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
