--[[--
AI Chat Agent for AppDock.

A small, explicit-action chat client for Groq or a local OpenAI-compatible
endpoint such as Ollama or llama.cpp. Settings and chat history remain local.
No request is made until the user taps Send.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SETTINGS_KEY = "appdock_ai_chat_v1"
local GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"
local DEFAULT_LOCAL_ENDPOINT = "http://127.0.0.1:11434/v1/chat/completions"
local DEFAULT_GROQ_MODEL = "llama-3.1-8b-instant"
local DEFAULT_LOCAL_MODEL = "llama3.2"
local MAX_PROMPT = 4000
local MAX_RESPONSE = 12000
local MAX_HISTORY = 20
local CONNECT_TIMEOUT, REQUEST_TIMEOUT = 12, 90

local Screen = Device.screen
local function scale(value) return Screen:scaleBySize(value) end
local function trim(value) return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or "" end
local function short(value, limit)
    value = tostring(value or "")
    return #value <= limit and value or value:sub(1, limit - 1) .. "…"
end

local function cloneSettings(stored)
    stored = type(stored) == "table" and stored or {}
    return {
        provider = stored.provider == "local" and "local" or "groq",
        endpoint = trim(stored.endpoint) ~= "" and trim(stored.endpoint) or DEFAULT_LOCAL_ENDPOINT,
        model = trim(stored.model) ~= "" and trim(stored.model) or DEFAULT_GROQ_MODEL,
        api_key = trim(stored.api_key),
        system = trim(stored.system) ~= "" and trim(stored.system) or "You are a concise, helpful assistant. Reply in the user's language.",
        history = type(stored.history) == "table" and stored.history or {},
    }
end

local function loadSettings()
    return cloneSettings(G_reader_settings:readSetting(SETTINGS_KEY, {}))
end

local function saveSettings(settings)
    G_reader_settings:saveSetting(SETTINGS_KEY, settings)
    if G_reader_settings.flush then G_reader_settings:flush() end
end

local function validEndpoint(endpoint)
    local url = require("socket.url")
    local parsed = url.parse(trim(endpoint))
    if not parsed or not parsed.host or parsed.host == "" then return nil, _("Enter a valid model endpoint.") end
    if parsed.scheme == "https" then return trim(endpoint) end
    local host = parsed.host:lower()
    local local_host = host == "localhost" or host == "127.0.0.1" or host == "::1"
    local a, b = host:match("^(%d+)%.(%d+)%.")
    local private = a and ((a == "10") or (a == "192" and b == "168") or (a == "172" and tonumber(b) >= 16 and tonumber(b) <= 31))
    if parsed.scheme == "http" and (local_host or private) then return trim(endpoint) end
    return nil, _("Use HTTPS, or HTTP only for a local/private model endpoint.")
end

local function httpJson(endpoint, payload, headers)
    local socket, socketutil, ltn12, https = require("socket"), require("socketutil"), require("ltn12"), require("ssl.https")
    local JSON = require("json")
    local encoded_ok, body = pcall(JSON.encode, payload)
    if not encoded_ok or type(body) ~= "string" or #body > MAX_PROMPT * 20 then return nil, _("The chat request is too large.") end
    local response, received = {}, 0
    local function sink(chunk, sink_error)
        if sink_error then return nil, sink_error end
        if chunk then
            received = received + #chunk
            if received > MAX_RESPONSE then return nil, "response too large" end
            response[#response + 1] = chunk
        end
        return 1
    end
    headers = headers or {}
    headers["content-type"] = "application/json"
    headers["content-length"] = tostring(#body)
    headers["accept"] = "application/json"
    headers["user-agent"] = "AppDock-AIChat/1.0"
    socketutil:set_timeout(CONNECT_TIMEOUT, REQUEST_TIMEOUT)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, https.request{ url = endpoint, method = "POST", source = ltn12.source.string(body), sink = sink, headers = headers })
    end)
    socketutil:reset_timeout()
    code = tonumber(code)
    if not ok or not response_headers then return nil, status or _("The model could not be reached.") end
    local raw = table.concat(response)
    if code < 200 or code > 299 then return nil, _("The model returned HTTP ") .. tostring(code) .. ": " .. short(raw, 220) end
    local decoded_ok, decoded = pcall(JSON.decode, raw, JSON.decode.simple)
    if not decoded_ok or type(decoded) ~= "table" then return nil, _("The model returned invalid JSON.") end
    return decoded
end

local function askModel(settings, history)
    local endpoint
    if settings.provider == "groq" then
        endpoint = GROQ_ENDPOINT
        if settings.api_key == "" then return nil, _("Enter the Groq API key first.") end
    else
        endpoint = validEndpoint(settings.endpoint)
        if not endpoint then return nil, _("Configure a valid local model endpoint first.") end
    end
    if settings.model == "" then return nil, _("Enter a model name first.") end
    local messages = { { role = "system", content = settings.system } }
    for index = math.max(1, #history - MAX_HISTORY + 1), #history do
        local item = history[index]
        if type(item) == "table" and (item.role == "user" or item.role == "assistant") and type(item.content) == "string" then
            messages[#messages + 1] = { role = item.role, content = item.content }
        end
    end
    local headers = {}
    if settings.provider == "groq" then headers.authorization = "Bearer " .. settings.api_key end
    local decoded, err = httpJson(endpoint, { model = settings.model, messages = messages, temperature = 0.3, max_tokens = 800 }, headers)
    if not decoded then return nil, err end
    local choice = type(decoded.choices) == "table" and decoded.choices[1]
    local message = choice and choice.message
    if type(message) ~= "table" or type(message.content) ~= "string" or trim(message.content) == "" then
        return nil, _("The model response contained no assistant text.")
    end
    return short(message.content, MAX_RESPONSE)
end

local Action = InputContainer:extend{ title = "", subtitle = "", callback = nil, width = 0, height = 0, primary = false }
function Action:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 1, color = Blitbuffer.COLOR_BLACK, radius = scale(8), background = self.primary and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", scale(11)), bold = true, fgcolor = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK } } }
    self.ges_events = { TapAIChatAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:onTapAIChatAction() if self.callback then self.callback() end; return true end

local function stateFor(instance)
    if instance.ai_chat then return instance.ai_chat end
    instance.ai_chat = { settings = loadSettings(), status = _("Ready. Nothing is sent until you tap Send.") }
    return instance.ai_chat
end

local function showInput(title, hint, value, callback)
    local dialog
    dialog = InputDialog:new{ title = title, input = value or "", input_hint = hint, buttons = {
        { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
          { text = _("Save"), is_enter_default = true, callback = function() local result = dialog:getInputText() or ""; UIManager:close(dialog); callback(result) end } },
    } }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function configure(instance, context, field, title, hint)
    local settings = instance.ai_chat.settings
    showInput(title, hint, settings[field], function(value)
        settings[field] = trim(value)
        saveSettings(settings)
        instance.ai_chat.status = _("Saved locally.")
        context.requestRebuild("ui")
    end)
end

local function toggleProvider(instance, context)
    local settings = instance.ai_chat.settings
    settings.provider = settings.provider == "groq" and "local" or "groq"
    settings.model = settings.provider == "groq" and DEFAULT_GROQ_MODEL or DEFAULT_LOCAL_MODEL
    saveSettings(settings)
    instance.ai_chat.status = settings.provider == "groq" and _("Groq selected.") or _("Local model selected.")
    context.requestRebuild("ui")
end

local function sendMessage(instance, context)
    showInput(_("Message"), _("Write a message for the assistant"), "", function(text)
        text = trim(text)
        if text == "" then return end
        if #text > MAX_PROMPT then instance.ai_chat.status = _("Message is too long."); context.requestRebuild("ui"); return end
        local settings, history = instance.ai_chat.settings, instance.ai_chat.settings.history
        history[#history + 1] = { role = "user", content = text }
        while #history > MAX_HISTORY do table.remove(history, 1) end
        instance.ai_chat.status = _("Contacting the model…")
        context.requestRebuild("ui")
        local answer, err = askModel(settings, history)
        if answer then
            history[#history + 1] = { role = "assistant", content = answer }
            while #history > MAX_HISTORY do table.remove(history, 1) end
            instance.ai_chat.status = _("Reply received and saved locally.")
            saveSettings(settings)
        else
            table.remove(history, #history)
            instance.ai_chat.status = err or _("The model request failed.")
        end
        context.requestRebuild("ui")
    end)
end

local function clearChat(instance, context)
    instance.ai_chat.settings.history = {}
    saveSettings(instance.ai_chat.settings)
    instance.ai_chat.status = _("Local chat history cleared.")
    context.requestRebuild("ui")
end

local function buildPane(instance, context)
    local state, settings = stateFor(instance), stateFor(instance).settings
    local width, height, px = context.dimen.w, context.dimen.h, context.px or scale
    local margin, gap = px(10), px(6)
    local button_h = math.max(px(36), math.floor(height * .09))
    local content = { FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, HorizontalSpan:new{ width = 0 } },
        TextWidget:new{ text = _("AI Chat Agent"), face = Font:getFace("cfont", px(20)), bold = true, overlap_offset = { margin, px(10) } },
        TextWidget:new{ text = (settings.provider == "groq" and "Groq" or _("Local model")) .. " · " .. short(settings.model, 28), face = Font:getFace("smallinfofont", px(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, px(38) } },
    }
    local transcript = _("No messages yet. Tap Send to start a conversation.")
    if #settings.history > 0 then
        local lines = {}
        for index = math.max(1, #settings.history - 5), #settings.history do
            local item = settings.history[index]
            lines[#lines + 1] = (item.role == "user" and "You: " or "AI: ") .. item.content
        end
        transcript = table.concat(lines, "\n\n")
    end
    local chat_y = px(68)
    local chat_h = math.max(px(120), height - px(190))
    content[#content + 1] = TextBoxWidget:new{ text = transcript, face = Font:getFace("smallinfofont", px(10)), width = width - 2 * margin, height = chat_h, line_height = 0.3, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, chat_y } }
    content[#content + 1] = TextWidget:new{ text = short(state.status, 160), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - px(116) } }
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    local y = height - margin - button_h
    content[#content + 1] = Action:new{ title = _("Send"), width = third, height = button_h, primary = true, callback = function() sendMessage(instance, context) end, overlap_offset = { margin, y } }
    content[#content + 1] = Action:new{ title = settings.provider == "groq" and _("Groq") or _("Local"), width = third, height = button_h, callback = function() toggleProvider(instance, context) end, overlap_offset = { margin + third + gap, y } }
    content[#content + 1] = Action:new{ title = _("Settings"), width = third, height = button_h, callback = function()
        if settings.provider == "groq" then configure(instance, context, "api_key", _("Groq API key"), _("Paste the key; it is stored only on this reader")) else configure(instance, context, "endpoint", _("Local model endpoint"), DEFAULT_LOCAL_ENDPOINT) end
    end, overlap_offset = { margin + 2 * (third + gap), y } }
    content[#content + 1] = Action:new{ title = _("Model"), width = third, height = button_h, callback = function() configure(instance, context, "model", _("Model name"), settings.provider == "groq" and DEFAULT_GROQ_MODEL or DEFAULT_LOCAL_MODEL) end, overlap_offset = { margin, y - button_h - gap } }
    content[#content + 1] = Action:new{ title = _("System prompt"), width = third, height = button_h, callback = function() configure(instance, context, "system", _("System prompt"), "You are a helpful assistant") end, overlap_offset = { margin + third + gap, y - button_h - gap } }
    content[#content + 1] = Action:new{ title = _("Clear chat"), width = third, height = button_h, callback = function() clearChat(instance, context) end, overlap_offset = { margin + 2 * (third + gap), y - button_h - gap } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(content) }
end

return { id = "ai_chat", version = "1.0.0", title = "AI Chat Agent", subtitle = "Groq or local model", symbol = "AI", logo = "dchat", buildPane = buildPane }
