local root = "/tmp/appdock_new_widgets_test"
os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root .. "/appdock_calendar")

local function class(prototype)
    prototype = prototype or {}; prototype.__index = prototype
    function prototype:extend(child) child = child or {}; child.__index = child; setmetatable(child, { __index = self }); return child end
    function prototype:new(args) local instance = setmetatable(args or {}, self); if instance.init then instance:init() end; return instance end
    function prototype:getSize() return self.dimen or { w = self.width or 0, h = self.height or 0 } end
    return prototype
end

local Widget = class({})
local WidgetContainer = Widget:extend({})
package.preload["ffi/blitbuffer"] = function() return { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_DARK_GRAY = "dark" } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, n) return n end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, args) return args end } end
package.preload["ui/widget/overlapgroup"] = function() return WidgetContainer end
package.preload["ui/widget/textwidget"] = function() return WidgetContainer end
package.preload["ui/widget/widget"] = function() return Widget end
package.preload["datastorage"] = function() return { getDataDir = function() return root end } end
package.preload["gettext"] = function() return function(text) return text end end

local reading = dofile("/home/ubuntu/dapps-store-repo/reading_stats_widget.lua")
local info = reading._test.readingInfo({ appdock = { ui = { document = { file = "/books/Quiet Book.epub", getCurrentPage = function() return 25 end, getPageCount = function() return 100 end } } } })
assert(info and info.title == "Quiet Book.epub" and info.page == 25 and info.pages == 100, "Reading Stats must use real active-document page information when available")
assert(reading._test.readingInfo({ appdock = { ui = {} } }) == nil, "Reading Stats must not invent progress without an active document")
local reading_card = reading.buildWidget({}, { dimen = { w = 560, h = 120 }, appdock = { ui = { document = { file = "/books/Quiet Book.epub", getCurrentPage = function() return 25 end, getPageCount = function() return 100 end } } } })
assert(reading_card and reading_card.dimen.w == 560, "Reading Stats must build inside the assigned widget dimensions")

local today = os.date("%Y-%m-%d")
local store = assert(io.open(root .. "/appdock_calendar/events.lua", "wb"))
store:write("return { version = 1, events = { { id = 2, date = '" .. today .. "', title = 'Today appointment' }, { id = 1, date = '9999-12-31', title = 'Future appointment' }, { id = 3, date = '1999-01-01', title = 'Old appointment' } } }\n")
store:close()
local calendar = dofile("/home/ubuntu/dapps-store-repo/calendar_widget.lua")
local events = calendar._test.localEvents()
assert(#events == 2 and events[1].title == "Today appointment" and events[2].title == "Future appointment", "Calendar Widget must read and sort only upcoming Calendar DApp events")
assert(calendar._test.displayDate(today):match("^%d%d%.%d%d%.$"), "Calendar Widget must render concise local dates")
local calendar_card = calendar.buildWidget({}, { dimen = { w = 560, h = 120 } })
assert(calendar_card and calendar_card.dimen.h == 120, "Calendar Widget must build inside the assigned widget dimensions")

local clock = dofile("/home/ubuntu/dapps-store-repo/analog_clock_widget.lua")
local clock_card = clock.buildWidget({}, { dimen = { w = 560, h = 120 } })
assert(clock_card and clock_card.dimen.w == 560, "Analog Clock Widget must build inside the assigned widget dimensions")
local marks = {}
clock._test.ClockFace:new{ size = 80, hour = 10, minute = 15 }:paintTo({ paintRect = function(_, x, y, w, h) marks[#marks + 1] = { x = x, y = y, w = w, h = h } end }, 0, 0)
assert(#marks > 20, "Analog Clock Widget must paint visible dial and hand geometry")

os.execute("rm -rf " .. root)
print("New AppDock Store widgets test: OK")
