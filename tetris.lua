--[[--
Tetris for AppDock.
A local, E-Ink-friendly falling-block game. The active arena is painted directly
and refreshed with KOReader's fast waveform at a fixed 10 FPS while playing.
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

local BOARD_W, BOARD_H = 10, 20
local FRAME_SECONDS = 0.1
local COLORS = {
    { 55, 140, 220, Blitbuffer.COLOR_DARK_GRAY },
    { 235, 190, 45, Blitbuffer.COLOR_GRAY_8 },
    { 170, 80, 190, Blitbuffer.COLOR_DARK_GRAY },
    { 75, 175, 105, Blitbuffer.COLOR_GRAY_8 },
    { 215, 75, 75, Blitbuffer.COLOR_DARK_GRAY },
    { 70, 185, 185, Blitbuffer.COLOR_GRAY_8 },
    { 225, 125, 55, Blitbuffer.COLOR_DARK_GRAY },
}
local SHAPES = {
    I = { { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 3, 1 } }, { { 2, 0 }, { 2, 1 }, { 2, 2 }, { 2, 3 } } },
    O = { { { 1, 0 }, { 2, 0 }, { 1, 1 }, { 2, 1 } } },
    T = { { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } }, { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } }, { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 1, 2 } }, { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, 2 } } },
    S = { { { 1, 0 }, { 2, 0 }, { 0, 1 }, { 1, 1 } }, { { 1, 0 }, { 1, 1 }, { 2, 1 }, { 2, 2 } } },
    Z = { { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 2, 1 } }, { { 2, 0 }, { 1, 1 }, { 2, 1 }, { 1, 2 } } },
    J = { { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } }, { { 1, 0 }, { 2, 0 }, { 1, 1 }, { 1, 2 } }, { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 2, 2 } }, { { 1, 0 }, { 1, 1 }, { 0, 2 }, { 1, 2 } } },
    L = { { { 2, 0 }, { 0, 1 }, { 1, 1 }, { 2, 1 } }, { { 1, 0 }, { 1, 1 }, { 1, 2 }, { 2, 2 } }, { { 0, 1 }, { 1, 1 }, { 2, 1 }, { 0, 2 } }, { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 1, 2 } } },
}
local PIECES = { "I", "O", "T", "S", "Z", "J", "L" }
local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function emptySizedWidget(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end
local function colorValue(entry, enabled)
    if enabled and Screen:isColorEnabled() then return Blitbuffer.ColorRGB32(entry[1], entry[2], entry[3], 0xFF) end
    return entry[4]
end
local function pieceCells(piece)
    return SHAPES[piece.kind][(piece.rotation or 0) % #SHAPES[piece.kind] + 1]
end
local TetrisSession = {}
TetrisSession.__index = TetrisSession
function TetrisSession.new(on_event)
    local self = setmetatable({ board = {}, current = nil, next_kind = nil, rng = 17, paused = true, over = false, score = 0, lines = 0, level = 1, frames = 0, fall_frames = 0, on_event = on_event }, TetrisSession)
    self._tick = function() self:tick() end
    self:reset(true)
    return self
end
function TetrisSession:emit(kind, message)
    if self.on_event then self.on_event(kind, message) end
end
function TetrisSession:randomKind()
    self.rng = (self.rng * 1103515245 + 12345) % 2147483648
    return PIECES[(self.rng % #PIECES) + 1]
end
function TetrisSession:reset(silent)
    UIManager:unschedule(self._tick)
    self.board, self.paused, self.over = {}, true, false
    for index = 1, BOARD_W * BOARD_H do self.board[index] = 0 end
    self.current, self.next_kind = nil, self:randomKind()
    self.score, self.lines, self.level, self.frames, self.fall_frames = 0, 0, 1, 0, 0
    self:spawn()
    if not silent then self:emit("ready", _("Ready — tap Play or use the controls.")) end
end
function TetrisSession:cell(x, y) return self.board[y * BOARD_W + x + 1] or 0 end
function TetrisSession:collides(piece, dx, dy, rotation)
    local probe = { kind = piece.kind, rotation = rotation == nil and piece.rotation or rotation, x = piece.x + (dx or 0), y = piece.y + (dy or 0) }
    for _, cell in ipairs(pieceCells(probe)) do
        local x, y = probe.x + cell[1], probe.y + cell[2]
        if x < 0 or x >= BOARD_W or y >= BOARD_H or (y >= 0 and self:cell(x, y) ~= 0) then return true end
    end
    return false
end
function TetrisSession:spawn()
    local kind = self.next_kind or self:randomKind(); self.next_kind = self:randomKind()
    self.current = { kind = kind, rotation = 0, x = 3, y = -1 }
    if self:collides(self.current, 0, 0) then self.over, self.paused = true, true; UIManager:unschedule(self._tick); self:emit("over", _("Game over — score: ") .. tostring(self.score) .. _(". Tap Restart.")) end
end
function TetrisSession:start()
    if self.over then self:reset() end
    if not self.paused then return end
    self.paused = false; self:emit("playing", _("10 FPS fast refresh active.")); UIManager:unschedule(self._tick); UIManager:scheduleIn(FRAME_SECONDS, self._tick)
end
function TetrisSession:pause()
    if self.paused then return end
    self.paused = true; UIManager:unschedule(self._tick); self:emit("paused", _("Paused. Tap Play to continue."))
end
function TetrisSession:move(dx)
    if self.paused or self.over or not self.current then return false end
    if not self:collides(self.current, dx, 0) then self.current.x = self.current.x + dx; return true end
    return false
end
function TetrisSession:rotate()
    if self.paused or self.over or not self.current then return false end
    local next_rotation = (self.current.rotation + 1) % #SHAPES[self.current.kind]
    for _, kick in ipairs({ 0, -1, 1, -2, 2 }) do
        if not self:collides(self.current, kick, 0, next_rotation) then self.current.x = self.current.x + kick; self.current.rotation = next_rotation; return true end
    end
    return false
end
function TetrisSession:lock()
    for _, cell in ipairs(pieceCells(self.current)) do
        local x, y = self.current.x + cell[1], self.current.y + cell[2]
        if y >= 0 and y < BOARD_H and x >= 0 and x < BOARD_W then self.board[y * BOARD_W + x + 1] = ({ I = 1, O = 2, T = 3, S = 4, Z = 5, J = 6, L = 7 })[self.current.kind] end
    end
    local cleared = 0
    for y = BOARD_H - 1, 0, -1 do
        local full = true
        for x = 0, BOARD_W - 1 do if self:cell(x, y) == 0 then full = false; break end end
        if full then
            for move_y = y, 1, -1 do for x = 0, BOARD_W - 1 do self.board[move_y * BOARD_W + x + 1] = self:cell(x, move_y - 1) end end
            for x = 0, BOARD_W - 1 do self.board[x + 1] = 0 end
            cleared = cleared + 1; y = y + 1
        end
    end
    if cleared > 0 then self.lines = self.lines + cleared; self.score = self.score + ({ [1] = 100, [2] = 300, [3] = 500, [4] = 800 })[cleared] * self.level; self.level = math.floor(self.lines / 10) + 1; self:emit("score", _("Lines: ") .. tostring(self.lines)) end
    self:spawn()
end
function TetrisSession:hardDrop()
    if self.paused or self.over or not self.current then return false end
    local distance = 0; while not self:collides(self.current, 0, distance + 1) do distance = distance + 1 end
    self.current.y = self.current.y + distance; self.score = self.score + distance * 2; self:lock(); return true
end
function TetrisSession:tick()
    if self.paused or self.over or not self.current then return end
    self.frames = self.frames + 1; self.fall_frames = self.fall_frames + 1
    local interval = math.max(1, 12 - math.floor((self.level - 1) / 2))
    if self.fall_frames >= interval then self.fall_frames = 0; if self:collides(self.current, 0, 1) then self:lock() else self.current.y = self.current.y + 1 end end
    if self.canvas then self.canvas:refreshFast() end
    if not self.paused then UIManager:scheduleIn(FRAME_SECONDS, self._tick) end
end
local TetrisCanvas = InputContainer:extend{ session = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0, _cell = 1, _board_x = 0, _board_y = 0, color_enabled = false }
function TetrisCanvas:init() self.dimen = Geom:new{ w = self.width, h = self.height }; self.ges_events = { TapTetrisCanvas = { GestureRange:new{ ges = "tap", range = self.dimen } } } end
function TetrisCanvas:_layout(x, y)
    self._cell = math.max(4, math.floor(math.min((self.width - 8) / BOARD_W, (self.height - 8) / BOARD_H))); self._board_x = x + math.floor((self.width - BOARD_W * self._cell) / 2); self._board_y = y + math.floor((self.height - BOARD_H * self._cell) / 2)
end
function TetrisCanvas:_paintBlock(bb, x, y, value, inset)
    if x < 0 or y < 0 or x >= BOARD_W or y >= BOARD_H then return end
    local size = math.max(1, self._cell - (inset or 1) * 2); local entry = COLORS[value] or COLORS[1]; bb:paintRect(self._board_x + x * self._cell + (inset or 1), self._board_y + y * self._cell + (inset or 1), size, size, colorValue(entry, self.color_enabled))
end
function TetrisCanvas:paintTo(bb, x, y)
    local range = self.ges_events.TapTetrisCanvas[1].range; range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h; self._origin_x, self._origin_y = x, y; self:_layout(x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE); local board_w, board_h = BOARD_W * self._cell, BOARD_H * self._cell
    bb:paintRect(self._board_x - 2, self._board_y - 2, board_w + 4, board_h + 4, Blitbuffer.COLOR_BLACK); bb:paintRect(self._board_x, self._board_y, board_w, board_h, Blitbuffer.COLOR_WHITE)
    local session = self.session; if not session then return end
    for gy = 0, BOARD_H - 1 do for gx = 0, BOARD_W - 1 do local value = session:cell(gx, gy); if value ~= 0 then self:_paintBlock(bb, gx, gy, value, 1) end end end
    if session.current then for _, cell in ipairs(pieceCells(session.current)) do self:_paintBlock(bb, session.current.x + cell[1], session.current.y + cell[2], ({ I = 1, O = 2, T = 3, S = 4, Z = 5, J = 6, L = 7 })[session.current.kind], 0) end end
end
function TetrisCanvas:refreshFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y); UIManager:setDirty(nil, "fast", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height }); if UIManager.forceRePaint then UIManager:forceRePaint() end; if UIManager.yieldToEPDC then UIManager:yieldToEPDC() end; return true
end
function TetrisCanvas:onTapTetrisCanvas() if self.session and self.session.paused then self.session:start(); self:refreshFast() end; return true end
local GameButton = InputContainer:extend{ title = "", width = nil, height = nil, callback = nil, primary = false, dimen = nil }
function GameButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }; self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.max(4, math.floor(self.height * .24)), background = self.primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY, CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", math.max(scale(8), math.floor(self.height * .31))), fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, bold = true, max_width = self.width - scale(8) } } }; self.ges_events = { TapTetrisButton = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function GameButton:paintTo(bb, x, y) local range = self.ges_events.TapTetrisButton[1].range; range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h; return InputContainer.paintTo(self, bb, x, y) end
function GameButton:onTapTetrisButton() if self.callback then self.callback() end; return true end
local TetrisPane = InputContainer:extend{}
function TetrisPane:_action(action) if self.session then action(self.session); if self.session.canvas then self.session.canvas:refreshFast() end end; return true end
function TetrisPane:onTetrisLeft() return self:_action(function(s) s:move(-1) end) end
function TetrisPane:onTetrisRight() return self:_action(function(s) s:move(1) end) end
function TetrisPane:onTetrisRotate() return self:_action(function(s) s:rotate() end) end
function TetrisPane:onTetrisDown() return self:_action(function(s) s:hardDrop() end) end
local function stateFor(instance, context)
    if instance.tetris then return instance.tetris end
    local state = { color = Screen:isColorEnabled(), status = _("Ready — tap Play or use the controls."), session = nil }
    state.session = TetrisSession.new(function(kind, message) state.status = message; if context and context.requestRebuild and (kind == "ready" or kind == "playing" or kind == "paused" or kind == "over" or kind == "score") then context.requestRebuild("ui") end end)
    instance.tetris = state; return state
end
return {
    id = "tetris", version = "1.0.0", title = "Tetris", subtitle = "Classic falling blocks with 10 FPS fast refresh", symbol = "T", logo = "other",
    buildPane = function(instance, context)
        local state = stateFor(instance, context); local width, height = context.dimen.w, context.dimen.h; local px = context.px or scale; local margin, gap = px(10), px(6); local header_h, action_h, control_h, footer_h = px(38), px(31), px(31), px(15); local arena_h = math.max(px(150), height - header_h - action_h - control_h - footer_h - 4 * gap); local arena_y, action_y, control_y = header_h, header_h + arena_h + gap, header_h + arena_h + gap + action_h + gap
        local pane = TetrisPane:new{ dimen = Geom:new{ w = width, h = height }, session = state.session }; function pane:onDeactivate() if self.session then self.session:pause() end end
        pane.ges_events = {}; pane.key_events = {}; local groups = Device.input and Device.input.group or {}; if groups.Left then pane.key_events.TetrisLeft = { { groups.Left }, event = "TetrisLeft" } end; if groups.Right then pane.key_events.TetrisRight = { { groups.Right }, event = "TetrisRight" } end; if groups.Up then pane.key_events.TetrisRotate = { { groups.Up }, event = "TetrisRotate" } end; if groups.Down then pane.key_events.TetrisDown = { { groups.Down }, event = "TetrisDown" } end
        local arena = TetrisCanvas:new{ width = width - 2 * margin, height = arena_h, session = state.session, color_enabled = state.color }; state.session.canvas = arena; local action_w = math.floor((width - 2 * margin - 2 * gap) / 3); local control_w = math.floor((width - 2 * margin - 3 * gap) / 4); local play_title = state.session.over and _("Play") or (state.session.paused and _("Play") or _("Pause"))
        local function rebuild() if context.requestRebuild then context.requestRebuild("ui") end end
        local layers = { FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) }, TextWidget:new{ text = "TETRIS", face = Font:getFace("cfont", px(19)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, px(6) } }, TextWidget:new{ text = _("Score ") .. tostring(state.session.score) .. "  " .. _("Level ") .. tostring(state.session.level), face = Font:getFace("smallinfofont", px(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, px(14) } }, arena,
            GameButton:new{ title = play_title, primary = true, width = action_w, height = action_h, callback = function() if state.session.over then state.session:reset(); rebuild() elseif state.session.paused then state.session:start(); arena:refreshFast() else state.session:pause(); rebuild() end end, overlap_offset = { margin, action_y } },
            GameButton:new{ title = _("Restart"), width = action_w, height = action_h, callback = function() state.session:reset(); rebuild() end, overlap_offset = { margin + action_w + gap, action_y } },
            GameButton:new{ title = state.color and _("Color on") or _("Color off"), width = action_w, height = action_h, callback = function() state.color = not state.color; arena.color_enabled = state.color; rebuild() end, overlap_offset = { margin + 2 * (action_w + gap), action_y } },
            GameButton:new{ title = _("LEFT"), width = control_w, height = control_h, callback = function() pane:onTetrisLeft() end, overlap_offset = { margin, control_y } },
            GameButton:new{ title = _("ROTATE"), width = control_w, height = control_h, callback = function() pane:onTetrisRotate() end, overlap_offset = { margin + control_w + gap, control_y } },
            GameButton:new{ title = _("DROP"), width = control_w, height = control_h, callback = function() pane:onTetrisDown() end, overlap_offset = { margin + 2 * (control_w + gap), control_y } },
            GameButton:new{ title = _("RIGHT"), width = control_w, height = control_h, callback = function() pane:onTetrisRight() end, overlap_offset = { margin + 3 * (control_w + gap), control_y } },
            TextWidget:new{ text = state.status .. " " .. _("Arrows: move/rotate/drop."), face = Font:getFace("smallinfofont", px(8)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - footer_h } }, }
        arena.overlap_offset = { margin, arena_y }; pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, unpack(layers) }; return pane
    end,
    onClose = function(instance) if instance and instance.tetris and instance.tetris.session then instance.tetris.session:pause() end end,
    _test = { TetrisSession = TetrisSession, BOARD_W = BOARD_W, BOARD_H = BOARD_H, FRAME_SECONDS = FRAME_SECONDS, pieceCells = pieceCells },
}
