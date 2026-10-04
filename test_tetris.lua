local function class(base)
    base = base or {}; base.__index = base
    function base:extend(child) child = child or {}; child.__index = child; setmetatable(child, { __index = self }); return child end
    function base:new(args) local value = setmetatable(args or {}, self); if value.init then value:init() end; return value end
    function base:clear() while table.remove(self) do end end
    return base
end
local Widget = class({})
local InputContainer = Widget:extend({})
local scheduled = {}
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_LIGHT_GRAY = "light", COLOR_DARK_GRAY = "dark", COLOR_GRAY_8 = "gray", ColorRGB32 = function(r, g, b, a) return { r, g, b, a } end }
end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, value) return value end, isColorEnabled = function() return true end }, input = { group = {} } }
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, value) return value end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, value) return value end } end
for _, module in ipairs({ "ui/widget/container/centercontainer", "ui/widget/container/framecontainer", "ui/widget/container/inputcontainer", "ui/widget/horizontalspan", "ui/widget/overlapgroup", "ui/widget/textwidget" }) do
    package.preload[module] = function() return InputContainer end
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, seconds, callback) scheduled[#scheduled + 1] = { seconds = seconds, callback = callback } end,
        unschedule = function() end,
        widgetRepaint = function() end,
        setDirty = function() end,
        forceRePaint = function() end,
        yieldToEPDC = function() end,
    }
end
local app = dofile("tetris.lua")
assert(app.id == "tetris" and app.version == "1.0.0" and app.logo == "other")
assert(app._test.FRAME_SECONDS == 0.1 and app._test.BOARD_W == 10 and app._test.BOARD_H == 20)
local session = app._test.TetrisSession.new()
assert(session.current and session.next_kind and #session.board == 200, "Tetris must initialize a 10x20 board and pieces")
assert(session:move(-1) == false, "Paused Tetris must ignore movement")
session:start()
assert(scheduled[#scheduled].seconds == 0.1, "Playing Tetris must schedule exactly 10 FPS ticks")
assert(session:move(-1) and session:rotate(), "Active Tetris must accept movement and rotation")
local start_y = session.current.y
for _ = 1, 12 do session:tick() end
assert(session.current.y > start_y or session.frames == 12, "Ticks must advance the falling piece")
session:hardDrop()
assert(session.score >= 0 and session.current, "Hard drop must lock the piece and spawn the next one")
for index = 1, 200 do session.board[index] = 0 end
for x = 0, 5 do session.board[19 * 10 + x + 1] = 1 end
session.current = { kind = "I", rotation = 0, x = 6, y = 18 }
session:lock()
assert(session.lines == 1 and session.score >= 100, "Completing a row must clear it and award points")
local rebuilds = 0
local pane = app.buildPane({}, { dimen = { w = 600, h = 420 }, px = function(value) return value end, requestRebuild = function(kind) assert(kind == "ui"); rebuilds = rebuilds + 1 end })
assert(pane and pane.dimen.w == 600 and pane.dimen.h == 420, "Tetris must build inside the assigned AppDock pane")
local source = assert(io.open("dapps.txt", "rb")):read("*a")
assert(source:find("tetris.lua | 1.0.0 | other", 1, true), "Tetris must be published in the DApp catalog")
print("Tetris DApp test: OK")
