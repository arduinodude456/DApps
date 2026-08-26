--[[--
DChat for AppDock.

One public, text-only room. This DApp deliberately has no private messages,
no end-to-end encryption claim, no background refresh, and no account recovery.
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
local DEFAULT_ENDPOINT = "https://appdock-bd7bcrzm.manus.space"
local MAX_ENDPOINT_BYTES = 240
local MAX_NAME_BYTES = 80
local MAX_TEXT_BYTES = 1500
local MAX_NOTE_BYTES = 840
local MAX_RESPONSE_BYTES = 96 * 1024
local MAX_CACHE_MESSAGES = 60
local MAX_VISIBLE_PER_PAGE = 5
local CONNECT_TIMEOUT = 10
local REQUEST_MAX_TIME = 25

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

local function cloneStore(raw)
    raw = type(raw) == "table" and raw or {}
    local messages, seen = {}, {}
    for index, raw_message in ipairs(type(raw.messages) == "table" and raw.messages or {}) do
        local message = cloneMessage(raw_message)
        if message and not seen[message.id] and #messages < MAX_CACHE_MESSAGES then
            seen[message.id] = true
            messages[#messages + 1] = message
        end
    end
    return {
        endpoint = (trim(raw.endpoint) ~= "" and trim(raw.endpoint) or DEFAULT_ENDPOINT):gsub("/+$", ""):sub(1, MAX_ENDPOINT_BYTES),
        device_id = trim(raw.device_id):sub(1, 52),
        device_secret = trim(raw.device_secret):sub(1, 128),
        display_name = safeText(raw.display_name, MAX_NAME_BYTES) or "",
        messages = messages,
        last_refresh = tonumber(raw.last_refresh) or 0,
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

local function apiUrl(store, suffix)
    local endpoint, err = validEndpoint(store.endpoint)
    if not endpoint then return nil, err end
    return endpoint .. "/api/dchat/v1" .. suffix
end

local function httpJson(store, method, suffix, payload, include_identity)
    local url, url_err = apiUrl(store, suffix)
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
    local headers = { ["accept"] = "application/json", ["user-agent"] = "AppDock-DChat/1.0" }
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
            saveStore(state.store)
            state.status = _("Public service address saved locally. Create an identity before posting or reporting.")
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
    state.store.device_id, state.store.device_secret, state.store.display_name = device_id, device_secret, name
    saveStore(state.store)
    state.status = _("Local DChat identity registered. This identity cannot be recovered after reset.")
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
    state.page = 1
    saveStore(state.store)
    state.status = #state.store.messages == 0 and _("No public messages yet.") or _("Public messages refreshed manually.")
    refresh(context)
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
        TextWidget:new{ text = _("Public text room · no private messages · no encryption · manual refresh"), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(28) } },
        ActionButton:new{ width = third, height = button_height, title = _("Refresh"), primary = true, callback = function() fetchMessages(state, context) end, overlap_offset = { margin, margin + px(62) } },
        ActionButton:new{ width = third, height = button_height, title = _("Send"), callback = function() promptMessage(state, context) end, overlap_offset = { margin + third + gap, margin + px(62) } },
        ActionButton:new{ width = third, height = button_height, title = _("Settings"), callback = function() state.view = "settings"; refresh(context) end, overlap_offset = { margin + 2 * (third + gap), margin + px(62) } },
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
    local identity_status = hasIdentity(state.store) and (_("Identity: ") .. state.store.display_name) or _("No local identity")
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
        TextWidget:new{ text = _("DChat settings"), face = Font:getFace("cfont", px(20)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin, margin } },
        TextBoxWidget:new{ text = _("DChat is a public room. Do not share sensitive data. It does not provide private messages, end-to-end encryption, real-time delivery, account recovery or identity transfer."), face = Font:getFace("smallinfofont", px(10)), width = width - 2 * margin, height = px(67), line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, margin + px(31) } },
        TextWidget:new{ text = endpoint_status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(108) } },
        TextWidget:new{ text = identity_status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(126) } },
        ActionButton:new{ width = width - 2 * margin, height = button_height, title = _("Public service address"), callback = function() setEndpoint(state, context) end, overlap_offset = { margin, margin + px(151) } },
        ActionButton:new{ width = width - 2 * margin, height = button_height, title = hasIdentity(state.store) and _("Reset local identity") or _("Create local identity"), callback = function() createOrResetIdentity(state, context) end, overlap_offset = { margin, margin + px(151) + button_height + gap } },
        ActionButton:new{ width = width - 2 * margin, height = button_height, title = _("‹ Back to messages"), primary = true, callback = function() state.view = "timeline"; refresh(context) end, overlap_offset = { margin, height - margin - button_height } },
        TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - button_height - px(24) } },
    }
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
    version = "1.0.1",
    title = "DChat",
    subtitle = "Public AppDock Lounge, manual refresh",
    symbol = "D",
    logo = "rss",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        if state.view == "settings" then return settingsPane(instance, context) end
        if state.view == "message" then return messagePane(instance, context) end
        return timelinePane(instance, context)
    end,
    _test = { validEndpoint = validEndpoint, cloneStore = cloneStore, cloneMessage = cloneMessage, hasIdentity = hasIdentity, newIdentity = newIdentity, replaceMessages = replaceMessages, httpJson = httpJson },
}
