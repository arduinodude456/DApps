--[[--
Geometry Dash for AppDock.

An offline E-Ink runner inspired by one-button rhythm platformers. The moving
playfield is redrawn directly into the active screen buffer and refreshed with
KOReader's fast waveform. UI chrome changes only on pause, retry, crash, or
completion; every moving frame is confined to the canvas region.

Version 1.1.1 fixes the KOReader gesture dispatch for the level editor. obstacles are placed on a snapped grid,
custom levels are stored atomically in the KOReader data directory and appear
next to the built-in levels in the level switcher.
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

-- Optional KOReader services. The level editor keeps working without them: when
-- the data directory or libkoreader-lfs is unavailable, saving reports a clear
-- error instead of failing silently, and the editor still supports live play.
local ok_datastorage, DataStorage = pcall(require, "datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then
    local ok_plain_lfs, plain_lfs = pcall(require, "lfs")
    if ok_plain_lfs then lfs = plain_lfs end
end
local ok_confirm, ConfirmBox = pcall(require, "ui/widget/confirmbox")
local ok_dialog, InputDialog = pcall(require, "ui/widget/inputdialog")

local Screen = Device.screen

local WORLD_W = 600
local WORLD_H = 360
local GROUND_Y = 306
local PLAYER_X = 86
local PLAYER_SIZE = 23
local GRAVITY = 1090
local JUMP_VELOCITY = -410
local PAD_VELOCITY = -510
local RUN_SPEED = 205
-- 20 Hz is a practical fast-waveform cadence: it is visibly smoother than the
-- original 12.5 Hz while remaining confined to the small game arena.
local FRAME_SECONDS = 0.05
local DEFAULT_LEVEL_LENGTH = 2250

-- Editor geometry. Spikes and pads snap to one 26-unit lane, blocks snap to the
-- 42-unit block module, so neighbouring placements never overlap by accident.
local EDITOR_SNAP = 26
local EDITOR_BLOCK_GRID = 42
local EDITOR_VIEW_WIDTH = 1040
local EDITOR_SCROLL_STEP = 520
local EDITOR_BLOCK_STEP = 26
local EDITOR_BLOCK_MIN = 26
local EDITOR_BLOCK_MAX = 130
local EDITOR_BLOCK_WIDTH = 42
local EDITOR_MIN_LENGTH = 780
local EDITOR_MAX_LENGTH = 7020
local EDITOR_LENGTH_STEP = 260
local EDITOR_MAX_OBJECTS = 420
local MAX_CUSTOM_LEVELS = 12

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
    level[#level + 1] = { kind = "block", x = x, y = GROUND_Y - height, w = width or EDITOR_BLOCK_WIDTH, h = height }
end

local function addPad(level, x)
    level[#level + 1] = { kind = "pad", x = x, y = GROUND_Y - 7, w = 34, h = 7 }
end

local function buildWarmup()
    local level = {}
    -- Generous approach lanes introduce jumping, landing, and pads one at a time.
    addSpike(level, 390, 1); addSpike(level, 590, 1); addBlock(level, 770, 36, 52)
    addSpike(level, 900, 1); addPad(level, 1060); addSpike(level, 1180, 1)
    addBlock(level, 1370, 48, 58); addSpike(level, 1510, 1)
    addPad(level, 1690); addBlock(level, 1820, 62, 64); addSpike(level, 1940, 1)
    addSpike(level, 2100, 1)
    return level
end

local function buildMeadow()
    local level = {}
    -- Gentle pairs and low platforms make timing forgiving without removing rhythm.
    addSpike(level, 360, 1); addSpike(level, 545, 2); addBlock(level, 730, 42, 52)
    addPad(level, 930); addSpike(level, 1040, 1); addBlock(level, 1210, 58, 58)
    addSpike(level, 1345, 1); addPad(level, 1510); addSpike(level, 1625, 2)
    addBlock(level, 1850, 46, 58); addBlock(level, 1980, 70, 64); addSpike(level, 2115, 1)
    addPad(level, 2280); addSpike(level, 2400, 2); addBlock(level, 2600, 82, 70)
    addSpike(level, 2760, 1); addPad(level, 2910)
    return level
end

local function buildSteps()
    local level = {}
    -- A longer level with clearly spaced stair patterns and no triple spikes.
    addSpike(level, 380, 1); addSpike(level, 550, 2); addBlock(level, 745, 40, 50)
    addPad(level, 920); addSpike(level, 1040, 1); addBlock(level, 1210, 54, 56)
    addSpike(level, 1340, 1); addBlock(level, 1500, 72, 60); addPad(level, 1650)
    addSpike(level, 1770, 2); addBlock(level, 1990, 38, 42); addBlock(level, 2050, 62, 42); addBlock(level, 2110, 86, 42)
    addSpike(level, 2230, 1); addPad(level, 2390); addSpike(level, 2510, 2)
    addBlock(level, 2730, 70, 74); addSpike(level, 2860, 1); addBlock(level, 3030, 98, 72)
    addPad(level, 3210); addSpike(level, 3340, 2); addBlock(level, 3540, 80, 70)
    addSpike(level, 3690, 1)
    return level
end

local function buildClassic()
    local level = {}
    -- The original marathon, softened with slower travel, lower platforms, and
    -- double (rather than triple) spike groups.
    addSpike(level, 360, 1); addSpike(level, 520, 2); addBlock(level, 690, 38, 44)
    addSpike(level, 790, 1); addPad(level, 915); addSpike(level, 1000, 2)
    addBlock(level, 1190, 48, 52); addSpike(level, 1260, 1)
    addBlock(level, 1370, 64, 58); addSpike(level, 1450, 2)
    addPad(level, 1585); addBlock(level, 1695, 82, 66); addSpike(level, 1782, 1)
    addSpike(level, 1900, 2); addPad(level, 2020); addSpike(level, 2120, 2)
    addBlock(level, 2240, 38, 38); addBlock(level, 2294, 58, 38); addBlock(level, 2348, 78, 38)
    addSpike(level, 2440, 2); addPad(level, 2545); addSpike(level, 2640, 2)
    addBlock(level, 2800, 62, 82); addSpike(level, 2898, 1)
    addBlock(level, 3030, 86, 70); addSpike(level, 3118, 2)
    addPad(level, 3240); addBlock(level, 3350, 104, 74); addSpike(level, 3440, 1)
    addSpike(level, 3580, 2); addPad(level, 3690); addSpike(level, 3780, 2)
    addBlock(level, 3910, 46, 46); addSpike(level, 3974, 1); addBlock(level, 4070, 72, 52)
    addPad(level, 4175); addSpike(level, 4265, 2); addBlock(level, 4380, 96, 64)
    addSpike(level, 4462, 1); addSpike(level, 4580, 2); addPad(level, 4705)
    addBlock(level, 4815, 58, 46); addBlock(level, 4877, 76, 46); addSpike(level, 4950, 2)
    addPad(level, 5070); addSpike(level, 5170, 1)
    return level
end

local LEVELS = {
    { id = "warmup", title = _("Warm-up"), length = 2250, objects = buildWarmup() },
    { id = "meadow", title = _("Meadow"), length = 3100, objects = buildMeadow() },
    { id = "steps", title = _("Steps"), length = 3950, objects = buildSteps() },
    { id = "classic", title = _("Classic"), length = 5350, objects = buildClassic() },
}
local BUILTIN_LEVEL_COUNT = #LEVELS

local TOOL_TITLES = {
    spike = _("Spike"),
    block = _("Block"),
    pad = _("Trampolin"),
    erase = _("Löschen"),
}
local TOOL_ORDER = { "spike", "block", "pad", "erase" }

local function levelFor(index)
    index = math.floor(tonumber(index) or 1)
    if index < 1 or index > #LEVELS then index = 1 end
    return LEVELS[index], index
end

local function buildLevel(index)
    return levelFor(index).objects
end

local function rectangleOverlap(left_a, top_a, width_a, height_a, left_b, top_b, width_b, height_b)
    return left_a < left_b + width_b and left_a + width_a > left_b and top_a < top_b + height_b and top_a + height_a > top_b
end

local function playerBounds(session)
    return PLAYER_X, session.player_y, PLAYER_SIZE, PLAYER_SIZE
end

local function nearbyObjects(session)
    local objects = {}
    local lower, upper = session.distance - 110, session.distance + WORLD_W + 110
    for _, object in ipairs(session.level.objects) do
        if object.x + object.w >= lower and object.x <= upper then objects[#objects + 1] = object end
    end
    return objects
end

-- Shared level drawing ---------------------------------------------------------

local function levelLayout(width, height, x, y, view_width)
    local view = view_width or WORLD_W
    local layout = { scale = math.max(0.1, math.min(width / view, height / WORLD_H)), view = view }
    layout.x = x + math.floor((width - view * layout.scale) / 2)
    layout.y = y + math.floor((height - WORLD_H * layout.scale) / 2)
    return layout
end

local function paintRect(bb, layout, world_x, world_y, width, height, ink)
    local left = math.floor(layout.x + world_x * layout.scale)
    local top = math.floor(layout.y + world_y * layout.scale)
    local draw_w = math.max(1, math.ceil(width * layout.scale))
    local draw_h = math.max(1, math.ceil(height * layout.scale))
    bb:paintRect(left, top, draw_w, draw_h, ink)
end

local function paintSpike(bb, layout, world_x, world_y, width, height)
    local steps = math.max(4, math.floor(width * layout.scale))
    for step = 0, steps - 1 do
        local progress = step / math.max(1, steps - 1)
        local slope = progress <= 0.5 and progress * 2 or (1 - progress) * 2
        local column_height = math.max(1, math.floor(height * slope * layout.scale))
        local left = math.floor(layout.x + world_x * layout.scale + step)
        local top = math.floor(layout.y + (world_y + height) * layout.scale - column_height)
        bb:paintRect(left, top, 1, column_height, Blitbuffer.COLOR_BLACK)
    end
end

local function paintObject(bb, layout, object, offset_x)
    local draw_x = object.x - offset_x
    if object.kind == "spike" then
        paintSpike(bb, layout, draw_x, object.y, object.w, object.h)
    elseif object.kind == "block" then
        paintRect(bb, layout, draw_x, object.y, object.w, object.h, Blitbuffer.COLOR_BLACK)
        paintRect(bb, layout, draw_x + 4, object.y + 4, object.w - 8, object.h - 8, Blitbuffer.COLOR_WHITE)
    elseif object.kind == "pad" then
        paintRect(bb, layout, draw_x, object.y, object.w, object.h, Blitbuffer.COLOR_DARK_GRAY)
        paintRect(bb, layout, draw_x + 4, object.y - 4, object.w - 8, 4, Blitbuffer.COLOR_BLACK)
    end
end

local function paintBackdrop(bb, layout)
    for line_y = 46, GROUND_Y - 26, 42 do paintRect(bb, layout, 0, line_y, layout.view, 1, Blitbuffer.COLOR_LIGHT_GRAY) end
    for line_x = 0, layout.view, 75 do paintRect(bb, layout, line_x, 0, 1, GROUND_Y, Blitbuffer.COLOR_LIGHT_GRAY) end
    paintRect(bb, layout, 0, GROUND_Y, layout.view, 5, Blitbuffer.COLOR_BLACK)
end

local function paintProgressBar(bb, layout, progress)
    paintRect(bb, layout, 18, 17, WORLD_W - 36, 5, Blitbuffer.COLOR_LIGHT_GRAY)
    paintRect(bb, layout, 18, 17, math.floor((WORLD_W - 36) * progress), 5, Blitbuffer.COLOR_BLACK)
end

-- Custom level storage ---------------------------------------------------------

local Store = {}

local function storeDirectory()
    if not ok_datastorage then return nil end
    return DataStorage:getDataDir() .. "/appdock_geometry_dash"
end

local function storeFile()
    local directory = storeDirectory()
    return directory and (directory .. "/levels.lua") or nil
end

local function ensureStoreDir()
    local directory = storeDirectory()
    if not directory then return false end
    if lfs and lfs.attributes and lfs.attributes(directory) then return true end
    if lfs and lfs.mkdir then
        local ok = pcall(lfs.mkdir, directory)
        return ok == true
    end
    return false
end

local function serialize(value, indent)
    indent = indent or ""
    local kind = type(value)
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "0" end
        return string.format("%d", math.floor(value))
    elseif kind == "string" then
        return string.format("%q", value)
    elseif kind ~= "table" then
        return "nil"
    end
    local inner = indent .. "  "
    local parts = { "{" }
    for index = 1, #value do
        parts[#parts + 1] = inner .. serialize(value[index], inner) .. ","
    end
    for key, item in pairs(value) do
        if type(key) == "string" then
            parts[#parts + 1] = inner .. "[" .. string.format("%q", key) .. "] = " .. serialize(item, inner) .. ","
        end
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end

local function sortObjects(objects)
    table.sort(objects, function(first, second)
        if first.x == second.x then return first.kind < second.kind end
        return first.x < second.x
    end)
end

local function validObject(raw)
    if type(raw) ~= "table" then return nil end
    local kind = raw.kind
    if kind ~= "spike" and kind ~= "block" and kind ~= "pad" then return nil end
    local x = tonumber(raw.x)
    if not x or x ~= x then return nil end
    x = clamp(math.floor(x / EDITOR_SNAP + 0.5) * EDITOR_SNAP, 0, EDITOR_MAX_LENGTH)
    if kind == "block" then
        local height = clamp(math.floor(tonumber(raw.h) or EDITOR_BLOCK_MIN), EDITOR_BLOCK_MIN, EDITOR_BLOCK_MAX)
        return { kind = "block", x = x, y = GROUND_Y - height, w = EDITOR_BLOCK_WIDTH, h = height }
    elseif kind == "pad" then
        return { kind = "pad", x = x, y = GROUND_Y - 7, w = 34, h = 7 }
    end
    return { kind = "spike", x = x, y = GROUND_Y - 30, w = 25, h = 30 }
end

local function validLevel(raw, fallback_id)
    if type(raw) ~= "table" then return nil end
    local objects = {}
    if type(raw.objects) == "table" then
        for _, item in ipairs(raw.objects) do
            if #objects >= EDITOR_MAX_OBJECTS then break end
            local clean = validObject(item)
            if clean then objects[#objects + 1] = clean end
        end
    end
    if #objects == 0 then return nil end
    sortObjects(objects)
    local title = tostring(raw.title or ""):gsub("[\r\n\t]", " "):sub(1, 40)
    if title == "" then title = _("Eigene Ebene") end
    local id = tostring(raw.id or "")
    if not id:match("^[%w_%-]+$") then id = fallback_id end
    return {
        id = id,
        title = title,
        length = clamp(math.floor(tonumber(raw.length) or DEFAULT_LEVEL_LENGTH), EDITOR_MIN_LENGTH, EDITOR_MAX_LENGTH),
        objects = objects,
        custom = true,
    }
end

function Store.load()
    local file_path = storeFile()
    if not file_path then return {} end
    local chunk = loadfile(file_path)
    if not chunk then return {} end
    setfenv(chunk, {})
    local ok, loaded = pcall(chunk)
    if not ok or type(loaded) ~= "table" or tonumber(loaded.version) ~= 1 then return {} end
    local levels = {}
    if type(loaded.levels) == "table" then
        for index, raw in ipairs(loaded.levels) do
            if #levels >= MAX_CUSTOM_LEVELS then break end
            local clean = validLevel(raw, "custom-" .. tostring(index))
            if clean then levels[#levels + 1] = clean end
        end
    end
    return levels
end

function Store.save(levels)
    local file_path = storeFile()
    if not file_path then return nil, _("Speichern ist ohne KOReader-Datenverzeichnis nicht möglich.") end
    if not ensureStoreDir() then return nil, _("Der Editor-Ordner konnte nicht angelegt werden.") end
    local payload = { version = 1, levels = {} }
    for index, level in ipairs(levels or {}) do
        if #payload.levels >= MAX_CUSTOM_LEVELS then break end
        local clean = validLevel(level, "custom-" .. tostring(index))
        if clean then clean.id = "custom-" .. tostring(index); payload.levels[#payload.levels + 1] = clean end
    end
    local temporary = file_path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err or _("Der Editor-Ordner ist nicht beschreibbar.") end
    local ok, write_err = file:write("return " .. serialize(payload) .. "\n")
    file:close()
    if not ok then os.remove(temporary); return nil, write_err end
    local renamed, rename_err = os.rename(temporary, file_path)
    if not renamed then os.remove(temporary); return nil, rename_err end
    return true
end

local function registerCustomLevels(levels)
    for index = #LEVELS, 1, -1 do
        if LEVELS[index].custom then table.remove(LEVELS, index) end
    end
    for _, level in ipairs(levels or {}) do
        if #LEVELS - BUILTIN_LEVEL_COUNT < MAX_CUSTOM_LEVELS then LEVELS[#LEVELS + 1] = level end
    end
    return LEVELS
end

local function levelIndexById(id)
    for index, level in ipairs(LEVELS) do
        if level.id == id then return index end
    end
    return nil
end

-- Level editor -----------------------------------------------------------------

local Editor = {}

function Editor.snapLane(world_x)
    return math.max(0, math.floor((tonumber(world_x) or 0) / EDITOR_SNAP + 0.5) * EDITOR_SNAP)
end

function Editor.snapBlock(world_x)
    return math.max(0, math.floor((tonumber(world_x) or 0) / EDITOR_BLOCK_GRID) * EDITOR_BLOCK_GRID)
end

function Editor.clampLength(value)
    return math.floor(clamp(tonumber(value) or DEFAULT_LEVEL_LENGTH, EDITOR_MIN_LENGTH, EDITOR_MAX_LENGTH))
end

function Editor.newDraft(title)
    return {
        id = nil,
        title = title or _("Eigene Ebene"),
        length = Editor.clampLength(DEFAULT_LEVEL_LENGTH),
        objects = {},
        custom = true,
    }
end

function Editor.findAt(draft, tool, world_x)
    if not draft then return nil end
    local lane, module = Editor.snapLane(world_x), Editor.snapBlock(world_x)
    for index, object in ipairs(draft.objects) do
        local matches = (tool == nil or tool == object.kind)
        if matches then
            if object.kind == "block" and module == object.x then return index end
            if object.kind ~= "block" and lane == object.x then return index end
        end
    end
    return nil
end

function Editor.apply(draft, tool, world_x)
    if not draft then return "none" end
    if tool == "erase" then
        local index = Editor.findAt(draft, nil, world_x)
        if not index then return "none" end
        table.remove(draft.objects, index)
        return "removed"
    end
    if tool == "block" then
        local index = Editor.findAt(draft, "block", world_x)
        if index then
            local block = draft.objects[index]
            if block.h >= EDITOR_BLOCK_MAX then return "limit" end
            block.h = math.min(EDITOR_BLOCK_MAX, block.h + EDITOR_BLOCK_STEP)
            block.y = GROUND_Y - block.h
            return "raised"
        end
        if #draft.objects >= EDITOR_MAX_OBJECTS then return "full" end
        local height = EDITOR_BLOCK_STEP * 2
        draft.objects[#draft.objects + 1] = { kind = "block", x = Editor.snapBlock(world_x), y = GROUND_Y - height, w = EDITOR_BLOCK_WIDTH, h = height }
        sortObjects(draft.objects)
        return "placed"
    end
    local kind = tool == "pad" and "pad" or "spike"
    local index = Editor.findAt(draft, kind, world_x)
    if index then
        table.remove(draft.objects, index)
        return "removed"
    end
    if #draft.objects >= EDITOR_MAX_OBJECTS then return "full" end
    if kind == "pad" then
        addPad(draft.objects, Editor.snapLane(world_x))
    else
        addSpike(draft.objects, Editor.snapLane(world_x), 1)
    end
    sortObjects(draft.objects)
    return "placed"
end

function Editor.scrollLimit(draft)
    if not draft then return 0 end
    return math.max(0, draft.length - EDITOR_VIEW_WIDTH + 200)
end

function Editor.clampScroll(draft, value)
    return math.floor(clamp(tonumber(value) or 0, 0, Editor.scrollLimit(draft)))
end

function Editor.messageFor(action, editor)
    local tool = TOOL_TITLES[(editor and editor.tool) or "spike"] or ""
    if action == "placed" then return string.format(_("%s gesetzt."), tool) end
    if action == "raised" then return _("Block erhöht.") end
    if action == "removed" then return _("Objekt entfernt.") end
    if action == "full" then return string.format(_("Maximal %d Objekte pro Ebene."), EDITOR_MAX_OBJECTS) end
    if action == "limit" then return _("Dieser Block ist bereits maximal hoch.") end
    return _("Kein Objekt an dieser Stelle.")
end

-- Game session -----------------------------------------------------------------

local GameSession = {}
GameSession.__index = GameSession

function GameSession.new(on_event, level_index)
    local level, index = levelFor(level_index)
    local self = setmetatable({ canvas = nil, paused = true, over = false, complete = false, distance = 0, player_y = GROUND_Y - PLAYER_SIZE, velocity_y = 0, grounded = true, pad_latch = {}, frames = 0, on_event = on_event, level = level, level_index = index }, GameSession)
    self._tick = function() self:tick() end
    return self
end

function GameSession:setCanvas(canvas)
    self.canvas = canvas
    if canvas then canvas.session = self end
end

function GameSession:setLevel(index)
    local level, normalized = levelFor(index)
    self.level, self.level_index = level, normalized
    self:reset()
    self:emit("level", string.format(_("%s selected — tap Play when ready."), level.title))
    return level
end

function GameSession:nextLevel()
    return self:setLevel((self.level_index % #LEVELS) + 1)
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
    self:emit("complete", string.format(_("%s complete! Choose the next level or tap Retry."), self.level.title))
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
    if self.distance >= self.level.length then self:finish(); return false end
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

function ArenaCanvas:paintTo(bb, x, y)
    -- OverlapGroup positions the arena below the host chrome. Keep the tap
    -- hitbox in that same local rectangle; otherwise its default 0,0 range
    -- overlaps AppDock's close control and turns Close into a jump.
    local range = self.ges_events.TapGeometryDashJump[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    self._origin_x, self._origin_y = x, y
    local layout = levelLayout(self.width, self.height, x, y)
    self._scale, self._draw_x, self._draw_y = layout.scale, layout.x, layout.y
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local session = self.session
    if not session then return end
    -- Quiet geometric backdrop: meaningful motion stays in the lower arena.
    paintBackdrop(bb, layout)
    for _, object in ipairs(nearbyObjects(session)) do paintObject(bb, layout, object, session.distance) end
    paintRect(bb, layout, PLAYER_X, session.player_y, PLAYER_SIZE, PLAYER_SIZE, session.over and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK)
    paintRect(bb, layout, PLAYER_X + 5, session.player_y + 5, PLAYER_SIZE - 10, PLAYER_SIZE - 10, Blitbuffer.COLOR_WHITE)
    paintRect(bb, layout, PLAYER_X + 8, session.player_y + 8, 4, 4, Blitbuffer.COLOR_BLACK)
    paintRect(bb, layout, PLAYER_X + 15, session.player_y + 8, 4, 4, Blitbuffer.COLOR_BLACK)
    paintProgressBar(bb, layout, clamp(session.distance / session.level.length, 0, 1))
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

-- Editor canvas ----------------------------------------------------------------

local EditorCanvas = InputContainer:extend{
    editor = nil,
    width = nil,
    height = nil,
    dimen = nil,
    on_change = nil,
    _origin_x = 0,
    _origin_y = 0,
    _layout = nil,
}

function EditorCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapGeometryDashEditor = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function EditorCanvas:layoutAt(x, y)
    self._layout = levelLayout(self.width, self.height, x, y, EDITOR_VIEW_WIDTH)
    return self._layout
end

function EditorCanvas:worldXAt(screen_x)
    local layout = self._layout or self:layoutAt(self._origin_x, self._origin_y)
    local scroll = (self.editor and self.editor.scroll) or 0
    return scroll + (screen_x - layout.x) / layout.scale
end

function EditorCanvas:paintTo(bb, x, y)
    local range = self.ges_events.TapGeometryDashEditor[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    self._origin_x, self._origin_y = x, y
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local editor = self.editor
    if not editor or not editor.draft then return end
    local layout = self:layoutAt(x, y)
    local draft = editor.draft
    paintBackdrop(bb, layout)
    -- Vertical editor grid: one line every two spike lanes for readability.
    for line_x = 0, layout.view, EDITOR_SNAP * 2 do
        paintRect(bb, layout, line_x, 0, 1, GROUND_Y, Blitbuffer.COLOR_LIGHT_GRAY)
    end
    -- Start marker and finish flag keep the editable level length visible.
    paintRect(bb, layout, 0, GROUND_Y - 46, 3, 46, Blitbuffer.COLOR_BLACK)
    paintRect(bb, layout, 4, GROUND_Y - 46, 12, 5, Blitbuffer.COLOR_BLACK)
    local finish_x = draft.length - editor.scroll
    paintRect(bb, layout, finish_x, GROUND_Y - 62, 2, 62, Blitbuffer.COLOR_BLACK)
    for row = 0, 5 do
        for column = 0, 3 do
            if (row + column) % 2 == 0 then
                paintRect(bb, layout, finish_x + 2 + column * 10, GROUND_Y - 60 + row * 10, 9, 9, Blitbuffer.COLOR_BLACK)
            end
        end
    end
    for _, object in ipairs(draft.objects) do paintObject(bb, layout, object, editor.scroll) end
    -- Scroll position of the editor viewport.
    local limit = Editor.scrollLimit(draft)
    local fraction = limit > 0 and clamp(editor.scroll / limit, 0, 1) or 0
    paintRect(bb, layout, 18, 17, WORLD_W - 36, 5, Blitbuffer.COLOR_LIGHT_GRAY)
    paintRect(bb, layout, 18, 17, math.floor((WORLD_W - 36) * fraction), 5, Blitbuffer.COLOR_BLACK)
end

function EditorCanvas:refreshFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "fast", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    if UIManager.yieldToEPDC then UIManager:yieldToEPDC() end
    return true
end

function EditorCanvas:onTapGeometryDashEditor(first, second)
    -- KOReader dispatches gesture callbacks as (event_arg, gesture). Keep
    -- the one-argument form too, because the editor is also exercised directly
    -- by tests and by lightweight hosts.
    local gesture = second or first
    local editor = self.editor
    if not editor or not editor.draft or not gesture or not gesture.pos then return true end
    local action = Editor.apply(editor.draft, editor.tool, self:worldXAt(gesture.pos.x))
    editor.message = Editor.messageFor(action, editor)
    if self.on_change then self.on_change(editor, action) end
    self:refreshFast()
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

-- DApp state and editor actions -------------------------------------------------

local function stateFor(instance, context)
    if instance.geometry_dash then return instance.geometry_dash end
    local state = { status = _("Ready — tap the arena or press Play."), session = nil, custom_levels = Store.load(), editor = nil, notice = nil }
    registerCustomLevels(state.custom_levels)
    state.session = GameSession.new(function(kind, message)
        state.status = message
        if context and context.requestRebuild and (kind == "crash" or kind == "complete" or kind == "paused" or kind == "ready") then context.requestRebuild("ui") end
    end)
    instance.geometry_dash = state
    return state
end

local function persistCustomLevels(state, context)
    local ok, err = Store.save(state.custom_levels)
    state.notice = ok and string.format(_("%d eigene Ebene(n) in %s"), #state.custom_levels, "appdock_geometry_dash") or (err or _("Speichern fehlgeschlagen."))
    if context and context.requestRebuild then context.requestRebuild("ui") end
    return ok
end

local function openEditor(state, context, draft)
    state.editor = state.editor or { tool = "spike", scroll = 0, draft = nil, message = nil }
    state.editor.draft = draft or Editor.newDraft()
    state.editor.scroll = 0
    state.editor.open = true
    state.editor.message = _("Tippen setzt oder entfernt Objekte.")
    state.notice = nil
    if context and context.requestRebuild then context.requestRebuild("ui") end
    return state.editor
end

local function currentCustomDraft(state)
    local current = state.session and state.session.level
    if current and current.custom and current.objects then
        local draft = Editor.newDraft(current.title)
        draft.id = current.id
        draft.length = Editor.clampLength(current.length)
        for _, object in ipairs(current.objects) do
            draft.objects[#draft.objects + 1] = { kind = object.kind, x = object.x, y = object.y, w = object.w, h = object.h }
        end
        return draft
    end
    return nil
end

local function upsertCustomLevel(state, draft)
    local clean = validLevel(draft, "custom-1")
    if not clean then return nil, _("Diese Ebene enthält noch keine Objekte.") end
    if draft.id then
        for index, level in ipairs(state.custom_levels) do
            if level.id == draft.id then
                clean.id = draft.id
                state.custom_levels[index] = clean
                registerCustomLevels(state.custom_levels)
                return clean
            end
        end
    end
    if #state.custom_levels >= MAX_CUSTOM_LEVELS then
        return nil, string.format(_("Maximal %d eigene Ebenen."), MAX_CUSTOM_LEVELS)
    end
    clean.id = "custom-" .. tostring(#state.custom_levels + 1)
    state.custom_levels[#state.custom_levels + 1] = clean
    registerCustomLevels(state.custom_levels)
    return clean
end

local function playDraft(state, context, draft)
    local clean, err = upsertCustomLevel(state, draft)
    if not clean then
        if state.editor then state.editor.message = err end
        if context and context.requestRebuild then context.requestRebuild("ui") end
        return nil, err
    end
    draft.id = clean.id
    local index = levelIndexById(clean.id)
    if not index then return nil, _("Ebene konnte nicht geladen werden.") end
    state.editor.open = false
    state.session:setLevel(index)
    state.status = string.format(_("%s — tap Play when ready."), clean.title)
    Store.save(state.custom_levels)
    if context and context.requestRebuild then context.requestRebuild("ui") end
    return index
end

local function clearDraft(state, context)
    local previous = state.editor and state.editor.draft
    state.editor.draft = Editor.newDraft(previous and previous.title)
    state.editor.scroll = 0
    state.editor.message = _("Ebene geleert.")
    if context and context.requestRebuild then context.requestRebuild("ui") end
    return state.editor.draft
end

local function promptClearDraft(state, context)
    if ok_confirm and ConfirmBox then
        local dialog
        dialog = ConfirmBox:new{
            text = _("Alle Objekte dieser Ebene entfernen?"),
            ok_text = _("Leeren"),
            ok_callback = function() UIManager:close(dialog); clearDraft(state, context) end,
        }
        UIManager:show(dialog)
        return true
    end
    clearDraft(state, context)
    return true
end

local function promptEditTitle(state, context)
    if not (ok_dialog and InputDialog) then return false end
    local dialog
    dialog = InputDialog:new{
        title = _("Ebenenname"),
        input = state.editor.draft.title or "",
        buttons = {
            {
                { text = _("Abbrechen"), callback = function() UIManager:close(dialog) end },
                { text = _("Übernehmen"), is_enter_default = true, callback = function()
                    local title = dialog:getInputText():gsub("[\r\n\t]", " "):sub(1, 40)
                    if title ~= "" then state.editor.draft.title = title end
                    UIManager:close(dialog)
                    if context and context.requestRebuild then context.requestRebuild("ui") end
                end },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return true
end

-- Pane building -----------------------------------------------------------------

local function buildGamePane(state, context, pane, width, height, px)
    local margin, gap = px(10), px(7)
    local header_h, controls_h = px(42), px(34)
    local arena_h = math.max(px(118), height - header_h - controls_h - px(42))
    local arena_y = header_h
    local arena = ArenaCanvas:new{ width = width - 2 * margin, height = arena_h, session = state.session }
    state.session:setCanvas(arena)
    local button_w = math.floor((width - 2 * margin - 3 * gap) / 4)
    local play_title = (state.session.over or state.session.complete) and _("Retry") or (state.session.paused and _("Play") or _("Pause"))
    local level = state.session.level
    local level_info = (level.custom and string.format(_("%d Objekte"), #level.objects) or _("Original")) .. " · " .. string.format(_("%d/%d"), state.session.level_index, #LEVELS)
    local layers = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = "GEOMETRY DASH", face = Font:getFace("cfont", px(19)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, px(7) } },
        TextWidget:new{ text = level.title .. " · " .. level_info, face = Font:getFace("smallinfofont", px(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = math.floor(width * .52), overlap_offset = { margin, px(30) } },
        TextWidget:new{ text = string.format("%d%%", math.floor(clamp(state.session.distance / level.length, 0, 1) * 100)), face = Font:getFace("smallinfofont", px(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = px(58), overlap_offset = { width - margin - px(58), px(13) } },
        arena,
        GameButton:new{ title = play_title, primary = true, width = button_w, height = controls_h, callback = function()
            if state.session.over or state.session.complete then state.session:reset(); context.requestRebuild("ui")
            elseif state.session.paused then state.session:start(); context.requestRebuild("ui")
            else state.session:pause() end
        end, overlap_offset = { margin, arena_y + arena_h + gap } },
        GameButton:new{ title = _("Neustart"), width = button_w, height = controls_h, callback = function() state.session:reset(); context.requestRebuild("ui") end, overlap_offset = { margin + button_w + gap, arena_y + arena_h + gap } },
        GameButton:new{ title = _("Nächste Ebene"), width = button_w, height = controls_h, callback = function() state.session:nextLevel(); context.requestRebuild("ui") end, overlap_offset = { margin + 2 * (button_w + gap), arena_y + arena_h + gap } },
        GameButton:new{ title = _("Editor"), width = button_w, height = controls_h, callback = function()
            state.session:pause()
            openEditor(state, context, currentCustomDraft(state))
        end, overlap_offset = { margin + 3 * (button_w + gap), arena_y + arena_h + gap } },
        TextWidget:new{ text = state.notice or state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - px(16) } },
    }
    arena.overlap_offset = { margin, arena_y }
    pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, unpack(layers) }
    return pane
end

local function buildEditorPane(state, context, pane, width, height, px)
    local editor = state.editor
    local draft = editor.draft
    local margin, gap = px(10), px(6)
    local header_h, row_h = px(42), px(32)
    local canvas_h = math.max(px(120), height - header_h - 3 * row_h - px(40))
    local canvas_w = width - 2 * margin
    local canvas = EditorCanvas:new{ width = canvas_w, height = canvas_h, editor = editor, on_change = function(_, action)
        if action ~= "none" then state.notice = nil end
    end }
    editor.canvas = canvas
    local tool_w = math.floor((width - 2 * margin - 3 * gap) / 4)
    local action_w = math.floor((width - 2 * margin - 4 * gap) / 5)
    local palette_y = header_h + canvas_h + gap
    local scroll_y = palette_y + row_h + gap
    local action_y = scroll_y + row_h + gap
    local layers = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = "LEVEL EDITOR", face = Font:getFace("cfont", px(19)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, px(7) } },
        TextWidget:new{ text = string.format("%s · %d Objekte · Länge %d", draft.title or _("Eigene Ebene"), #draft.objects, draft.length), face = Font:getFace("smallinfofont", px(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, px(30) } },
        canvas,
    }
    for index, tool in ipairs(TOOL_ORDER) do
        layers[#layers + 1] = GameButton:new{ title = TOOL_TITLES[tool], primary = editor.tool == tool, width = tool_w, height = row_h, callback = function()
            editor.tool = tool
            editor.message = string.format(_("Werkzeug: %s"), TOOL_TITLES[tool])
            context.requestRebuild("ui")
        end, overlap_offset = { margin + (index - 1) * (tool_w + gap), palette_y } }
    end
    layers[#layers + 1] = GameButton:new{ title = _("◀ zurück"), width = tool_w, height = row_h, callback = function()
        editor.scroll = Editor.clampScroll(draft, editor.scroll - EDITOR_SCROLL_STEP)
        editor.message = string.format(_("Ansicht bei %d"), editor.scroll)
        canvas:refreshFast()
        context.requestRebuild("ui")
    end, overlap_offset = { margin, scroll_y } }
    layers[#layers + 1] = GameButton:new{ title = _("vor ▶"), width = tool_w, height = row_h, callback = function()
        editor.scroll = Editor.clampScroll(draft, editor.scroll + EDITOR_SCROLL_STEP)
        editor.message = string.format(_("Ansicht bei %d"), editor.scroll)
        canvas:refreshFast()
        context.requestRebuild("ui")
    end, overlap_offset = { margin + tool_w + gap, scroll_y } }
    layers[#layers + 1] = GameButton:new{ title = _("Länge −"), width = tool_w, height = row_h, callback = function()
        draft.length = Editor.clampLength(draft.length - EDITOR_LENGTH_STEP)
        editor.scroll = Editor.clampScroll(draft, editor.scroll)
        context.requestRebuild("ui")
    end, overlap_offset = { margin + 2 * (tool_w + gap), scroll_y } }
    layers[#layers + 1] = GameButton:new{ title = _("Länge +"), width = tool_w, height = row_h, callback = function()
        draft.length = Editor.clampLength(draft.length + EDITOR_LENGTH_STEP)
        context.requestRebuild("ui")
    end, overlap_offset = { margin + 3 * (tool_w + gap), scroll_y } }
    layers[#layers + 1] = GameButton:new{ title = _("Neu"), width = action_w, height = row_h, callback = function() promptClearDraft(state, context) end, overlap_offset = { margin, action_y } }
    layers[#layers + 1] = GameButton:new{ title = _("Name"), width = action_w, height = row_h, callback = function() promptEditTitle(state, context) end, overlap_offset = { margin + (action_w + gap), action_y } }
    layers[#layers + 1] = GameButton:new{ title = _("Speichern"), width = action_w, height = row_h, callback = function()
        local ok, err = upsertCustomLevel(state, draft)
        if ok then
            draft.id = ok.id
            persistCustomLevels(state, context)
        else
            editor.message = err
            context.requestRebuild("ui")
        end
    end, overlap_offset = { margin + 2 * (action_w + gap), action_y } }
    layers[#layers + 1] = GameButton:new{ title = _("Spielen"), primary = true, width = action_w, height = row_h, callback = function() playDraft(state, context, draft) end, overlap_offset = { margin + 3 * (action_w + gap), action_y } }
    layers[#layers + 1] = GameButton:new{ title = _("Zurück"), width = action_w, height = row_h, callback = function()
        editor.open = false
        context.requestRebuild("ui")
    end, overlap_offset = { margin + 4 * (action_w + gap), action_y } }
    layers[#layers + 1] = TextWidget:new{ text = editor.message or _("Tippen setzt oder entfernt Objekte."), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - px(14) } }
    canvas.overlap_offset = { margin, header_h }
    pane[1] = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false, unpack(layers) }
    return pane
end

return {
    id = "geometry_dash",
    version = "1.1.1",
    title = "Geometry Dash",
    subtitle = "Fast-refresh obstacle runner mit Leveleditor",
    symbol = "G",
    logo = "other",
    buildPane = function(instance, context)
        local state = stateFor(instance, context)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or scale
        local pane = GamePane:new{ dimen = Geom:new{ w = width, h = height }, session = state.session }
        function pane:onDeactivate()
            if state.session then state.session:pause() end
        end
        pane.key_events = {}
        local groups = Device.input and Device.input.group or {}
        if groups.Press then pane.key_events.GeometryDashJump = { { groups.Press }, event = "GeometryDashJump" } end
        if groups.Select then pane.key_events.GeometryDashJumpSelect = { { groups.Select }, event = "GeometryDashJump" } end
        if groups.Back then pane.key_events.GeometryDashPause = { { groups.Back }, event = "GeometryDashPause" } end
        if state.editor and state.editor.open then
            return buildEditorPane(state, context, pane, width, height, px)
        end
        return buildGamePane(state, context, pane, width, height, px)
    end,
    onClose = function(instance)
        local state = instance and instance.geometry_dash
        if state and state.session then state.session:pause() end
    end,
    _test = {
        GameSession = GameSession,
        GameButton = GameButton,
        EditorCanvas = EditorCanvas,
        ArenaCanvas = ArenaCanvas,
        Editor = Editor,
        Store = Store,
        levelLayout = levelLayout,
        paintObject = paintObject,
        buildLevel = buildLevel,
        levels = LEVELS,
        levelFor = levelFor,
        levelIndexById = levelIndexById,
        rectangleOverlap = rectangleOverlap,
        registerCustomLevels = registerCustomLevels,
        stateFor = stateFor,
        openEditor = openEditor,
        currentCustomDraft = currentCustomDraft,
        upsertCustomLevel = upsertCustomLevel,
        playDraft = playDraft,
        clearDraft = clearDraft,
        validLevel = validLevel,
        validObject = validObject,
        serialize = serialize,
        builtinLevelCount = BUILTIN_LEVEL_COUNT,
        defaultLevelLength = DEFAULT_LEVEL_LENGTH,
        runSpeed = RUN_SPEED,
        frameSeconds = FRAME_SECONDS,
        groundY = GROUND_Y,
        worldWidth = WORLD_W,
        editorSnap = EDITOR_SNAP,
        editorBlockGrid = EDITOR_BLOCK_GRID,
        editorViewWidth = EDITOR_VIEW_WIDTH,
        editorScrollStep = EDITOR_SCROLL_STEP,
        editorBlockStep = EDITOR_BLOCK_STEP,
        editorBlockMax = EDITOR_BLOCK_MAX,
        editorMinLength = EDITOR_MIN_LENGTH,
        editorMaxLength = EDITOR_MAX_LENGTH,
        editorLengthStep = EDITOR_LENGTH_STEP,
        editorMaxObjects = EDITOR_MAX_OBJECTS,
        maxCustomLevels = MAX_CUSTOM_LEVELS,
        toolTitles = TOOL_TITLES,
        toolOrder = TOOL_ORDER,
    },
}
