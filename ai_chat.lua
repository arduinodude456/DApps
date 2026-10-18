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
-- New AppDock hosts composite glyphs transparently; older hosts use the
-- explicit surface bgcolor below instead of KOReader's implicit white buffer.
local ok_text, AppDockText = pcall(require, "appdock_text")
if ok_text and type(AppDockText) == "table" and type(AppDockText.TextBoxWidget) == "table" then
    TextBoxWidget = AppDockText.TextBoxWidget
end
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
local DOWNLOAD_IDLE_TIMEOUT, DOWNLOAD_MAX_TIME = 60, 7200
local DOWNLOAD_POLL_INTERVAL, DOWNLOAD_BURST_BYTES = .2, 64 * 1024

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
        local_model = trim(stored.local_model),
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
local pumpModelDownload
local pumpLocalInference
local startRuntimeDownload
local pumpRuntimeDownload

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

local function sourceDirectory()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    return source:match("^(.*)/[^/]+$") or "."
end

local runtimeDirectory

local function localRuntimePath()
    return runtimeDirectory() .. "/llama-completion"
end

local RUNTIME_FILES = {
    { name = "llama-completion", size = 70304 },
    { name = "libllama-completion-impl.so", size = 168584 },
    { name = "libllama-common.so.0", source = "libllama-common.so.0.6.0", size = 5486648 },
    { name = "libllama.so.0", source = "libllama.so.0.6.0", size = 4623920 },
    { name = "libggml-base.so.0", source = "libggml-base.so.0.26.0", size = 876752 },
    { name = "libggml.so.0", source = "libggml.so.0.26.0", size = 78456 },
    { name = "libggml-cpu.so.0", source = "libggml-cpu.so.0.26.0", size = 1002552 },
}
local RUNTIME_BASE_URL = "https://raw.githubusercontent.com/arduinodude456/DApps/9fcbc62/runtime/arm64/"
local RUNTIME_VERSION = "arm64-smollm-1.5.3"

runtimeDirectory = function()
    -- The installed DApp directory may be read-only. Keep the downloaded
    -- runtime in AppDock's writable data directory instead.
    return modelDirectory() .. "/runtime-arm64"
end

local function hasElfHeader(path)
    local handle = path and io.open(path, "rb")
    if not handle then return false end
    local header = handle:read(4)
    handle:close()
    return header == "\127ELF"
end

local function runtimeFileIsValid(file, path)
    return type(file) == "table" and fileSize(path) == tonumber(file.size) and hasElfHeader(path)
end

local function runtimeIsInstalled()
    local marker = io.open(runtimeDirectory() .. "/.version", "rb")
    local version = marker and trim(marker:read("*a") or "") or ""
    if marker then marker:close() end
    if version ~= RUNTIME_VERSION then return false end
    for _, file in ipairs(RUNTIME_FILES) do
        if not runtimeFileIsValid(file, runtimeDirectory() .. "/" .. file.name) then return false end
    end
    return true
end

local function installedModelPath(settings)
    for _, model in ipairs(MODEL_CATALOG) do
        if settings.model == model.id or settings.model == model.filename or settings.local_model == model.filename then
            local path = modelPath(model)
            if fileExists(path) then return path end
        end
    end
    -- Also recover files downloaded by AppDock AI Chat 1.2/1.3, where the
    -- local_model selection was not stored separately yet.
    for _, model in ipairs(MODEL_CATALOG) do
        local path = modelPath(model)
        if fileExists(path) then
            settings.local_model = model.filename
            settings.model = model.filename
            return path
        end
    end
    return nil
end

local function hasGgufHeader(path)
    local handle = path and io.open(path, "rb")
    if not handle then return false end
    local header = handle:read(4)
    handle:close()
    return header == "GGUF"
end

local function friendlyBytes(value)
    value = tonumber(value) or 0
    if value >= 1024 * 1024 then return string.format("%.1f MB", value / (1024 * 1024)) end
    if value >= 1024 then return string.format("%.0f KB", value / 1024) end
    return tostring(value) .. " B"
end

local function markDownloadActivity(download)
    download.last_activity = os.time()
end

local function downloadIsActive(download)
    if download.cancelled then return nil, "cancelled" end
    local now = os.time()
    if now - (download.started_at or now) > DOWNLOAD_MAX_TIME then return nil, "download timed out" end
    if now - (download.last_activity or now) > DOWNLOAD_IDLE_TIMEOUT then return nil, "network timed out" end
    return true
end

local function waitForDownloadIo(download)
    local active, err = downloadIsActive(download)
    if not active then return nil, err end
    coroutine.yield()
    return downloadIsActive(download)
end

local function asyncConnect(download, sock, host, port)
    sock:settimeout(0)
    while true do
        local connected, err = sock:connect(host, port)
        if connected or err == "already connected" then
            markDownloadActivity(download)
            return true
        end
        if err ~= "timeout" and err ~= "Operation already in progress" then return nil, "connect error: " .. tostring(err) end
        local active, wait_err = waitForDownloadIo(download)
        if not active then return nil, wait_err end
    end
end

local function asyncHandshake(download, sock)
    while true do
        local ok, err = sock:dohandshake()
        if ok then
            markDownloadActivity(download)
            return true
        end
        if err ~= "wantread" and err ~= "wantwrite" and err ~= "timeout" then return nil, "TLS handshake error: " .. tostring(err) end
        local active, wait_err = waitForDownloadIo(download)
        if not active then return nil, wait_err end
    end
end

local function asyncSend(download, sock, data)
    local index = 1
    while index <= #data do
        local sent, err, last = sock:send(data, index)
        if sent then
            index = sent + 1
            markDownloadActivity(download)
        elseif err == "timeout" or err == "wantwrite" or err == "wantread" then
            if last then index = last + 1 end
            local active, wait_err = waitForDownloadIo(download)
            if not active then return nil, wait_err end
        else
            return nil, "send error: " .. tostring(err)
        end
    end
    return true
end

local function asyncReceive(download, sock, pattern)
    local accumulated = ""
    while true do
        local value, err, partial = sock:receive(pattern, accumulated)
        if value then
            markDownloadActivity(download)
            return value
        end
        if err == "timeout" or err == "wantread" or err == "wantwrite" then
            accumulated = partial or accumulated
            if #accumulated > 0 then markDownloadActivity(download) end
            local active, wait_err = waitForDownloadIo(download)
            if not active then return nil, wait_err end
        else
            return nil, tostring(err), partial
        end
    end
end

local function closeSocket(sock)
    if sock then pcall(function() sock:close() end) end
end

local function writeDownloadChunk(download, handle, chunk)
    if not chunk or #chunk == 0 then return true end
    local ok, err = handle:write(chunk)
    if not ok then return nil, "file write error: " .. tostring(err) end
    download.bytes = (download.bytes or 0) + #chunk
    if (download.total or 0) > 0 then download.progress = math.floor(math.min(100, 100 * download.bytes / download.total)) end
    download.burst_bytes = (download.burst_bytes or 0) + #chunk
    markDownloadActivity(download)
    if download.burst_bytes >= DOWNLOAD_BURST_BYTES then
        download.burst_bytes = 0
        local active, wait_err = waitForDownloadIo(download)
        if not active then return nil, wait_err end
    end
    return true
end

local function streamModelUrl(download, url, redirect_count, range_start)
    local socket = require("socket")
    local socket_url = require("socket.url")
    local ssl = require("ssl")
    redirect_count = redirect_count or 0
    if redirect_count > 5 then return nil, "too many redirects" end

    local parsed = socket_url.parse(url)
    if not parsed or not parsed.host or (parsed.scheme ~= "https" and parsed.scheme ~= "http") then return nil, "invalid download URL" end
    if parsed.scheme ~= "https" then return nil, "model download redirect was not HTTPS" end
    local host = parsed.host
    local port = tonumber(parsed.port) or 443
    local path = parsed.path or "/"
    if parsed.query and parsed.query ~= "" then path = path .. "?" .. parsed.query end
    local sock = socket.tcp()
    local connected, connect_err = asyncConnect(download, sock, host, port)
    if not connected then closeSocket(sock); return nil, connect_err end

    local tls_sock, wrap_err = ssl.wrap(sock, {
        mode = "client", protocol = "any", verify = "none",
        options = { "all", "no_sslv2", "no_sslv3" },
    })
    if not tls_sock then closeSocket(sock); return nil, "TLS setup error: " .. tostring(wrap_err) end
    sock = tls_sock
    sock:settimeout(0)
    if sock.sni then pcall(function() sock:sni(host) end) end
    local handshaken, handshake_err = asyncHandshake(download, sock)
    if not handshaken then closeSocket(sock); return nil, handshake_err end

    local host_header = host
    if port ~= 443 then host_header = host_header .. ":" .. tostring(port) end
    local request = {
        "GET " .. path .. " HTTP/1.1",
        "Host: " .. host_header,
        "User-Agent: AppDock-AIChat/1.2",
        "Accept: application/octet-stream",
        "Connection: close",
    }
    if range_start and range_start > 0 then request[#request + 1] = "Range: bytes=" .. tostring(range_start) .. "-" end
    request[#request + 1] = ""
    request[#request + 1] = ""
    local sent, send_err = asyncSend(download, sock, table.concat(request, "\r\n"))
    if not sent then closeSocket(sock); return nil, send_err end

    local headers, status_line = {}, nil
    while true do
        local line, read_err = asyncReceive(download, sock, "*l")
        if not line then closeSocket(sock); return nil, "header read error: " .. tostring(read_err) end
        if line == "" then break end
        if not status_line then
            status_line = line
        else
            local key, value = line:match("^(.-):%s*(.*)")
            if key and value then headers[key:lower()] = value end
        end
    end
    local code = tonumber(status_line and status_line:match("HTTP/%d%.%d%s+(%d%d%d)"))
    if not code then closeSocket(sock); return nil, "invalid HTTP response" end
    if code >= 300 and code < 400 and headers.location then
        local next_url = socket_url.absolute(url, headers.location:gsub("\r$", ""))
        closeSocket(sock)
        return streamModelUrl(download, next_url, redirect_count + 1, range_start)
    end
    if code < 200 or code > 299 then closeSocket(sock); return nil, "HTTP " .. tostring(code) end

    local append, total = false, nil
    if code == 206 then
        local first, _, full_size = (headers["content-range"] or ""):match("^bytes%s+(%d+)%-(%d+)/(%d+)$")
        if not first or tonumber(first) ~= (range_start or 0) then closeSocket(sock); return nil, "invalid resume response" end
        append, total = true, tonumber(full_size)
    else
        total = tonumber(headers["content-length"])
        range_start = 0
    end
    local handle, open_err = io.open(download.partial, append and "ab" or "wb")
    if not handle then closeSocket(sock); return nil, "cannot save model: " .. tostring(open_err) end
    download.bytes = append and (range_start or 0) or 0
    download.total = total or 0
    download.progress = download.total > 0 and math.floor(math.min(100, 100 * download.bytes / download.total)) or 0

    local function fail(err)
        handle:close()
        closeSocket(sock)
        return nil, err
    end
    local function save(chunk)
        local ok, err = writeDownloadChunk(download, handle, chunk)
        if not ok then return nil, err end
        return true
    end

    local transfer = headers["transfer-encoding"]
    if transfer and transfer:lower():find("chunked", 1, true) then
        while true do
            local size_line, size_err = asyncReceive(download, sock, "*l")
            if not size_line then return fail("chunk header error: " .. tostring(size_err)) end
            local size_hex = size_line:match("^%s*([%x]+)")
            local size = size_hex and tonumber(size_hex, 16)
            if not size then return fail("invalid chunked response") end
            if size == 0 then break end
            local chunk, chunk_err = asyncReceive(download, sock, size)
            if not chunk then return fail("chunk read error: " .. tostring(chunk_err)) end
            local saved, save_err = save(chunk)
            if not saved then return fail(save_err) end
            local _, ending_err = asyncReceive(download, sock, 2)
            if ending_err then return fail("chunk terminator error: " .. tostring(ending_err)) end
        end
    elseif headers["content-length"] then
        local remaining = tonumber(headers["content-length"]) or 0
        while remaining > 0 do
            local chunk, chunk_err = asyncReceive(download, sock, math.min(16384, remaining))
            if not chunk then return fail("file read error: " .. tostring(chunk_err)) end
            remaining = remaining - #chunk
            local saved, save_err = save(chunk)
            if not saved then return fail(save_err) end
        end
    else
        while true do
            local chunk, chunk_err, partial = asyncReceive(download, sock, 16384)
            if chunk then
                local saved, save_err = save(chunk)
                if not saved then return fail(save_err) end
            elseif chunk_err == "closed" then
                if partial and #partial > 0 then
                    local saved, save_err = save(partial)
                    if not saved then return fail(save_err) end
                end
                break
            else
                return fail("file read error: " .. tostring(chunk_err))
            end
        end
    end
    handle:close()
    closeSocket(sock)
    if download.total > 0 and download.bytes ~= download.total then return nil, "incomplete model file" end
    return true
end

local function downloadModel(download)
    local partial_size = fileSize(download.partial)
    if partial_size > 0 and not hasGgufHeader(download.partial) then
        os.remove(download.partial)
        partial_size = 0
    end
    return streamModelUrl(download, download.model.url, 0, partial_size)
end

local function runtimeProgress(download)
    local completed, total = 0, 0
    for index, file in ipairs(download.files) do
        total = total + file.size
        if index < download.index then
            completed = completed + file.size
        elseif index == download.index then
            completed = completed + math.min(file.size, download.current_bytes or 0)
        end
    end
    download.progress = total > 0 and math.floor(math.min(100, 100 * completed / total)) or 0
end

startRuntimeDownload = function(instance, context)
    local state = stateFor(instance)
    if runtimeIsInstalled() then return true end
    if state.runtime_download then return true end
    os.execute("mkdir -p " .. shellQuote(runtimeDirectory()) .. " >/dev/null 2>&1")
    local files = {}
    for _, source in ipairs(RUNTIME_FILES) do
        local file = {}
        for key, value in pairs(source) do file[key] = value end
        file.source = file.source or file.name
        file.target = runtimeDirectory() .. "/" .. file.name
        file.partial = file.target .. ".part"
        files[#files + 1] = file
    end
    state.runtime_download = { files = files, index = 1, current_bytes = 0, progress = 0 }
    state.status = _("Downloading the local SmolLM runtime…")
    context.requestRebuild("ui")
    UIManager:scheduleIn(0, function() pumpRuntimeDownload(instance, context) end)
    return true
end

pumpRuntimeDownload = function(instance, context)
    local state = stateFor(instance)
    local download = state.runtime_download
    if not download then return end
    local file = download.files[download.index]
    if not file then
        state.runtime_download = nil
        local marker = io.open(runtimeDirectory() .. "/.version", "wb")
        if marker then marker:write(RUNTIME_VERSION .. "\n"); marker:close() end
        state.status = _("SmolLM runtime installed. Ready to run locally.")
        context.requestRebuild("ui")
        return
    end
    local worker = download.worker
    if not worker then
        -- A prior session may have finished receiving a file but been closed
        -- before the atomic rename below. Promote that verified partial instead
        -- of asking the server for an impossible range beyond EOF.
        if runtimeFileIsValid(file, file.partial) then
            if os.rename(file.partial, file.target) then
                download.index = download.index + 1
                download.current_bytes = 0
                runtimeProgress(download)
                context.requestRebuild("fast")
                UIManager:scheduleIn(0, function() pumpRuntimeDownload(instance, context) end)
                return
            end
            state.status = _("Runtime download failed: could not install ") .. file.name
            state.runtime_download = nil
            context.requestRebuild("ui")
            return
        end
        download.current_bytes = fileSize(file.partial)
        download.worker = coroutine.create(function()
            local partial_size = fileSize(file.partial)
            if partial_size > file.size then
                os.remove(file.partial)
                partial_size = 0
            end
            local transfer = { partial = file.partial, bytes = partial_size, total = file.size, started_at = os.time(), last_activity = os.time() }
            local ok, err = streamModelUrl(transfer, RUNTIME_BASE_URL .. file.source, 0, partial_size)
            return ok, err
        end)
        worker = download.worker
    end
    local resumed, ok, err = coroutine.resume(worker)
    if not resumed then
        state.status = _("Runtime download failed: ") .. short(ok, 180)
        state.runtime_download = nil
        context.requestRebuild("ui")
        return
    end
    download.current_bytes = fileSize(file.partial)
    runtimeProgress(download)
    if coroutine.status(worker) ~= "dead" then
        context.requestRebuild("fast")
        UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function() pumpRuntimeDownload(instance, context) end)
        return
    end
    if ok and runtimeFileIsValid(file, file.partial) then
        if os.rename(file.partial, file.target) then
            download.index = download.index + 1
            download.worker = nil
            download.current_bytes = 0
            runtimeProgress(download)
            context.requestRebuild("fast")
            UIManager:scheduleIn(0, function() pumpRuntimeDownload(instance, context) end)
        else
            state.status = _("Runtime download failed: could not install ") .. file.name
            state.runtime_download = nil
            context.requestRebuild("ui")
        end
    else
        state.status = _("Runtime download failed: ") .. short(err or ("incomplete " .. file.name), 180)
        state.runtime_download = nil
        context.requestRebuild("ui")
    end
end

local function finishModelDownload(instance, context, succeeded, err)
    local state = stateFor(instance)
    local download = state.download
    if not download then return end
    if succeeded and hasGgufHeader(download.partial) then
        local renamed, rename_err = os.rename(download.partial, download.target)
        if renamed then
            state.settings.local_model = download.model.filename
            if state.settings.provider == "local" then state.settings.model = download.model.filename end
            state.status = _("Downloaded: ") .. download.model.title .. _(". Ready to run directly on this Kobo.")
            saveSettings(state.settings)
            startRuntimeDownload(instance, context)
        else
            state.status = _("Model download failed: could not save the file (") .. short(rename_err or "rename failed", 80) .. ")"
        end
    else
        local saved = fileSize(download.partial)
        local resume_note = saved > 0 and (" " .. friendlyBytes(saved) .. " saved for resume.") or ""
        state.status = _("Model download failed: ") .. short(err or "invalid GGUF file", 100) .. resume_note
    end
    state.download = nil
    context.requestRebuild("ui")
end

pumpModelDownload = function(instance, context)
    local state = stateFor(instance)
    local download = state.download
    if not download then return end
    if os.time() - (download.started_at or os.time()) > DOWNLOAD_MAX_TIME then download.cancelled = true end
    local resumed, succeeded, err = coroutine.resume(download.worker)
    if not resumed then
        finishModelDownload(instance, context, false, "internal downloader error: " .. tostring(succeeded))
        return
    end
    if coroutine.status(download.worker) == "dead" then
        finishModelDownload(instance, context, succeeded == true, err)
        return
    end
    context.requestRebuild("fast")
    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function() pumpModelDownload(instance, context) end)
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
    local partial = target .. ".part"
    local now = os.time()
    local download = {
        model_id = model.id, model = model, partial = partial, target = target,
        progress = 0, bytes = fileSize(partial), total = 0,
        started_at = now, last_activity = now, burst_bytes = 0,
    }
    download.worker = coroutine.create(function() return downloadModel(download) end)
    state.download = download
    state.status = download.bytes > 0 and (_("Resuming ") .. model.title .. "…") or (_("Downloading ") .. model.title .. "…")
    saveSettings(state.settings)
    context.requestRebuild("ui")
    UIManager:scheduleIn(0, function() pumpModelDownload(instance, context) end)
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
    local socketutil, ltn12 = require("socketutil"), require("ltn12")
    local parsed = require("socket.url").parse(endpoint)
    local http
    if parsed and parsed.scheme == "https" then
        http = require("ssl.https")
    elseif parsed and parsed.scheme == "http" then
        http = require("socket.http")
    else
        return nil, _("The model endpoint must start with http:// or https://.")
    end
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
    local ok, result, code, response_headers, status = pcall(function()
        return http.request{ url = endpoint, method = "POST", source = ltn12.source.string(body), sink = sink, headers = headers }
    end)
    socketutil:reset_timeout()
    local raw_code = code
    code = tonumber(code)
    if not ok then return nil, _("The model request failed: ") .. short(result, 220) end
    if not result then return nil, _("The model could not be reached: ") .. short(raw_code or status or "connection failed", 220) end
    if not code or not response_headers then return nil, _("The model returned no HTTP status.") end
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

local function localPrompt(settings, history)
    local lines = { "<|im_start|>system", settings.system, "<|im_end|>" }
    for _, item in ipairs(history) do
        if type(item) == "table" and (item.role == "user" or item.role == "assistant") then
            lines[#lines + 1] = "<|im_start|>" .. item.role
            lines[#lines + 1] = item.content
            lines[#lines + 1] = "<|im_end|>"
        end
    end
    lines[#lines + 1] = "<|im_start|>assistant"
    return table.concat(lines, "\n")
end

local function buildLocalLauncher(runtime, model_path, prompt_path, output_path, log_path, exit_path)
    local runtime_dir = runtime:match("^(.*)/[^/]+$") or "."
    return "#!/bin/sh\n"
        .. "export LD_LIBRARY_PATH=" .. shellQuote(runtime_dir) .. "\n"
        .. "if [ ! -x " .. shellQuote(runtime) .. " ]; then echo 'runtime executable is missing or not executable' >&2; echo 126 >" .. shellQuote(exit_path) .. "; exit 126; fi\n"
        .. shellQuote(runtime) .. " --model " .. shellQuote(model_path)
        .. " --file " .. shellQuote(prompt_path) .. " --predict 256 --threads 2"
        .. " --no-display-prompt --single-turn --simple-io --temp 0.3"
        .. " >" .. shellQuote(output_path) .. " 2>" .. shellQuote(log_path) .. "\n"
        .. "code=$?\necho \"$code\" >" .. shellQuote(exit_path) .. "\nexit \"$code\"\n"
end

local function startLocalInference(instance, context)
    local state = stateFor(instance)
    local model_path = installedModelPath(state.settings)
    if not model_path or not hasGgufHeader(model_path) then
        state.status = _("Download a local GGUF model first, then select Local.")
        context.requestRebuild("ui")
        return false
    end
    if not runtimeIsInstalled() then
        startRuntimeDownload(instance, context)
        return "pending"
    end
    local runtime = localRuntimePath()
    local work = modelDirectory() .. "/.smollm-chat-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
    local prompt_path, output_path, log_path, exit_path, script_path = work .. ".prompt", work .. ".out", work .. ".log", work .. ".exit", work .. ".sh"
    local prompt = io.open(prompt_path, "wb")
    if not prompt then
        state.status = _("Could not create the local SmolLM prompt file.")
        context.requestRebuild("ui")
        return false
    end
    prompt:write(localPrompt(state.settings, state.settings.history))
    prompt:close()
    os.remove(output_path); os.remove(log_path); os.remove(exit_path)
    local script = io.open(script_path, "wb")
    if not script then
        os.remove(prompt_path)
        state.status = _("Could not create the local SmolLM launcher script.")
        context.requestRebuild("ui")
        return false
    end
    -- The launcher is POSIX /bin/sh syntax only. Exporting the sibling
    -- libraries also prevents loader errors when the runtime is in AppDock's
    -- writable data folder rather than a system library directory.
    script:write(buildLocalLauncher(runtime, model_path, prompt_path, output_path, log_path, exit_path))
    script:close()
    os.execute("chmod 755 " .. shellQuote(script_path) .. " >/dev/null 2>&1")
    local launch = "sh " .. shellQuote(script_path) .. " </dev/null >/dev/null 2>&1 & echo $!"
    local pipe = io.popen(launch, "r")
    local read_ok, line = false, nil
    if pipe then
        read_ok, line = pcall(function() return pipe:read("*l") end)
        pcall(function() pipe:close() end)
    end
    local pid = read_ok and tonumber(line) or nil
    if not pid then
        os.remove(prompt_path); os.remove(output_path); os.remove(log_path); os.remove(exit_path); os.remove(script_path)
        state.status = _("Could not start the bundled SmolLM runtime.")
        context.requestRebuild("ui")
        return false
    end
    state.inference = { pid = pid, prompt = prompt_path, output = output_path, log = log_path, exit = exit_path, script = script_path }
    state.status = _("Running SmolLM directly on this Kobo…")
    context.requestRebuild("ui")
    UIManager:scheduleIn(.5, function() pumpLocalInference(instance, context) end)
    return true
end

pumpLocalInference = function(instance, context)
    local state = stateFor(instance)
    local inference = state.inference
    if not inference then return end
    local exit = io.open(inference.exit, "rb")
    if not exit then
        context.requestRebuild("fast")
        UIManager:scheduleIn(.5, function() pumpLocalInference(instance, context) end)
        return
    end
    local exit_marker = exit:read("*a") or ""
    local code = tonumber(exit_marker:match("^%s*([%-]?%d+)%s*\n$"))
    exit:close()
    if code == nil then
        context.requestRebuild("fast")
        UIManager:scheduleIn(.5, function() pumpLocalInference(instance, context) end)
        return
    end
    local output_handle = io.open(inference.output, "rb")
    local answer = output_handle and trim(output_handle:read("*a") or "") or ""
    if output_handle then output_handle:close() end
    local log_handle = io.open(inference.log, "rb")
    local log = log_handle and trim(log_handle:read("*a") or "") or ""
    if log_handle then log_handle:close() end
    os.remove(inference.prompt); os.remove(inference.output); os.remove(inference.log); os.remove(inference.exit); os.remove(inference.script)
    state.inference = nil
    if code == 0 and answer ~= "" then
        state.settings.history[#state.settings.history + 1] = { role = "assistant", content = short(answer, MAX_RESPONSE) }
        while #state.settings.history > MAX_HISTORY do table.remove(state.settings.history, 1) end
        saveSettings(state.settings)
        state.status = _("SmolLM replied locally; chat saved.")
    else
        table.remove(state.settings.history, #state.settings.history)
        state.status = _("SmolLM failed: ") .. short(log ~= "" and log or ("exit code " .. tostring(code)), 180)
    end
    context.requestRebuild("ui")
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
    if settings.provider == "groq" then
        settings.model = DEFAULT_GROQ_MODEL
    else
        settings.model = settings.local_model ~= "" and settings.local_model or DEFAULT_LOCAL_MODEL
    end
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
        if settings.provider == "local" then
            if instance.ai_chat.inference then
                table.remove(history, #history)
                instance.ai_chat.status = _("SmolLM is already generating a reply.")
                context.requestRebuild("ui")
                return
            end
            local started = startLocalInference(instance, context)
            if started then return end
            table.remove(history, #history)
            return
        end
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
    content[#content + 1] = TextBoxWidget:new{ bgcolor = Blitbuffer.COLOR_WHITE, text = transcript, face = Font:getFace("smallinfofont", px(10)), width = width - 2 * margin, height = chat_h, line_height = 0.3, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, chat_y } }
    if state.download then
        local progress = ModelProgress:new{ width = width - 2 * margin, height = px(10), progress = state.download.progress or 0 }
        progress.overlap_offset = { margin, upper_buttons_y - px(18) }
        content[#content + 1] = progress
        content[#content + 1] = TextWidget:new{
            text = string.format(_("Downloading %s · %d%%"), state.download.model.title, state.download.progress or 0),
            face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = width - 2 * margin, overlap_offset = { margin, upper_buttons_y - px(32) },
        }
    elseif state.runtime_download then
        local progress = ModelProgress:new{ width = width - 2 * margin, height = px(10), progress = state.runtime_download.progress or 0 }
        progress.overlap_offset = { margin, upper_buttons_y - px(18) }
        content[#content + 1] = progress
        content[#content + 1] = TextWidget:new{
            text = string.format(_("Installing local SmolLM runtime · %d%%"), state.runtime_download.progress or 0),
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

return { id = "ai_chat", version = "1.5.4", title = "AI Chat Agent", subtitle = "Groq and direct local SmolLM", symbol = "AI", logo = "dchat", buildPane = buildPane,
    _test = { modelCatalog = MODEL_CATALOG, runtimeFiles = RUNTIME_FILES, runtimeVersion = RUNTIME_VERSION, runtimeIsInstalled = runtimeIsInstalled, runtimeFileIsValid = runtimeFileIsValid, buildLocalLauncher = buildLocalLauncher, startModelDownload = startModelDownload, pumpModelDownload = pumpModelDownload, httpJson = httpJson, localPrompt = localPrompt },
}
