-- Regression tests for the Geometry Rush AppDock DApp.
-- Run with: luajit test_geodash.lua
local function class()
    local C = {}
    C.__index = C
    function C:extend(proto)
        proto = proto or {}
        proto.__index = proto
        return setmetatable(proto, { __index = self })
    end
    function C:new(args)
        local instance = setmetatable(args or {}, self)
        if instance.init then instance:init() end
        return instance
    end
    function C:getSize() return { w = 60, h = 20 } end
    function C:free() end
    function C:paintTo() end
    return C
end

local function install(name, value)
    package.preload[name] = function() return value end
end

local Widget = class()
local InputContainer = class()
local scheduled = {}
local UIManager = {
    scheduleIn = function(_, delay, callback)
        scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        return callback
    end,
    unschedule = function() end,
    widgetRepaint = function() end,
    setDirty = function() end,
    show = function() end,
}
local screen = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    scaleBySize = function(_, value) return value end,
}
local Device = { screen = screen }
function Device:hasKeys() return false end
install("ffi/blitbuffer", {
    COLOR_WHITE = 1, COLOR_BLACK = 2, COLOR_GRAY = 3, TYPE_BBRGB32 = 4,
})
install("device", Device)
install("ui/font", { getFace = function(_, _, size) return { size = size } end })
install("ui/geometry", { new = function(_, value) return value end })
install("ui/gesturerange", { new = function(_, value) return value end })
install("ui/widget/infomessage", Widget)
install("ui/widget/container/inputcontainer", InputContainer)
install("ui/widget/overlapgroup", Widget)
install("ui/widget/textboxwidget", Widget)
install("ui/widget/textwidget", Widget)
install("ui/uimanager", UIManager)
install("logger", { warn = function() end })
install("gettext", function(value) return value end)

local app = assert(loadfile("geodash.lua"))()
local test = app._test
assert(app.version == "1.0.5", "GeoDash must advertise the render-cost optimization version")
assert(test.POLL_INTERVAL <= 1 / 60, "RFB polling must not cap the stream below the 60-FPS game rate")
assert(test.FRAME_MS == 10, "The native game must not receive zero frame time and fall back to ~7 FPS")
assert(test.PIC_OUT_W == 380 and test.MAX_SCALE == 2,
    "The game must render a small stream and scale it up for a large visible picture")
assert(test.REFRESH_MODE == "fast", "The default e-ink waveform must favor responsive game frames")
assert(test.JUMP_PRESS_DURATION >= 1 / 30, "A jump press must span at least one game frame")
assert(test.LAYOUT_UNITS == 3, "Controls must use two compact rows so the picture gets more vertical space")

local key_events, pointer_events, update_requests = {}, {}, {}
local poll_responses = 0
test.Game.running = true
test.Game.poll_cb = function() end
test.Game.rfb = {
    w = 400, h = 240, dw = 400, dh = 240,
    poll = function()
        poll_responses = poll_responses + 1
        if poll_responses == 1 then return false end
        return nil
    end,
    requestUpdate = function(_, incremental) update_requests[#update_requests + 1] = incremental end,
    toDisplay = function(_, x0, y0, x1, y1) return x0, y0, x1, y1 end,
    key = function(_, key, down) key_events[#key_events + 1] = { key = key, down = down } end,
    pointer = function(_, x, y, mask) pointer_events[#pointer_events + 1] = { x = x, y = y, mask = mask } end,
}

-- Empty framebuffer updates still need a subsequent request or the VNC stream can stall.
test.Game:poll()
assert(#update_requests == 1 and update_requests[1] == true,
    "A completed empty RFB response must trigger the next incremental update")

-- A quick touch press/release must stay down until the minimum jump interval expires.
local view = test.GameView:new{ width = 400, height = 240 }
view._ox, view._oy = 10, 20
local touch = { pos = { x = 110, y = 120 }, slot = 7 }
assert(view:onTouchGeodashGame("TouchGeodashGame", touch), "Game touch must be handled")
assert(pointer_events[#pointer_events].mask == 1, "A picture touch must send left-button down")
assert(view:onReleaseGeodashGame("ReleaseGeodashGame", touch), "Game release must be handled")
assert(pointer_events[#pointer_events].mask == 1,
    "A short picture tap must not release before one game frame")
local pointer_press = view.ptr_slot[7]
assert(pointer_press and pointer_press.min_cb, "A picture press must have a minimum-duration release")
pointer_press.min_cb()
assert(pointer_events[#pointer_events].mask == 0 and view.ptr_slot[7] == nil,
    "The picture click must release cleanly after the minimum duration")

-- A plain tap with no touch/release events must still produce a frame-safe click pulse.
view.tap_suppressed = nil
local before_tap = #pointer_events
assert(view:onTapGeodashGame("TapGeodashGame", { pos = { x = 110, y = 120 } }), "Tap fallback must be handled")
assert(pointer_events[before_tap + 1].mask == 0 and pointer_events[before_tap + 2].mask == 1,
    "Tap fallback must begin from a known-up state and click")
scheduled[#scheduled].callback()
assert(pointer_events[#pointer_events].mask == 0, "Tap fallback must release the mouse button")

-- The JUMP pad must send Space down and keep it down until the frame-safe timer.
local pad = test.Pad:new{ width = 400, height = 160 }
pad._ox, pad._oy = 0, 0
local jump = pad.buttons[1]
assert(jump and jump.label == "JUMP", "The first game control must be the JUMP button")
local jump_pos = { pos = { x = jump.rect.x + 2, y = jump.rect.y + 2 }, slot = 3 }
assert(pad:onTouchGeodashPad("TouchGeodashPad", jump_pos), "JUMP touch must be handled")
assert(key_events[#key_events].key == test.K.Space and key_events[#key_events].down,
    "JUMP touch must send Space down")
local before_release = #key_events
assert(pad:onReleaseGeodashPad("ReleaseGeodashPad", jump_pos), "JUMP release must be handled")
assert(#key_events == before_release, "A quick touch release must not cancel the jump pulse early")
local jump_timeout = jump.timeout_cb
assert(jump_timeout, "JUMP press must schedule an automatic release")
jump_timeout()
assert(key_events[#key_events].key == test.K.Space and not key_events[#key_events].down,
    "JUMP must release after the frame-safe interval")
local after_timeout = #key_events
pad:onTapGeodashPad("TapGeodashPad", jump_pos)
assert(#key_events == after_timeout, "The matching tap event must not double-trigger a touch jump")

print("GeoDash FPS, RFB update loop, and jump input tests passed.")
