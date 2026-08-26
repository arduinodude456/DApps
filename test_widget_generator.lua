local function generic()
    local T = {}
    function T:new(args) args = args or {}; setmetatable(args, { __index = self }); if args.init then args:init() end; return args end
    function T:extend(args) args = args or {}; setmetatable(args, { __index = self }); return args end
    return T
end

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
package.preload["ui/widget/confirmbox"] = generic
package.preload["ui/widget/inputdialog"] = function() local T = generic(); function T:onShowKeyboard() end; function T:getInputText() return self.input end; return T end
package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local created, updated = nil, nil
local manager = {
    getGeneratedWidgets = function() return { { id = "generated_widget_1", title = "Morning", text = "Read calmly", show_time = true, show_date = false, show_battery = true } } end,
    createGeneratedWidget = function(_, spec) created = spec; return "generated_widget_2", spec end,
    updateGeneratedWidget = function(_, id, spec) updated = { id = id, spec = spec }; return true, spec end,
    removeGeneratedWidget = function() return true end,
}
local appdock = { isStoreWidgetEnabled = function(_, id) return id == "generated_widget_1" end }
local app = dofile("widget_generator.lua")
assert(app.id == "widget_generator" and app.version == "1.0.0" and app.logo == "settings", "WidgetGenerator must satisfy the Store DApp contract")
assert(app._test.featureSummary({ text = "x", show_time = true, show_date = false, show_battery = true }) == "Text · Time · Battery", "WidgetGenerator must expose only declarative safe fields")
local rebuilds, px_calls = 0, 0
local context = { manager = manager, appdock = appdock, dimen = { w = 600, h = 340 }, px = function(value) px_calls = px_calls + 1; return math.max(1, math.floor(value * .65 + .5)) end, requestRebuild = function(kind) assert(kind == "ui"); rebuilds = rebuilds + 1 end }
local instance = {}
local list = app.buildPane(instance, context)
assert(list and list.dimen.h == 340 and px_calls > 0, "WidgetGenerator must build a relative short split-pane layout")
local create_action
for _, child in ipairs(list[1]) do if child.title == "Create widget" then create_action = child; break end end
assert(create_action and create_action.callback, "WidgetGenerator must offer local no-code creation")
create_action.callback()
assert(instance.widget_generator.view == "edit" and rebuilds == 1, "WidgetGenerator must enter the editor without creating code")
local edit = app.buildPane(instance, context)
local save_action
for _, child in ipairs(edit[1]) do if child.title == "Save" then save_action = child; break end end
assert(save_action and save_action.callback, "WidgetGenerator editor must allow saving a declarative widget")
save_action.callback()
assert(created and created.title == "Custom widget" and instance.widget_generator.view == "list", "WidgetGenerator must save a bounded local configuration through the manager")
print("WidgetGenerator DApp test: OK")
