-- Regression test for AI Chat model downloads. It uses deterministic fake TLS sockets
-- so no network access or large GGUF file is needed.
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

local function install(name, value)
    package.preload[name] = function() return value end
end

local test_dir = os.tmpname() .. "_ai_chat_download_test"
os.execute("mkdir -p " .. string.format("%q", test_dir))

local Widget = class()
local Input = class()
install("ffi/blitbuffer", {
    COLOR_GRAY_8 = 1, COLOR_WHITE = 2, COLOR_LIGHT_GRAY = 3,
    COLOR_BLACK = 4, COLOR_DARK_GRAY = 5,
})
install("ui/widget/container/centercontainer", Widget)
install("datastorage", { getDataDir = function() return test_dir end })
install("device", { screen = { scaleBySize = function(_, value) return value end } })
install("ui/font", { getFace = function() return {} end })
install("ui/widget/container/framecontainer", Widget)
install("ui/geometry", Widget)
install("ui/gesturerange", Widget)
install("ui/widget/horizontalspan", Widget)
install("ui/widget/infomessage", Widget)
install("ui/widget/container/inputcontainer", Input)
install("ui/widget/inputdialog", Widget)
install("ui/widget/buttondialog", Widget)
install("ui/widget/overlapgroup", Widget)
install("ui/widget/textboxwidget", Widget)
install("ui/widget/textwidget", Widget)
install("ui/widget/container/widgetcontainer", Widget)
install("gettext", function(value) return value end)

local scheduled = {}
install("ui/uimanager", {
    scheduleIn = function(_, _, callback) scheduled[#scheduled + 1] = callback end,
    show = function() end,
    close = function() end,
})

local stored = { provider = "local" }
_G.G_reader_settings = {
    readSetting = function() return stored end,
    saveSetting = function(_, value) stored = value end,
    flush = function() end,
}
_G.unpack = table.unpack or unpack

local responses, requests = {}, {}
local function next_response()
    local response = table.remove(responses, 1)
    assert(response, "fake socket received an unexpected request")
    response.lines = response.lines or {}
    response.body = response.body or ""
    return response
end

local function fake_socket(response)
    local sock = { response = response }
    function sock:settimeout() end
    function sock:connect() return true end
    function sock:sni() return true end
    function sock:dohandshake() return true end
    function sock:send(data)
        requests[#requests + 1] = data
        return #data
    end
    function sock:receive(pattern)
        if self.response.events and #self.response.events > 0 then
            local event = table.remove(self.response.events, 1)
            return event[1], event[2], event[3]
        end
        if pattern == "*l" then
            local line = table.remove(self.response.lines, 1)
            if line == nil then return nil, "closed", "" end
            return line
        end
        if #self.response.body == 0 then return nil, "closed", "" end
        local size = tonumber(pattern) or #self.response.body
        local chunk = self.response.body:sub(1, size)
        self.response.body = self.response.body:sub(#chunk + 1)
        return chunk
    end
    function sock:close() self.closed = true end
    return sock
end

install("socket", { tcp = function() return fake_socket(next_response()) end })
install("ssl", { wrap = function(sock) return sock end })
install("socket.url", {
    parse = function(url)
        local scheme, tail = url:match("^(https?)://(.+)$")
        if not scheme then return nil end
        local authority, path_query = tail:match("^([^/]+)(/.*)$")
        authority, path_query = authority or tail, path_query or "/"
        local host, port = authority:match("^([^:]+):(%d+)$")
        host = host or authority
        local path, query = path_query:match("^([^?]*)%??(.*)$")
        return { scheme = scheme, host = host, port = port, path = path, query = query ~= "" and query or nil }
    end,
    absolute = function(_, location) return location end,
})

local app = assert(loadfile("ai_chat.lua"))()
assert(app.id == "ai_chat" and app.version == "1.5.2", "AI Chat must publish version 1.5.2")

-- Local endpoints use plain LuaSocket HTTP, and connection errors must retain
-- the actual reason instead of collapsing into a generic message.
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end }
end
package.preload["ltn12"] = function()
    return { source = { string = function() return function() return nil end end } }
end
package.preload["json"] = function()
    local json = { decode = { simple = true } }
    json.encode = function() return "{}" end
    return json
end
package.preload["socket.http"] = function()
    return { request = function() return nil, "connection refused on 127.0.0.1:11434" end }
end
local _, local_error = app._test.httpJson("http://127.0.0.1:11434/v1/chat/completions", {}, {})
assert(local_error:find("connection refused", 1, true), "local connection error was hidden")

local function run_scheduled()
    local limit = 50
    while #scheduled > 0 do
        limit = limit - 1
        assert(limit > 0, "download did not finish")
        local callback = table.remove(scheduled, 1)
        callback()
    end
end

local function read_file(path)
    local handle = assert(io.open(path, "rb"))
    local data = handle:read("*a")
    handle:close()
    return data
end

local function remove(path)
    os.remove(path)
    os.remove(path .. ".part")
end

local context = { requestRebuild = function() end }
local model = app._test.modelCatalog[1]
local model_dir = test_dir .. "/appdock/ai-models"
local target = model_dir .. "/" .. model.filename
local runtime_dir = model_dir .. "/runtime-arm64"
os.execute("mkdir -p " .. string.format("%q", runtime_dir))
local runtime_marker = assert(io.open(runtime_dir .. "/.version", "wb"))
runtime_marker:write("arm64-smollm-1.5.2\n")
runtime_marker:close()
for _, name in ipairs({ "llama-completion", "libllama-completion-impl.so", "libllama-common.so.0", "libllama.so.0", "libggml-base.so.0", "libggml.so.0", "libggml-cpu.so.0" }) do
    local runtime_file = assert(io.open(runtime_dir .. "/" .. name, "wb"))
    runtime_file:write("test-runtime")
    runtime_file:close()
end

-- The first request redirects to a CDN; the final response must be streamed,
-- verified as GGUF and atomically renamed into its final name.
responses = {
    { lines = { "HTTP/1.1 302 Found", "Location: https://cdn.example/model", "" } },
    {
        -- An initial would-block result proves the worker yields back to the
        -- UI scheduler and resumes correctly rather than blocking KOReader.
        events = { { nil, "timeout", "" } },
        lines = { "HTTP/1.1 200 OK", "Content-Length: 9", "" }, body = "GGUFModel",
    },
}
requests = {}
remove(target)
local instance = {}
app._test.startModelDownload(instance, context, model)
run_scheduled()
assert(read_file(target) == "GGUFModel", "redirected GGUF file was not written")
assert(instance.ai_chat.settings.local_model == model.filename, "local model was not selected after download")
assert(instance.ai_chat.status:find("Downloaded:", 1, true), "successful download was not reported")
assert(#requests == 2 and requests[1]:find("GET ", 1, true) and requests[2]:find("GET /model HTTP/1.1", 1, true), "HTTPS redirect was not followed")

-- A valid partial GGUF file must resume with a Range request and preserve the
-- already-downloaded bytes before atomic promotion.
remove(target)
local partial = assert(io.open(target .. ".part", "wb"))
partial:write("GGUF")
partial:close()
responses = {
    { lines = { "HTTP/1.1 302 Found", "Location: https://cdn.example/model", "" } },
    { lines = { "HTTP/1.1 206 Partial Content", "Content-Range: bytes 4-8/9", "Content-Length: 5", "" }, body = "Model" },
}
requests = {}
instance = {}
app._test.startModelDownload(instance, context, model)
run_scheduled()
assert(read_file(target) == "GGUFModel", "resumed GGUF file was not assembled")
assert(requests[2]:find("Range: bytes=4%-"), "resume request did not use the existing partial size")

-- HTTP failures must name the actual cause and retain valid partial data for a
-- later resume instead of deleting it and showing only a generic error.
remove(target)
partial = assert(io.open(target .. ".part", "wb"))
partial:write("GGUFpartial")
partial:close()
responses = {
    { lines = { "HTTP/1.1 403 Forbidden", "Content-Length: 0", "" } },
}
requests = {}
instance = {}
app._test.startModelDownload(instance, context, model)
run_scheduled()
assert(read_file(target .. ".part") == "GGUFpartial", "failed download removed resumable data")
assert(instance.ai_chat.status:find("HTTP 403", 1, true), "HTTP failure reason was hidden")
assert(instance.ai_chat.status:find("saved for resume", 1, true), "resume state was not communicated")

os.execute("rm -rf " .. string.format("%q", test_dir))
print("ai-chat-download-ok")
