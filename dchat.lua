--[[--
DChat for AppDock.

A public, text-only room plus server-side private device-to-device messages.
DChat makes no end-to-end encryption claim and has no account recovery. Its optional
background check is disabled by default and only runs through AppDock's
explicit background-notification permission.
The reader keeps a local opaque device secret; the server only receives it in
an HTTPS request and stores a one-way hash.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SETTINGS_KEY = "appdock_dchat_v1"
local LEGACY_ENDPOINT = "https://appdock-bd7bcrzm.manus.space"
local DEFAULT_ENDPOINT = LEGACY_ENDPOINT
local DEFAULT_DM_ENDPOINT = "https://dchatdm-qkwwnvdq.manus.space"
local MAX_ENDPOINT_BYTES = 240
local MAX_NAME_BYTES = 80
local MAX_TEXT_BYTES = 1500
local MAX_ATTACHMENT_BYTES = 512 * 1024
local MAX_NOTE_BYTES = 840
local MAX_RESPONSE_BYTES = 4 * 1024 * 1024
local RESPONSE_TOO_LARGE = "response too large"
local CONVERSATION_RETRY_LIMIT = 5
local MAX_CACHE_MESSAGES = 60
local MAX_VISIBLE_PER_PAGE = 5
local MAX_RECIPIENTS = 30
local CONNECT_TIMEOUT = 10
local REQUEST_MAX_TIME = 25
local BACKGROUND_CHECK_SECONDS = 15 * 60
local CHAT_GREEN = Blitbuffer.COLOR_DARK_GREEN or Blitbuffer.COLOR_GRAY_8
local CHAT_LIGHT_GREEN = Blitbuffer.COLOR_LIGHT_GREEN or Blitbuffer.COLOR_LIGHT_GRAY
local CHAT_BACKGROUND = Blitbuffer.COLOR_LIGHT_GRAY
local DM_EMOJIS = { "😀", "😂", "😍", "👍", "❤️" }
local DM_EMOJI_FILES = { "smile.png", "laugh.png", "heart.png", "thumbs.png", "surprise.png" }
local DM_EMOJI_LABELS = { ":)", "XD", "<3", "+1", "!!" }
local DCHAT_SOURCE_DIR = (debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "")

local function scale(value)
    return Device.screen:scaleBySize(value)
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function emptySizedWidget(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local function safeText(value, maximum)
    value = trim(value):gsub("[%c]", " "):gsub("%s+", " ")
    if value == "" or #value > maximum then return nil end
    return value
end

local function cloneMessage(raw)
    if type(raw) ~= "table" then return nil end
    local id = trim(tostring(raw.id or ""))
    local author_name = safeText(raw.authorName, MAX_NAME_BYTES)
    local body = safeText(raw.body, MAX_TEXT_BYTES)
    local created_at = trim(tostring(raw.createdAt or "")):sub(1, 48)
    if not id:match("^%d+$") or not author_name or not body then return nil end
    return { id = id, authorName = author_name, body = body, createdAt = created_at }
end

local function cloneRecipient(raw)
    if type(raw) ~= "table" then return nil end
    local device_id = trim(raw.deviceId):sub(1, 64)
    local display_name = safeText(raw.displayName, MAX_NAME_BYTES)
    if not device_id:match("^dch_[%w_%-]+$") or not display_name then return nil end
    return { deviceId = device_id, displayName = display_name, unreadCount = tonumber(raw.unreadCount) or 0 }
end

local function cloneDirectMessage(raw)
    if type(raw) ~= "table" then return nil end
    local id = trim(tostring(raw.id or ""))
    local author_name = safeText(raw.authorName, MAX_NAME_BYTES)
    local body = safeText(raw.body or "", MAX_TEXT_BYTES) or ""
    local created_at = trim(tostring(raw.createdAt or "")):sub(1, 48)
    local attachment_mime = trim(tostring(raw.attachmentMime or ""))
    local attachment_data = trim(tostring(raw.attachmentData or ""))
    if not id:match("^%d+$") or not author_name or (body == "" and attachment_data == "") then return nil end
    return { id = id, authorName = author_name, body = body, createdAt = created_at, senderDeviceId = trim(tostring(raw.senderDeviceId or "")), readAt = trim(tostring(raw.readAt or "")), attachmentMime = attachment_mime, attachmentData = attachment_data }
end

local function cloneStore(raw)
    raw = type(raw) == "table" and raw or {}
    local messages, seen = {}, {}
    local recipients, recipient_seen = {}, {}
    local dm_messages, dm_seen = {}, {}
    for index, raw_message in ipairs(type(raw.messages) == "table" and raw.messages or {}) do
        local message = cloneMessage(raw_message)
        if message and not seen[message.id] and #messages < MAX_CACHE_MESSAGES then
            seen[message.id] = true
            messages[#messages + 1] = message
        end
    end
    for index, raw_recipient in ipairs(type(raw.recipients) == "table" and raw.recipients or {}) do
        local recipient = cloneRecipient(raw_recipient)
        if recipient and not recipient_seen[recipient.deviceId] and #recipients < MAX_RECIPIENTS then
            recipient_seen[recipient.deviceId] = true
            recipients[#recipients + 1] = recipient
        end
    end
    for index, raw_dm_message in ipairs(type(raw.dm_messages) == "table" and raw.dm_messages or {}) do
        local message = cloneDirectMessage(raw_dm_message)
        if message and not dm_seen[message.id] and #dm_messages < MAX_CACHE_MESSAGES then
            dm_seen[message.id] = true
            dm_messages[#dm_messages + 1] = message
        end
    end
    local saved_endpoint = trim(raw.endpoint):gsub("/+$", "")
    if saved_endpoint == "" then saved_endpoint = DEFAULT_ENDPOINT end
    local saved_dm_endpoint = trim(raw.dm_endpoint):gsub("/+$", "")
    if saved_dm_endpoint == "" or saved_dm_endpoint == LEGACY_ENDPOINT then saved_dm_endpoint = DEFAULT_DM_ENDPOINT end
    return {
        endpoint = saved_endpoint:gsub("/+$", ""):sub(1, MAX_ENDPOINT_BYTES),
        dm_endpoint = saved_dm_endpoint:sub(1, MAX_ENDPOINT_BYTES),
        device_id = trim(raw.device_id):sub(1, 52),
        device_secret = trim(raw.device_secret):sub(1, 128),
        display_name = safeText(raw.display_name, MAX_NAME_BYTES) or "",
        messages = messages,
        recipients = recipients,
        dm_messages = dm_messages,
        selected_recipient_id = trim(raw.selected_recipient_id):match("^dch_[%w_%-]+$") and trim(raw.selected_recipient_id) or "",
        selected_recipient_name = safeText(raw.selected_recipient_name, MAX_NAME_BYTES) or "",
        last_refresh = tonumber(raw.last_refresh) or 0,
        last_background_check = math.max(0, math.floor(tonumber(raw.last_background_check) or 0)),
        last_seen_message_id = trim(raw.last_seen_message_id):match("^%d+$") and trim(raw.last_seen_message_id) or "",
        background_baseline_ready = raw.background_baseline_ready == true,
    }
end

local function loadStore()
    return cloneStore(G_reader_settings:readSetting(SETTINGS_KEY, {}))
end

local function saveStore(store)
    G_reader_settings:saveSetting(SETTINGS_KEY, cloneStore(store))
end

local function validEndpoint(value)
    value = trim(value):gsub("/+$", "")
    if value == "" or #value > MAX_ENDPOINT_BYTES or value:find("[%c%s]") then return nil, _("Enter the HTTPS address of the public DChat service.") end
    local ok, socket_url = pcall(require, "socket.url")
    if not ok or not socket_url then return nil, _("URL support is unavailable.") end
    local parsed = socket_url.parse(value)
    if not parsed or parsed.scheme ~= "https" or not parsed.host or parsed.host == "" or parsed.userinfo or parsed.query or parsed.fragment or (parsed.path and parsed.path ~= "") then
        return nil, _("Use an HTTPS service address without a path, login or query.")
    end
    return value
end

local function hasIdentity(store)
    return store.device_id:match("^dch_[%w_%-]+$") and store.device_secret:match("^[%w_%-]+$") and store.display_name ~= ""
end

local function randomHex(bytes)
    local file = io.open("/dev/urandom", "rb")
    if not file then return nil end
    local data = file:read(bytes)
    file:close()
    if type(data) ~= "string" or #data ~= bytes then return nil end
    return (data:gsub(".", function(character) return string.format("%02x", string.byte(character)) end))
end

local function newIdentity()
    local public_part, secret_part = randomHex(12), randomHex(24)
    if not public_part or not secret_part then return nil, _("The reader could not create a secure local device identity.") end
    return "dch_" .. public_part, secret_part
end

local function apiUrl(store, suffix, endpoint_override)
    local endpoint, err = validEndpoint(endpoint_override or store.endpoint)
    if not endpoint then return nil, err end
    return endpoint .. "/api/dchat/v1" .. suffix
end

local function httpJson(store, method, suffix, payload, include_identity, endpoint_override)
    local url, url_err = apiUrl(store, suffix, endpoint_override)
    if not url then return nil, nil, url_err end
    local ok_https, https = pcall(require, "ssl.https")
    local ok_socket, socket = pcall(require, "socket")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_util, socketutil = pcall(require, "socketutil")
    local ok_json, JSON = pcall(require, "json")
    if not ok_https or not ok_socket or not ok_ltn12 or not ok_util or not ok_json then return nil, nil, _("HTTPS or JSON support is unavailable.") end
    local chunks, received = {}, 0
    local function sink(chunk, sink_err)
        if sink_err then return nil, sink_err end
        if chunk then
            received = received + #chunk
            if received > MAX_RESPONSE_BYTES then return nil, RESPONSE_TOO_LARGE end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    local headers = { ["accept"] = "application/json", ["user-agent"] = "AppDock-DChat/1.1" }
    local body = nil
    if payload then
        local encoded_ok, encoded = pcall(JSON.encode, payload)
        if not encoded_ok or type(encoded) ~= "string" or #encoded > MAX_RESPONSE_BYTES then return nil, nil, _("The DChat request could not be encoded.") end
        body = encoded
        headers["content-type"] = "application/json"
        headers["content-length"] = tostring(#body)
    end
    if include_identity then
        if not hasIdentity(store) then return nil, nil, _("Create a local DChat identity first.") end
        headers["x-dchat-device-id"] = store.device_id
        headers["x-dchat-device-secret"] = store.device_secret
    end
    -- Match AppDock's established KOReader HTTPS transport. KOReader's LuaSec
    -- bundle owns TLS/SNI behavior; forcing a separate CA mode here can fail on
    -- readers that do not ship a system CA bundle.
    local request = { url = url, method = method, sink = sink, headers = headers }
    if body then request.source = ltn12.source.string(body) end
    socketutil:set_timeout(CONNECT_TIMEOUT, REQUEST_MAX_TIME)
    local ok, code, response_headers, status = pcall(function() return socket.skip(1, https.request(request)) end)
    socketutil:reset_timeout()
    code = tonumber(code)
    local response_body = table.concat(chunks)
    local decoded = nil
    if response_body ~= "" then
        local decoded_ok, result = pcall(JSON.decode, response_body, JSON.decode.simple)
        if decoded_ok and type(result) == "table" then decoded = result end
    end
    if not ok or not response_headers then
        if status == RESPONSE_TOO_LARGE then return nil, nil, RESPONSE_TOO_LARGE end
        local detail = safeText(tostring(status or code or ""), 160)
        local message = _("DChat could not reach the service. Your saved messages remain on this reader.")
        if detail and detail ~= "" then message = message .. " " .. detail end
        return nil, nil, message
    end
    if not code then return nil, nil, _("DChat could not reach the service. Your saved messages remain on this reader.") end
    if code < 200 or code > 299 then
        local message = decoded and decoded.error and safeText(decoded.error.message, 240)
        return nil, code, message or _("The DChat service refused the request.")
    end
    if not decoded then return nil, code, _("The DChat service returned invalid data.") end
    return decoded, code
end

local function replaceMessages(store, raw_messages)
    local messages, seen = {}, {}
    for index, raw_message in ipairs(type(raw_messages) == "table" and raw_messages or {}) do
        local message = cloneMessage(raw_message)
        if message and not seen[message.id] and #messages < MAX_CACHE_MESSAGES then
            seen[message.id] = true
            messages[#messages + 1] = message
        end
    end
    store.messages = messages
    store.last_refresh = os.time()
end

local function replaceRecipients(store, raw_recipients)
    local recipients, seen = {}, {}
    for _, raw_recipient in ipairs(type(raw_recipients) == "table" and raw_recipients or {}) do
        local recipient = cloneRecipient(raw_recipient)
        if recipient and not seen[recipient.deviceId] and #recipients < MAX_RECIPIENTS then
            seen[recipient.deviceId] = true
            recipients[#recipients + 1] = recipient
        end
    end
    store.recipients = recipients
end

local function replaceDirectMessages(store, raw_messages)
    local messages, seen = {}, {}
    for _, raw_message in ipairs(type(raw_messages) == "table" and raw_messages or {}) do
        local message = cloneDirectMessage(raw_message)
        if message and not seen[message.id] and #messages < MAX_CACHE_MESSAGES then
            seen[message.id] = true
            messages[#messages + 1] = message
        end
    end
    store.dm_messages = messages
end

local function urlEncode(value)
    return tostring(value):gsub("([^%w%-_%.~])", function(character) return string.format("%%%02X", string.byte(character)) end)
end

local function base64Encode(data)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local output = {}
    for index = 1, #data, 3 do
        local a, b, c = data:byte(index, index + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        output[#output + 1] = alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
            .. alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
            .. (b and alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
            .. (c and alphabet:sub(n % 64 + 1, n % 64 + 1) or "=")
    end
    return table.concat(output)
end

local function base64Decode(data)
    if type(data) ~= "string" then return nil end
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local decoded = {}
    data = data:gsub("%s", "")
    if data == "" or #data % 4 ~= 0 or data:find("[^%w%+/=]") or (data:find("=", 1, true) and not (data:match("^[%w%+/]+=$") or data:match("^[%w%+/]+==$"))) then return nil end
    for index = 1, #data, 4 do
        local a, b, c, d = data:sub(index, index + 3):match("^(%S)(%S)(%S)(%S)$")
        local va, vb = alphabet:find(a, 1, true), alphabet:find(b, 1, true)
        if not va or not vb then return nil end
        local vc = c == "=" and 0 or (alphabet:find(c, 1, true) or 0) - 1
        local vd = d == "=" and 0 or (alphabet:find(d, 1, true) or 0) - 1
        if not vc or not vd then return nil end
        local n = (va - 1) * 262144 + (vb - 1) * 4096 + vc * 64 + vd
        decoded[#decoded + 1] = string.char(math.floor(n / 65536) % 256)
        if c ~= "=" then decoded[#decoded + 1] = string.char(math.floor(n / 256) % 256) end
        if d ~= "=" then decoded[#decoded + 1] = string.char(n % 256) end
    end
    return table.concat(decoded)
end

local function newestMessageId(messages)
    local newest_id, newest_number = "", -1
    for _, message in ipairs(messages or {}) do
        local numeric_id = tonumber(message.id)
        if numeric_id and numeric_id > newest_number then newest_id, newest_number = message.id, numeric_id end
    end
    return newest_id, newest_number
end

local function markMessagesSeen(store)
    local newest_id = newestMessageId(store.messages)
    if newest_id ~= "" then store.last_seen_message_id = newest_id end
    store.background_baseline_ready = true
end

local function countNewMessages(messages, last_seen_message_id)
    local seen_number = tonumber(last_seen_message_id)
    if not seen_number then return 0 end
    local count = 0
    for _, message in ipairs(messages or {}) do
        local numeric_id = tonumber(message.id)
        if numeric_id and numeric_id > seen_number then count = count + 1 end
    end
    return count
end

local function wifiIsOn()
    local loaded, NetworkMgr = pcall(require, "ui/network/manager")
    if not loaded or not NetworkMgr or type(NetworkMgr.isWifiOn) ~= "function" then return false end
    local state_ok, wifi_on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return state_ok and wifi_on == true
end

local function stateFor(instance)
    instance.dchat = instance.dchat or { store = loadStore(), view = "timeline", page = 1, dm_page = 1, selected_id = nil, selected_dm_id = nil, status = _("Public DChat service ready. Create a local identity before posting or reporting."), loading = false, attachment_files = {} }
    return instance.dchat
end

local function refresh(context)
    context.requestRebuild("ui")
end

local function setEndpoint(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Public DChat service"), input = state.store.endpoint, input_hint = "https://dchat.example.org",
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Save"), is_enter_default = true, callback = function()
            local endpoint, err = validEndpoint(dialog:getInputText())
            if not endpoint then state.status = err; UIManager:close(dialog); refresh(context); return end
            state.store.endpoint = endpoint
            state.store.last_background_check, state.store.last_seen_message_id, state.store.background_baseline_ready = 0, "", false
            saveStore(state.store)
            state.status = _("Public service address saved locally. Create an identity before posting or reporting.")
            UIManager:close(dialog)
            refresh(context)
        end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function setDMEndpoint(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Private DM service"), input = state.store.dm_endpoint, input_hint = "https://dchatdm.example.org",
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Save"), is_enter_default = true, callback = function()
            local endpoint, err = validEndpoint(dialog:getInputText())
            if not endpoint then state.status = err; UIManager:close(dialog); refresh(context); return end
            state.store.dm_endpoint = endpoint
            saveStore(state.store)
            state.status = _("DM service address saved locally.")
            UIManager:close(dialog)
            refresh(context)
        end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function registerIdentity(state, context, display_name)
    local name = safeText(display_name, MAX_NAME_BYTES)
    if not name or #name < 3 then state.status = _("Use a display name with 3–24 visible characters."); refresh(context); return end
    local device_id, device_secret = newIdentity()
    if not device_id then state.status = device_secret; refresh(context); return end
    local draft = cloneStore(state.store)
    draft.device_id, draft.device_secret, draft.display_name = device_id, device_secret, name
    local response, code, err = httpJson(draft, "POST", "/devices", { deviceId = device_id, deviceSecret = device_secret, displayName = name }, false)
    if not response then
        state.status = err or _("DChat identity registration failed.")
        refresh(context)
        return
    end
    local dm_response = httpJson(draft, "POST", "/devices", { deviceId = device_id, deviceSecret = device_secret, displayName = name }, false, draft.dm_endpoint)
    state.store.device_id, state.store.device_secret, state.store.display_name = device_id, device_secret, name
    saveStore(state.store)
    state.status = dm_response and _("Local DChat identity registered for public chat and DMs. This identity cannot be recovered after reset.") or _("Public identity registered; DMs will retry registration on first use.")
    refresh(context)
end

local function promptIdentity(state, context, reset)
    local dialog
    dialog = InputDialog:new{
        title = reset and _("Reset local identity") or _("Create local identity"), input = reset and "" or state.store.display_name, input_hint = _("Display name (3–24 characters)"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Create"), is_enter_default = true, callback = function()
            local name = dialog:getInputText()
            UIManager:close(dialog)
            registerIdentity(state, context, name)
        end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function createOrResetIdentity(state, context)
    if not hasIdentity(state.store) then promptIdentity(state, context, false); return end
    UIManager:show(ConfirmBox:new{
        text = _("Reset this reader's DChat identity?\n\nThe current local device secret cannot be recovered or transferred. You will lose the ability to act as this identity. Public messages already posted remain public."),
        ok_text = _("Reset identity"),
        ok_callback = function() promptIdentity(state, context, true) end,
    })
end

local function fetchMessages(state, context)
    if state.loading then return end
    state.loading = true
    state.status = _("Refreshing public messages…")
    refresh(context)
    local response, code, err = httpJson(state.store, "GET", "/messages?limit=" .. tostring(MAX_CACHE_MESSAGES), nil, false)
    state.loading = false
    if not response or type(response.messages) ~= "table" then
        state.status = err or _("DChat refresh failed. The previous local cache is still shown.")
        refresh(context)
        return
    end
    replaceMessages(state.store, response.messages)
    markMessagesSeen(state.store)
    state.page = 1
    saveStore(state.store)
    state.status = #state.store.messages == 0 and _("No public messages yet.") or _("Public messages refreshed manually.")
    refresh(context)
end

local function backgroundCheck(instance, context)
    local state = stateFor(instance)
    local now = math.max(0, math.floor(tonumber(context and context.now) or os.time()))
    if now - state.store.last_background_check < BACKGROUND_CHECK_SECONDS then return false, "interval" end
    if not wifiIsOn() then return false, "wifi" end
    state.store.last_background_check = now
    local response = httpJson(state.store, "GET", "/messages?limit=" .. tostring(MAX_CACHE_MESSAGES), nil, false)
    if type(response) ~= "table" or type(response.messages) ~= "table" then
        saveStore(state.store)
        return false, "network"
    end
    local previous_seen = state.store.last_seen_message_id
    replaceMessages(state.store, response.messages)
    local newest_id = newestMessageId(state.store.messages)
    if not state.store.background_baseline_ready then
        state.store.last_seen_message_id = newest_id
        state.store.background_baseline_ready = true
        saveStore(state.store)
        return true, "baseline"
    end
    local new_count = previous_seen == "" and #state.store.messages or countNewMessages(state.store.messages, previous_seen)
    state.store.last_seen_message_id = newest_id ~= "" and newest_id or previous_seen
    saveStore(state.store)
    if new_count > 0 and context and type(context.notify) == "function" then
        pcall(context.notify, {
            title = _("DChat"),
            message = new_count == 1 and _("1 new public message in AppDock Lounge.") or string.format(_("%d new public messages in AppDock Lounge."), new_count),
            source = "DChat",
            priority = "normal",
        })
        return true, "notified"
    end
    return true, "current"
end

local function sendMessage(state, context, text)
    local message = safeText(text, MAX_TEXT_BYTES)
    if not message or #message > 500 then state.status = _("Use a plain-text message between 1 and 500 characters."); refresh(context); return end
    local response, code, err = httpJson(state.store, "POST", "/messages", { text = message }, true)
    if not response then state.status = err or _("Message could not be sent."); refresh(context); return end
    state.status = _("Message sent publicly. DChat has no private messages or encryption.")
    fetchMessages(state, context)
end

local function promptMessage(state, context)
    if not hasIdentity(state.store) then state.status = _("Create a local identity before sending a public message."); refresh(context); return end
    local dialog
    dialog = InputDialog:new{
        title = _("Send public message"), input = "", input_hint = _("Plain text, up to 500 characters"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Send"), is_enter_default = true, callback = function()
            local text = dialog:getInputText()
            UIManager:close(dialog)
            sendMessage(state, context, text)
        end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function selectedRecipient(state)
    for _, recipient in ipairs(state.store.recipients or {}) do
        if recipient.deviceId == state.store.selected_recipient_id then return recipient end
    end
end

local function registerExistingIdentity(state)
    if not hasIdentity(state.store) then return false end
    local response = httpJson(state.store, "POST", "/devices", {
        deviceId = state.store.device_id,
        deviceSecret = state.store.device_secret,
        displayName = state.store.display_name,
    }, false, state.store.dm_endpoint)
    return response ~= nil
end

local function fetchRecipients(state, context, query)
    if state.loading then return end
    state.loading = true
    state.status = _("Searching DChat recipients…")
    refresh(context)
    local clean_query = trim(query or "")
    if #clean_query > MAX_NAME_BYTES then clean_query = clean_query:sub(1, MAX_NAME_BYTES) end
    local suffix = "/recipients?limit=" .. tostring(MAX_RECIPIENTS)
    if clean_query ~= "" then suffix = suffix .. "&q=" .. urlEncode(clean_query) end
    local response, code, err = httpJson(state.store, "GET", suffix, nil, true, state.store.dm_endpoint)
    if not response and code == 401 and registerExistingIdentity(state) then
        response, code, err = httpJson(state.store, "GET", suffix, nil, true, state.store.dm_endpoint)
    end
    state.loading = false
    if not response or type(response.recipients) ~= "table" then
        state.status = err or _("Recipient search failed.")
        refresh(context)
        return
    end
    replaceRecipients(state.store, response.recipients)
    saveStore(state.store)
    state.status = #state.store.recipients == 0 and _("No recipients found.") or _("Recipients refreshed manually.")
    refresh(context)
end

local function fetchConversation(state, context)
    if state.loading or state.store.selected_recipient_id == "" then return end
    state.loading = true
    state.status = _("Refreshing private conversation…")
    refresh(context)
    local conversation_path = "/dms/" .. urlEncode(state.store.selected_recipient_id)
    local response, code, err = httpJson(state.store, "GET", conversation_path .. "?limit=" .. tostring(MAX_CACHE_MESSAGES), nil, true, state.store.dm_endpoint)
    if not response and err == RESPONSE_TOO_LARGE then
        response, code, err = httpJson(state.store, "GET", conversation_path .. "?limit=" .. tostring(CONVERSATION_RETRY_LIMIT), nil, true, state.store.dm_endpoint)
    end
    state.loading = false
    if not response or type(response.conversation) ~= "table" then
        state.status = err == RESPONSE_TOO_LARGE and _("This chat contains very large attachments. The latest messages could not be loaded; saved messages remain on this reader.") or (err or _("Private conversation could not be loaded."))
        refresh(context)
        return
    end
    state.store.selected_recipient_name = safeText(response.conversation.displayName, MAX_NAME_BYTES) or state.store.selected_recipient_name
    replaceDirectMessages(state.store, response.conversation.messages)
    state.dm_page = math.max(1, math.ceil(#state.store.dm_messages / MAX_VISIBLE_PER_PAGE))
    saveStore(state.store)
    state.status = #state.store.dm_messages == 0 and _("No private messages yet.") or _("Private conversation refreshed.")
    refresh(context)
end

local function deleteConversation(state, context)
    if state.store.selected_recipient_id == "" then return end
    local response, code, err = httpJson(state.store, "DELETE", "/dms/" .. urlEncode(state.store.selected_recipient_id), nil, true, state.store.dm_endpoint)
    if not response or response.deleted ~= true then
        state.status = err or _("The private chat could not be deleted.")
        refresh(context)
        return
    end
    state.store.dm_messages = {}
    state.store.selected_recipient_id = ""
    state.store.selected_recipient_name = ""
    state.selected_dm_id = nil
    state.dm_page = 1
    state.view = "dm"
    saveStore(state.store)
    state.status = _("Private chat deleted from the server.")
    refresh(context)
end

local function confirmDeleteConversation(state, context)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this private chat and all server-stored messages for both participants? This cannot be undone."),
        ok_text = _("Delete chat"),
        ok_callback = function() deleteConversation(state, context) end,
    })
end

local function openPrivateChats(state, context)
    if not hasIdentity(state.store) then state.status = _("Create a local identity before opening private chats."); refresh(context); return end
    state.view = "dm"
    fetchRecipients(state, context, "")
end

local function promptRecipientSearch(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Find recipient"), input = "", input_hint = _("Display name or device ID"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Search"), is_enter_default = true, callback = function() local query = dialog:getInputText(); UIManager:close(dialog); fetchRecipients(state, context, query) end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function sendDirectMessage(state, context, text, attachment)
    local recipient = selectedRecipient(state)
    local message = safeText(text, MAX_TEXT_BYTES)
    if not recipient or (not message and not attachment) then state.status = _("Choose a recipient and use text or a small image."); refresh(context); return end
    local response, code, err = httpJson(state.store, "POST", "/dms", { recipientDeviceId = recipient.deviceId, text = message or "", attachment = attachment }, true, state.store.dm_endpoint)
    if not response then state.status = err or _("Private message could not be sent."); refresh(context); return end
    state.status = _("Private message sent. It is stored server-side and is not end-to-end encrypted.")
    fetchConversation(state, context)
end

local function promptDirectMessage(state, context, initial_text)
    if not hasIdentity(state.store) then state.status = _("Create a local identity before sending a private message."); refresh(context); return end
    if not selectedRecipient(state) then state.status = _("Choose a recipient first."); refresh(context); return end
    local dialog
    dialog = InputDialog:new{
        title = _("Send private message"), input = initial_text or "", input_hint = _("Text or attached image, up to 1500 characters"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Send"), is_enter_default = true, callback = function() local text = dialog:getInputText(); UIManager:close(dialog); sendDirectMessage(state, context, text, nil) end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function selectedMessage(state)
    for index, message in ipairs(state.store.messages) do if message.id == state.selected_id then return message end end
end

local function chooseImageAttachment(state, context)
    local function attachPath(path)
        path = trim(path)
        local file = io.open(path, "rb")
        if not file then state.status = _("The image could not be opened."); refresh(context); return end
        local data = file:read(MAX_ATTACHMENT_BYTES + 1); file:close()
        local lower = path:lower()
        local mime = lower:match("%.png$") and "image/png" or lower:match("%.jpe?g$") and "image/jpeg" or lower:match("%.gif$") and "image/gif" or lower:match("%.webp$") and "image/webp"
        if not mime then state.status = _("Use a PNG, JPEG, GIF or WEBP image."); refresh(context); return end
        if not data or #data > MAX_ATTACHMENT_BYTES then state.status = _("Images are limited to 512 KB."); refresh(context); return end
        sendDirectMessage(state, context, "", { mime = mime, data = base64Encode(data) })
    end
    local ok_chooser, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok_chooser and FileChooser then
        local chooser_ui = {
            selected_files = {},
            folder_shortcuts = {
                getShortcutFullName = function() return nil end,
                hasShortcut = function() return false end,
                hasFolderShortcut = function() return false end,
            },
        }
        local ok_new, chooser = pcall(function()
            return FileChooser:new{ name = "dchat_attachment", ui = chooser_ui, path = Device.home_dir or "/", show_path = true, file_filter = function(filename)
                return tostring(filename):lower():match("%.(png|jpe?g|gif|webp)$") ~= nil
            end }
        end)
        if ok_new and chooser then
            function chooser:onFileSelect(item)
                local path = item and item.path
                UIManager:close(self)
                if path then attachPath(path) else state.status = _("The image could not be opened."); refresh(context) end
                return true
            end
            UIManager:show(chooser)
            return
        end
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Attach image"), input = Device.home_dir and (Device.home_dir .. "/") or "/", input_hint = _("Full path to PNG, JPEG, GIF or WEBP (max. 512 KB)"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Attach"), is_enter_default = true, callback = function()
            local path = dialog:getInputText()
            UIManager:close(dialog)
            attachPath(path)
        end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function selectedDirectMessage(state)
    for _, message in ipairs(state.store.dm_messages or {}) do if message.id == state.selected_dm_id then return message end end
end

local function reportMessage(state, context, category, note)
    local message = selectedMessage(state)
    if not message then state.status = _("That cached message is no longer available."); state.view = "timeline"; refresh(context); return end
    local clean_note = trim(note or "")
    if clean_note ~= "" then clean_note = safeText(clean_note, MAX_NOTE_BYTES); if not clean_note or #clean_note > 280 then state.status = _("A report note must be plain text with at most 280 characters."); refresh(context); return end end
    local response, code, err = httpJson(state.store, "POST", "/reports", { messageId = message.id, category = category, note = clean_note == "" and nil or clean_note }, true)
    state.status = response and _("Report sent to AppDock moderation.") or (err or _("The report could not be sent."))
    refresh(context)
end

local function promptReport(state, context)
    if not hasIdentity(state.store) then state.status = _("Create a local identity before reporting."); refresh(context); return end
    local dialog
    dialog = InputDialog:new{
        title = _("Report public message"), input = "", input_hint = _("Optional note for moderation"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Spam"), callback = function() local note = dialog:getInputText(); UIManager:close(dialog); reportMessage(state, context, "spam", note) end }, { text = _("Abuse"), is_enter_default = true, callback = function() local note = dialog:getInputText(); UIManager:close(dialog); reportMessage(state, context, "abuse", note) end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local ActionButton = InputContainer:extend{ width = nil, height = nil, title = "", primary = false, callback = nil }
function ActionButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local content = self.body and TextBoxWidget:new{ text = self.body, face = Font:getFace("smallinfofont", math.max(scale(9), math.floor(self.height * .24))), width = self.width - scale(14), height = self.height - scale(8), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK } or CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", math.max(scale(9), math.floor(self.height * .28))), fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, bold = self.primary, max_width = self.width - scale(10) } }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = self.body and scale(7) or 0, bordersize = 0, radius = math.max(4, math.floor(self.height * .2)), background = self.bubble_background or (self.primary and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY),
        content,
    }
    self.ges_events = { TapDChatAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function ActionButton:paintTo(bb, x, y)
    local range = self.ges_events.TapDChatAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function ActionButton:onTapDChatAction()
    if self.callback then self.callback() end
    return true
end

local EmojiButton = InputContainer:extend{ width = nil, height = nil, image_file = nil, fallback = "?", callback = nil }
function EmojiButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local image_file = io.open(self.image_file, "rb")
    if image_file then image_file:close() end
    local icon = image_file and ImageWidget:new{ file = self.image_file, width = self.height - 4, height = self.height - 4, scale_factor = 0, alpha = true } or emptySizedWidget(self.height - 4, self.height - 4)
    local fallback = TextWidget:new{ text = self.fallback, face = Font:getFace("cfont", math.max(scale(8), math.floor(self.height * .24))), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { 2, self.height - scale(14) } }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 2, bordersize = 0, radius = math.max(4, math.floor(self.height * .2)), background = Blitbuffer.COLOR_WHITE, OverlapGroup:new{ dimen = self.dimen, CenterContainer:new{ dimen = self.dimen, icon }, fallback } }
    self.ges_events = { TapDChatEmoji = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function EmojiButton:paintTo(bb, x, y)
    local range = self.ges_events.TapDChatEmoji[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function EmojiButton:onTapDChatEmoji()
    if self.callback then self.callback() end
    return true
end

local function messageButton(width, height, message, callback)
    return ActionButton:new{ width = width, height = height, title = message.authorName .. ": " .. message.body, callback = callback }
end

local function timelinePane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap = math.max(px(8), math.floor(width / 70)), math.max(px(5), math.floor(width / 130))
    local button_height = math.max(px(32), math.floor(height / 16))
    local row_height = math.max(px(45), math.floor(height / 9))
    local content_y = margin + px(69) + button_height + gap
    local content_end = height - margin - button_height - gap
    local start_index = (state.page - 1) * MAX_VISIBLE_PER_PAGE + 1
    local total_pages = math.max(1, math.ceil(#state.store.messages / MAX_VISIBLE_PER_PAGE))
    state.page = math.max(1, math.min(state.page, total_pages))
    start_index = (state.page - 1) * MAX_VISIBLE_PER_PAGE + 1
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = _("AppDock Lounge"), face = Font:getFace("cfont", px(21)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin, margin } },
        TextWidget:new{ text = _("Public text room · private chats are server-stored, not end-to-end encrypted"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(28) } },
        ActionButton:new{ width = third, height = button_height, title = _("Refresh"), primary = true, callback = function() fetchMessages(state, context) end, overlap_offset = { margin, margin + px(62) } },
        ActionButton:new{ width = third, height = button_height, title = _("Send"), callback = function() promptMessage(state, context) end, overlap_offset = { margin + third + gap, margin + px(62) } },
        ActionButton:new{ width = third, height = button_height, title = _("DMs"), callback = function() openPrivateChats(state, context) end, overlap_offset = { margin + 2 * (third + gap), margin + px(62) } },
    }
    local y = content_y
    if #state.store.messages == 0 then
        elements[#elements + 1] = TextBoxWidget:new{ text = _("No local message cache yet. Tap Refresh after configuring the public service address."), face = Font:getFace("smallinfofont", px(12)), width = width - 2 * margin, height = math.max(px(76), math.floor(height / 5)), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, y } }
    else
        for index = start_index, math.min(#state.store.messages, start_index + MAX_VISIBLE_PER_PAGE - 1) do
            local message = state.store.messages[index]
            if y + row_height > content_end then break end
            elements[#elements + 1] = messageButton(width - 2 * margin, row_height, message, function() state.selected_id = message.id; state.view = "message"; refresh(context) end)
            elements[#elements].overlap_offset = { margin, y }
            y = y + row_height + gap
        end
    end
    local half = math.floor((width - 2 * margin - gap) / 2)
    elements[#elements + 1] = ActionButton:new{ width = half, height = button_height, title = _("Settings"), callback = function() state.view = "settings"; refresh(context) end, overlap_offset = { margin, math.max(content_y, height - margin - 2 * button_height - gap) } }
    elements[#elements + 1] = ActionButton:new{ width = half, height = button_height, title = _("‹ Newer"), callback = function() state.page = math.max(1, state.page - 1); refresh(context) end, overlap_offset = { margin, height - margin - button_height } }
    elements[#elements + 1] = ActionButton:new{ width = half, height = button_height, title = _("Older ›") .. " " .. state.page .. "/" .. total_pages, callback = function() state.page = math.min(total_pages, state.page + 1); refresh(context) end, overlap_offset = { margin + half + gap, height - margin - button_height } }
    elements[#elements + 1] = TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, math.max(content_y, height - margin - button_height - px(20)) } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function settingsPane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap, button_height = math.max(px(10), math.floor(width / 65)), math.max(px(7), math.floor(width / 110)), math.max(px(38), math.floor(height / 13))
    local endpoint_status = state.store.endpoint ~= "" and state.store.endpoint or _("Public service address missing")
    local dm_endpoint_status = state.store.dm_endpoint ~= "" and state.store.dm_endpoint or _("DM service address missing")
    local identity_status = hasIdentity(state.store) and (_("Identity: ") .. state.store.display_name) or _("No local identity")
    local permissions = context.appdock and context.appdock.getDAppPermissions and context.appdock:getDAppPermissions("dchat") or {}
    local background_status = permissions.background and _("Background checks: on · Wi-Fi only · every 15 minutes") or _("Background checks: off · enable in DApp permissions")
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = _("DChat settings"), face = Font:getFace("cfont", px(20)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin, margin } },
        TextBoxWidget:new{ text = _("DChat has a public room and server-stored private chats. Private messages are not end-to-end encrypted. Do not share sensitive data. There is no account recovery or identity transfer."), face = Font:getFace("smallinfofont", px(10)), width = width - 2 * margin, height = px(67), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, margin + px(31) } },
        TextWidget:new{ text = endpoint_status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(108) } },
        TextWidget:new{ text = identity_status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(126) } },
        TextWidget:new{ text = background_status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(143) } },
        TextWidget:new{ text = dm_endpoint_status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(160) } },
        ActionButton:new{ width = math.floor((width - 2 * margin - gap) / 2), height = button_height, title = _("Public address"), callback = function() setEndpoint(state, context) end, overlap_offset = { margin, margin + px(181) } },
        ActionButton:new{ width = math.floor((width - 2 * margin - gap) / 2), height = button_height, title = _("DM address"), primary = true, callback = function() setDMEndpoint(state, context) end, overlap_offset = { margin + math.floor((width - 2 * margin - gap) / 2) + gap, margin + px(181) } },
        ActionButton:new{ width = width - 2 * margin, height = button_height, title = hasIdentity(state.store) and _("Reset local identity") or _("Create local identity"), callback = function() createOrResetIdentity(state, context) end, overlap_offset = { margin, margin + px(181) + button_height + gap } },
        ActionButton:new{ width = width - 2 * margin, height = button_height, title = _("‹ Back to messages"), primary = true, callback = function() state.view = "timeline"; refresh(context) end, overlap_offset = { margin, height - margin - button_height } },
        TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - button_height - px(24) } },
    }
end

local function dmPane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap = math.max(px(8), math.floor(width / 70)), math.max(px(5), math.floor(width / 130))
    local button_height, row_height = math.max(px(32), math.floor(height / 16)), math.max(px(42), math.floor(height / 9))
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = CHAT_BACKGROUND, emptySizedWidget(width, height) },
        FrameContainer:new{ width = width, height = px(56), padding = margin, bordersize = 0, background = CHAT_GREEN, TextWidget:new{ text = _("Chats"), face = Font:getFace("cfont", px(20)), fgcolor = Blitbuffer.COLOR_WHITE, bold = true, overlap_offset = { margin, px(8) } }, TextWidget:new{ text = _("private · server stored"), face = Font:getFace("smallinfofont", px(8)), fgcolor = Blitbuffer.COLOR_WHITE, overlap_offset = { margin, px(33) } } },
    }
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Refresh"), primary = true, callback = function() fetchRecipients(state, context, "") end, overlap_offset = { margin, px(60) } }
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Search"), callback = function() promptRecipientSearch(state, context) end, overlap_offset = { margin + third + gap, px(60) } }
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Public"), callback = function() state.view = "timeline"; refresh(context) end, overlap_offset = { margin + 2 * (third + gap), px(60) } }
    local y, end_y = px(112), height - margin - button_height - gap
    local recipients = state.store.recipients or {}
    if #recipients == 0 then
        elements[#elements + 1] = TextBoxWidget:new{ text = _("No recipients cached. Tap Search or Refresh."), face = Font:getFace("smallinfofont", px(12)), width = width - 2 * margin, height = px(70), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, y } }
    else
        for index, recipient in ipairs(recipients) do
            if y + row_height > end_y then break end
            local unread_count = tonumber(recipient.unreadCount) or 0
            local unread = unread_count > 0 and (" · " .. tostring(unread_count) .. " unread") or ""
            elements[#elements + 1] = ActionButton:new{ width = width - 2 * margin, height = row_height, title = recipient.displayName .. unread .. " · " .. recipient.deviceId, callback = function() state.store.selected_recipient_id = recipient.deviceId; state.store.selected_recipient_name = recipient.displayName; state.view = "dm_conversation"; saveStore(state.store); fetchConversation(state, context) end, overlap_offset = { margin, y } }
            y = y + row_height + gap
        end
    end
    elements[#elements + 1] = TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - button_height - px(20) } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function dmPreview(text, maximum)
    text = tostring(text or "")
    if #text <= maximum then return text end
    return text:sub(1, math.max(1, maximum - 3)) .. "..."
end

local function attachmentFilePath(state, message)
    if not message or message.attachmentData == "" then return nil end
    state.attachment_files = state.attachment_files or {}
    local cached = state.attachment_files[message.id]
    if cached then
        local file = io.open(cached, "rb")
        if file then file:close(); return cached end
        state.attachment_files[message.id] = nil
    end
    local data = base64Decode(message.attachmentData)
    if not data or #data == 0 or #data > MAX_ATTACHMENT_BYTES then return nil end
    local extension = ({ ["image/png"] = ".png", ["image/jpeg"] = ".jpg", ["image/gif"] = ".gif", ["image/webp"] = ".webp" })[message.attachmentMime]
    if not extension then return nil end
    local path = os.tmpname() .. extension
    local file = io.open(path, "wb")
    if not file then return nil end
    local ok = pcall(function() file:write(data); file:close() end)
    if not ok then pcall(function() file:close() end); os.remove(path); return nil end
    state.attachment_files[message.id] = path
    return path
end

local function safeImageWidget(options)
    local ok, widget = pcall(function() return ImageWidget:new(options) end)
    return ok and widget or nil
end

local DMBubble = InputContainer:extend{ width = nil, height = nil, image_file = nil, body = "", bubble_background = nil, callback = nil }
function DMBubble:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local padding = scale(7)
    local content = {}
    local content_width = self.width - 2 * padding
    local image_height = self.image_file and math.max(scale(58), math.min(scale(150), self.height - 2 * padding - scale(28))) or 0
    local image = self.image_file and safeImageWidget{ file = self.image_file, width = content_width, height = image_height, scale_factor = 0, overlap_offset = { padding, padding } }
    if image then content[#content + 1] = image end
    local text_y = padding + (image and image_height or 0) + (image and scale(4) or 0)
    if self.body ~= "" then
        content[#content + 1] = TextBoxWidget:new{ text = self.body, face = Font:getFace("smallinfofont", math.max(scale(9), math.floor(self.height * .18))), width = content_width, height = math.max(scale(20), self.height - text_y - padding), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { padding, text_y } }
    elseif image then
        content[#content + 1] = TextWidget:new{ text = _("Image"), face = Font:getFace("smallinfofont", scale(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { padding, self.height - padding - scale(16) } }
    end
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.max(4, math.floor(self.height * .12)), background = self.bubble_background or Blitbuffer.COLOR_WHITE, OverlapGroup:new{ dimen = self.dimen, unpack(content) } }
    self.ges_events = { TapDChatBubble = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function DMBubble:paintTo(bb, x, y)
    local range = self.ges_events.TapDChatBubble[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function DMBubble:onTapDChatBubble()
    if self.callback then self.callback() end
    return true
end

local function dmBubble(width, height, message, own, callback, state)
    local bubble_width = math.max(math.floor(width * 0.78), width - 40)
    local x = own and width - bubble_width or 0
    local background = own and CHAT_LIGHT_GREEN or Blitbuffer.COLOR_WHITE
    local body = message.body
    local image_file = attachmentFilePath(state, message)
    if message.attachmentData ~= "" and not image_file then body = (body ~= "" and body .. "\n" or "") .. _("Image unavailable") end
    if own then body = (message.readAt ~= "" and "✓✓" or "✓") .. " " .. body end
    return DMBubble:new{ width = bubble_width, height = height, body = dmPreview(body, 36), image_file = image_file, callback = callback, bubble_background = background, overlap_offset = { x, 0 } }
end

local function dmConversationPane(instance, context)
    local state = stateFor(instance)
    local recipient = selectedRecipient(state)
    if not recipient then state.view = "dm"; return dmPane(instance, context) end
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap = math.max(px(8), math.floor(width / 70)), math.max(px(5), math.floor(width / 130))
    local button_height, row_height = math.max(px(32), math.floor(height / 16)), math.max(px(42), math.floor(height / 9))
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = CHAT_BACKGROUND, emptySizedWidget(width, height) },
        FrameContainer:new{ width = width, height = px(56), padding = margin, bordersize = 0, background = CHAT_GREEN, TextWidget:new{ text = recipient.displayName, face = Font:getFace("cfont", px(18)), fgcolor = Blitbuffer.COLOR_WHITE, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, px(8) } }, TextWidget:new{ text = _("private chat · server stored"), face = Font:getFace("smallinfofont", px(8)), fgcolor = Blitbuffer.COLOR_WHITE, max_width = width - 2 * margin, overlap_offset = { margin, px(31) } } },
    }
    local fifth = math.floor((width - 2 * margin - 4 * gap) / 5)
    elements[#elements + 1] = ActionButton:new{ width = fifth, height = button_height, title = _("Message…"), callback = function() promptDirectMessage(state, context) end, overlap_offset = { margin, px(60) } }
    elements[#elements + 1] = ActionButton:new{ width = fifth, height = button_height, title = _("Send"), primary = true, callback = function() promptDirectMessage(state, context) end, overlap_offset = { margin + fifth + gap, px(60) } }
    elements[#elements + 1] = ActionButton:new{ width = fifth, height = button_height, title = _("Attach"), callback = function() chooseImageAttachment(state, context) end, overlap_offset = { margin + 2 * (fifth + gap), px(60) } }
    elements[#elements + 1] = ActionButton:new{ width = fifth, height = button_height, title = _("Delete"), callback = function() confirmDeleteConversation(state, context) end, overlap_offset = { margin + 3 * (fifth + gap), px(60) } }
    elements[#elements + 1] = ActionButton:new{ width = fifth, height = button_height, title = _("‹ Chats"), callback = function() state.view = "dm"; refresh(context) end, overlap_offset = { margin + 4 * (fifth + gap), px(60) } }
    local emoji_height = math.max(px(28), math.floor(button_height * .8))
    local emoji_width = math.floor((width - 2 * margin - 5 * gap) / 6)
    elements[#elements + 1] = ActionButton:new{ width = emoji_width, height = emoji_height, title = _("↻"), callback = function() fetchConversation(state, context) end, overlap_offset = { margin, px(60) + button_height + gap } }
    for index, emoji in ipairs(DM_EMOJIS) do
        local emoji_file = DCHAT_SOURCE_DIR .. "assets/dchat_emojis/" .. DM_EMOJI_FILES[index]
        elements[#elements + 1] = EmojiButton:new{ width = emoji_width, height = emoji_height, image_file = emoji_file, fallback = DM_EMOJI_LABELS[index], callback = function() promptDirectMessage(state, context, emoji) end, overlap_offset = { margin + index * (emoji_width + gap), px(60) + button_height + gap } }
    end
    local total_pages = math.max(1, math.ceil(#(state.store.dm_messages or {}) / MAX_VISIBLE_PER_PAGE))
    state.dm_page = math.max(1, math.min(state.dm_page or 1, total_pages))
    local start_index = (state.dm_page - 1) * MAX_VISIBLE_PER_PAGE + 1
    local y, end_y = px(60) + button_height + emoji_height + 3 * gap, height - margin - 2 * button_height - 2 * gap
    for index = start_index, math.min(#(state.store.dm_messages or {}), start_index + MAX_VISIBLE_PER_PAGE - 1) do
        local message = state.store.dm_messages[index]
        if y + row_height > end_y then break end
        local own = message.senderDeviceId == state.store.device_id
        local bubble_height = message.attachmentData ~= "" and math.max(row_height, math.min(px(176), math.floor(height * .30))) or row_height
        local bubble = dmBubble(width - 2 * margin, bubble_height, message, own, function() state.selected_dm_id = message.id; state.view = "dm_message"; refresh(context) end, state)
        bubble.overlap_offset = { margin + (own and math.floor((width - 2 * margin) * 0.22) or 0), y }
        elements[#elements + 1] = bubble
        y = y + bubble_height + gap
    end
    if #state.store.dm_messages == 0 then elements[#elements + 1] = TextBoxWidget:new{ text = _("No private messages yet."), face = Font:getFace("smallinfofont", px(12)), width = width - 2 * margin, height = px(70), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, y } } end
    elements[#elements + 1] = ActionButton:new{ width = math.floor((width - 2 * margin - gap) / 2), height = button_height, title = _("‹ Newer"), callback = function() state.dm_page = math.max(1, state.dm_page - 1); refresh(context) end, overlap_offset = { margin, height - margin - button_height } }
    local half = math.floor((width - 2 * margin - gap) / 2)
    elements[#elements + 1] = ActionButton:new{ width = half, height = button_height, title = _("Older ›") .. " " .. state.dm_page .. "/" .. total_pages, callback = function() state.dm_page = math.min(total_pages, state.dm_page + 1); refresh(context) end, overlap_offset = { margin + half + gap, height - margin - button_height } }
    elements[#elements + 1] = TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - button_height - px(20) } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function dmMessagePane(instance, context)
    local state = stateFor(instance)
    local message = selectedDirectMessage(state)
    if not message then state.view = "dm_conversation"; return dmConversationPane(instance, context) end
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap, button_height = math.max(px(10), math.floor(width / 65)), math.max(px(7), math.floor(width / 110)), math.max(px(36), math.floor(height / 14))
    local half = math.floor((width - 2 * margin - gap) / 2)
    local full_body = message.body
    local image_file = attachmentFilePath(state, message)
    local image_height = image_file and math.min(px(220), math.floor(height * .34)) or 0
    local image = image_file and safeImageWidget{ file = image_file, width = width - 2 * margin, height = image_height, scale_factor = 0, overlap_offset = { margin, margin + px(48) } }
    if message.attachmentData ~= "" and not image then full_body = (full_body ~= "" and full_body .. "\n\n" or "") .. _("[Image unavailable]") end
    if message.senderDeviceId == state.store.device_id then full_body = (message.readAt ~= "" and "✓✓ " or "✓ ") .. full_body end
    local body_y = margin + px(48) + (image and image_height or 0) + (image and gap or 0)
    local elements = {
        dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = message.authorName, face = Font:getFace("cfont", px(18)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, margin } },
        TextWidget:new{ text = message.createdAt ~= "" and message.createdAt or _("Private message"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(26) } },
    }
    if image then elements[#elements + 1] = image end
    elements[#elements + 1] = TextBoxWidget:new{ text = full_body, face = Font:getFace("smallinfofont", px(13)), width = width - 2 * margin, height = math.max(px(24), height - body_y - 2 * margin - button_height - gap), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, body_y } }
    elements[#elements + 1] = ActionButton:new{ width = half, height = button_height, title = _("‹ Conversation"), callback = function() state.view = "dm_conversation"; refresh(context) end, overlap_offset = { margin, height - margin - button_height } }
    elements[#elements + 1] = ActionButton:new{ width = half, height = button_height, title = _("DMs"), primary = true, callback = function() state.view = "dm"; refresh(context) end, overlap_offset = { margin + half + gap, height - margin - button_height } }
    elements[#elements + 1] = TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - button_height - px(20) } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function messagePane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap, button_height = math.max(px(10), math.floor(width / 65)), math.max(px(7), math.floor(width / 110)), math.max(px(36), math.floor(height / 14))
    local message = selectedMessage(state)
    if not message then state.view = "timeline"; return timelinePane(instance, context) end
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = message.authorName, face = Font:getFace("cfont", px(18)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, margin } },
        TextWidget:new{ text = message.createdAt ~= "" and message.createdAt or _("Public message"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(26) } },
        TextBoxWidget:new{ text = message.body, face = Font:getFace("smallinfofont", px(12)), width = width - 2 * margin, height = height - 2 * margin - px(48) - 2 * button_height - 2 * gap, line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, margin + px(47) } },
        ActionButton:new{ width = math.floor((width - 2 * margin - gap) / 2), height = button_height, title = _("‹ Messages"), callback = function() state.view = "timeline"; refresh(context) end, overlap_offset = { margin, height - margin - button_height } },
        ActionButton:new{ width = math.floor((width - 2 * margin - gap) / 2), height = button_height, title = _("Report"), primary = true, callback = function() promptReport(state, context) end, overlap_offset = { margin + math.floor((width - 2 * margin - gap) / 2) + gap, height - margin - button_height } },
        TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - button_height - px(20) } },
    }
end

return {
    id = "dchat",
    version = "1.4.8",
    title = "DChat",
    subtitle = "Public Lounge and private device chats",
    symbol = "D",
    logo = "rss",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        if state.view == "settings" then return settingsPane(instance, context) end
        if state.view == "dm" then return dmPane(instance, context) end
        if state.view == "dm_conversation" then return dmConversationPane(instance, context) end
        if state.view == "dm_message" then return dmMessagePane(instance, context) end
        if state.view == "message" then return messagePane(instance, context) end
        return timelinePane(instance, context)
    end,
    backgroundTick = backgroundCheck,
    _test = { validEndpoint = validEndpoint, cloneStore = cloneStore, cloneMessage = cloneMessage, cloneRecipient = cloneRecipient, cloneDirectMessage = cloneDirectMessage, dmPreview = dmPreview, base64Encode = base64Encode, base64Decode = base64Decode, hasIdentity = hasIdentity, newIdentity = newIdentity, replaceMessages = replaceMessages, replaceRecipients = replaceRecipients, replaceDirectMessages = replaceDirectMessages, httpJson = httpJson, backgroundCheck = backgroundCheck, countNewMessages = countNewMessages, newestMessageId = newestMessageId },
}
