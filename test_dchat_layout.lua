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
local image_widget_files = {}
local deferred_ui_callback
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
install("ui/widget/imagewidget", { new = function(_, options)
    image_widget_files[#image_widget_files + 1] = options.file
    return Widget:new(options)
end })
install("ui/widget/infomessage", Widget)
install("ui/widget/container/inputcontainer", Input)
install("ui/widget/inputdialog", Widget)
install("ui/widget/overlapgroup", Widget)
install("ui/widget/textboxwidget", Widget)
install("ui/widget/textwidget", Widget)
local scheduled_ui_callback
install("ui/uimanager", {
    show = function() end,
    close = function() end,
    scheduleIn = function(_, delay, callback)
        scheduled_ui_callback = { delay = delay, callback = callback }
    end,
    tickAfterNext = function(_, callback)
        deferred_ui_callback = callback
    end,
})
install("ui/widget/container/widgetcontainer", Widget)
install("gettext", function(value) return value end)
install("json", { encode = function() return "{}" end, decode = function() return {} end })
install("socket.url", { parse = function(value) return { scheme = "https", host = value:match("https://([^/]+)") } end })
_G.unpack = table.unpack or unpack
_G.G_reader_settings = { readSetting = function() return {} end, saveSetting = function() end }
local dchat = assert(loadfile("dchat.lua"))()
assert(dchat._test.cloneDirectMessage({ id = 7, authorName = "Test", body = "ok", createdAt = "2026-10-04T00:00:00Z" }).id == "7", "numeric DM id was not normalized")
assert(dchat._test.cloneDirectMessage({ id = 8, authorName = "Test", body = "", attachmentMime = "image/png", attachmentData = "TWFudXM=", createdAt = "2026-10-04T00:00:00Z" }).attachmentData == "TWFudXM=", "PNG-only DM attachment was not preserved")
assert(dchat._test.dmPreview("kurz", 10) == "kurz", "short DM preview was changed")
assert(dchat._test.dmPreview(string.rep("x", 40), 36) == string.rep("x", 33) .. "...", "long DM preview was not ellipsized")
assert(dchat._test.base64Encode("Manus") == "TWFudXM=", "attachment base64 encoding failed")
assert(dchat._test.base64Decode("TWFudXM=") == "Manus", "attachment base64 decoding failed")
assert(dchat._test.base64Decode("not-base64") == nil, "invalid attachment base64 was accepted")
assert(dchat._test.imageMimeForPath("/tmp/photo.png") == "image/png", "PNG attachment MIME was not detected")
for _, unsupported_path in ipairs({ "/tmp/photo.jpg", "/tmp/photo.jpeg", "/tmp/photo.gif", "/tmp/photo.webp" }) do
    assert(dchat._test.imageMimeForPath(unsupported_path) == nil, "non-PNG attachment was accepted: " .. unsupported_path)
end
local old_jpeg = dchat._test.cloneDirectMessage({ id = 9, authorName = "Test", body = "", attachmentMime = "image/jpeg", attachmentData = "TWFudXM=", createdAt = "2026-10-04T00:00:00Z" })
assert(old_jpeg and old_jpeg.attachmentData == "" and old_jpeg.attachmentMime == "" and old_jpeg.body:find("PNG only", 1, true), "existing JPEG DM was not safely converted to a text-only placeholder")
assert(dchat._test.attachmentFilePath({ attachment_files = {} }, { id = "10", attachmentMime = "image/jpeg", attachmentData = "TWFudXM=" }) == nil, "existing JPEG DM was decoded for inline display")
local dm_instance = { dchat = {
    store = { recipients = { { deviceId = "dch_testrecipient123", displayName = "Test" } }, messages = {}, dm_messages = { { id = "10", authorName = "Test", body = "", createdAt = "2026-10-04T00:00:00Z", senderDeviceId = "dch_testrecipient123", readAt = "", attachmentMime = "image/png", attachmentData = "TWFudXM=" } }, endpoint = "https://example.com", dm_endpoint = "https://example.com", device_id = "", device_secret = "", display_name = "", selected_recipient_id = "dch_testrecipient123" },
    view = "dm_conversation", status = "", loading = false,
} }
local dm_context = { dimen = { w = 800, h = 600 }, px = function(v) return v end, requestRebuild = function() end, appdock = {} }
local dm_pane = dchat.buildPane(dm_instance, dm_context)
local android_image_file
for _, image_file in ipairs(image_widget_files) do
    if image_file:match("^/tmp/") then android_image_file = image_file end
end
assert(android_image_file, "Android DM conversation did not restore inline image preview")
local refresh_button
for _, widget in ipairs(dm_pane) do
    if type(widget) == "table" and widget.title == "↻" then refresh_button = widget; break end
end
assert(refresh_button, "DM conversation refresh button was not built")
refresh_button:onTapDChatAction()
assert(scheduled_ui_callback and scheduled_ui_callback.delay == 0.1, "DM refresh was not deferred beyond the touch callback")
dm_instance.dchat.view = "dm"
scheduled_ui_callback.callback()
assert(dm_instance.dchat.loading == false, "stale DM refresh ran after leaving the conversation")
local kobo_dchat = assert(loadfile("dchat.lua"))()
local kobo_instance = { dchat = { store = dm_instance.dchat.store, view = "dm_conversation", status = "", loading = false } }
kobo_dchat.buildPane(kobo_instance, dm_context)
local kobo_image_file
for _, image_file in ipairs(image_widget_files) do
    if image_file:match("^/tmp/") then kobo_image_file = image_file; break end
end
assert(kobo_image_file, "Kobo inline DM image preview was not preserved")
os.remove(kobo_image_file)
os.remove(android_image_file)
local rebuild_count = 0
local deferred_state = { view = "dm_conversation" }
local deferred_context = { requestRebuild = function() rebuild_count = rebuild_count + 1 end }
dchat._test.deferConversationRefresh(deferred_state, deferred_context)
assert(rebuild_count == 0 and deferred_ui_callback, "DM refresh rebuilt the native host inside the network callback")
local pending_rebuild = deferred_ui_callback
deferred_ui_callback = nil
deferred_state.view = "dm"
pending_rebuild()
assert(rebuild_count == 0, "deferred DM refresh rebuilt after the conversation had closed")
deferred_state.view = "dm_conversation"
dchat._test.deferConversationRefresh(deferred_state, deferred_context)
pending_rebuild = deferred_ui_callback
deferred_ui_callback = nil
pending_rebuild()
assert(rebuild_count == 1, "deferred DM refresh did not rebuild an active conversation")
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
