--[[--
Geometry Dash for AppDock.

An offline E-Ink runner inspired by one-button rhythm platformers. The moving
playfield is redrawn directly into the active screen buffer and refreshed with
KOReader's fast waveform. UI chrome changes only on pause, retry, crash, or
completion; every moving frame is confined to the canvas region.
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
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen

local WORLD_W = 600
local WORLD_H = 360
local GROUND_Y = 306
local PLAYER_X = 86
local PLAYER_SIZE = 23
local GRAVITY = 1090
local JUMP_VELOCITY = -410
local PAD_VELOCITY = -510
local RUN_SPEED = 225
-- 20 Hz is a practical fast-waveform cadence: it is visibly smoother than the
-- original 12.5 Hz while remaining confined to the small game arena.
local FRAME_SECONDS = 0.05
local LEVEL_LENGTH = 5350

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

local function emptySizedWidget(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local function addSpike(level, x, count, baseline)
    baseline = baseline or GROUND_Y
    for index = 0, (count or 1) - 1 do
        level[#level + 1] = { kind = "spike", x = x + index * 26, y = baseline - 30, w = 25, h = 30 }
    end
end

local function addBlock(level, x, height, width)
    level[#level + 1] = { kind = "block", x = x, y = GROUND_Y - height, w = width or 42, h = height }
end

local function addPad(level, x)
    level[#level + 1] = { kind = "pad", x = x, y = GROUND_Y - 7, w = 34, h = 7 }
end

local function buildLevel()
    local level = {}
    -- 1. Launch line: readable single and double jumps.
    addSpike(level, 360, 1); addSpike(level, 520, 2); addBlock(level, 690, 42, 44)
    addSpike(level, 790, 1); addPad(level, 915); addSpike(level, 1000, 2)
    -- 2. Block rhythm: raised landings and gated gaps.
    addBlock(level, 1190, 54, 52); addSpike(level, 1260, 1)
    addBlock(level, 1370, 78, 58); addSpike(level, 1450, 2)
    addPad(level, 1585); addBlock(level, 1695, 102, 66); addSpike(level, 1782, 1)
    -- 3. Pressure corridor: alternating triples, pads, and stair blocks.
    addSpike(level, 1900, 3); addPad(level, 2020); addSpike(level, 2120, 2)
    addBlock(level, 2240, 40, 38); addBlock(level, 2294, 68, 38); addBlock(level, 2348, 96, 38)
    addSpike(level, 2440, 2); addPad(level, 2545); addSpike(level, 2640, 3)
    -- 4. Skyline: long jumps across elevated blocks.
    addBlock(level, 2800, 74, 82); addSpike(level, 2898, 1)
    addBlock(level, 3030, 116, 70); addSpike(level, 3118, 2)
    addPad(level, 3240); addBlock(level, 3350, 142, 74); addSpike(level, 3440, 1)
    -- 5. Finale: dense but deterministic final rhythm.
    addSpike(level, 3580, 2); addPad(level, 3690); addSpike(level, 3780, 3)
    addBlock(level, 3910, 52, 46); addSpike(level, 3974, 1); addBlock(level, 4070, 88, 52)
    addPad(level, 4175); addSpike(level, 4265, 2); addBlock(level, 4380, 120, 64)
    addSpike(level, 4462, 1); addSpike(level, 4580, 3); addPad(level, 4705)
    addBlock(level, 4815, 64, 46); addBlock(level, 4877, 92, 46); addSpike(level, 4950, 2)
    addPad(level, 5070); addSpike(level, 5170, 1)
    return level
end

local LEVEL = buildLevel()

local function rectangleOverlap(left_a, top_a, width_a, height_a, left_b, top_b, width_b, height_b)
    return left_a < left_b + width_b and left_a + width_a > left_b and top_a < top_b + height_b and top_a + height_a > top_b
end

local function playerBounds(session)
    return PLAYER_X, session.player_y, PLAYER_SIZE, PLAYER_SIZE
end

local function nearbyObjects(session)
    local objects = {}
    local lower, upper = session.distance - 110, session.distance + WORLD_W + 110
    for _, object in ipairs(LEVEL) do
        if object.x + object.w >= lower and object.x <= upper then objects[#objects + 1] = object end
    end
    return objects
end

local GameSession = {}
GameSession.__index = GameSession

function GameSession.new(on_event)
    local self = setmetatable({ canvas = nil, paused = true, over = false, complete = false, distance = 0, player_y = GROUND_Y - PLAYER_SIZE, velocity_y = 0, grounded = true, pad_latch = {}, frames = 0, on_event = on_event }, GameSession)
    self._tick = function() self:tick() end
    return self
end

function GameSession:setCanvas(canvas)
    self.canvas = canvas
    if canvas then canvas.session = self end
end

function GameSession:emit(kind, message)
    if self.on_event then self.on_event(kind, message) end
end

function GameSession:reset()
    UIManager:unschedule(self._tick)
    self.paused, self.over, self.complete = true, false, false
    self.distance, self.player_y, self.velocity_y, self.grounded = 0, GROUND_Y - PLAYER_SIZE, 0, true
    self.pad_latch, self.frames = {}, 0
    self:emit("ready", _("Ready — tap the arena or press Play."))
end

function GameSession:start()
    if self.over or self.complete then self:reset() end
    if not self.paused then return true end
    self.paused = false
    self:emit("playing", _("Fast refresh active · tap to jump"))
    UIManager:unschedule(self._tick)
    UIManager:scheduleIn(FRAME_SECONDS, self._tick)
    return true
end

function GameSession:pause()
    if self.paused then return end
    self.paused = true
    UIManager:unschedule(self._tick)
    self:emit("paused", _("Paused. Tap Play to continue."))
end

function GameSession:jump()
    if self.over or self.complete then self:reset() end
    if self.paused then self:start() end
    if self.grounded then
        self.velocity_y, self.grounded = JUMP_VELOCITY, false
        return true
    end
    return false
end

function GameSession:crash()
    self.over, self.paused = true, true
    UIManager:unschedule(self._tick)
    self:emit("crash", _("Crashed at ") .. tostring(math.floor(self.distance)) .. _(". Tap Retry."))
end

function GameSession:finish()
    self.complete, self.paused = true, true
    UIManager:unschedule(self._tick)
    self:emit("complete", _("Level complete! Tap Retry for another run."))
end

function GameSession:advance(delta)
    if self.paused or self.over or self.complete then return false end
    delta = clamp(tonumber(delta) or FRAME_SECONDS, 0.02, 0.14)
    local previous_y, previous_bottom = self.player_y, self.player_y + PLAYER_SIZE
    self.distance = self.distance + RUN_SPEED * delta
    self.velocity_y = self.velocity_y + GRAVITY * delta
    self.player_y = self.player_y + self.velocity_y * delta
    self.grounded = false
    local player_x, player_y, player_w, player_h = playerBounds(self)
    local player_bottom = player_y + player_h
    local landed, launched = false, false
    for _, object in ipairs(nearbyObjects(self)) do
        local object_x = object.x - self.distance
        if object.kind == "block" then
            if previous_bottom <= object.y + 3 and player_bottom >= object.y and player_x + player_w > object_x + 3 and player_x < object_x + object.w - 3 and self.velocity_y >= 0 then
                self.player_y, self.velocity_y, self.grounded, landed = object.y - PLAYER_SIZE, 0, true, true
                player_y, player_bottom = self.player_y, self.player_y + PLAYER_SIZE
            elseif rectangleOverlap(player_x + 3, player_y + 3, player_w - 6, player_h - 6, object_x, object.y, object.w, object.h) then
                self:crash(); return false
            end
        elseif object.kind == "spike" and rectangleOverlap(player_x + 5, player_y + 5, player_w - 10, player_h - 7, object_x + 3, object.y + 7, object.w - 6, object.h - 7) then
            self:crash(); return false
        elseif object.kind == "pad" and player_bottom >= object.y - 3 and previous_bottom <= object.y + 9 and player_x + player_w > object_x and player_x < object_x + object.w and not self.pad_latch[object.x] then
            self.velocity_y, self.grounded, self.pad_latch[object.x], launched = PAD_VELOCITY, false, true, true
        end
    end
    if not landed and not launched and self.player_y + PLAYER_SIZE >= GROUND_Y then
        self.player_y, self.velocity_y, self.grounded = GROUND_Y - PLAYER_SIZE, 0, true
    end
    if self.distance >= LEVEL_LENGTH then self:finish(); return false end
    self.frames = self.frames + 1
    return true
end

function GameSession:tick()
    if not self:advance(FRAME_SECONDS) then
        if self.canvas then self.canvas:refreshFast() end
        return
    end
    if self.canvas then self.canvas:refreshFast() end
    UIManager:scheduleIn(FRAME_SECONDS, self._tick)
end

local ArenaCanvas = InputContainer:extend{ session = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0, _scale = 1, _draw_x = 0, _draw_y = 0 }

function ArenaCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapGeometryDashJump = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function ArenaCanvas:_layout(x, y)
    local ratio = math.min(self.width / WORLD_W, self.height / WORLD_H)
    self._scale = math.max(0.1, ratio)
    self._draw_x = x + math.floor((self.width - WORLD_W * self._scale) / 2)
    self._draw_y = y + math.floor((self.height - WORLD_H * self._scale) / 2)
end

function ArenaCanvas:_rect(bb, x, y, width, height, ink)
    local left = math.floor(self._draw_x + x * self._scale)
    local top = math.floor(self._draw_y + y * self._scale)
    local draw_w = math.max(1, math.ceil(width * self._scale))
    local draw_h = math.max(1, math.ceil(height * self._scale))
    bb:paintRect(left, top, draw_w, draw_h, ink)
end

function ArenaCanvas:_spike(bb, x, y, width, height)
    local steps = math.max(4, math.floor(width * self._scale))
    for step = 0, steps - 1 do
        local progress = step / math.max(1, steps - 1)
        local slope = progress <= 0.5 and progress * 2 or (1 - progress) * 2
        local column_height = math.max(1, math.floor(height * slope * self._scale))
        bb:paintRect(math.floor(self._draw_x + x * self._scale + step), math.floor(self._draw_y + (y + height) * self._scale - column_height), 1, column_height, Blitbuffer.COLOR_BLACK)
    end
end

function ArenaCanvas:paintTo(bb, x, y)
    -- OverlapGroup positions the arena below the host chrome. Keep the tap
    -- hitbox in that same local rectangle; otherwise its default 0,0 range
    -- overlaps AppDock's close control and turns Close into a jump.
    local range = self.ges_events.TapGeometryDashJump[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    self._origin_x, self._origin_y = x, y
    self:_layout(x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local session = self.session
    if not session then return end
    -- Quiet geometric backdrop: meaningful motion stays in the lower arena.
    for line_y = 46, GROUND_Y - 26, 42 do self:_rect(bb, 0, line_y, WORLD_W, 1, Blitbuffer.COLOR_LIGHT_GRAY) end
    for line_x = 0, WORLD_W, 75 do self:_rect(bb, line_x, 0, 1, GROUND_Y, Blitbuffer.COLOR_LIGHT_GRAY) end
    self:_rect(bb, 0, GROUND_Y, WORLD_W, 5, Blitbuffer.COLOR_BLACK)
    for _, object in ipairs(nearbyObjects(session)) do
        local draw_x = object.x - session.distance
        if object.kind == "spike" then self:_spike(bb, draw_x, object.y, object.w, object.h)
        elseif object.kind == "block" then
            self:_rect(bb, draw_x, object.y, object.w, object.h, Blitbuffer.COLOR_BLACK)
            self:_rect(bb, draw_x + 4, object.y + 4, object.w - 8, object.h - 8, Blitbuffer.COLOR_WHITE)
        elseif object.kind == "pad" then
            self:_rect(bb, draw_x, object.y, object.w, object.h, Blitbuffer.COLOR_DARK_GRAY)
            self:_rect(bb, draw_x + 4, object.y - 4, object.w - 8, 4, Blitbuffer.COLOR_BLACK)
        end
    end
    self:_rect(bb, PLAYER_X, session.player_y, PLAYER_SIZE, PLAYER_SIZE, session.over and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK)
    self:_rect(bb, PLAYER_X + 5, session.player_y + 5, PLAYER_SIZE - 10, PLAYER_SIZE - 10, Blitbuffer.COLOR_WHITE)
    self:_rect(bb, PLAYER_X + 8, session.player_y + 8, 4, 4, Blitbuffer.COLOR_BLACK)
    self:_rect(bb, PLAYER_X + 15, session.player_y + 8, 4, 4, Blitbuffer.COLOR_BLACK)
    local progress = clamp(session.distance / LEVEL_LENGTH, 0, 1)
    self:_rect(bb, 18, 17, WORLD_W - 36, 5, Blitbuffer.COLOR_LIGHT_GRAY)
    self:_rect(bb, 18, 17, math.floor((WORLD_W - 36) * progress), 5, Blitbuffer.COLOR_BLACK)
end

function ArenaCanvas:refreshFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "fast", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    if UIManager.yieldToEPDC then UIManager:yieldToEPDC() end
    return true
end

function ArenaCanvas:onTapGeometryDashJump()
    if self.session then self.session:jump(); self:refreshFast() end
    return true
end

local GameButton = InputContainer:extend{ title = "", width = nil, height = nil, callback = nil, primary = false, dimen = nil }
function GameButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.max(4, math.floor(self.height * .24)), background = self.primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", math.max(scale(9), math.floor(self.height * .31))), fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, bold = true, max_width = self.width - scale(8) } } }
    self.ges_events = { TapGeometryDashButton = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function GameButton:paintTo(bb, x, y)
    local range = self.ges_events.TapGeometryDashButton[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function GameButton:onTapGeometryDashButton() if self.callback then self.callback() end; return true end

local GamePane = InputContainer:extend{ session = nil }
function GamePane:onGeometryDashJump() if self.session then self.session:jump(); if self.session.canvas then self.session.canvas:refreshFast() end end; return true end
function GamePane:onGeometryDashPause() if self.session then self.session:pause() end; return true end

local function stateFor(instance, context)
    if instance.geometry_dash then return instance.geometry_dash end
    local state = { status = _("Ready — tap the arena or press Play."), session = nil }
    state.session = GameSession.new(function(kind, message)
        state.status = message
        if context and context.requestRebuild and (kind == "crash" or kind == "complete" or kind == "paused" or kind == "ready") then context.requestRebuild("ui") end
    end)
    instance.geometry_dash = state
    return state
end

return {
    id = "geometry_dash",
    version = "1.0.2",
    title = "Geometry Dash",
    subtitle = "Fast-refresh obstacle runner",
    symbol = "G",
    logo = "other",
    buildPane = function(instance, context)
        local state = stateFor(instance, context)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or scale
        local margin, gap = px(10), px(7)
        local header_h, controls_h = px(42), px(34)
        local arena_h = math.max(px(118), height - header_h - controls_h - px(42))
        local arena_y = header_h
        local pane = GamePane:new{ dimen = Geom:new{ w = width, h = height }, session = state.session }
        function pane:onDeactivate()
            if self.session then self.session:pause() end
        end
        pane.key_events = {}
        local groups = Device.input and Device.input.group or {}
        if groups.Press then pane.key_events.GeometryDashJump = { { groups.Press }, event = "GeometryDashJump" } end
        if groups.Select then pane.key_events.GeometryDashJumpSelect = { { groups.Select }, event = "GeometryDashJump" } end
        if groups.Back then pane.key_events.GeometryDashPause = { { groups.Back }, event = "GeometryDashPause" } end
        local arena = ArenaCanvas:new{ width = width - 2 * margin, height = arena_h, session = state.session }
        state.session:setCanvas(arena)
        local button_w = math.floor((width - 2 * margin - gap) / 2)
        local play_title = (state.session.over or state.session.complete) and _("Retry") or (state.session.paused and _("Play") or _("Pause"))
        local layers = {
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = "GEOMETRY DASH", face = Font:getFace("cfont", px(19)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, px(7) } },
            TextWidget:new{ text = string.format("%d%%", math.floor(clamp(state.session.distance / LEVEL_LENGTH, 0, 1) * 100)), face = Font:getFace("smallinfofont", px(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = px(58), overlap_offset = { width - margin - px(58), px(13) } },
            arena,
            GameButton:new{ title = play_title, primary = true, width = button_w, height = controls_h, callback = function()
                if state.session.over or state.session.complete then state.session:reset(); context.requestRebuild("ui")
                elseif state.session.paused then state.session:start(); context.requestRebuild("ui")
                else state.session:pause() end
            end, overlap_offset = { margin, arena_y + arena_h + gap } },
            GameButton:new{ title = _("Restart"), width = button_w, height = controls_h, callback = function() state.session:reset(); context.requestRebuild("ui") end, overlap_offset = { margin + button_w + gap, arena_y + arena_h + gap } },
            TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - px(16) } },
        }
        arena.overlap_offset = { margin, arena_y }
        pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, unpack(layers) }
        return pane
    end,
    onClose = function(instance)
        local state = instance and instance.geometry_dash
        if state and state.session then state.session:pause() end
    end,
    _test = { GameSession = GameSession, buildLevel = buildLevel, rectangleOverlap = rectangleOverlap, LEVEL_LENGTH = LEVEL_LENGTH, FRAME_SECONDS = FRAME_SECONDS, GROUND_Y = GROUND_Y },
}
