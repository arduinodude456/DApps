-- Regression test for Geometry Dash level selection and approachable defaults.
local function class()
    local C = {}
    function C:new(value)
        value = value or {}
        setmetatable(value, { __index = C })
        if value.init then value:init() end
        return value
    end
    function C:extend(proto)
        local E = class()
        setmetatable(E, { __index = C })
        for key, value in pairs(proto or {}) do E[key] = value end
        return E
    end
    return C
end

local function install(name, value) package.preload[name] = function() return value end end
local Widget, Input = class(), class()
install("ffi/blitbuffer", { COLOR_WHITE = 1, COLOR_BLACK = 2, COLOR_DARK_GRAY = 3, COLOR_LIGHT_GRAY = 4 })
install("device", { screen = { scaleBySize = function(_, value) return value end }, input = { group = {} } })
install("ui/font", { getFace = function() return {} end })
install("ui/widget/container/centercontainer", Widget)
install("ui/widget/container/framecontainer", Widget)
install("ui/geometry", { new = function(_, value) return value end })
install("ui/gesturerange", { new = function(_, value) return value end })
install("ui/widget/horizontalspan", Widget)
install("ui/widget/container/inputcontainer", Input)
install("ui/widget/overlapgroup", Widget)
install("ui/widget/textwidget", Widget)
install("ui/widget/container/widgetcontainer", Widget)
install("gettext", function(value) return value end)
install("ui/uimanager", { scheduleIn = function() end, unschedule = function() end, setDirty = function() end })
_G.unpack = table.unpack or unpack

local app = assert(loadfile("geometry_dash.lua"))()
assert(app.id == "geometry_dash" and app.version == "1.0.3", "Geometry Dash must publish the expanded level release")
local test = app._test
assert(#test.levels >= 4, "Geometry Dash must offer four playable levels")
assert(test.runSpeed < 225, "The runner must be slower than the original difficulty")
assert(test.levels[1].id == "warmup" and test.levels[1].length == test.defaultLevelLength, "The first level must be a short warm-up")
for index, level in ipairs(test.levels) do
    assert(type(level.objects) == "table" and #level.objects > 0 and level.length > 0, "Every level needs obstacles and a positive finish length")
    if index > 1 then assert(level.length > test.levels[index - 1].length, "Levels must progress in length") end
end

local events = {}
local session = test.GameSession.new(function(kind, message) events[#events + 1] = { kind = kind, message = message } end)
assert(session.level_index == 1 and session.level.id == "warmup", "A new game must start on the approachable warm-up level")
session:nextLevel()
assert(session.level_index == 2 and session.level.id == "meadow" and session.paused, "Next level must reset safely before play")
session:setLevel(999)
assert(session.level_index == 1, "Invalid level selection must fall back to warm-up")
assert(#test.buildLevel(4) == #test.levels[4].objects, "The level builder must return the selected level data")
print("geometry-dash-levels-ok")
