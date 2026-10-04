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
install("ffi/blitbuffer", { COLOR_GRAY_8 = 1, COLOR_WHITE = 2, COLOR_LIGHT_GRAY = 3, COLOR_BLACK = 4, COLOR_DARK_GRAY = 5, COLOR_DARK_GREEN = 6, COLOR_LIGHT_GREEN = 7 })
install("ui/widget/container/centercontainer", Widget)
install("ui/widget/confirmbox", Widget)
install("device", { screen = { scaleBySize = function(_, value) return value end } })
install("ui/font", { getFace = function() return {} end })
install("ui/widget/container/framecontainer", Widget)
install("ui/widget/filechooser", Widget)
install("ui/geometry", Widget)
install("ui/gesturerange", Widget)
install("ui/widget/horizontalspan", Widget)
install("ui/widget/imagewidget", Widget)
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
assert(dchat._test.cloneDirectMessage({ id = 7, authorName = "Test", body = "ok", createdAt = "2026-10-04T00:00:00Z" }).id == "7", "numeric DM id was not normalized")
assert(dchat._test.cloneDirectMessage({ id = 8, authorName = "Test", body = "", attachmentData = "a", createdAt = "2026-10-04T00:00:00Z" }).attachmentData == "a", "image-only DM was not normalized")
assert(dchat._test.dmPreview("kurz", 10) == "kurz", "short DM preview was changed")
assert(dchat._test.dmPreview(string.rep("x", 40), 36) == string.rep("x", 33) .. "...", "long DM preview was not ellipsized")
assert(dchat._test.base64Encode("Manus") == "TWFudXM=", "attachment base64 encoding failed")
local old_dm_instance = { dchat = { store = { recipients = { { deviceId = "dch_legacyrecipient123", displayName = "Legacy" } }, messages = {}, dm_messages = {}, endpoint = "https://example.com", dm_endpoint = "https://example.com", device_id = "", device_secret = "", display_name = "" }, view = "dm", status = "", loading = true } }
assert(dchat.buildPane(old_dm_instance, { dimen = { w = 800, h = 600 }, px = function(v) return v end, requestRebuild = function() end, appdock = {} }), "legacy DM cache pane crashed")
local dual_store = dchat._test.cloneStore({ endpoint = "https://appdock-bd7bcrzm.manus.space/" })
assert(dual_store.endpoint == "https://appdock-bd7bcrzm.manus.space", "public endpoint was not normalized")
assert(dual_store.dm_endpoint == "https://dchatdm-qkwwnvdq.manus.space", "DM endpoint was not initialized")
for _, dimen in ipairs({ { w = 210, h = 126 }, { w = 800, h = 600 } }) do
    local pane = dchat.buildPane({}, { dimen = dimen, px = function(value) return value end, requestRebuild = function() end, appdock = {} })
    assert(type(pane) == "table", "pane did not build")
end
print("dchat-pane-smoke-ok")
