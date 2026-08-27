local function class(proto)
    proto = proto or {}; proto.__index = proto
    function proto:extend(child) child = child or {}; child.__index = child; setmetatable(child, { __index = self }); return child end
    function proto:new(values) local value = values or {}; setmetatable(value, self); if value.init then value:init() end; return value end
    return proto
end

local Widget = class({})
local WidgetContainer = Widget:extend({})
local InputContainer = WidgetContainer:extend({})
function InputContainer:paintTo() end
local function widgetModule() return WidgetContainer end

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dark", COLOR_LIGHT_GRAY = "light", COLOR_GRAY = "gray", COLOR_GRAY_8 = "g8" } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, value) return value end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, values) return values end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, values) return values end } end
package.preload["ui/widget/container/centercontainer"] = widgetModule
package.preload["ui/widget/container/framecontainer"] = widgetModule
package.preload["ui/widget/horizontalspan"] = widgetModule
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/inputdialog"] = widgetModule
package.preload["ui/widget/overlapgroup"] = widgetModule
package.preload["ui/widget/textwidget"] = widgetModule
package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end } end
package.preload["ui/widget/verticalgroup"] = widgetModule
package.preload["ui/widget/widget"] = function() return Widget end
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["gettext"] = function() return function(value) return value end end

local app = dofile(os.getenv("DBASIC_SOURCE") or "/home/ubuntu/dapps-dbasic-release/dbasic.lua")
assert(app.id == "dbasic" and app.version == "1.0.0" and type(app.buildPane) == "function", "DBASIC must satisfy the AppStore DApp contract")
assert(app._test.parseExpression("2 + 3 * 4", {}) == 14, "DBASIC expressions must respect arithmetic precedence")
assert(app._test.parseExpression("MAX(3, 7) + ABS(-2)", {}) == 9, "DBASIC must support bounded built-in numeric functions")
local program = [[
10 LET SUM = 0
20 FOR I = 1 TO 3
30 LET SUM = SUM + I
40 NEXT I
50 PRINT "SUM="; SUM
60 COLOR 2
70 LINE 0,0,160,100
80 ON TOUCH GOTO 100
90 END
100 PSET TOUCHX,TOUCHY
110 END
]]
local state = {}
assert(app._test.runProgram(program, state), "DBASIC must execute bounded assignment, loop, output, drawing and touch-registration commands")
assert(state.output == "SUM= 6" and #state.graphics == 1 and state.graphics[1].kind == "line" and state.touch_target == 100, "DBASIC must retain output, graphics and a safe ON TOUCH target")
assert(app._test.runProgram(program, state, { x = 42, y = 57 }, state.touch_target), "DBASIC must execute a registered touch target as a separate bounded run")
assert(#state.graphics == 1 and state.graphics[1].kind == "pset" and state.graphics[1].x == 42 and state.graphics[1].y == 57, "DBASIC touch variables must map to bounded graphics coordinates")
assert(not app._test.runProgram("10 PRINT os.execute", {}), "DBASIC must reject unsupported Lua-like expression syntax rather than execute it")
assert(not app._test.runProgram("10 GOTO 999", {}), "DBASIC must reject jumps to missing line numbers")
assert(not app._test.runProgram("10 ON TOUCH GOTO 99", {}), "DBASIC must reject touch targets that do not exist")
print("DBASIC test: OK")
