-- BWR Video: a compact AppDock DApp for pre-dithered BWR1 E-Ink video.
-- Local BWR1 frames are rendered directly; optional WAV audio follows the
-- system's current output route, including an already paired Bluetooth device.

local bit = require("bit")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen
local HEADER_SIZE = 32
local MAX_FRAME_BYTES = 8 * 1024 * 1024
local MAX_FRAME_COUNT = 500000

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function trim(value) return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or "" end
local function basename(path) return (path or ""):match("([^/]+)$") or path or "" end
local function empty(width, height) return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } } end

local function commandPath(name)
    local pipe = io.popen("command -v " .. name .. " 2>/dev/null", "r")
    if not pipe then return nil end
    local value = pipe:read("*l")
    pipe:close()
    return value and value ~= "" and value or nil
end

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function u16(data, index)
    local a, b = data:byte(index, index + 1)
    return a and b and a + b * 256 or nil
end

local function u32(data, index)
    local a, b, c, d = data:byte(index, index + 3)
    return a and b and c and d and a + b * 256 + c * 65536 + d * 16777216 or nil
end

local function parseBWR(handle)
    local data = handle:read(HEADER_SIZE)
    if not data or #data ~= HEADER_SIZE or data:sub(1, 4) ~= "BWR1" then return nil, _("Not a valid BWR1 video file.") end
    local header = {
        version = data:byte(5), format = data:byte(6), width = u16(data, 7), height = u16(data, 9),
        fps100 = u16(data, 11), frames = u32(data, 13), bytes = u32(data, 17),
    }
    if header.version ~= 1 or header.format ~= 1 then return nil, _("Unsupported BWR1 version or pixel format.") end
    if not header.width or not header.height or header.width < 8 or header.width % 8 ~= 0 then return nil, _("Invalid BWR1 dimensions.") end
    if not header.fps100 or header.fps100 < 1 or not header.frames or header.frames < 1 or header.frames > MAX_FRAME_COUNT then return nil, _("Invalid BWR1 timing or frame count.") end
    if not header.bytes or header.bytes ~= header.width / 8 * header.height or header.bytes > MAX_FRAME_BYTES then return nil, _("Invalid BWR1 frame size.") end
    return header
end

local first, second = {}, {}
local function spread(nibble)
    local word = 0
    for pixel = 0, 3 do
        if bit.band(nibble, bit.rshift(0x08, pixel)) ~= 0 then word = bit.bor(word, bit.lshift(0xFF, pixel * 8)) end
    end
    return word
end
for value = 0, 255 do
    first[value], second[value] = spread(bit.rshift(value, 4)), spread(bit.band(value, 0x0F))
end

local function nowSeconds()
    local good, Time = pcall(require, "ui/time")
    if good and Time and Time.now and Time.to_s then
        local converted, value = pcall(function() return Time.to_s(Time.now()) end)
        if converted and type(value) == "number" then return value end
    end
    return os.time()
end

local AudioOut = {}
AudioOut.__index = AudioOut
function AudioOut.new(path)
    return setmetatable({ path = path, bin = commandPath("aplay") or commandPath("tinyplay"), pid = nil }, AudioOut)
end
function AudioOut:start()
    if not self.bin or not self.path then return true end
    local input = io.open(self.path, "rb")
    if not input then return nil, _("Companion WAV file cannot be opened.") end
    input:close()
    self:stop()
    local pipe = io.popen(quote(self.bin) .. " " .. quote(self.path) .. " >/dev/null 2>&1 & echo $!", "r")
    if not pipe then return nil, _("Audio process could not start.") end
    self.pid = tonumber(pipe:read("*l")); pipe:close()
    return self.pid and true or nil, self.pid and nil or _("Audio process returned no identifier.")
end
function AudioOut:stop()
    if self.pid then os.execute("kill -TERM " .. tostring(self.pid) .. " 2>/dev/null"); self.pid = nil end
end

local Canvas = InputContainer:extend{ engine = nil, width = nil, height = nil, dimen = nil, origin_x = 0, origin_y = 0 }
function Canvas:init() self.dimen = Geom:new{ w = self.width, h = self.height } end
function Canvas:paintTo(bb, x, y)
    self.origin_x, self.origin_y = x, y
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local engine = self.engine
    if not engine or not engine.frame then return end
    local draw_w, draw_h = math.min(self.width, engine.header.width), math.min(self.height, engine.header.height)
    local source_x, source_y = math.max(0, math.floor((engine.header.width - draw_w) / 2)), math.max(0, math.floor((engine.header.height - draw_h) / 2))
    local target_x, target_y = x + math.max(0, math.floor((self.width - draw_w) / 2)), y + math.max(0, math.floor((self.height - draw_h) / 2))
    bb:blitFrom(engine.frame, target_x, target_y, source_x, source_y, draw_w, draw_h)
end
function Canvas:updateFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self.origin_x, self.origin_y)
    UIManager:setDirty(nil, "fast", Geom:new{ x = self.origin_x, y = self.origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    if UIManager.yieldToEPDC then UIManager:yieldToEPDC() end
    return true
end

local Engine = {}
Engine.__index = Engine
function Engine.open(video_path, wav_path, report)
    local handle = io.open(video_path, "rb")
    local self = setmetatable({ handle = handle, path = video_path, wav_path = wav_path, report = report, paused = true, closed = false, frame = nil, index = -1, position = 0, start_wall = nil, start_position = 0, canvas = nil }, Engine)
    if not handle then self.error = _("BWR1 file cannot be opened."); return self end
    self.header, self.error = parseBWR(handle)
    if not self.header then handle:close(); self.handle = nil; return self end
    self.fps, self.duration = self.header.fps100 / 100, self.header.frames / (self.header.fps100 / 100)
    self.interval = math.max(0.10, 1 / self.fps)
    self.audio = wav_path and AudioOut.new(wav_path) or nil
    self.tick = function() self:step() end
    return self
end
function Engine:setCanvas(canvas) self.canvas = canvas; if canvas then canvas.engine = self end end
function Engine:status(message) if self.report then self.report(message) end end
function Engine:currentTime()
    if not self.start_wall then return self.position end
    return clamp(self.start_position + math.max(0, nowSeconds() - self.start_wall), 0, self.duration)
end
function Engine:read(index)
    if not self.handle or index < 0 or index >= self.header.frames then return nil, _("Frame is outside the BWR1 file.") end
    self.handle:seek("set", HEADER_SIZE + index * self.header.bytes)
    local raw = self.handle:read(self.header.bytes)
    if not raw or #raw ~= self.header.bytes then return nil, _("Cannot read BWR1 frame.") end
    return raw
end
function Engine:show(position)
    local index = clamp(math.floor(position * self.fps), 0, self.header.frames - 1)
    if index ~= self.index or not self.frame then
        local raw, err = self:read(index)
        if not raw then return nil, err end
        local bb = Blitbuffer.new(self.header.width, self.header.height, Blitbuffer.TYPE_BB8)
        local words = require("ffi").cast("uint32_t*", bb.data)
        local at = 0
        for byte = 1, #raw do
            local value = raw:byte(byte)
            words[at], words[at + 1], at = first[value], second[value], at + 2
        end
        if self.frame then self.frame:free() end
        self.frame, self.index = bb, index
    end
    if self.canvas then self.canvas:updateFast() end
    return true
end
function Engine:play()
    if self.error then return nil, self.error end
    if self.audio then
        local ok, err = self.audio:start()
        if not ok then return nil, err end
        self:status(_("Audio uses the current system route, including a paired Bluetooth device."))
    else
        self:status(_("Playing BWR1 video without companion audio."))
    end
    self.start_position, self.start_wall, self.paused = self.position, nowSeconds(), false
    local ok, err = self:show(self.position)
    if not ok then self.paused = true; return nil, err end
    UIManager:unschedule(self.tick); UIManager:scheduleIn(self.interval, self.tick)
    return true
end
function Engine:pause()
    if self.paused then return end
    self.position = self:currentTime(); self.start_wall, self.paused = nil, true
    if self.audio then self.audio:stop() end
    UIManager:unschedule(self.tick)
end
function Engine:toggle() if self.paused then return self:play() end; self:pause(); self:status(_("Paused")); return true end
function Engine:jump(seconds)
    self.position = clamp((self.paused and self.position or self:currentTime()) + seconds, 0, self.duration)
    if not self.paused then self.start_position, self.start_wall = self.position, nowSeconds() end
    return self:show(self.position)
end
function Engine:step()
    if self.closed or self.paused then return end
    self.position = self:currentTime()
    if self.position >= self.duration then self:show(self.duration); self:pause(); self:status(_("Finished")); return end
    local ok, err = self:show(self.position)
    if not ok then self:pause(); self:status(err); return end
    UIManager:scheduleIn(self.interval, self.tick)
end
function Engine:close()
    if self.closed then return end
    self.closed = true; self:pause()
    if self.audio then self.audio:stop() end
    if self.frame then self.frame:free(); self.frame = nil end
    if self.handle then self.handle:close(); self.handle = nil end
end

local Action = InputContainer:extend{ label = nil, callback = nil, width = nil, height = nil, shade = nil, dimen = nil }
function Action:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.floor(self.height * .3), background = self.shade or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.label or "", face = Font:getFace("smallinfofont", scale(10)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = self.width - scale(6) } } }
    self.ges_events = { TapBWRAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:paintTo(bb, x, y)
    local range = self.ges_events.TapBWRAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    return InputContainer.paintTo(self, bb, x, y)
end
function Action:onTapBWRAction() if self.callback then self.callback() end; return true end

local function state(instance)
    instance.bwr_video = instance.bwr_video or { path = nil, wav = nil, engine = nil, note = _("Open a local .bwr file. A same-name .wav file is used when present.") }
    return instance.bwr_video
end

local function load(instance, context, path)
    local data = state(instance)
    path = trim(path)
    if not path:lower():match("%.bwr$") then data.note = _("Only local .bwr BWR1 files are supported."); context.requestRebuild("ui"); return false end
    if data.engine then data.engine:close() end
    local companion = path:gsub("%.bwr$", ".wav")
    local wav = io.open(companion, "rb")
    data.wav = wav and companion or nil
    if wav then wav:close() end
    data.path = path
    data.engine = Engine.open(path, data.wav, function(message) data.note = message end)
    data.note = data.engine.error or (_("Loaded ") .. basename(path) .. (data.wav and _(" with WAV audio.") or _(" without companion audio.")))
    context.requestRebuild("ui")
    return not data.engine.error
end

local function selectFile(instance, context)
    local data, dialog = state(instance), nil
    dialog = InputDialog:new{
        title = _("Open BWR1 video"), input = data.path or "", input_hint = _("Absolute path ending in .bwr"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Open"), is_enter_default = true, callback = function() local path = dialog:getInputText(); UIManager:close(dialog); load(instance, context, path) end } } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function control(instance, context, name)
    local data, engine = state(instance), state(instance).engine
    if not engine or engine.error then UIManager:show(InfoMessage:new{ text = _("Open a valid BWR1 file first.") }); return end
    local ok, err
    if name == "toggle" then ok, err = engine:toggle() elseif name == "back" then ok, err = engine:jump(-5) elseif name == "forward" then ok, err = engine:jump(5) elseif name == "stop" then engine:pause(); engine.position = 0; ok, err = engine:show(0); data.note = _("Stopped") end
    if not ok and err then data.note = tostring(err); UIManager:show(InfoMessage:new{ text = data.note }) end
    context.requestRefresh("fast")
end

return {
    id = "bwr_video",
    version = "1.0.0",
    title = "BWR Video",
    subtitle = "Minimal E-Ink BWR1 video and system audio",
    symbol = "V",
    logo = "gallery",
    openFile = function(instance, path)
        if not (path or ""):lower():match("%.bwr$") then return false, _("BWR Video accepts .bwr files only.") end
        local data = state(instance)
        if data.engine then data.engine:close() end
        local companion = path:gsub("%.bwr$", ".wav")
        local wav = io.open(companion, "rb")
        data.wav = wav and companion or nil
        if wav then wav:close() end
        data.path, data.engine = path, Engine.open(path, data.wav, function(message) data.note = message end)
        data.note = data.engine.error or (_("Loaded from AppDock Files: ") .. basename(path))
        return not data.engine.error, data.engine.error
    end,
    buildPane = function(instance, context)
        local data = state(instance)
        local width, height = context.dimen.w, context.dimen.h
        local margin, gap, h = scale(10), scale(5), scale(31)
        local row1, row2 = scale(53), scale(89)
        local canvas_y, canvas_h = row2 + h + scale(8), math.max(scale(60), height - (row2 + h + scale(8)) - scale(23))
        local canvas_w, button_w = width - 2 * margin, math.max(scale(42), math.floor((width - 2 * margin - 3 * gap) / 4))
        local canvas = Canvas:new{ engine = data.engine, width = canvas_w, height = canvas_h }
        if data.engine then data.engine:setCanvas(canvas) end
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen, allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) },
            TextWidget:new{ text = _("BWR Video"), face = Font:getFace("cfont", scale(18)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, scale(7) } },
            TextWidget:new{ text = data.path and basename(data.path) or _("Pre-dithered BWR1 local video"), face = Font:getFace("smallinfofont", scale(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = canvas_w, overlap_offset = { margin, scale(31) } },
            Action:new{ label = _("Open video"), width = canvas_w, height = h, shade = Blitbuffer.COLOR_LIGHT_GRAY, callback = function() selectFile(instance, context) end, overlap_offset = { margin, row1 } },
            Action:new{ label = _("-5 s"), width = button_w, height = h, callback = function() control(instance, context, "back") end, overlap_offset = { margin, row2 } },
            Action:new{ label = data.engine and not data.engine.paused and _("Pause") or _("Play"), width = button_w, height = h, shade = Blitbuffer.COLOR_GRAY_8, callback = function() control(instance, context, "toggle") end, overlap_offset = { margin + button_w + gap, row2 } },
            Action:new{ label = _("+5 s"), width = button_w, height = h, callback = function() control(instance, context, "forward") end, overlap_offset = { margin + 2 * (button_w + gap), row2 } },
            Action:new{ label = _("Stop"), width = button_w, height = h, shade = Blitbuffer.COLOR_GRAY_7, callback = function() control(instance, context, "stop") end, overlap_offset = { margin + 3 * (button_w + gap), row2 } },
            canvas,
            TextWidget:new{ text = data.note or "", face = Font:getFace("smallinfofont", scale(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = canvas_w, overlap_offset = { margin, height - scale(16) } },
        }
        canvas.overlap_offset = { margin, canvas_y }
        function pane:onDeactivate()
            if data.engine then data.engine:close(); data.engine = nil; data.note = _("Playback stopped while BWR Video is inactive.") end
        end
        return pane
    end,
}
