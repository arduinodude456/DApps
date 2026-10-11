--[[--
AI Chat Agent for AppDock.

A small, explicit-action chat client for Groq or a local OpenAI-compatible
endpoint such as Ollama or llama.cpp. Settings and chat history remain local.
No request is made until the user taps Send.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
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

-- These are direct Hugging Face resolve URLs for small GGUF files suitable for
-- an E-Ink reader. The files are only downloaded after the user selects one.
local MODEL_CATALOG = {
    {
        id = "smollm2-360m-q8",
        title = "SmolLM2 360M · Q8",
        size = "~386 MB",
        filename = "SmolLM2-360M-Instruct-Q8_0.gguf",
        url = "https://huggingface.co/bartowski/SmolLM2-360M-Instruct-GGUF/resolve/main/SmolLM2-360M-Instruct-Q8_0.gguf",
    },
    {
        id = "qwen25-05b-q4",
        title = "Qwen2.5 0.5B · Q4_K_M",
        size = "~491 MB",
        filename = "Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
        url = "https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf",
    },
    {
        id = "qwen25-15b-q4",
        title = "Qwen2.5 1.5B · Q4_K_M",
        size = "~1.1 GB",
        filename = "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
        url = "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
    },
}

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

local stateFor
local pollModelDownload

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function modelDirectory()
    local base = DataStorage:getDataDir()
    local directory = base .. "/appdock/ai-models"
    os.execute("mkdir -p " .. shellQuote(directory) .. " >/dev/null 2>&1")
    return directory
end

local function fileExists(path)
    local handle = path and io.open(path, "rb")
    if handle then handle:close(); return true end
    return false
end

local function fileSize(path)
    local handle = path and io.open(path, "rb")
    if not handle then return 0 end
    local size = handle:seek("end") or 0
    handle:close()
    return size
end

local function modelPath(model)
    return modelDirectory() .. "/" .. model.filename
end

local function modelById(id)
    for _, model in ipairs(MODEL_CATALOG) do
        if model.id == id then return model end
    end
end

local function startModelDownload(instance, context, model)
    local state = stateFor(instance)
    if state.download then
        state.status = _("A model download is already running.")
        context.requestRebuild("ui")
        return
    end
    local target = modelPath(model)
    if fileExists(target) then
        if state.settings.provider == "local" then state.settings.model = model.filename end
        state.status = _("Model is already downloaded: ") .. model.title
        saveSettings(state.settings)
        context.requestRebuild("ui")
        return
    end
    local work = modelDirectory() .. "/." .. model.id .. ".download"
    local log_path, exit_path, partial = work .. ".log", work .. ".exit", target .. ".part"
    os.remove(log_path); os.remove(exit_path); os.remove(partial)
    local command = "curl -L --fail --retry 2 --connect-timeout 15 --max-time 7200 --progress-bar"
        .. " -o " .. shellQuote(partial) .. " " .. shellQuote(model.url)
        .. " >" .. shellQuote(log_path) .. " 2>&1; code=$?; echo $code >" .. shellQuote(exit_path)
    local launch = "( " .. command .. " ) </dev/null >/dev/null 2>&1 & echo $!"
    local pipe = io.popen("sh -c " .. shellQuote(launch), "r")
    local pid = pipe and tonumber(pipe:read("*l")) or nil
    if pipe then pipe:close() end
    if not pid then
        state.status = _("The model download could not be started.")
        context.requestRebuild("ui")
        return
    end
    state.download = { model_id = model.id, model = model, pid = pid, log = log_path, exit = exit_path, partial = partial, target = target, progress = 0 }
    state.status = _("Downloading ") .. model.title .. "…"
    saveSettings(state.settings)
    context.requestRebuild("ui")
    UIManager:scheduleIn(.5, function() pollModelDownload(instance, context) end)
end

pollModelDownload = function(instance, context)
    local state = stateFor(instance)
    local download = state.download
    if not download then return end
    local log = io.open(download.log, "rb")
    if log then
        local text = log:read("*a") or ""
        log:close()
        local latest
        for value in text:gmatch("([%d]+[%.]?[%d]*)%%") do latest = tonumber(value) end
        if latest then download.progress = math.max(0, math.min(100, latest)) end
    end
    local exit = io.open(download.exit, "rb")
    if not exit then
        UIManager:scheduleIn(.5, function() pollModelDownload(instance, context) end)
        context.requestRebuild("fast")
        return
    end
    local code = tonumber(exit:read("*a") or "1") or 1
    exit:close()
    os.remove(download.exit)
    if code == 0 and fileSize(download.partial) > 0 then
        os.rename(download.partial, download.target)
        if state.settings.provider == "local" then state.settings.model = download.model.filename end
        state.status = _("Downloaded: ") .. download.model.title
        saveSettings(state.settings)
    else
        os.remove(download.partial)
        state.status = _("Model download failed. Check the network connection.")
    end
    os.remove(download.log)
    state.download = nil
    context.requestRebuild("ui")
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

local ModelProgress = WidgetContainer:extend{ width = 0, height = 0, progress = 0 }
function ModelProgress:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function ModelProgress:paintTo(bb, x, y)
    local border = math.max(1, scale(1))
    local value = math.max(0, math.min(100, tonumber(self.progress) or 0)) / 100
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_GRAY_8)
    bb:paintRect(x, y, math.floor(self.width * value), self.height, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, self.width, border, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + self.height - border, self.width, border, Blitbuffer.COLOR_BLACK)
end

stateFor = function(instance)
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

local function showModelPicker(instance, context)
    local dialog
    local rows = {}
    for _, model in ipairs(MODEL_CATALOG) do
        local installed = fileExists(modelPath(model))
        rows[#rows + 1] = {
            {
                text = (installed and "✓  " or "↓  ") .. model.title .. "  (" .. model.size .. ")",
                callback = function()
                    UIManager:close(dialog)
                    startModelDownload(instance, context, model)
                end,
            },
        }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = _("Choose a local GGUF model"), buttons = rows }
    UIManager:show(dialog)
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
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    local y = height - margin - button_h
    local upper_buttons_y = y - button_h - gap
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
    -- Reserve a status strip above the two button rows. Without this explicit
    -- space the progress bar was painted underneath the model/settings row.
    local chat_h = math.max(px(120), upper_buttons_y - chat_y - px(50))
    content[#content + 1] = TextBoxWidget:new{ text = transcript, face = Font:getFace("smallinfofont", px(10)), width = width - 2 * margin, height = chat_h, line_height = 0.3, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, chat_y } }
    if state.download then
        local progress = ModelProgress:new{ width = width - 2 * margin, height = px(10), progress = state.download.progress or 0 }
        progress.overlap_offset = { margin, upper_buttons_y - px(18) }
        content[#content + 1] = progress
        content[#content + 1] = TextWidget:new{
            text = string.format(_("Downloading %s · %d%%"), state.download.model.title, state.download.progress or 0),
            face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = width - 2 * margin, overlap_offset = { margin, upper_buttons_y - px(32) },
        }
    end
    content[#content + 1] = TextWidget:new{ text = short(state.status, 160), face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, upper_buttons_y - px(46) } }
    content[#content + 1] = Action:new{ title = _("Send"), width = third, height = button_h, primary = true, callback = function() sendMessage(instance, context) end, overlap_offset = { margin, y } }
    content[#content + 1] = Action:new{ title = settings.provider == "groq" and _("Groq") or _("Local"), width = third, height = button_h, callback = function() toggleProvider(instance, context) end, overlap_offset = { margin + third + gap, y } }
    content[#content + 1] = Action:new{ title = _("Settings"), width = third, height = button_h, callback = function()
        if settings.provider == "groq" then configure(instance, context, "api_key", _("Groq API key"), _("Paste the key; it is stored only on this reader")) else configure(instance, context, "endpoint", _("Local model endpoint"), DEFAULT_LOCAL_ENDPOINT) end
    end, overlap_offset = { margin + 2 * (third + gap), y } }
    content[#content + 1] = Action:new{ title = _("Models"), width = third, height = button_h, callback = function() showModelPicker(instance, context) end, overlap_offset = { margin, y - button_h - gap } }
    content[#content + 1] = Action:new{ title = _("System prompt"), width = third, height = button_h, callback = function() configure(instance, context, "system", _("System prompt"), "You are a helpful assistant") end, overlap_offset = { margin + third + gap, y - button_h - gap } }
    content[#content + 1] = Action:new{ title = _("Clear chat"), width = third, height = button_h, callback = function() clearChat(instance, context) end, overlap_offset = { margin + 2 * (third + gap), y - button_h - gap } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(content) }
end

return { id = "ai_chat", version = "1.1.1", title = "AI Chat Agent", subtitle = "Groq, local model and GGUF downloads", symbol = "AI", logo = "dchat", buildPane = buildPane }
