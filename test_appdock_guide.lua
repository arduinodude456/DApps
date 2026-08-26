local function generic()
    local T = {}
    function T:new(args) args = args or {}; setmetatable(args, { __index = self }); return args end
    function T:extend(args) args = args or {}; setmetatable(args, { __index = self }); return args end
    return T
end

local shown = {}
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_LIGHT_GRAY = "light", COLOR_DARK_GRAY = "dark", COLOR_GRAY_8 = "gray" } end
package.preload["ui/font"] = function() return { getFace = function(_, size) return { size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, args) return args end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, args) return args end } end
package.preload["ui/widget/container/centercontainer"] = generic
package.preload["ui/widget/container/framecontainer"] = generic
package.preload["ui/widget/container/inputcontainer"] = generic
package.preload["ui/widget/overlapgroup"] = generic
package.preload["ui/widget/textwidget"] = generic
package.preload["ui/widget/container/widgetcontainer"] = generic
package.preload["ui/widget/horizontalspan"] = generic
package.preload["ui/widget/inputdialog"] = function() local T = generic(); function T:onShowKeyboard() end; function T:getInputText() return self.input end; return T end
package.preload["ui/uimanager"] = function() return { show = function(_, dialog) shown[#shown + 1] = dialog end, close = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local app = dofile("appdock_guide.lua")
assert(app.id == "appdock_guide" and app.version == "1.0.0" and app.logo == "help", "Guide must satisfy the Store DApp contract")
assert(#app._test.topics >= 6 and #app._test.matches("splitscreen") >= 1 and #app._test.matches("definitely_missing") == 0, "Guide must provide searchable interactive topics")
local rebuilds, px_calls = 0, 0
local instance = {}
local context = { dimen = { w = 600, h = 340 }, px = function(value) px_calls = px_calls + 1; return math.max(1, math.floor(value * .65 + .5)) end, requestRebuild = function(kind) assert(kind == "ui"); rebuilds = rebuilds + 1 end }
local pane = app.buildPane(instance, context)
assert(pane and pane.dimen.h == 340 and px_calls > 0, "Guide must build a relative short split-pane layout")
local state = instance.appdock_guide
state.view, state.selected, state.step = "lesson", 1, 1
local lesson = app.buildPane(instance, context)
local next_action
for _, child in ipairs(lesson[1]) do if child.title == "Weiter ›" then next_action = child; break end end
assert(next_action and next_action.callback, "Guide lessons must expose an interactive next-step action")
next_action.callback()
assert(state.step == 2 and rebuilds == 1, "Guide must advance a local lesson step and rebuild")
print("AppDock Guide DApp test: OK")
