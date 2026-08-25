-- Gmail Notifications for AppDock.
-- Design: a manual HTTPS pull to a local adapter; no Gmail credential or mail body reaches KOReader.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SETTINGS_KEY = "appdock_gmail_notifications_v1"
local MAX_SEEN_IDS = 200
local MAX_MESSAGES_PER_PULL = 12
local MAX_ENDPOINT_BYTES = 240
local MAX_PAIRING_TOKEN_BYTES = 160
local MAX_CA_PATH_BYTES = 280
local MAX_SENDER_BYTES = 120
local MAX_SUBJECT_BYTES = 160
local MAX_RESPONSE_BYTES = 96 * 1024

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

local function cloneStore(raw)
    raw = type(raw) == "table" and raw or {}
    local seen, dedup = {}, {}
    for _, id in ipairs(type(raw.seen_ids) == "table" and raw.seen_ids or {}) do
        if type(id) == "string" and id:match("^[%w_%-]+$") and not dedup[id] and #seen < MAX_SEEN_IDS then
            dedup[id] = true
            seen[#seen + 1] = id
        end
    end
    return {
        endpoint = trim(raw.endpoint):sub(1, MAX_ENDPOINT_BYTES),
        pairing_token = trim(raw.pairing_token):sub(1, MAX_PAIRING_TOKEN_BYTES),
        ca_cert_path = trim(raw.ca_cert_path):sub(1, MAX_CA_PATH_BYTES),
        seen_ids = seen,
        initialized = raw.initialized == true,
        last_checked = tonumber(raw.last_checked) or 0,
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
    if value == "" or #value > MAX_ENDPOINT_BYTES or value:find("[%c%s]") then return nil, _("Enter a valid HTTPS adapter address.") end
    local ok, socket_url = pcall(require, "socket.url")
    if not ok or not socket_url then return nil, _("URL support is unavailable.") end
    local parsed = socket_url.parse(value)
    if not parsed or parsed.scheme ~= "https" or not parsed.host or parsed.host == "" or parsed.userinfo or parsed.query or parsed.fragment or (parsed.path and parsed.path ~= "") then
        return nil, _("The adapter address must be HTTPS without a path, login or query.")
    end
    return value
end

local function validCAPath(value)
    value = trim(value)
    if value == "" then return "" end
    if #value > MAX_CA_PATH_BYTES or value:find("[%c]") or value:sub(1, 1) ~= "/" then
        return nil, _("Use an absolute path to a local CA certificate, or leave it empty for the device trust store.")
    end
    return value
end

local function normalizeMessage(raw)
    if type(raw) ~= "table" then return nil end
    local id = trim(raw.id)
    local sender = trim(raw.from):gsub("[%c]", " "):sub(1, MAX_SENDER_BYTES)
    local subject = trim(raw.subject):gsub("[%c]", " "):sub(1, MAX_SUBJECT_BYTES)
    if not id:match("^[%w_%-]+$") or sender == "" or subject == "" then return nil end
    return { id = id, from = sender, subject = subject }
end

local function mergeMessages(store, raw_messages)
    local known, messages, fresh = {}, {}, {}
    for _, id in ipairs(store.seen_ids) do known[id] = true end
    local received = type(raw_messages) == "table" and raw_messages or {}
    for _, raw in ipairs(received) do
        local message = normalizeMessage(raw)
        if message and not messages[message.id] then messages[message.id] = message end
    end
    local ordered = {}
    for _, raw in ipairs(received) do
        local id = type(raw) == "table" and raw.id or nil
        if id and messages[id] then
            ordered[#ordered + 1] = messages[id]
            messages[id] = nil
        end
    end
    if store.initialized then
        for _, message in ipairs(ordered) do if not known[message.id] then fresh[#fresh + 1] = message end end
    end
    local new_seen, seen = {}, {}
    for _, message in ipairs(ordered) do
        if not seen[message.id] then seen[message.id] = true; new_seen[#new_seen + 1] = message.id end
    end
    for _, id in ipairs(store.seen_ids) do
        if not seen[id] and #new_seen < MAX_SEEN_IDS then seen[id] = true; new_seen[#new_seen + 1] = id end
    end
    store.seen_ids = new_seen
    local was_initialized = store.initialized
    store.initialized = true
    store.last_checked = os.time()
    return fresh, was_initialized, #ordered
end

local function fetchAdapterMessages(endpoint, pairing_token, ca_cert_path)
    local valid, url_err = validEndpoint(endpoint)
    if not valid then return nil, url_err end
    pairing_token = trim(pairing_token)
    if pairing_token == "" or #pairing_token > MAX_PAIRING_TOKEN_BYTES then return nil, _("Enter the adapter pairing token first.") end
    local ok_https, https = pcall(require, "ssl.https")
    local ok_socket, socket = pcall(require, "socket")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_util, socketutil = pcall(require, "socketutil")
    local ok_json, JSON = pcall(require, "json")
    if not ok_https or not ok_socket or not ok_ltn12 or not ok_util or not ok_json then return nil, _("HTTPS or JSON support is unavailable.") end
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
    local request = {
        url = valid .. "/v1/messages?limit=" .. tostring(MAX_MESSAGES_PER_PULL),
        method = "GET", sink = sink,
        verify = "peer", options = "all",
        headers = { ["accept"] = "application/json", ["authorization"] = "Bearer " .. pairing_token, ["user-agent"] = "AppDock-GmailNotifications/1.0" },
    }
    local ca_path, ca_err = validCAPath(ca_cert_path)
    if not ca_path then return nil, ca_err end
    if ca_path ~= "" then request.cafile = ca_path end
    socketutil:set_timeout(10, 25)
    local ok, code = pcall(function()
        return socket.skip(1, https.request(request))
    end)
    socketutil:reset_timeout()
    code = tonumber(code)
    if not ok or code ~= 200 then return nil, _("The local Gmail adapter could not be reached or refused the request.") end
    local decoded_ok, decoded = pcall(JSON.decode, table.concat(chunks), JSON.decode.simple)
    if not decoded_ok or type(decoded) ~= "table" or type(decoded.messages) ~= "table" then return nil, _("The local Gmail adapter returned invalid data.") end
    return decoded.messages
end

local ActionButton = InputContainer:extend{ width = nil, height = nil, title = "", primary = false, callback = nil }

function ActionButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = 0, radius = scale(12),
        background = self.primary and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", scale(12)), fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, bold = self.primary, max_width = self.width - scale(14) } },
    }
    self.ges_events = { TapGmailAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function ActionButton:paintTo(bb, x, y)
    local range = self.ges_events.TapGmailAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function ActionButton:onTapGmailAction()
    if self.callback then self.callback() end
    return true
end

local function stateFor(instance)
    instance.gmail_notifications = instance.gmail_notifications or { store = loadStore(), status = _("Configure the local adapter first.") }
    return instance.gmail_notifications
end

local function editField(state, context, key, title, hint, secret)
    local dialog
    dialog = InputDialog:new{
        title = title, input = state.store[key] or "", input_hint = hint,
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Save"), is_enter_default = true, callback = function()
            local value = trim(dialog:getInputText())
            if key == "endpoint" then
                local endpoint, err = validEndpoint(value)
                if not endpoint then state.status = err; UIManager:close(dialog); context.requestRebuild("ui"); return end
                value = endpoint
            elseif key == "ca_cert_path" then
                local ca_path, err = validCAPath(value)
                if not ca_path then state.status = err; UIManager:close(dialog); context.requestRebuild("ui"); return end
                value = ca_path
            elseif value == "" or #value > MAX_PAIRING_TOKEN_BYTES then
                state.status = _("The pairing token is missing or too long."); UIManager:close(dialog); context.requestRebuild("ui"); return
            end
            state.store[key] = value; saveStore(state.store)
            state.status = key == "ca_cert_path" and (value == "" and _("Using the Kobo device trust store.") or _("Local CA certificate path saved.")) or (secret and _("Pairing token saved locally.") or _("Adapter address saved locally."))
            UIManager:close(dialog); context.requestRebuild("ui")
        end } } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function checkMailbox(instance, context)
    local state = stateFor(instance)
    if type(context.notify) ~= "function" then
        state.status = _("Gmail Notifications requires AppDock 2.1.0 or later.")
        context.requestRebuild("ui")
        return
    end
    local messages, err = fetchAdapterMessages(state.store.endpoint, state.store.pairing_token, state.store.ca_cert_path)
    if not messages then state.status = err; context.requestRebuild("ui"); return end
    local fresh, was_initialized, received = mergeMessages(state.store, messages)
    saveStore(state.store)
    if not was_initialized then
        state.status = string.format(_("First scan saved %d recent message IDs; no old mail was notified."), received)
    elseif #fresh == 0 then
        state.status = _("No new Gmail messages.")
    else
        for _, message in ipairs(fresh) do
            context.notify({ title = _("Gmail"), message = message.from .. " — " .. message.subject, priority = "normal" })
        end
        state.status = string.format(_("%d new Gmail message(s) added to Notifications."), #fresh)
    end
    context.requestRebuild("ui")
end

local function forgetLocalData(instance, context)
    UIManager:show(ConfirmBox:new{
        text = _("Remove the local adapter address, pairing token and saved Gmail message IDs from this reader?\n\nYour Google authorization remains on the computer running the adapter."),
        ok_text = _("Forget local data"),
        ok_callback = function()
            local state = stateFor(instance)
            state.store = cloneStore({})
            saveStore(state.store)
            state.status = _("Local Gmail connection data removed from this reader.")
            context.requestRebuild("ui")
        end,
    })
end

return {
    id = "gmail_notifications",
    version = "1.0.0",
    title = "Gmail Notifications",
    subtitle = "Manual inbox checks through your local adapter",
    symbol = "M",
    logo = "mail",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local width, height = context.dimen.w, context.dimen.h
        local margin, gap = scale(16), scale(8)
        local button_width = math.floor((width - 2 * margin - gap) / 2)
        local clear_width = math.min(scale(132), math.floor((width - 2 * margin - gap) / 2))
        local check_width = width - 2 * margin - gap - clear_width
        local endpoint_status = state.store.endpoint ~= "" and _("Adapter address configured") or _("Adapter address missing")
        local token_status = state.store.pairing_token ~= "" and _("Pairing token configured") or _("Pairing token missing")
        local trust_status = state.store.ca_cert_path ~= "" and _("Custom local CA configured") or _("Using Kobo device trust store")
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen, allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = _("Gmail Notifications"), face = Font:getFace("cfont", scale(21)), fgcolor = Blitbuffer.COLOR_BLACK, bold = true, overlap_offset = { margin, margin } },
            TextWidget:new{ text = _("Manual checks only. Gmail tokens remain on your local adapter."), face = Font:getFace("smallinfofont", scale(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + scale(31) } },
            FrameContainer:new{ width = width - 2 * margin, height = scale(90), padding = 0, bordersize = 0, radius = scale(12), background = Blitbuffer.COLOR_LIGHT_GRAY, emptySizedWidget(width - 2 * margin, scale(90)), overlap_offset = { margin, margin + scale(59) } },
            TextWidget:new{ text = endpoint_status .. "\n" .. token_status .. "\n" .. trust_status, face = Font:getFace("smallinfofont", scale(10)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 4 * margin, overlap_offset = { 2 * margin, margin + scale(76) } },
            ActionButton:new{ width = button_width, height = scale(45), title = _("Adapter address"), callback = function() editField(state, context, "endpoint", _("Local adapter address"), "https://gmail-adapter.example:8443", false) end, overlap_offset = { margin, margin + scale(162) } },
            ActionButton:new{ width = button_width, height = scale(45), title = _("Pairing token"), callback = function() editField(state, context, "pairing_token", _("Adapter pairing token"), _("Paste the token from your computer"), true) end, overlap_offset = { margin + button_width + gap, margin + scale(162) } },
            ActionButton:new{ width = width - 2 * margin, height = scale(42), title = _("Trusted CA certificate"), callback = function() editField(state, context, "ca_cert_path", _("Local CA certificate"), _("/mnt/onboard/.adds/appdock/gmail-local-ca.pem (optional)"), false) end, overlap_offset = { margin, margin + scale(215) } },
            ActionButton:new{ width = check_width, height = scale(49), title = _("Check Gmail"), primary = true, callback = function() checkMailbox(instance, context) end, overlap_offset = { margin, margin + scale(268) } },
            ActionButton:new{ width = clear_width, height = scale(49), title = _("Forget local data"), callback = function() forgetLocalData(instance, context) end, overlap_offset = { margin + check_width + gap, margin + scale(268) } },
            TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", scale(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + scale(331) } },
            TextWidget:new{ text = _("The first successful scan is a quiet baseline. Later scans only notify for new message IDs."), face = Font:getFace("smallinfofont", scale(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - scale(28) } },
        }
        return pane
    end,
    _test = { validEndpoint = validEndpoint, validCAPath = validCAPath, normalizeMessage = normalizeMessage, mergeMessages = mergeMessages, cloneStore = cloneStore, forgetLocalData = forgetLocalData },
}
