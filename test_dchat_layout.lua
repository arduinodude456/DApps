-- Lightweight AppDock pane smoke test: verifies both requested geometries build without errors.
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
local Widget = class()
local Input = class()
function Input:paintTo() end
install("ffi/blitbuffer", { COLOR_GRAY_8 = 1, COLOR_WHITE = 2, COLOR_LIGHT_GRAY = 3, COLOR_BLACK = 4, COLOR_DARK_GRAY = 5 })
install("ui/widget/container/centercontainer", Widget)
install("ui/widget/confirmbox", Widget)
install("device", { screen = { scaleBySize = function(_, value) return value end } })
install("ui/font", { getFace = function() return {} end })
install("ui/widget/container/framecontainer", Widget)
install("ui/geometry", Widget)
install("ui/gesturerange", Widget)
install("ui/widget/horizontalspan", Widget)
install("ui/widget/infomessage", Widget)
install("ui/widget/container/inputcontainer", Input)
install("ui/widget/inputdialog", Widget)
install("ui/widget/overlapgroup", Widget)
install("ui/widget/textboxwidget", Widget)
install("ui/widget/textwidget", Widget)
install("ui/uimanager", { show = function() end, close = function() end })
install("ui/widget/container/widgetcontainer", Widget)
install("gettext", function(value) return value end)
install("json", { encode = function() return "{}" end, decode = function() return {} end })
install("socket.url", { parse = function(value) return { scheme = "https", host = value:match("https://([^/]+)") } end })
_G.unpack = table.unpack
_G.G_reader_settings = { readSetting = function() return {} end, saveSetting = function() end }
local dchat = assert(loadfile("dchat.lua"))()
assert(dchat._test.cloneStore({ endpoint = "https://appdock-bd7bcrzm.manus.space" }).endpoint == "https://dchatdm-qkwwnvdq.manus.space", "legacy endpoint was not migrated")
for _, dimen in ipairs({ { w = 210, h = 126 }, { w = 800, h = 600 } }) do
    local pane = dchat.buildPane({}, { dimen = dimen, px = function(value) return value end, requestRebuild = function() end, appdock = {} })
    assert(type(pane) == "table", "pane did not build")
end
print("dchat-pane-smoke-ok")
