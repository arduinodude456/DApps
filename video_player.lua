--[[--
VideoPlayer for AppDock.

Plays local BWR1 monochrome raw-video files. BWR1 frames are already dithered
for E-Ink. A companion WAV file can be sent to the device's current audio
output; when the operating system routes audio to a paired Bluetooth headset,
the same output path is used.

The DApp deliberately does not pair Bluetooth devices itself and does not
attempt to decode MP4, WebM, MKV, or other compressed video containers.
--]]--

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
local MAGIC = "BWR1"
local HEADER_BYTES = 32
local MAX_FRAME_BYTES = 8 * 1024 * 1024
local MAX_FRAMES = 500000

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function trim(value) return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or "" end
local function basename(path) return (path or ""):match("([^/]+)$") or path or "" end

local function emptySizedWidget(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function findCommand(name)
    local pipe = io.popen("command -v " .. name .. " 2>/dev/null", "r")
    if not pipe then return nil end
    local path = pipe:read("*l")
    pipe:close()
    return path and path ~= "" and path or nil
end

local function u16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    if not a or not b then return nil end
    return a + b * 256
end

local function u32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    if not a or not b or not c or not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function putU32(value)
    return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function parseHeader(handle)
    local data = handle:read(HEADER_BYTES)
    if not data or #data ~= HEADER_BYTES then return nil, _("The BWR1 file has no complete header.") end
    if data:sub(1, 4) ~= MAGIC then return nil, _("This is not a BWR1 raw-video file.") end
    local header = {
        version = data:byte(5), pixel_format = data:byte(6), width = u16(data, 7), height = u16(data, 9),
        fps_x100 = u16(data, 11), frames = u32(data, 13), frame_bytes = u32(data, 17),
    }
    if header.version ~= 1 or header.pixel_format ~= 1 then return nil, _("Unsupported BWR1 version or pixel format.") end
    if not header.width or not header.height or header.width < 8 or header.height < 1 or header.width % 8 ~= 0 then return nil, _("Invalid BWR1 dimensions.") end
    if not header.fps_x100 or header.fps_x100 < 1 or not header.frames or header.frames < 1 or header.frames > MAX_FRAMES then return nil, _("Invalid BWR1 timing or frame count.") end
    local expected = header.width / 8 * header.height
    if not header.frame_bytes or header.frame_bytes ~= expected or header.frame_bytes > MAX_FRAME_BYTES then return nil, _("Invalid or oversized BWR1 frame size.") end
    return header
end

local LUT_FIRST, LUT_SECOND = {}, {}
local function expandNibble(value)
    local packed = 0
    for pixel = 0, 3 do
        if bit.band(value, bit.rshift(0x08, pixel)) ~= 0 then packed = bit.bor(packed, bit.lshift(0xFF, pixel * 8)) end
    end
    return packed
end
for value = 0, 255 do
    LUT_FIRST[value] = expandNibble(bit.rshift(value, 4))
    LUT_SECOND[value] = expandNibble(bit.band(value, 0x0F))
end

local function clockSeconds()
    local ok, Time = pcall(require, "ui/time")
    if ok and Time and Time.now and Time.to_s then
        local good, value = pcall(function() return Time.to_s(Time.now()) end)
        if good and type(value) == "number" then return value end
    end
    return os.time()
end

local AudioPlayer = {}
AudioPlayer.__index = AudioPlayer

function AudioPlayer.new(path)
    local self = setmetatable({ path = path, command = nil, command_name = nil, pid = nil, paused = false, clip_path = nil }, AudioPlayer)
    local gst_launch, gst_inspect = findCommand("gst-launch-1.0"), findCommand("gst-inspect-1.0")
    if gst_launch and gst_inspect then
        local probe = io.popen(shellQuote(gst_inspect) .. " mtkbtmwrpcaudiosink 2>/dev/null", "r")
        local output = probe and probe:read("*a") or ""
        if probe then probe:close() end
        if output:find("mtkbtmwrpcaudiosink", 1, true) then self.command, self.command_name = gst_launch, "mtk-gstreamer" end
    end
    if not self.command then self.command, self.command_name = findCommand("aplay"), "aplay" end
    if not self.command then self.command, self.command_name = findCommand("tinyplay"), "tinyplay" end
    return self
end

function AudioPlayer:isAvailable() return self.command ~= nil end
function AudioPlayer:getError()
    return self.command and nil or _("No supported WAV audio backend was found. Bluetooth audio requires a paired device and a system audio backend such as GStreamer, aplay, or tinyplay.")
end

function AudioPlayer:_makeClip(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds == 0 then return self.path end
    local input = io.open(self.path, "rb")
    if not input then return nil end
    local header = input:read(44)
    if not header or #header ~= 44 or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then input:close(); return nil end
    local rate, align, bytes = u32(header, 25), u16(header, 33), u32(header, 41)
    if not rate or not align or not bytes or rate < 1 or align < 1 then input:close(); return nil end
    local offset = math.min(bytes, math.floor(seconds * rate) * align)
    input:seek("set", 44 + offset)
    local remaining, temporary = bytes - offset, os.tmpname()
    local output = io.open(temporary, "wb")
    if not output then input:close(); return nil end
    output:write(header:sub(1, 4) .. putU32(36 + remaining) .. header:sub(9, 40) .. putU32(remaining))
    while remaining > 0 do
        local chunk = input:read(math.min(65536, remaining))
        if not chunk or #chunk == 0 then break end
        output:write(chunk); remaining = remaining - #chunk
    end
    input:close(); output:close()
    return temporary
end

function AudioPlayer:startFrom(seconds)
    if not self.command then return nil, self:getError() end
    local input = io.open(self.path, "rb")
    if not input then return nil, _("Companion WAV file was not found.") end
    input:close()
    self:stop()
    self.clip_path = self:_makeClip(seconds)
    if not self.clip_path then return nil, _("The WAV file could not be prepared for the requested position.") end
    local command
    if self.command_name == "mtk-gstreamer" then
        local pipeline = "tail -c +45 " .. shellQuote(self.clip_path) .. " | exec " .. shellQuote(self.command)
            .. " fdsrc fd=0 ! audio/x-raw,format=S16LE,rate=44100,channels=2 ! audioconvert ! audioresample ! mtkbtmwrpcaudiosink"
        local setsid = findCommand("setsid")
        command = setsid and (shellQuote(setsid) .. " sh -c " .. shellQuote(pipeline)) or ("sh -c " .. shellQuote(pipeline))
    elseif self.command_name == "aplay" then
        command = shellQuote(self.command) .. " -q " .. shellQuote(self.clip_path)
    else
        command = shellQuote(self.command) .. " " .. shellQuote(self.clip_path)
    end
    local pipe = io.popen(command .. " >/dev/null 2>&1 & echo $!", "r")
    if not pipe then return nil, _("The audio process could not be started.") end
    self.pid = tonumber(pipe:read("*l")); pipe:close()
    if not self.pid then return nil, _("The audio process returned no process ID.") end
    self.paused = false
    return true
end

function AudioPlayer:pause()
    if self.pid and not self.paused then os.execute("kill -STOP -" .. tostring(self.pid) .. " 2>/dev/null"); self.paused = true end
end
function AudioPlayer:stop()
    if self.pid then os.execute("kill -TERM -" .. tostring(self.pid) .. " 2>/dev/null"); self.pid = nil end
    if self.clip_path and self.clip_path ~= self.path then os.remove(self.clip_path) end
    self.clip_path, self.paused = nil, false
end

local VideoCanvas = InputContainer:extend{ player = nil, width = nil, height = nil, dimen = nil, _origin_x = 0, _origin_y = 0 }
function VideoCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function VideoCanvas:paintTo(bb, x, y)
    self._origin_x, self._origin_y = x, y
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    local player, frame = self.player, self.player and self.player.frame_bb
    if not player or not frame then return end
    local source_x = math.max(0, math.floor((player.header.width - self.width) / 2))
    local source_y = math.max(0, math.floor((player.header.height - self.height) / 2))
    local draw_w = math.min(self.width, player.header.width)
    local draw_h = math.min(self.height, player.header.height)
    local target_x = x + math.max(0, math.floor((self.width - draw_w) / 2))
    local target_y = y + math.max(0, math.floor((self.height - draw_h) / 2))
    bb:blitFrom(frame, target_x, target_y, source_x, source_y, draw_w, draw_h)
end
function VideoCanvas:refreshFast()
    if not UIManager.widgetRepaint or not UIManager.setDirty then return false end
    UIManager:widgetRepaint(self, self._origin_x, self._origin_y)
    UIManager:setDirty(nil, "fast", Geom:new{ x = self._origin_x, y = self._origin_y, w = self.width, h = self.height })
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    if UIManager.yieldToEPDC then UIManager:yieldToEPDC() end
    return true
end

local Player = {}
Player.__index = Player

function Player.new(video_path, audio_path, on_status)
    local handle, open_err = io.open(video_path, "rb")
    local self = setmetatable({ video_path = video_path, audio_path = audio_path, handle = handle, open_error = open_err, frame_bb = nil, frame_index = -1, paused = true, closed = false, position = 0, anchor_wall = nil, anchor_position = 0, canvas = nil, on_status = on_status }, Player)
    if not handle then self.open_error = _("BWR1 video file was not found."); return self end
    self.header, self.open_error = parseHeader(handle)
    if not self.header then handle:close(); self.handle = nil; return self end
    self.fps = self.header.fps_x100 / 100
    self.duration = self.header.frames / self.fps
    self.tick_period = math.max(0.08, 1 / self.fps)
    self.audio = audio_path and audio_path ~= "" and AudioPlayer.new(audio_path) or nil
    self._tick = function() self:_tick() end
    return self
end

function Player:setCanvas(canvas)
    self.canvas = canvas
    if canvas then canvas.player = self end
end
function Player:_setStatus(message) if self.on_status then self.on_status(message) end end
function Player:_audioPosition()
    if not self.anchor_wall then return self.position end
    return clamp(self.anchor_position + math.max(0, clockSeconds() - self.anchor_wall), 0, self.duration)
end
function Player:_markPosition(position)
    self.position, self.anchor_position, self.anchor_wall = position, position, clockSeconds()
end
function Player:_readFrame(index)
    if not self.handle or index < 0 or index >= self.header.frames then return nil, _("Video frame is outside the file.") end
    self.handle:seek("set", HEADER_BYTES + index * self.header.frame_bytes)
    local packed = self.handle:read(self.header.frame_bytes)
    if not packed or #packed ~= self.header.frame_bytes then return nil, _("Could not read a complete BWR1 frame.") end
    return packed
end
function Player:_loadFrame(index)
    local packed, err = self:_readFrame(index)
    if not packed then return nil, err end
    local bb = Blitbuffer.new(self.header.width, self.header.height, Blitbuffer.TYPE_BB8)
    local destination = require("ffi").cast("uint32_t*", bb.data)
    local out = 0
    for i = 1, #packed do
        local value = packed:byte(i)
        destination[out], destination[out + 1] = LUT_FIRST[value], LUT_SECOND[value]
        out = out + 2
    end
    if self.frame_bb then self.frame_bb:free() end
    self.frame_bb, self.frame_index = bb, index
    return true
end
function Player:_show(position)
    local index = clamp(math.floor(position * self.fps), 0, self.header.frames - 1)
    if index ~= self.frame_index or not self.frame_bb then
        local ok, err = self:_loadFrame(index)
        if not ok then self:_setStatus(err); self:pause(); return nil, err end
    end
    if self.canvas then self.canvas:refreshFast() end
    return true
end
function Player:_tick()
    if self.closed or self.paused then return end
    local position = self:_audioPosition()
    if position >= self.duration then
        self.position = self.duration; self:_show(self.duration); self:pause(); self:_setStatus(_("Playback finished")); return
    end
    self.position = position
    self:_show(position)
    UIManager:scheduleIn(self.tick_period, self._tick)
end
function Player:start()
    if self.open_error then return nil, self.open_error end
    if self.audio then
        local ok, err = self.audio:startFrom(self.position)
        if not ok then return nil, err end
        self:_setStatus(_("Playing through the system audio output (including an already connected Bluetooth device)."))
    else
        self:_setStatus(_("Playing without companion audio."))
    end
    self:_markPosition(self.position)
    self.paused = false
    local ok, err = self:_show(self.position)
    if not ok then self.paused = true; return nil, err end
    UIManager:unschedule(self._tick); UIManager:scheduleIn(self.tick_period, self._tick)
    return true
end
function Player:pause()
    if self.paused then return end
    self.position = self:_audioPosition()
    if self.audio then self.audio:pause() end
    self.anchor_wall, self.paused = nil, true
    UIManager:unschedule(self._tick)
end
function Player:toggle()
    if self.paused then return self:start() end
    self:pause(); self:_setStatus(_("Paused")); return true
end
function Player:seek(delta)
    local target = clamp((self.paused and self.position or self:_audioPosition()) + delta, 0, self.duration)
    self.position = target
    if not self.paused then
        if self.audio then
            local ok, err = self.audio:startFrom(target)
            if not ok then self:_setStatus(err); return nil, err end
        end
        self:_markPosition(target)
    end
    return self:_show(target)
end
function Player:stop()
    UIManager:unschedule(self._tick)
    if self.audio then self.audio:stop() end
    self.paused, self.position, self.anchor_wall = true, 0, nil
    if self.frame_bb then self.frame_bb:free(); self.frame_bb = nil end
    self.frame_index = -1
end
function Player:close()
    if self.closed then return end
    self.closed = true; self:stop()
    if self.handle then self.handle:close(); self.handle = nil end
end

local PlayerButton = InputContainer:extend{ title = nil, callback = nil, width = nil, height = nil, background = nil, foreground = nil, dimen = nil }
function PlayerButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.floor(self.height * 0.30), background = self.background or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", scale(10)), bold = true, fgcolor = self.foreground, max_width = self.width - scale(6) } } }
    self.ges_events = { TapVideoPlayerButton = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function PlayerButton:paintTo(bb, x, y)
    local range = self.ges_events.TapVideoPlayerButton[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function PlayerButton:onTapVideoPlayerButton() if self.callback then self.callback() end; return true end

local function stateFor(instance)
    instance.video_player = instance.video_player or { video_path = nil, audio_path = nil, player = nil, status = _("Open a local .bwr BWR1 video. A same-name .wav file is selected automatically when present.") }
    return instance.video_player
end

local function configureVideo(instance, context, path)
    local state = stateFor(instance)
    path = trim(path)
    if not path:lower():match("%.bwr$") then state.status = _("Choose a local BWR1 file ending in .bwr."); context.requestRebuild("ui"); return false end
    local input = io.open(path, "rb")
    if not input then state.status = _("Video file cannot be opened."); context.requestRebuild("ui"); return false end
    input:close()
    if state.player then state.player:close() end
    state.video_path = path
    local companion = path:gsub("%.bwr$", ".wav")
    local wav = io.open(companion, "rb")
    if wav then wav:close(); state.audio_path = companion else state.audio_path = nil end
    state.player = Player.new(state.video_path, state.audio_path, function(message) state.status = message end)
    if state.player.open_error then state.status = state.player.open_error else state.status = _("Loaded ") .. basename(path) .. (state.audio_path and _(" with companion WAV audio.") or _(" without companion audio.")) end
    context.requestRebuild("ui")
    return not state.player.open_error
end

local function editPath(instance, context, kind)
    local state = stateFor(instance)
    local is_video = kind == "video"
    local dialog
    dialog = InputDialog:new{
        title = is_video and _("Open BWR1 video") or _("Companion WAV audio"),
        input = is_video and (state.video_path or "") or (state.audio_path or ""),
        input_hint = is_video and _("Absolute path to .bwr") or _("Absolute path to .wav; leave empty for silent video"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Use"), is_enter_default = true, callback = function()
            local value = trim(dialog:getInputText()); UIManager:close(dialog)
            if is_video then configureVideo(instance, context, value) else
                state.audio_path = value ~= "" and value or nil
                if state.player then state.player:close(); state.player = Player.new(state.video_path, state.audio_path, function(message) state.status = message end) end
                state.status = state.audio_path and (_("Audio selected: ") .. basename(state.audio_path)) or _("Silent video selected")
                context.requestRebuild("ui")
            end
        end } } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function act(instance, context, action)
    local state = stateFor(instance)
    local player = state.player
    if not player or player.open_error then UIManager:show(InfoMessage:new{ text = _("Open a valid BWR1 video first.") }); return end
    local ok, err
    if action == "toggle" then ok, err = player:toggle()
    elseif action == "back" then ok, err = player:seek(-5)
    elseif action == "forward" then ok, err = player:seek(5)
    elseif action == "stop" then player:stop(); state.status = _("Stopped"); ok = true end
    if not ok and err then state.status = tostring(err); UIManager:show(InfoMessage:new{ text = state.status }) end
    context.requestRefresh("fast")
end

return {
    id = "video_player",
    version = "1.0.1",
    title = "VideoPlayer",
    subtitle = "BWR1 E-Ink video with system and Bluetooth audio",
    symbol = "V",
    logo = "gallery",
    openFile = function(instance, path)
        if not (path or ""):lower():match("%.bwr$") then return false, _("VideoPlayer accepts BWR1 .bwr files only.") end
        local state = stateFor(instance)
        if state.player then state.player:close() end
        state.video_path, state.audio_path = path, nil
        local companion = path:gsub("%.bwr$", ".wav")
        local wav = io.open(companion, "rb")
        if wav then wav:close(); state.audio_path = companion end
        state.player = Player.new(path, state.audio_path, function(message) state.status = message end)
        state.status = state.player.open_error or (_("Loaded from AppDock Files: ") .. basename(path))
        return not state.player.open_error, state.player.open_error
    end,
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        local margin, gap = scale(10), scale(5)
        local action_h = scale(30)
        local first_y, second_y = scale(54), scale(89)
        local view_y = second_y + action_h + scale(8)
        local view_h = math.max(scale(60), height - view_y - scale(24))
        local view_w = width - 2 * margin
        local button_w = math.max(scale(44), math.floor((view_w - 3 * gap) / 4))
        local canvas = VideoCanvas:new{ player = state.player, width = view_w, height = view_h }
        if state.player then state.player:setCanvas(canvas) end
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen, allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = _("VideoPlayer"), face = Font:getFace("cfont", scale(18)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, scale(7) } },
            TextWidget:new{ text = state.video_path and basename(state.video_path) or _("BWR1 pre-dithered local video"), face = Font:getFace("smallinfofont", scale(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = view_w, overlap_offset = { margin, scale(31) } },
            PlayerButton:new{ title = _("Open video"), width = math.floor((view_w - gap) / 2), height = action_h, background = Blitbuffer.COLOR_LIGHT_GRAY, foreground = Blitbuffer.COLOR_BLACK, callback = function() editPath(instance, context, "video") end, overlap_offset = { margin, first_y } },
            PlayerButton:new{ title = state.audio_path and _("Audio WAV") or _("Add audio"), width = math.floor((view_w - gap) / 2), height = action_h, background = Blitbuffer.COLOR_LIGHT_GRAY, foreground = Blitbuffer.COLOR_BLACK, callback = function() editPath(instance, context, "audio") end, overlap_offset = { margin + math.floor((view_w - gap) / 2) + gap, first_y } },
            PlayerButton:new{ title = _("-5 s"), width = button_w, height = action_h, background = Blitbuffer.COLOR_LIGHT_GRAY, foreground = Blitbuffer.COLOR_BLACK, callback = function() act(instance, context, "back") end, overlap_offset = { margin, second_y } },
            PlayerButton:new{ title = state.player and not state.player.paused and _("Pause") or _("Play"), width = button_w, height = action_h, background = Blitbuffer.COLOR_GRAY_8, foreground = Blitbuffer.COLOR_BLACK, callback = function() act(instance, context, "toggle") end, overlap_offset = { margin + button_w + gap, second_y } },
            PlayerButton:new{ title = _("+5 s"), width = button_w, height = action_h, background = Blitbuffer.COLOR_LIGHT_GRAY, foreground = Blitbuffer.COLOR_BLACK, callback = function() act(instance, context, "forward") end, overlap_offset = { margin + (button_w + gap) * 2, second_y } },
            PlayerButton:new{ title = _("Stop"), width = button_w, height = action_h, background = Blitbuffer.COLOR_GRAY_7, foreground = Blitbuffer.COLOR_BLACK, callback = function() act(instance, context, "stop") end, overlap_offset = { margin + (button_w + gap) * 3, second_y } },
            canvas,
            TextWidget:new{ text = state.status or "", face = Font:getFace("smallinfofont", scale(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = view_w, overlap_offset = { margin, height - scale(16) } },
        }
        canvas.overlap_offset = { margin, view_y }
        function pane:onDeactivate()
            if state.player then state.player:close(); state.player = nil; state.status = _("Playback stopped while VideoPlayer is inactive.") end
        end
        return pane
    end,
    test = {
        parseHeader = parseHeader,
        Player = Player,
        AudioPlayer = AudioPlayer,
    },
}
