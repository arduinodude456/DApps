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
local MAX_NOTE_BYTES = 840
local MAX_RESPONSE_BYTES = 96 * 1024
local MAX_CACHE_MESSAGES = 60
local MAX_VISIBLE_PER_PAGE = 5
local MAX_RECIPIENTS = 30
local CONNECT_TIMEOUT = 10
local REQUEST_MAX_TIME = 25
local BACKGROUND_CHECK_SECONDS = 15 * 60

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
    local id = trim(raw.id)
    local author_name = safeText(raw.authorName, MAX_NAME_BYTES)
    local body = safeText(raw.body, MAX_TEXT_BYTES)
    local created_at = trim(raw.createdAt):sub(1, 48)
    if not id:match("^%d+$") or not author_name or not body then return nil end
    return { id = id, authorName = author_name, body = body, createdAt = created_at }
end

local function cloneRecipient(raw)
    if type(raw) ~= "table" then return nil end
    local device_id = trim(raw.deviceId):sub(1, 64)
    local display_name = safeText(raw.displayName, MAX_NAME_BYTES)
    if not device_id:match("^dch_[%w_%-]+$") or not display_name then return nil end
    return { deviceId = device_id, displayName = display_name }
end

local function cloneDirectMessage(raw)
    if type(raw) ~= "table" then return nil end
    local id = trim(raw.id)
    local author_name = safeText(raw.authorName, MAX_NAME_BYTES)
    local body = safeText(raw.body, MAX_TEXT_BYTES)
    local created_at = trim(raw.createdAt):sub(1, 48)
    if not id:match("^%d+$") or not author_name or not body then return nil end
    return { id = id, authorName = author_name, body = body, createdAt = created_at, senderDeviceId = trim(raw.senderDeviceId) }
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
            if received > MAX_RESPONSE_BYTES then return nil, "response too large" end
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
    instance.dchat = instance.dchat or { store = loadStore(), view = "timeline", page = 1, selected_id = nil, status = _("Public DChat service ready. Create a local identity before posting or reporting."), loading = false }
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
    local response, code, err = httpJson(state.store, "GET", "/dms/" .. urlEncode(state.store.selected_recipient_id) .. "?limit=" .. tostring(MAX_CACHE_MESSAGES), nil, true, state.store.dm_endpoint)
    state.loading = false
    if not response or type(response.conversation) ~= "table" then
        state.status = err or _("Private conversation could not be loaded.")
        refresh(context)
        return
    end
    state.store.selected_recipient_name = safeText(response.conversation.displayName, MAX_NAME_BYTES) or state.store.selected_recipient_name
    replaceDirectMessages(state.store, response.conversation.messages)
    saveStore(state.store)
    state.status = #state.store.dm_messages == 0 and _("No private messages yet.") or _("Private conversation refreshed.")
    refresh(context)
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

local function sendDirectMessage(state, context, text)
    local recipient = selectedRecipient(state)
    local message = safeText(text, MAX_TEXT_BYTES)
    if not recipient or not message then state.status = _("Choose a recipient and use plain text up to 1500 characters."); refresh(context); return end
    local response, code, err = httpJson(state.store, "POST", "/dms", { recipientDeviceId = recipient.deviceId, text = message }, true, state.store.dm_endpoint)
    if not response then state.status = err or _("Private message could not be sent."); refresh(context); return end
    state.status = _("Private message sent. It is stored server-side and is not end-to-end encrypted.")
    fetchConversation(state, context)
end

local function promptDirectMessage(state, context)
    if not hasIdentity(state.store) then state.status = _("Create a local identity before sending a private message."); refresh(context); return end
    if not selectedRecipient(state) then state.status = _("Choose a recipient first."); refresh(context); return end
    local dialog
    dialog = InputDialog:new{
        title = _("Send private message"), input = "", input_hint = _("Plain text, up to 1500 characters"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Send"), is_enter_default = true, callback = function() local text = dialog:getInputText(); UIManager:close(dialog); sendDirectMessage(state, context, text) end } } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function selectedMessage(state)
    for index, message in ipairs(state.store.messages) do if message.id == state.selected_id then return message end end
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
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.max(4, math.floor(self.height * .2)), background = self.primary and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", math.max(scale(9), math.floor(self.height * .28))), fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, bold = self.primary, max_width = self.width - scale(10) } },
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
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = _("Private chats"), face = Font:getFace("cfont", px(21)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin, margin } },
        TextWidget:new{ text = _("Server-stored · not end-to-end encrypted"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(28) } },
    }
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Refresh"), primary = true, callback = function() fetchRecipients(state, context, "") end, overlap_offset = { margin, margin + px(62) } }
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Search"), callback = function() promptRecipientSearch(state, context) end, overlap_offset = { margin + third + gap, margin + px(62) } }
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Public"), callback = function() state.view = "timeline"; refresh(context) end, overlap_offset = { margin + 2 * (third + gap), margin + px(62) } }
    local y, end_y = margin + px(106), height - margin - button_height - gap
    if #state.store.recipients == 0 then
        elements[#elements + 1] = TextBoxWidget:new{ text = _("No recipients cached. Tap Search or Refresh."), face = Font:getFace("smallinfofont", px(12)), width = width - 2 * margin, height = px(70), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, y } }
    else
        for index, recipient in ipairs(state.store.recipients) do
            if y + row_height > end_y then break end
            elements[#elements + 1] = ActionButton:new{ width = width - 2 * margin, height = row_height, title = recipient.displayName .. " · " .. recipient.deviceId, callback = function() state.store.selected_recipient_id = recipient.deviceId; state.store.selected_recipient_name = recipient.displayName; state.view = "dm_conversation"; saveStore(state.store); fetchConversation(state, context) end, overlap_offset = { margin, y } }
            y = y + row_height + gap
        end
    end
    elements[#elements + 1] = TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - button_height - px(20) } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
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
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = recipient.displayName, face = Font:getFace("cfont", px(20)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, max_width = width - 2 * margin, overlap_offset = { margin, margin } },
        TextWidget:new{ text = _("Private · stored server-side · no end-to-end encryption"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(27) } },
    }
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Refresh"), primary = true, callback = function() fetchConversation(state, context) end, overlap_offset = { margin, margin + px(61) } }
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("Send"), callback = function() promptDirectMessage(state, context) end, overlap_offset = { margin + third + gap, margin + px(61) } }
    elements[#elements + 1] = ActionButton:new{ width = third, height = button_height, title = _("‹ Chats"), callback = function() state.view = "dm"; refresh(context) end, overlap_offset = { margin + 2 * (third + gap), margin + px(61) } }
    local y, end_y = margin + px(104), height - margin - button_height - gap
    for _, message in ipairs(state.store.dm_messages or {}) do
        if y + row_height > end_y then break end
        elements[#elements + 1] = ActionButton:new{ width = width - 2 * margin, height = row_height, title = message.authorName .. ": " .. message.body, callback = function() end, overlap_offset = { margin, y } }
        y = y + row_height + gap
    end
    if #state.store.dm_messages == 0 then elements[#elements + 1] = TextBoxWidget:new{ text = _("No private messages yet."), face = Font:getFace("smallinfofont", px(12)), width = width - 2 * margin, height = px(70), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, y } } end
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
    version = "1.2.5",
    title = "DChat",
    subtitle = "Public Lounge and private device chats",
    symbol = "D",
    logo = "rss",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        if state.view == "settings" then return settingsPane(instance, context) end
        if state.view == "dm" then return dmPane(instance, context) end
        if state.view == "dm_conversation" then return dmConversationPane(instance, context) end
        if state.view == "message" then return messagePane(instance, context) end
        return timelinePane(instance, context)
    end,
    backgroundTick = backgroundCheck,
    _test = { validEndpoint = validEndpoint, cloneStore = cloneStore, cloneMessage = cloneMessage, cloneRecipient = cloneRecipient, cloneDirectMessage = cloneDirectMessage, hasIdentity = hasIdentity, newIdentity = newIdentity, replaceMessages = replaceMessages, replaceRecipients = replaceRecipients, replaceDirectMessages = replaceDirectMessages, httpJson = httpJson, backgroundCheck = backgroundCheck, countNewMessages = countNewMessages, newestMessageId = newestMessageId },
}
