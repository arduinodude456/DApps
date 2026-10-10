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
local test_data_dir = os.tmpname() .. "_dchat_test"
local test_cache_dir = test_data_dir .. "/appdock_dchat_images"
os.execute("mkdir -p " .. string.format("%q", test_cache_dir))
local stale_cache_path = test_cache_dir .. "/dchat_dch_stale_999.png"
local stale_cache_file = io.open(stale_cache_path, "wb")
stale_cache_file:write("stale")
stale_cache_file:close()
local test_lfs = {
    attributes = function(path)
        if path == test_data_dir or path == test_cache_dir then return { mode = "directory" } end
        local file = io.open(path, "rb")
        if file then file:close(); return { mode = "file" } end
    end,
    mkdir = function(path)
        if path == test_cache_dir then return true end
        return nil, "unexpected test directory"
    end,
    dir = function(path)
        local entries = {}
        if path == test_cache_dir then
            local file = io.open(stale_cache_path, "rb")
            if file then file:close(); entries[1] = "dchat_dch_stale_999.png" end
        end
        local index = 0
        return function() index = index + 1; return entries[index] end
    end,
}
install("datastorage", { getDataDir = function() return test_data_dir end })
install("libs/libkoreader-lfs", test_lfs)
local Widget = class()
local Input = class()
local image_widget_files = {}
local image_widget_cache_modes = {}
local test_is_android = true
local deferred_ui_callback
local appdock_keyboard_attach_count = 0
local shown_ui_widget
function Input:paintTo() end
install("ffi/blitbuffer", { COLOR_GRAY_8 = 1, COLOR_WHITE = 2, COLOR_LIGHT_GRAY = 3, COLOR_BLACK = 4, COLOR_DARK_GRAY = 5, COLOR_DARK_GREEN = 6, COLOR_LIGHT_GREEN = 7 })
install("ui/widget/container/centercontainer", Widget)
install("ui/widget/confirmbox", Widget)
install("device", { screen = { scaleBySize = function(_, value) return value end }, isAndroid = function() return test_is_android end })
install("ui/font", { getFace = function() return {} end })
install("ui/widget/container/framecontainer", Widget)
install("ui/widget/filechooser", Widget)
install("ui/geometry", Widget)
install("ui/gesturerange", Widget)
install("ui/widget/horizontalspan", Widget)
install("ui/widget/imagewidget", { new = function(_, options)
    image_widget_files[#image_widget_files + 1] = options.file
    image_widget_cache_modes[#image_widget_cache_modes + 1] = options.file_do_cache
    return Widget:new(options)
end })
install("ui/widget/infomessage", Widget)
install("ui/widget/container/inputcontainer", Input)
install("ui/widget/inputdialog", Widget)
install("appdock_keyboard", { attach = function(dialog)
    appdock_keyboard_attach_count = appdock_keyboard_attach_count + 1
    dialog.onShowKeyboard = function(self) self.appdock_keyboard_opened = true end
    return true
end })
install("ui/widget/overlapgroup", Widget)
install("ui/widget/textboxwidget", Widget)
install("ui/widget/textwidget", Widget)
local scheduled_ui_callback
install("ui/uimanager", {
    show = function(_, widget) shown_ui_widget = widget end,
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
assert(dchat.id == "dchat" and dchat.version == "1.8.6", "DChat metadata must expose the updated version")
local background_instance = { dchat = { store = dchat._test.cloneStore({ last_background_check = 100 }) } }
local ran_early, early_reason = dchat._test.backgroundCheck(background_instance, { now = 159 })
assert(ran_early == false and early_reason == "interval", "DChat background checks must wait a full minute")
local ran_on_minute, minute_reason = dchat._test.backgroundCheck(background_instance, { now = 160 })
assert(ran_on_minute == false and minute_reason == "wifi", "DChat background check should become eligible after 60 seconds")
local native_keyboard_opened = false
local appdock_input_dialog = { onShowKeyboard = function() native_keyboard_opened = true end }
dchat._test.showInputDialog(appdock_input_dialog)
assert(appdock_keyboard_attach_count == 1, "DChat did not attach the AppDock keyboard to text input")
assert(shown_ui_widget == appdock_input_dialog, "DChat did not show the input dialog")
assert(appdock_input_dialog.appdock_keyboard_opened and not native_keyboard_opened, "DChat opened KOReader's native keyboard instead of the AppDock keyboard")
local appdock_keyboard_stub = package.preload["appdock_keyboard"]
package.preload["appdock_keyboard"] = nil
package.loaded["appdock_keyboard"] = nil
local native_fallback_dchat = assert(loadfile("dchat.lua"))()
local native_fallback_opened = false
local native_fallback_dialog = { onShowKeyboard = function() native_fallback_opened = true end }
native_fallback_dchat._test.showInputDialog(native_fallback_dialog)
assert(native_fallback_opened, "DChat did not fall back to the native keyboard when AppDock keyboard is unavailable")
package.preload["appdock_keyboard"] = appdock_keyboard_stub
package.loaded["appdock_keyboard"] = nil
assert(dchat._test.cloneDirectMessage({ id = 7, authorName = "Test", body = "ok", createdAt = "2026-10-04T00:00:00Z" }).id == "7", "numeric DM id was not normalized")
assert(dchat._test.cloneDirectMessage({ id = 8, authorName = "Test", body = "", attachmentMime = "image/png", attachmentData = "TWFudXM=", createdAt = "2026-10-04T00:00:00Z" }).attachmentData == "TWFudXM=", "PNG DM attachment was not preserved")
local oversized_image = dchat._test.cloneDirectMessage({ id = 81, authorName = "Test", body = "", attachmentMime = "image/jpeg", attachmentData = string.rep("A", 700000), createdAt = "2026-10-04T00:00:00Z" })
assert(oversized_image and oversized_image.attachmentData == "" and oversized_image.body ~= "", "oversized remote image was retained in the local DChat cache")
assert(dchat._test.dmPreview("kurz", 10) == "kurz", "short DM preview was changed")
assert(dchat._test.dmPreview(string.rep("x", 40), 36) == string.rep("x", 33) .. "...", "long DM preview was not ellipsized")
assert(dchat._test.base64Encode("Manus") == "TWFudXM=", "attachment base64 encoding failed")
assert(dchat._test.base64Decode("TWFudXM=") == "Manus", "attachment base64 decoding failed")
assert(dchat._test.base64Decode("not-base64") == nil, "invalid attachment base64 was accepted")
for _, image_type in ipairs({ { "/tmp/photo.png", "image/png" }, { "/tmp/photo.jpg", "image/jpeg" }, { "/tmp/photo.jpeg", "image/jpeg" }, { "/tmp/photo.gif", "image/gif" }, { "/tmp/photo.webp", "image/webp" } }) do
    assert(dchat._test.imageMimeForPath(image_type[1]) == image_type[2], "supported image format was not detected: " .. image_type[1])
end
local old_jpeg = dchat._test.cloneDirectMessage({ id = 9, authorName = "Test", body = "", attachmentMime = "image/jpeg", attachmentData = "TWFudXM=", createdAt = "2026-10-04T00:00:00Z" })
assert(old_jpeg and old_jpeg.attachmentData == "TWFudXM=" and old_jpeg.attachmentMime == "image/jpeg", "JPEG DM attachment was not preserved")
for _, mime in ipairs({ "image/png", "image/jpeg", "image/gif", "image/webp" }) do
    assert(dchat._test.attachmentFilePath({ attachment_files = {} }, { id = "10", attachmentMime = mime, attachmentData = "TWFudXM=" }) == nil, "Android attempted to create a local " .. mime .. " image for rendering")
end
local dm_instance = { dchat = {
    store = { recipients = { { deviceId = "dch_testrecipient123", displayName = "Test" } }, messages = {}, dm_messages = { { id = "10", authorName = "Test", body = "", createdAt = "2026-10-04T00:00:00Z", senderDeviceId = "dch_testrecipient123", readAt = "", attachmentMime = "image/png", attachmentData = "TWFudXM=" } }, endpoint = "https://example.com", dm_endpoint = "https://example.com", device_id = "", device_secret = "", display_name = "", selected_recipient_id = "dch_testrecipient123" },
    view = "dm_conversation", status = "", loading = false,
} }
local dm_context = { dimen = { w = 800, h = 600 }, px = function(v) return v end, requestRebuild = function() end, appdock = {} }
local dm_pane = dchat.buildPane(dm_instance, dm_context)
assert(io.open(stale_cache_path, "rb") == nil, "stale DChat image cache file was not removed on startup")
assert(#image_widget_files == 0, "Android DChat instantiated ImageWidget in the conversation, including emoji shortcuts")
dm_instance.dchat.view = "dm_message"
dm_instance.dchat.selected_dm_id = "10"
assert(type(dchat.buildPane(dm_instance, dm_context)) == "table", "Android DM details failed to build without image rendering")
assert(#image_widget_files == 0, "Android DChat instantiated ImageWidget in DM details")
dm_instance.dchat.view = "dm_conversation"
local function find_widget(widget, predicate, visited)
    if type(widget) ~= "table" then return nil end
    visited = visited or {}
    if visited[widget] then return nil end
    visited[widget] = true
    if predicate(widget) then return widget end
    for _, child in ipairs(widget) do
        local found = find_widget(child, predicate, visited)
        if found then return found end
    end
end
local function collect_widgets(widget, predicate, found, visited)
    if type(widget) ~= "table" then return found or {} end
    found, visited = found or {}, visited or {}
    if visited[widget] then return found end
    visited[widget] = true
    if predicate(widget) then found[#found + 1] = widget end
    for _, child in ipairs(widget) do collect_widgets(child, predicate, found, visited) end
    return found
end
local initial_bubble = find_widget(dm_pane, function(widget) return type(widget.onTapDChatBubble) == "function" end)
assert(initial_bubble and initial_bubble[1].radius == 12, "DM bubbles must use consistent rounded corners instead of becoming pill-shaped")
local refresh_button = find_widget(dm_pane, function(widget) return widget.dchat_role == "conversation_refresh" and type(widget.onTapDChatAction) == "function" end)
assert(refresh_button, "DM conversation refresh button was not built")
refresh_button:onTapDChatAction()
assert(scheduled_ui_callback and scheduled_ui_callback.delay == 0.1, "DM refresh was not deferred beyond the touch callback")
dm_instance.dchat.view = "dm"
scheduled_ui_callback.callback()
assert(dm_instance.dchat.loading == false, "stale DM refresh ran after leaving the conversation")
local kobo_dchat = assert(loadfile("dchat.lua"))()
test_is_android = false
local kobo_messages = {}
for index, mime in ipairs({ "image/png", "image/jpeg", "image/gif", "image/webp" }) do
    kobo_messages[#kobo_messages + 1] = { id = tostring(20 + index), authorName = "Test", body = "", createdAt = "2026-10-04T00:00:00Z", senderDeviceId = "dch_testrecipient123", readAt = "", attachmentMime = mime, attachmentData = "TWFudXM=" }
end
local kobo_store = dm_instance.dchat.store
kobo_store.dm_messages = kobo_messages
local kobo_instance = { dchat = { store = kobo_store, view = "dm_conversation", status = "", loading = false, dm_page = 1, attachment_files = {} } }
kobo_dchat.buildPane(kobo_instance, dm_context)
for _, image_file in ipairs(image_widget_files) do
    assert(not image_file:match("/appdock_dchat_images/"), "opening the DM conversation rendered an attachment preview")
end
kobo_instance.dchat.view = "dm_message"
for _, message in ipairs(kobo_messages) do
    kobo_instance.dchat.selected_dm_id = message.id
    assert(type(kobo_dchat.buildPane(kobo_instance, dm_context)) == "table", "Tolino/Kobo image detail pane did not build for " .. message.attachmentMime)
end
local rendered_extensions = {}
for _, image_file in ipairs(image_widget_files) do
    if image_file:match("^/tmp/") then
        rendered_extensions[image_file:match("(%.[%w]+)$")] = true
    end
end
for _, extension in ipairs({ ".png", ".jpg", ".gif", ".webp" }) do
    assert(rendered_extensions[extension], "Tolino/Kobo did not render supported image format " .. extension)
end
for index, image_file in ipairs(image_widget_files) do
    if image_file:match("/appdock_dchat_images/") then
        assert(image_widget_cache_modes[index] == false, "DChat attachment was inserted into KOReader's shared ImageWidget cache")
    end
end
for _, path in pairs(kobo_instance.dchat.attachment_files) do os.remove(path) end
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
local many_messages = {}
for index = 1, 10 do
    many_messages[index] = {
        id = tostring(100 + index), authorName = index % 2 == 0 and "Me" or "Test",
        body = index % 2 == 0 and ("msg" .. index .. " ") .. string.rep("long text ", 28) or ("msg" .. index .. " short"),
        createdAt = "2026-10-04T00:00:00Z", senderDeviceId = index % 2 == 0 and "dch_me" or "dch_testrecipient123",
        readAt = "", attachmentMime = "", attachmentData = "",
    }
end
local layout_store = dchat._test.cloneStore({
    recipients = { { deviceId = "dch_testrecipient123", displayName = "Test" } },
    dm_messages = many_messages, endpoint = "https://example.com", dm_endpoint = "https://example.com",
    device_id = "dch_me", device_secret = "secret", display_name = "Me", selected_recipient_id = "dch_testrecipient123",
})
local layout_instance = { dchat = { store = layout_store, view = "dm_conversation", status = "", loading = false, dm_scroll = 0 } }
local layout_context = { dimen = { w = 800, h = 600 }, px = function(value) return value end, requestRebuild = function() end, appdock = {} }
local layout_pane = dchat.buildPane(layout_instance, layout_context)
local bubbles = collect_widgets(layout_pane, function(widget) return type(widget.onTapDChatBubble) == "function" end)
local short_height, long_height
local newest_visible = false
for _, bubble in ipairs(bubbles) do
    assert(bubble[1].radius == 12, "all DM bubbles must use the same corner radius")
    assert(bubble.overlap_offset[2] + bubble.height <= 600, "a variable-height message bubble exceeded the conversation pane")
    if bubble.body:find("msg10", 1, true) then newest_visible = true end
    if bubble.body:find("short", 1, true) then short_height = bubble.height else long_height = bubble.height end
end
assert(#bubbles > 1 and newest_visible, "the initial chat viewport must show multiple recent messages including the newest one")
assert(short_height and long_height and long_height > short_height, "bubble heights must follow message length rather than forcing every message into one tall slot")
local scroll_surfaces = collect_widgets(layout_pane, function(widget) return type(widget.onSwipeDChatScroll) == "function" end)
local scroll_step = math.max(1, math.floor(#bubbles / 2))
for _, scroll_surface in ipairs(scroll_surfaces) do
    scroll_surface:onSwipeDChatScroll(nil, { direction = "north" })
    if layout_instance.dchat.dm_scroll == scroll_step then break end
end
assert(layout_instance.dchat.dm_scroll == scroll_step, "a northward swipe must advance roughly half a viewport into older messages")
layout_pane = dchat.buildPane(layout_instance, layout_context)
bubbles = collect_widgets(layout_pane, function(widget) return type(widget.onTapDChatBubble) == "function" end)
for _, bubble in ipairs(bubbles) do assert(not bubble.body:find("msg10", 1, true), "scrolling to older messages must remove the newest message from the visible range") end
local old_dm_instance = { dchat = { store = { recipients = { { deviceId = "dch_legacyrecipient123", displayName = "Legacy" } }, messages = {}, dm_messages = {}, endpoint = "https://example.com", dm_endpoint = "https://example.com", device_id = "", device_secret = "", display_name = "" }, view = "dm", status = "", loading = true } }
assert(dchat.buildPane(old_dm_instance, { dimen = { w = 800, h = 600 }, px = function(v) return v end, requestRebuild = function() end, appdock = {} }), "legacy DM cache pane crashed")
local dual_store = dchat._test.cloneStore({ endpoint = "https://appdock-bd7bcrzm.manus.space/" })
assert(dual_store.endpoint == "https://appdock-bd7bcrzm.manus.space", "public endpoint was not normalized")
assert(dual_store.dm_endpoint == "https://dchatdm-qkwwnvdq.manus.space", "DM endpoint was not initialized")
local dedupe_store = { recipients = {} }
dchat._test.replaceRecipients(dedupe_store, {
    { deviceId = "dch_duplicate", displayName = "Same account" },
    { deviceId = "dch_duplicate", displayName = "Same account" },
    { deviceId = "dch_other", displayName = "Same account" },
})
assert(#dedupe_store.recipients == 2, "recipient list did not remove duplicate device accounts")
local own_filter_store = { device_id = "dch_own", recipients = {} }
dchat._test.replaceRecipients(own_filter_store, {
    { deviceId = "dch_own", displayName = "This reader" },
    { deviceId = "dch_other", displayName = "Other reader" },
})
assert(#own_filter_store.recipients == 1 and own_filter_store.recipients[1].deviceId == "dch_other", "recipient list exposed the local device")
local hidden_contact_store = dchat._test.cloneStore({
    hidden_recipient_ids = { "dch_hidden" },
    recipients = {
        { deviceId = "dch_hidden", displayName = "Removed contact" },
        { deviceId = "dch_visible", displayName = "Visible contact" },
    },
})
assert(#hidden_contact_store.recipients == 1 and hidden_contact_store.recipients[1].deviceId == "dch_visible", "locally removed contacts returned after restoring the DChat cache")
dchat._test.replaceRecipients(hidden_contact_store, {
    { deviceId = "dch_hidden", displayName = "Removed contact" },
    { deviceId = "dch_visible", displayName = "Visible contact" },
})
assert(#hidden_contact_store.recipients == 1 and hidden_contact_store.recipients[1].deviceId == "dch_visible", "recipient refresh re-added a locally removed contact")
local compact_instance = { dchat = {
    store = { recipients = { { deviceId = "dch_compact", displayName = "Compact contact" } }, messages = {}, dm_messages = {}, endpoint = "https://example.com", dm_endpoint = "https://example.com", device_id = "", device_secret = "", display_name = "", hidden_recipient_ids = {} },
    view = "dm", compact_sidebar = true, status = "", loading = false, attachment_files = {},
} }
local compact_context = { dimen = { w = 210, h = 126 }, px = function(value) return value end, requestRebuild = function() end, appdock = {} }
local compact_pane = dchat.buildPane(compact_instance, compact_context)
local compact_settings = find_widget(compact_pane, function(widget) return widget.title == "Settings" and type(widget.onTapDChatAction) == "function" end)
assert(compact_settings, "compact DChat sidebar did not provide settings access")
compact_settings:onTapDChatAction()
assert(compact_instance.dchat.view == "settings", "compact DChat settings action did not change the view")
local compact_settings_pane = dchat.buildPane(compact_instance, compact_context)
assert(find_widget(compact_settings_pane, function(widget) return widget.title == "Public address" end), "compact DChat settings did not expose public service configuration")
for _, dimen in ipairs({ { w = 210, h = 126 }, { w = 800, h = 600 } }) do
    local pane = dchat.buildPane({}, { dimen = dimen, px = function(value) return value end, requestRebuild = function() end, appdock = {} })
assert(type(pane) == "table", "pane did not build")
end
local catalog = assert(io.open("dapps.txt", "rb")):read("*a")
assert(catalog:find("dchat.lua | 1.8.6 | dchat", 1, true), "DChat must be published in the DApp catalog at the updated version")
os.execute("rm -rf " .. string.format("%q", test_data_dir))
print("dchat-pane-smoke-ok")
