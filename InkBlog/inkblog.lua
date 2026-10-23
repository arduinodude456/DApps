--[[--
InkBlog for AppDock.

A deliberately quiet, monochrome InkBlog reader and writer.  This is a single
Lua 5.1 file because AppStore installs one Lua file per DApp.  It does not load
any InkBlog companion code and never contacts the network while buildPane runs.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then pcall(function() lfs = require("lfs") end) end
local ok_html, HtmlBoxWidget = pcall(require, "ui/widget/htmlboxwidget")
local ok_image, ImageWidget = pcall(require, "ui/widget/imagewidget")

local APP_ID = "inkblog"
local SETTINGS_KEY = "appdock_inkblog_v1"
local API = "https://qndwbriqomqqaqhkasbh.supabase.co"
local PUBLISHABLE_KEY = "sb_publishable_UAIcZameyUZHtEB-NY1ffQ_TfF67BjS"
-- The Edge Function returns paths in this bucket.  Keep this in sync with the
-- bucket configured by the InkBlog deployment; paths themselves are validated.
local MEDIA_BUCKET = "inkblog-media"
local DATA_DIR = DataStorage:getDataDir() .. "/inkblog"
local SESSION_FILE = "session.json"
local DRAFTS_FILE = "drafts.json"
local IMAGE_DIR = DATA_DIR .. "/images"
local MAX_RESPONSE_BYTES = 1024 * 1024
local MAX_POST_BYTES = 96 * 1024
local MAX_IMAGE_BYTES = 700 * 1024
local MAX_CACHED_IMAGES = 8
-- The database RPCs cap every batch at 50.  Small batches also make page turns
-- inexpensive on an e-ink reader; cached rows are only a local view of them.
local PAGE_SIZE = 8
local COMMENT_SIZE = 8
local NOTIFICATION_SIZE = 30

-- Only these names may ever reach PostgREST.  Keeping the public aliases here
-- prevents a future call site from accidentally editing an old, non-InkBlog
-- table with the publishable key.
local REST_TABLES = {
    profiles = "inkblog_profiles", posts = "inkblog_posts",
    post_images = "inkblog_post_images", follows = "inkblog_follows",
    likes = "inkblog_likes", comments = "inkblog_comments",
    notifications = "inkblog_notifications", reports = "inkblog_reports",
    blocks = "inkblog_blocks",
}
local CONNECT_TIMEOUT = 8
local REQUEST_TIMEOUT = 20

-- These values intentionally do not consult context.palette or appdock_theme.
-- Color8 makes the requested #333, #666 and #CCC exact on KOReader builds
-- which expose it.  Named colors are only a compatibility fallback.
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local function exactGray(value, fallback)
    local color8 = Blitbuffer.Color8
    if type(color8) == "function" then
        local ok, color = pcall(color8, value)
        if ok and color ~= nil then return color end
    elseif type(color8) == "table" and type(color8.new) == "function" then
        local ok, color = pcall(color8.new, color8, value)
        if ok and color ~= nil then return color end
    end
    return fallback
end
local GRAY_333 = exactGray(0x33, Blitbuffer.COLOR_DARK_GRAY or BLACK)
local GRAY_666 = exactGray(0x66, Blitbuffer.COLOR_GRAY_8 or GRAY_333)
local GRAY_CCC = exactGray(0xCC, Blitbuffer.COLOR_LIGHT_GRAY or WHITE)

local function scale(value)
    return Device.screen:scaleBySize(value)
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function escapeHtml(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copyTable(item) end
    return result
end

local function randomHex(bytes)
    local file = io.open("/dev/urandom", "rb")
    if file then
        local data = file:read(bytes)
        file:close()
        if type(data) == "string" and #data == bytes then
            return (data:gsub(".", function(character) return string.format("%02x", string.byte(character)) end))
        end
    end
    -- This only names a local temporary file. It is never an authentication secret.
    return string.format("%08x%08x", os.time() % 0x7fffffff, math.floor((os.clock() * 1000000) % 0x7fffffff))
end

local function ensureDir(path)
    if lfs and type(lfs.attributes) == "function" then
        local ok, attributes = pcall(lfs.attributes, path)
        if ok and attributes and attributes.mode == "directory" then return true end
        local made = pcall(lfs.mkdir, path)
        if made then
            local exists, check = pcall(lfs.attributes, path)
            return exists and check and check.mode == "directory"
        end
    end
    -- Paths are constants derived from DataStorage, never user input.
    return os.execute("mkdir -p " .. string.format("%q", path)) == 0
end

local function safeFileName(name)
    return type(name) == "string" and name:match("^[a-z][a-z0-9_%-]*%.json$") ~= nil
end

local function jsonModule()
    local ok, JSON = pcall(require, "json")
    return ok and JSON or nil
end

local function atomicJsonWrite(name, value)
    if not safeFileName(name) then return nil, "Unsafe local filename." end
    if not ensureDir(DATA_DIR) then return nil, "InkBlog storage is unavailable." end
    local JSON = jsonModule()
    if not JSON then return nil, "JSON support is unavailable." end
    local ok, encoded = pcall(JSON.encode, value)
    if not ok or type(encoded) ~= "string" or #encoded > 2 * MAX_RESPONSE_BYTES then return nil, "Local data could not be encoded." end
    local target = DATA_DIR .. "/" .. name
    local temporary = target .. "." .. randomHex(6) .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err or "Temporary file could not be opened." end
    local wrote, write_err = file:write(encoded)
    file:close()
    if not wrote then pcall(os.remove, temporary); return nil, write_err or "Temporary file could not be written." end
    local renamed, rename_err = os.rename(temporary, target)
    if not renamed then pcall(os.remove, temporary); return nil, rename_err or "Temporary file could not replace its target." end
    return true
end

local function readJsonFile(name)
    if not safeFileName(name) then return nil end
    local file = io.open(DATA_DIR .. "/" .. name, "rb")
    if not file then return nil end
    local raw = file:read(MAX_RESPONSE_BYTES + 1)
    file:close()
    if type(raw) ~= "string" or #raw > MAX_RESPONSE_BYTES then return nil end
    local JSON = jsonModule()
    if not JSON then return nil end
    local ok, decoded = pcall(JSON.decode, raw, JSON.decode and JSON.decode.simple)
    return ok and type(decoded) == "table" and decoded or nil
end

local function loadSettings()
    local settings = { sort = "newest", last_mode = "feed" }
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local ok, saved = pcall(G_reader_settings.readSetting, G_reader_settings, SETTINGS_KEY, {})
        if ok and type(saved) == "table" then
            if saved.sort == "popular" then settings.sort = "popular" end
            if type(saved.last_mode) == "string" then settings.last_mode = saved.last_mode end
        end
    end
    return settings
end

local function saveSettings(settings)
    if G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
        pcall(G_reader_settings.saveSetting, G_reader_settings, SETTINGS_KEY, {
            sort = settings.sort == "popular" and "popular" or "newest",
            last_mode = tostring(settings.last_mode or "feed"):sub(1, 24),
        })
    end
end

local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
local function validUuid(value)
    return type(value) == "string" and #value == 36 and value:match(UUID_PATTERN) ~= nil
end

-- The media function and the database validation triggers use only these two
-- processed-PNG shapes.  Rejecting everything else also rejects traversal,
-- duplicate separators, legacy JPEGs, and loose UUID-looking names.
local function validManagedPath(path)
    if type(path) ~= "string" or #path < 41 or #path > 146 then return false end
    local user_id, image_id = path:match("^(.-)/(.-)%.png$")
    if user_id and image_id and validUuid(user_id) and validUuid(image_id) then return true end
    local owner_id, post_id, processed_id = path:match("^(.-)/(.-)/(.-)%.png$")
    return owner_id ~= nil and validUuid(owner_id) and validUuid(post_id) and validUuid(processed_id)
end

local function validEmail(value)
    value = trim(value)
    return #value >= 5 and #value <= 240 and value:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") ~= nil
end

local function validPassword(value)
    return type(value) == "string" and #value >= 8 and #value <= 160 and not value:find("[%z\r\n]")
end

local function safeText(value, maximum)
    value = tostring(value or ""):gsub("%z", "")
    if #value > maximum then return nil end
    return value
end

local function utf8Next(source, position)
    local byte = source:byte(position)
    if not byte then return position end
    if byte < 0x80 then return position + 1 end
    if byte < 0xE0 then return position + 2 end
    if byte < 0xF0 then return position + 3 end
    if byte < 0xF8 then return position + 4 end
    return position + 1
end

local function utf8Length(source)
    local count, position = 0, 1
    source = tostring(source or "")
    while position <= #source do count = count + 1; position = utf8Next(source, position) end
    return count
end

-- Return a character-safe prefix and a character-safe remaining suffix.
local function utf8Cut(source, wanted)
    source, wanted = tostring(source or ""), math.max(1, math.floor(tonumber(wanted) or 1))
    local position, count, last_space = 1, 0, nil
    while position <= #source and count < wanted do
        local next_position = utf8Next(source, position)
        local character = source:sub(position, next_position - 1)
        count = count + 1
        if character:match("%s") then last_space = next_position - 1 end
        position = next_position
    end
    if position > #source + 1 then position = #source + 1 end
    local cut = position - 1
    if last_space and last_space > math.floor(cut * .55) then cut = last_space end
    local head = source:sub(1, cut):gsub("%s+$", "")
    local tail = source:sub(cut + 1):gsub("^%s+", "")
    return head, tail
end

local function initialFor(name)
    name = trim(name or "?")
    local letter = name:match("^%s*(.)") or "?"
    return letter:upper()
end

local function utcNow()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function localDraftId()
    return "local_" .. randomHex(12)
end

local function sessionShape(raw)
    if type(raw) ~= "table" then return {} end
    local token = type(raw.access_token) == "string" and raw.access_token or ""
    local refresh = type(raw.refresh_token) == "string" and raw.refresh_token or ""
    local user = type(raw.user) == "table" and raw.user or {}
    return {
        access_token = token,
        refresh_token = refresh,
        expires_at = tonumber(raw.expires_at) or 0,
        tbs_account_id = validUuid(raw.tbs_account_id) and raw.tbs_account_id or "",
        user = { id = validUuid(user.id) and user.id or "", email = type(user.email) == "string" and user.email:sub(1, 240) or "" },
    }
end

local function loadSession()
    return sessionShape(readJsonFile(SESSION_FILE))
end

local function saveSession(session)
    return atomicJsonWrite(SESSION_FILE, sessionShape(session))
end

local function loadDrafts()
    local raw, drafts = readJsonFile(DRAFTS_FILE), {}
    if type(raw) ~= "table" or type(raw.items) ~= "table" then return drafts end
    for _, item in ipairs(raw.items) do
        if type(item) == "table" and type(item.local_id) == "string" and type(item.title) == "string" and type(item.body) == "string" and #item.title <= 600 and #item.body <= MAX_POST_BYTES then
            drafts[#drafts + 1] = {
                local_id = item.local_id:match("^local_[0-9a-f]+$") and item.local_id or localDraftId(),
                remote_id = validUuid(item.remote_id) and item.remote_id or nil,
                title = item.title, body = item.body, updated_at = tostring(item.updated_at or ""), images = type(item.images) == "table" and item.images or {},
            }
        end
    end
    return drafts
end

local function saveDrafts(drafts)
    local clean = {}
    for _, item in ipairs(drafts or {}) do
        if type(item) == "table" and type(item.title) == "string" and type(item.body) == "string" then
            clean[#clean + 1] = { local_id = item.local_id, remote_id = item.remote_id, title = item.title, body = item.body, updated_at = item.updated_at, images = item.images or {} }
        end
    end
    return atomicJsonWrite(DRAFTS_FILE, { items = clean })
end

local getTbsIdentity
local function stateFor(instance)
    instance.inkblog = instance.inkblog or {
        settings = loadSettings(), session = loadSession(), drafts = loadDrafts(),
        view = "feed", mode = "feed", list_page = 0, list_offset = 0, posts_has_more = false,
        comment_page = 0, comment_offset = 0, comments_has_more = false,
        posts = {}, comments = {}, notifications = {}, profile = nil, author_profile = nil,
        selected_post = nil, selected_author_id = nil, article_page = 1, article_tab = "read",
        editor = { title = "", body = "", local_id = nil, remote_id = nil, images = {} },
        image_cache = {}, image_order = {}, pending_image_path = nil,
        status = _("Tap Laden to receive the latest ink."), loading = false,
    }
    local state = instance.inkblog
    state.session = sessionShape(state.session)
    state.posts, state.comments, state.notifications = state.posts or {}, state.comments or {}, state.notifications or {}
    state.drafts, state.image_cache, state.image_order = state.drafts or {}, state.image_cache or {}, state.image_order or {}
    if state.session.tbs_account_id ~= "" then
        local tbs = getTbsIdentity and getTbsIdentity() or nil
        if not tbs or tbs.account_id ~= state.session.tbs_account_id then
            state.session = sessionShape({})
            saveSession(state.session)
            state.profile, state.author_profile, state.notifications = nil, nil, {}
            state.posts, state.comments, state.selected_post, state.selected_author_id = {}, {}, nil, nil
            state.list_page, state.list_offset, state.comment_page, state.comment_offset = 0, 0, 0, 0
            for _, cached in pairs(state.image_cache) do if cached.file then pcall(os.remove, cached.file) end end
            state.image_cache, state.image_order = {}, {}
            state.status = _("The AppDock TBS account changed. InkBlog will use the account currently signed in on this reader.")
        end
    end
    return state
end

local function requestRebuild(context)
    if context and type(context.requestRebuild) == "function" then context.requestRebuild("ui") end
end

local function showInput(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return dialog
end

local function responseMessage(decoded, fallback)
    if type(decoded) == "table" then
        local value = decoded.message or decoded.msg or decoded.error_description or decoded.error
        if type(value) == "table" then value = value.message end
        if type(value) == "string" and value ~= "" then return value:sub(1, 220) end
    end
    return fallback
end

-- All HTTP is user initiated via runNetwork; this primitive has no side effects
-- outside the one bounded HTTPS request.
local function rawRequest(path, method, payload, headers, binary)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return nil, nil, "Invalid request path." end
    local ok_https, https = pcall(require, "ssl.https")
    local ok_socket, socket = pcall(require, "socket")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_util, socketutil = pcall(require, "socketutil")
    local JSON = jsonModule()
    if not ok_https or not ok_socket or not ok_ltn12 or not ok_util or not socketutil or (not binary and not JSON) then
        return nil, nil, _("HTTPS or JSON support is unavailable.")
    end
    local body
    if payload ~= nil then
        local encoded_ok, encoded = pcall(JSON.encode, payload)
        if not encoded_ok or type(encoded) ~= "string" or #encoded > MAX_RESPONSE_BYTES then return nil, nil, _("The request could not be encoded.") end
        body = encoded
    end
    local chunks, received = {}, 0
    local function sink(chunk, sink_error)
        if sink_error then return nil, sink_error end
        if chunk then
            received = received + #chunk
            if received > MAX_RESPONSE_BYTES then return nil, "response too large" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    local request_headers = { ["accept"] = binary and "image/*" or "application/json", ["apikey"] = PUBLISHABLE_KEY, ["user-agent"] = "AppDock-InkBlog/1.0" }
    for key, value in pairs(headers or {}) do request_headers[key] = value end
    if body then
        request_headers["content-type"] = "application/json"
        request_headers["content-length"] = tostring(#body)
    end
    local request = { url = API .. path, method = method, headers = request_headers, sink = sink }
    if body then request.source = ltn12.source.string(body) end
    socketutil:set_timeout(CONNECT_TIMEOUT, REQUEST_TIMEOUT)
    local ok, code, response_headers, status = pcall(function() return socket.skip(1, https.request(request)) end)
    socketutil:reset_timeout()
    code = tonumber(code)
    local response_body = table.concat(chunks)
    if not ok or not response_headers or not code then
        return nil, nil, _("InkBlog could not reach the service. Your local drafts remain on this reader.")
    end
    if code < 200 or code > 299 then
        local decoded
        if JSON and response_body ~= "" then pcall(function() decoded = JSON.decode(response_body, JSON.decode.simple) end) end
        return nil, code, responseMessage(decoded, _("The InkBlog service refused the request."))
    end
    if binary then return response_body, code, nil, response_headers end
    if response_body == "" then return {}, code end
    local decoded_ok, decoded = pcall(JSON.decode, response_body, JSON.decode.simple)
    if not decoded_ok then return nil, code, _("The InkBlog service returned invalid data.") end
    return decoded, code
end

local function authHeaders(session)
    local headers = {}
    if session and type(session.access_token) == "string" and session.access_token ~= "" then headers["authorization"] = "Bearer " .. session.access_token end
    return headers
end

getTbsIdentity = function()
    local ok, Account = pcall(require, "appdock_tbs_account")
    if not ok or type(Account) ~= "table" or type(Account.get) ~= "function" or type(Account.isSignedIn) ~= "function" then
        return nil, _("The AppDock TBS account module is unavailable. Update AppDock and try again.")
    end
    local signed_ok, signed = pcall(Account.isSignedIn, nil)
    if not signed_ok or signed ~= true then return nil, _("Sign in to your TBS account in AppDock first.") end
    local loaded, account = pcall(Account.get, nil)
    if not loaded or type(account) ~= "table" or not validUuid(account.account_id)
        or type(account.device_id) ~= "string" or type(account.device_secret) ~= "string" then
        return nil, _("The TBS account credentials on this reader are incomplete.")
    end
    local display_name = ""
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local settings_ok, settings = pcall(G_reader_settings.readSetting, G_reader_settings, "appdock_homescreen", {})
        local profile = settings_ok and type(settings) == "table" and settings.tbs_account or nil
        if type(profile) == "table" then display_name = trim(profile.display_name or profile.username) end
    end
    return {
        account_id = account.account_id:lower(),
        device_id = account.device_id,
        device_secret = account.device_secret,
        display_name = display_name,
    }
end

local function applySessionResult(state, result, code, err, purpose)
    if type(result) ~= "table" then
        state.status = err or _("Sign-in failed. Check the email, password, and connection.")
        return false
    end
    if type(result.access_token) ~= "string" or result.access_token == "" then
        if purpose == "signup" then
            state.status = _("Registration created. Confirm the email, then sign in. No session was issued yet.")
        else
            state.status = _("The service did not issue a session.")
        end
        return false
    end
    state.session = sessionShape(result)
    state.session.expires_at = os.time() + math.max(0, tonumber(result.expires_in) or 0)
    saveSession(state.session)
    state.status = purpose == "refresh" and _("Session refreshed.")
        or purpose == "tbs" and _("TBS account connected. Your InkBlog profile is ready.")
        or _("Signed in. Your profile is ready for ink.")
    return true
end

local function signInWithTbs(state)
    local account, account_error
    if getTbsIdentity then account, account_error = getTbsIdentity() end
    if not account then return nil, account_error or _("Sign in to your TBS account in AppDock first.") end
    local headers = {
        ["x-tbs-account-id"] = account.account_id,
        ["x-tbs-device-id"] = account.device_id,
        ["x-tbs-device-secret"] = account.device_secret,
    }
    local result, code, err = rawRequest("/functions/v1/inkblog-tbs-auth", "POST", { display_name = account.display_name }, headers)
    if not applySessionResult(state, result, code, err, "tbs") then return nil, state.status end
    if state.session.user.id ~= account.account_id then
        state.session = sessionShape({})
        saveSession(state.session)
        return nil, _("The InkBlog session did not match the TBS account on this reader.")
    end
    state.session.tbs_account_id = account.account_id
    saveSession(state.session)
    return true
end

local function refreshSession(state)
    if state.session.tbs_account_id ~= "" then
        local renewed, renewal_error = signInWithTbs(state)
        if not renewed then
            state.session = sessionShape({})
            saveSession(state.session)
            return nil, renewal_error
        end
        return true
    end
    if state.session.refresh_token == "" then return nil, _("Sign in before using this action.") end
    local result, code, err = rawRequest("/auth/v1/token?grant_type=refresh_token", "POST", { refresh_token = state.session.refresh_token }, {})
    if not applySessionResult(state, result, code, err, "refresh") then return nil, state.status end
    return true
end

local function ensureAccess(state)
    if state.session.tbs_account_id ~= "" then
        local account, account_error
        if getTbsIdentity then account, account_error = getTbsIdentity() end
        if not account then
            state.session = sessionShape({})
            saveSession(state.session)
            return nil, account_error or _("Sign in to your TBS account in AppDock first.")
        end
        if account.account_id ~= state.session.tbs_account_id then
            state.session = sessionShape({})
            saveSession(state.session)
        end
    end
    if state.session.access_token == "" then
        if state.session.refresh_token ~= "" then return refreshSession(state) end
        return signInWithTbs(state)
    end
    if state.session.expires_at > 0 and state.session.expires_at <= os.time() + 30 then return refreshSession(state) end
    return true
end

local function apiRequest(state, method, path, payload, extra_headers)
    -- Published posts, public profiles, and the list RPCs are readable through
    -- RLS with the publishable key. Add a bearer only when a session exists.
    if state.session.access_token ~= "" then
        local authenticated, auth_error = ensureAccess(state)
        if not authenticated then return nil, nil, auth_error end
    end
    local headers = authHeaders(state.session)
    for key, value in pairs(extra_headers or {}) do headers[key] = value end
    return rawRequest(path, method, payload, headers)
end

local function restPath(table_path, query)
    local managed_table = REST_TABLES[table_path]
    if not managed_table then return nil end
    local suffix = "/rest/v1/" .. managed_table
    if query and query ~= "" then suffix = suffix .. "?" .. query end
    return suffix
end

local function restRequest(state, method, table_path, query, payload, headers)
    local suffix = restPath(table_path, query)
    if not suffix then return nil, nil, "Unsafe or unknown InkBlog table." end
    return apiRequest(state, method, suffix, payload, headers)
end

local function rpcRequest(state, name, payload)
    return apiRequest(state, "POST", "/rest/v1/rpc/" .. name, payload)
end

local function urlEncode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(character) return string.format("%%%02X", string.byte(character)) end)
end

local function wifiReady()
    local loaded, NetworkMgr = pcall(require, "ui/network/manager")
    if not loaded or not NetworkMgr or type(NetworkMgr.isWifiOn) ~= "function" then return true end
    local ok, online = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return not ok or online == true
end

-- Deferring lets the busy indicator paint once before the short bounded request.
local function runNetwork(state, context, busy, operation, require_session)
    if state.loading then return end
    if not wifiReady() then state.status = _("Network is off. Turn on Wi-Fi, then retry."); requestRebuild(context); return end
    state.loading, state.status = true, busy
    requestRebuild(context)
    local function job()
        if require_session then
            local authenticated, auth_error = ensureAccess(state)
            if not authenticated then
                state.loading = false
                state.status = auth_error or _("Use the TBS account signed in on this reader.")
                requestRebuild(context)
                return
            end
        end
        local ok, err = pcall(operation)
        state.loading = false
        if not ok then state.status = _("InkBlog could not complete that action.") end
        requestRebuild(context)
    end
    if UIManager and type(UIManager.tickAfterNext) == "function" then UIManager:tickAfterNext(job) else job() end
end

local function markdownImagePaths(markdown)
    local found, seen = {}, {}
    for alt, target in tostring(markdown or ""):gmatch("!%[([^%]]*)%]%(([^%)]+)%)") do
        local path = target:match("^inkblog:(.+)$")
        if path and validManagedPath(path) and not seen[path] then
            seen[path] = true
            found[#found + 1] = { path = path, alt = trim(alt):sub(1, 160) }
        end
    end
    return found
end

-- Plain text is used only in controls and previews.  Blocks retain their
-- Markdown so native HTML rendering can preserve meaningful emphasis.
local function plainInlineText(value)
    value = tostring(value or "")
    value = value:gsub("!%[([^%]]*)%]%(([^%)]+)%)", function(alt, target)
        if target:match("^inkblog:") then return "[Bild: " .. alt .. "]" end
        return "[Externes Bild nicht geladen: " .. alt .. "]"
    end)
    value = value:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)")
    value = value:gsub("`([^`]*)`", "%1")
    value = value:gsub("%*%*([^*]+)%*%*", "%1"):gsub("__([^_]+)__", "%1")
    value = value:gsub("%*([^*]+)%*", "%1"):gsub("_([^_]+)_", "%1")
    return value
end

local function inlineHtml(value)
    local text = escapeHtml(value or "")
    -- No links, raw HTML, or remote image tags are emitted: reading remains
    -- passive while emphasis survives in the native HtmlBoxWidget.
    text = text:gsub("!%[([^%]]*)%]%(([^%)]+)%)", function(alt)
        return "[Bild: " .. alt .. "]"
    end)
    text = text:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)")
    text = text:gsub("`([^`]*)`", "<code>%1</code>")
    text = text:gsub("%*%*([^*]+)%*%*", "<strong>%1</strong>")
    text = text:gsub("__([^_]+)__", "<strong>%1</strong>")
    text = text:gsub("%*([^*]+)%*", "<em>%1</em>")
    text = text:gsub("_([^_]+)_", "<em>%1</em>")
    return text
end

local function markdownBlocks(source)
    source = tostring(source or "")
    if #source > MAX_POST_BYTES then source = source:sub(1, MAX_POST_BYTES) end
    source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines, blocks, paragraph = {}, {}, {}
    for line in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local function closeParagraph()
        if #paragraph > 0 then blocks[#blocks + 1] = { kind = "paragraph", text = table.concat(paragraph, " ") }; paragraph = {} end
    end
    local in_code, code = false, {}
    for _, line in ipairs(lines) do
        if line:match("^%s*```") then
            closeParagraph()
            if in_code then blocks[#blocks + 1] = { kind = "code", text = table.concat(code, "\n") }; code = {} end
            in_code = not in_code
        elseif in_code then
            code[#code + 1] = line
        elseif line:match("^%s*$") then
            closeParagraph()
        else
            local marks, heading = line:match("^%s*(#+)%s+(.+)%s*$")
            local quote = line:match("^%s*>%s?(.*)$")
            local bullet = line:match("^%s*[-*+]%s+(.+)%s*$")
            local ordered = line:match("^%s*%d+[%.%)]%s+(.+)%s*$")
            if marks then
                closeParagraph(); blocks[#blocks + 1] = { kind = "heading", level = math.min(#marks, 3), text = heading }
            elseif quote ~= nil then
                closeParagraph(); blocks[#blocks + 1] = { kind = "quote", text = quote }
            elseif bullet then
                closeParagraph(); blocks[#blocks + 1] = { kind = "list", text = "• " .. bullet }
            elseif ordered then
                closeParagraph(); blocks[#blocks + 1] = { kind = "list", text = "– " .. ordered }
            else
                paragraph[#paragraph + 1] = trim(line)
            end
        end
    end
    closeParagraph()
    if in_code then blocks[#blocks + 1] = { kind = "code", text = table.concat(code, "\n") } end
    if #blocks == 0 then blocks[1] = { kind = "paragraph", text = "" } end
    return blocks
end

local function hardUtf8Cut(source, position)
    local next_position = utf8Next(source, position)
    return source:sub(position, next_position - 1), next_position
end

local function blockFontSize(block, px)
    if block.kind == "heading" then return math.max(18, px((block.level or 1) == 1 and 24 or 20)) end
    if block.kind == "code" then return math.max(14, px(14)) end
    return math.max(16, px(18))
end

-- Count physical display lines, preserving hard newlines (especially code).
-- The optional TextBox measurement is used when the host exposes one; the
-- deterministic width-aware count remains the safe fallback for test and old
-- KOReader builds.
local function physicalLineCount(text, chars_per_line)
    local lines, column, position = 1, 0, 1
    text = tostring(text or "")
    while position <= #text do
        local character, next_position = hardUtf8Cut(text, position)
        if character == "\n" then
            lines, column = lines + 1, 0
        else
            if column >= chars_per_line then lines, column = lines + 1, 0 end
            column = column + 1
        end
        position = next_position
    end
    return lines
end

local function measureBlockLines(block, content_width, px, chars_per_line)
    local measured
    local size = blockFontSize(block, px)
    local ok, widget = pcall(function()
        return TextBoxWidget:new{ text = plainInlineText(block.text or ""), width = content_width,
            face = Font:getFace(block.kind == "code" and "smallinfofont" or "cfont", size),
            line_height = .30 }
    end)
    if ok and widget then
        local dimen = widget.dimen
        if not dimen and type(widget.getSize) == "function" then
            local sized, result = pcall(widget.getSize, widget)
            if sized then dimen = result end
        end
        if dimen and tonumber(dimen.h) and tonumber(dimen.h) > 0 then
            local line_height = math.max(1, math.floor(size * 1.35))
            measured = math.max(1, math.ceil(tonumber(dimen.h) / line_height))
        end
    end
    return math.max(measured or 0, physicalLineCount(block.text or "", chars_per_line))
end

-- Split exact UTF-8 source into pieces that individually fit a physical-line
-- capacity.  Unlike the old recursive splitter it always consumes input, so a
-- 600-line code block or an unbroken long heading cannot recurse forever.
local function splitBlock(block, max_lines, chars_per_line)
    local source, pieces, position = tostring(block.text or ""), {}, 1
    if source == "" then return { copyTable(block) } end
    while position <= #source do
        local first, lines, column = position, 1, 0
        while position <= #source do
            local character, next_position = hardUtf8Cut(source, position)
            if character == "\n" then
                position, column = next_position, 0
                if lines >= max_lines then break end
                lines = lines + 1
            else
                if column >= chars_per_line then
                    if lines >= max_lines then break end
                    lines, column = lines + 1, 0
                end
                column, position = column + 1, next_position
            end
        end
        -- The loop consumes at least one codepoint; retain every byte exactly.
        local piece = copyTable(block)
        piece.text = source:sub(first, position - 1)
        if piece.text == "" then
            local character, next_position = hardUtf8Cut(source, position)
            piece.text, position = character, next_position
        end
        pieces[#pieces + 1] = piece
    end
    return pieces
end

local function paginateBlocks(blocks, content_width, content_height, px)
    local pages, page = {}, {}
    local normal_size = math.max(16, px(18))
    local line_height = math.max(1, math.floor(normal_size * 1.35))
    local max_lines = math.max(3, math.floor(content_height / line_height))
    local used = 0
    local function addFittingBlock(block)
        local kind = block.kind or "paragraph"
        local size = blockFontSize(block, px)
        local width_factor = kind == "heading" and .58 or (kind == "code" and .60 or .52)
        local chars_per_line = math.max(4, math.floor(content_width / math.max(1, size * width_factor)))
        local lines = measureBlockLines(block, content_width, px, chars_per_line)
        if used > 0 and used + lines + 1 > max_lines then pages[#pages + 1] = page; page, used = {}, 0 end
        page[#page + 1] = block
        used = used + lines + 1
    end
    for _, block in ipairs(blocks or {}) do
        local kind = block.kind or "paragraph"
        local size = blockFontSize(block, px)
        local width_factor = kind == "heading" and .58 or (kind == "code" and .60 or .52)
        local chars_per_line = math.max(4, math.floor(content_width / math.max(1, size * width_factor)))
        local lines = measureBlockLines(block, content_width, px, chars_per_line)
        local capacity = math.max(1, max_lines - 1)
        if lines > capacity then
            for _, piece in ipairs(splitBlock(block, capacity, chars_per_line)) do addFittingBlock(piece) end
        else
            addFittingBlock(block)
        end
    end
    if #page > 0 or #pages == 0 then pages[#pages + 1] = page end
    return pages
end

local ActionButton = InputContainer:extend{ width = nil, height = nil, title = "", body = nil, callback = nil, primary = false, disabled = false, dimen = nil }

function ActionButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local background = self.primary and BLACK or WHITE
    local foreground = self.primary and WHITE or BLACK
    local inset = math.max(2, math.floor(math.min(self.width, self.height) * .12))
    local content
    if self.body then
        content = TextBoxWidget:new{ text = self.body, width = math.max(1, self.width - inset * 2), height = math.max(1, self.height - inset * 2), face = Font:getFace("smallinfofont", math.max(14, math.floor(self.height * .31))), fgcolor = foreground, bgcolor = background, line_height = 0.31, alignment = "left" }
    else
        content = CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", math.max(14, math.floor(self.height * .32))), fgcolor = foreground, bold = true, max_width = math.max(1, self.width - inset * 2) } }
    end
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = self.body and inset or 0, bordersize = self.primary and 0 or 1, radius = math.max(2, math.floor(self.height * .18)), background = self.disabled and GRAY_CCC or background, content }
    self.ges_events = { TapInkBlogAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function ActionButton:paintTo(bb, x, y)
    local range = self.ges_events.TapInkBlogAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function ActionButton:onTapInkBlogAction()
    if not self.disabled and self.callback then self.callback() end
    return true
end

local function rectanglesOverlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- All interactive geometry is derived from the caller's px function.  A
-- compact pane may intentionally choose smaller controls; this helper never
-- replaces their requested height with Device.screen's unrelated scale.
local function addButton(layer, title, x, y, width, height, callback, primary, body, disabled)
    x, y = math.floor(tonumber(x) or -1), math.floor(tonumber(y) or -1)
    width, height = math.floor(tonumber(width) or 0), math.floor(tonumber(height) or 0)
    local bounds = layer and layer.dimen
    if not bounds or x < 0 or y < 0 or width < 1 or height < 1 or x + width > bounds.w or y + height > bounds.h then return nil end
    local candidate = { x = x, y = y, w = width, h = height }
    layer._inkblog_button_bounds = layer._inkblog_button_bounds or {}
    for _, occupied in ipairs(layer._inkblog_button_bounds) do if rectanglesOverlap(candidate, occupied) then return nil end end
    local button = ActionButton:new{ title = title, body = body, width = width, height = height, callback = callback, primary = primary == true, disabled = disabled == true }
    button.overlap_offset = { x, y }
    layer[#layer + 1] = button
    layer._inkblog_button_bounds[#layer._inkblog_button_bounds + 1] = candidate
    return button
end

local function addText(layer, text, x, y, width, size, options)
    options = options or {}
    local font_size = math.max(14, math.floor(tonumber(size) or 14))
    layer[#layer + 1] = TextWidget:new{ text = tostring(text or ""), face = Font:getFace(options.serif and "cfont" or "smallinfofont", font_size), fgcolor = options.color or BLACK, bold = options.bold == true, max_width = math.max(1, width), overlap_offset = { x, y } }
end

local function addBox(layer, text, x, y, width, height, size, options)
    options = options or {}
    local font_size = math.max(options.serif and 16 or 14, math.floor(tonumber(size) or 14))
    local box = TextBoxWidget:new{ text = tostring(text or ""), width = math.max(1, width), height = math.max(1, height), face = Font:getFace(options.serif and "cfont" or "smallinfofont", font_size), fgcolor = options.color or BLACK, bgcolor = options.bg or WHITE, line_height = options.line_height or .30, alignment = options.alignment or "left" }
    box.overlap_offset = { x, y }
    layer[#layer + 1] = box
    return box
end

local function avatarWidget(profile, state, size)
    local avatar_path = profile and profile.avatar_path
    local interior
    local cached = avatar_path and state.image_cache[avatar_path]
    if cached and cached.file and ok_image and ImageWidget then
        local created, widget = pcall(function() return ImageWidget:new{ file = cached.file, width = size - scale(4), height = size - scale(4), dither = true, file_do_cache = false } end)
        interior = created and widget or nil
    end
    if not interior then
        interior = CenterContainer:new{ dimen = Geom:new{ w = size - scale(4), h = size - scale(4) }, TextWidget:new{ text = initialFor(profile and profile.display_name), face = Font:getFace("cfont", math.max(scale(14), math.floor(size * .45))), fgcolor = BLACK, bold = true, max_width = size - scale(8) } }
    end
    return FrameContainer:new{ width = size, height = size, padding = scale(2), bordersize = 1, radius = math.floor(size / 2), background = WHITE, interior }
end

local function listPosts(state, context, mode, author_id)
    state.mode, state.list_page, state.list_offset = mode, 0, 0
    runNetwork(state, context, _("Loading ink…"), function()
        local result, code, err = rpcRequest(state, "inkblog_list_posts", { p_mode = mode, p_author = author_id, p_sort = state.settings.sort, p_limit = PAGE_SIZE, p_offset = 0 })
        if type(result) ~= "table" then state.status = err or _("Posts could not be loaded."); return end
        state.posts = result
        state.posts_has_more = #result == PAGE_SIZE
        state.status = #result == 0 and _("No posts on this page yet.") or _("Fresh ink loaded.")
    end)
end

local function changePostBatch(state, context, offset)
    offset = clamp(offset, 0, 10000)
    runNetwork(state, context, _("Turning the page…"), function()
        local result, _, err = rpcRequest(state, "inkblog_list_posts", { p_mode = state.mode, p_author = state.mode == "blog" and state.selected_author_id or nil, p_sort = state.settings.sort, p_limit = PAGE_SIZE, p_offset = offset })
        if type(result) ~= "table" then state.status = err or _("The next page could not be loaded."); return end
        state.posts, state.list_offset, state.list_page = result, offset, 0
        state.posts_has_more = #result == PAGE_SIZE
        state.status = #result == 0 and _("No more posts on this page.") or _("Next page loaded.")
    end)
end

local function loadComments(state, context, post_id)
    state.comment_page, state.comment_offset = 0, 0
    runNetwork(state, context, _("Loading margin notes…"), function()
        local result, code, err = rpcRequest(state, "inkblog_list_comments", { p_post = post_id, p_limit = COMMENT_SIZE, p_offset = 0 })
        if type(result) ~= "table" then state.status = err or _("Margin notes could not be loaded."); return end
        state.comments = result
        state.comments_has_more = #result == COMMENT_SIZE
        state.status = #result == 0 and _("No margin notes yet.") or _("Margin notes loaded.")
    end)
end

local function changeCommentBatch(state, context, offset)
    offset = clamp(offset, 0, 10000)
    local post = state.selected_post
    if not post or not validUuid(post.id) then return end
    runNetwork(state, context, _("Turning the page…"), function()
        local result, _, err = rpcRequest(state, "inkblog_list_comments", { p_post = post.id, p_limit = COMMENT_SIZE, p_offset = offset })
        if type(result) ~= "table" then state.status = err or _("The next notes could not be loaded."); return end
        state.comments, state.comment_offset, state.comment_page = result, offset, 0
        state.comments_has_more = #result == COMMENT_SIZE
        state.status = #result == 0 and _("No more notes on this page.") or _("Next notes loaded.")
    end)
end

local function loadOwnProfile(state, context)
    runNetwork(state, context, _("Loading your profile…"), function()
        if state.session.user.id == "" then state.status = _("The InkBlog profile could not be linked to the TBS account."); return end
        local query = "id=eq." .. urlEncode(state.session.user.id) .. "&select=id,display_name,bio,avatar_path"
        local result, code, err = restRequest(state, "GET", "profiles", query)
        if type(result) ~= "table" then state.status = err or _("Profile could not be loaded."); return end
        state.profile = result[1]
        if not state.profile then
            local display = state.session.user.email:match("^([^@]+)") or _("Reader")
            local made, make_code, make_err = restRequest(state, "POST", "profiles", nil, { id = state.session.user.id, display_name = display, bio = "" }, { ["prefer"] = "return=representation" })
            state.profile = type(made) == "table" and made[1] or { id = state.session.user.id, display_name = display, bio = "" }
            state.status = made and _("Your new profile is ready.") or (make_err or _("Profile setup will retry later."))
        else
            state.status = _("Your profile is ready.")
        end
    end, true)
end

local function loadAuthor(state, context, author_id)
    if not validUuid(author_id) then return end
    state.selected_author_id, state.view, state.mode, state.author_profile = author_id, "author", "blog", nil
    runNetwork(state, context, _("Opening author’s blog…"), function()
        local result, code, err = restRequest(state, "GET", "profiles", "id=eq." .. urlEncode(author_id) .. "&select=id,display_name,bio,avatar_path")
        if type(result) ~= "table" then state.status = err or _("Author profile could not be loaded."); return end
        state.author_profile = result[1] or { id = author_id, display_name = _("Unknown author"), bio = "" }
        -- The profile endpoint is intentionally direct; relationship state is
        -- separately resolved so Follow/Block labels survive a reopened blog.
        if state.session.user.id ~= "" then
            local follows = restRequest(state, "GET", "follows", "follower_id=eq." .. urlEncode(state.session.user.id) .. "&following_id=eq." .. urlEncode(author_id) .. "&select=following_id")
            local blocks = restRequest(state, "GET", "blocks", "blocker_id=eq." .. urlEncode(state.session.user.id) .. "&blocked_id=eq." .. urlEncode(author_id) .. "&select=blocked_id")
            state.author_profile.followed = type(follows) == "table" and #follows > 0
            state.author_profile.blocked = type(blocks) == "table" and #blocks > 0
        else
            state.author_profile.followed, state.author_profile.blocked = false, false
        end
        local posts, post_code, post_err = rpcRequest(state, "inkblog_list_posts", { p_mode = "blog", p_author = author_id, p_sort = state.settings.sort, p_limit = PAGE_SIZE, p_offset = 0 })
        if type(posts) == "table" then state.posts = posts; state.list_page = 0; state.list_offset = 0; state.posts_has_more = #posts == PAGE_SIZE; state.status = _("Author blog loaded.") else state.status = post_err or _("The author profile loaded, but not the posts.") end
    end)
    requestRebuild(context)
end

local function openPost(state, context, post)
    if type(post) ~= "table" or not validUuid(post.id) then return end
    state.selected_post, state.article_page, state.article_tab, state.comments = post, 1, "read", {}
    state.view = "article"
    requestRebuild(context)
end

local function getPostAndOpen(state, context, post_id)
    if not validUuid(post_id) then state.status = _("This notification has no readable post."); requestRebuild(context); return end
    runNetwork(state, context, _("Opening post…"), function()
        local result, code, err = restRequest(state, "GET", "posts", "id=eq." .. urlEncode(post_id) .. "&select=id,author_id,title,markdown,status,created_at,updated_at,published_at")
        if type(result) ~= "table" or not result[1] then state.status = err or _("That post is no longer available."); return end
        state.selected_post, state.article_page, state.article_tab, state.view = result[1], 1, "read", "article"
        state.status = _("Post opened.")
    end)
end

local function promptCredentials(state, context, signup)
    local email_dialog
    email_dialog = InputDialog:new{
        title = signup and _("Register for InkBlog") or _("Sign in to InkBlog"), input = "", input_hint = _("Email"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(email_dialog) end }, { text = _("Next"), is_enter_default = true, callback = function()
            local email = trim(email_dialog:getInputText())
            UIManager:close(email_dialog)
            if not validEmail(email) then state.status = _("Enter a valid email address."); requestRebuild(context); return end
            local password_dialog
            password_dialog = InputDialog:new{
                title = _("Password"), input = "", input_hint = _("At least 8 characters"),
                buttons = { { { text = _("Cancel"), callback = function() UIManager:close(password_dialog) end }, { text = signup and _("Register") or _("Sign in"), is_enter_default = true, callback = function()
                    local password = password_dialog:getInputText()
                    UIManager:close(password_dialog)
                    if not validPassword(password) then state.status = _("Use a password between 8 and 160 characters."); requestRebuild(context); return end
                    runNetwork(state, context, signup and _("Creating account…") or _("Signing in…"), function()
                        local path = signup and "/auth/v1/signup" or "/auth/v1/token?grant_type=password"
                        local payload = signup and { email = email, password = password, data = { display_name = email:match("^([^@]+)") } } or { email = email, password = password }
                        local result, code, err = rawRequest(path, "POST", payload, {})
                        local purpose = signup and "signup" or "signin"
                        if applySessionResult(state, result, code, err, purpose) and not signup then
                            state.view = "profile"
                        end
                    end)
                end } } },
            }
            showInput(password_dialog)
        end } } },
    }
    showInput(email_dialog)
end

local function logout(state, context)
    if state.session.access_token == "" then return end
    runNetwork(state, context, _("Signing out…"), function()
        -- A failed remote logout never strands an account token on the reader.
        rawRequest("/auth/v1/logout", "POST", {}, authHeaders(state.session))
        state.session = sessionShape({})
        saveSession(state.session)
        state.profile, state.author_profile, state.posts, state.comments = nil, nil, {}, {}
        state.notifications, state.image_cache, state.image_order = {}, {}, {}
        state.selected_post, state.selected_author_id = nil, nil
        state.view, state.status = "profile", _("Signed out. Local drafts stay on this reader.")
    end)
end

local function draftIndex(state, local_id)
    for index, item in ipairs(state.drafts) do if item.local_id == local_id then return index, item end end
end

local function captureLocalDraft(state)
    local editor = state.editor or {}
    local title, body = tostring(editor.title or ""), tostring(editor.body or "")
    if #title > 600 or #body > MAX_POST_BYTES then return nil, _("A title or draft is too long to store safely.") end
    local local_id = editor.local_id or localDraftId()
    editor.local_id = local_id
    local record = { local_id = local_id, remote_id = editor.remote_id, title = title, body = body, images = copyTable(editor.images or {}), updated_at = utcNow() }
    local index = draftIndex(state, local_id)
    if index then state.drafts[index] = record else state.drafts[#state.drafts + 1] = record end
    local saved, save_err = saveDrafts(state.drafts)
    if not saved then return record, save_err end
    return record
end

local function removeLocalDraft(state, local_id)
    local remaining = {}
    for _, item in ipairs(state.drafts) do if item.local_id ~= local_id then remaining[#remaining + 1] = item end end
    state.drafts = remaining
    saveDrafts(state.drafts)
end

local function beginNewPost(state, context)
    state.editor = { title = "", body = "", local_id = nil, remote_id = nil, images = {} }
    state.view, state.status = "write", _("New ink. Add a title and your first line.")
    requestRebuild(context)
end

local function editDraft(state, context, draft)
    if type(draft) ~= "table" then return end
    state.editor = { title = draft.title or "", body = draft.body or "", local_id = draft.local_id, remote_id = draft.remote_id, images = copyTable(draft.images or {}) }
    state.view, state.status = "write", _("Local draft opened. It has not been sent.")
    requestRebuild(context)
end

local function editPost(state, context, post)
    if type(post) ~= "table" then return end
    state.editor = { title = post.title or "", body = post.markdown or "", local_id = nil, remote_id = post.id, images = markdownImagePaths(post.markdown or "") }
    state.view, state.status = "write", _("Editing your published ink.")
    requestRebuild(context)
end

local function promptEditorTitle(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Title"), input = state.editor.title or "", input_hint = _("A quiet, clear title"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Save"), is_enter_default = true, callback = function()
            local title = dialog:getInputText()
            UIManager:close(dialog)
            if #title > 600 then state.status = _("Titles are limited to 600 bytes.") else state.editor.title = title; state.status = _("Title kept locally.") end
            requestRebuild(context)
        end } } },
    }
    showInput(dialog)
end

local function promptEditorBody(state, context)
    local dialog
    dialog = InputDialog:new{
        title = _("Write in ink"), input = state.editor.body or "", input_hint = _("Markdown: headings, emphasis, lists, quotes, code, links, and inkblog images"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Keep text"), is_enter_default = true, callback = function()
            local body = dialog:getInputText()
            UIManager:close(dialog)
            if #body > MAX_POST_BYTES then state.status = _("Posts are limited to 96 KiB.") else state.editor.body = body; state.status = _("All entered Markdown was kept locally.") end
            requestRebuild(context)
        end } } },
    }
    showInput(dialog)
end

local function insertFormat(state, context, kind)
    local snippets = {
        heading = "\n# Heading\n", bold = "**bold**", italic = "*italic*", list = "\n- list item\n",
        quote = "\n> quotation\n", code = "\n```\ncode\n```\n", link = "[link text](https://)",
    }
    local snippet = snippets[kind]
    if not snippet then return end
    local current = tostring(state.editor.body or "")
    if #current + #snippet > MAX_POST_BYTES then state.status = _("This would exceed the post limit.") else state.editor.body = current .. snippet; state.status = _("Markdown mark inserted; edit its placeholder text.") end
    requestRebuild(context)
end

local function base64Encode(data)
    local alphabet, output = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", {}
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

local function imageMimeForPath(path)
    path = tostring(path or ""):lower()
    if path:match("%.png$") then return "image/png" end
    if path:match("%.jpe?g$") then return "image/jpeg" end
end

local function readUploadImage(path)
    path = trim(path)
    local mime = imageMimeForPath(path)
    if not mime then return nil, nil, _("Choose a PNG or JPEG image.") end
    if lfs and type(lfs.attributes) == "function" then
        local ok, attr = pcall(lfs.attributes, path)
        if not ok or not attr or attr.mode ~= "file" then return nil, nil, _("That image path is not a readable regular file.") end
        if tonumber(attr.size) and tonumber(attr.size) > MAX_IMAGE_BYTES then return nil, nil, _("Images are limited to 700 KiB.") end
    end
    local file = io.open(path, "rb")
    if not file then return nil, nil, _("The image could not be opened.") end
    local data = file:read(MAX_IMAGE_BYTES + 1)
    file:close()
    if not data or #data == 0 or #data > MAX_IMAGE_BYTES then return nil, nil, _("Images are limited to 700 KiB.") end
    local valid = mime == "image/png" and data:sub(1, 8) == "\137PNG\r\n\26\n" or mime == "image/jpeg" and data:sub(1, 2) == "\255\216"
    if not valid then return nil, nil, _("The file extension does not match a PNG or JPEG image.") end
    return data, mime
end

local function uploadImageNow(state, path, kind, post_id, alt)
    local data, mime, read_err = readUploadImage(path)
    if not data then return nil, read_err end
    local payload = { kind = kind, post_id = post_id, alt_text = trim(alt):sub(1, 160), mime = mime, image_base64 = base64Encode(data), dither = true }
    local result, code, err = apiRequest(state, "POST", "/functions/v1/inkblog-media", payload)
    if type(result) ~= "table" or not validManagedPath(result.path) then return nil, err or _("The media service returned an unsafe image path.") end
    return result
end

local function promptPostImage(state, context)
    if not state.editor or not validUuid(state.editor.remote_id) then
        state.status = _("Save the draft to InkBlog first; then add its image.")
        requestRebuild(context)
        return
    end
    local path_dialog
    path_dialog = InputDialog:new{
        title = _("Add ink image"), input = state.pending_image_path or "", input_hint = _("PNG/JPEG full path or use file handover"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(path_dialog) end }, { text = _("Next"), is_enter_default = true, callback = function()
            local path = trim(path_dialog:getInputText())
            UIManager:close(path_dialog)
            local alt_dialog
            alt_dialog = InputDialog:new{
                title = _("Image description"), input = "", input_hint = _("Brief alt text"),
                buttons = { { { text = _("Cancel"), callback = function() UIManager:close(alt_dialog) end }, { text = _("Upload"), is_enter_default = true, callback = function()
                    local alt = alt_dialog:getInputText()
                    UIManager:close(alt_dialog)
                    runNetwork(state, context, _("Uploading ink image…"), function()
                        local result, err = uploadImageNow(state, path, "post", state.editor.remote_id, alt)
                        if not result then state.status = err or _("Image upload failed; the text draft is preserved."); return end
                        local marker = "\n\n![" .. trim(alt):sub(1, 160) .. "](inkblog:" .. result.path .. ")\n"
                        state.editor.body = tostring(state.editor.body or "") .. marker
                        state.editor.images[#state.editor.images + 1] = { path = result.path, alt = trim(alt):sub(1, 160) }
                        state.pending_image_path, state.status = nil, _("Image uploaded in grayscale and marked in the draft.")
                    end, true)
                end } } },
            }
            showInput(alt_dialog)
        end } } },
    }
    showInput(path_dialog)
end

local function promptAvatarUpload(state, context)
    local old_avatar = state.profile and state.profile.avatar_path
    local dialog
    dialog = InputDialog:new{
        title = _("Avatar image"), input = state.pending_image_path or "", input_hint = _("PNG/JPEG full path or use file handover"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Upload"), is_enter_default = true, callback = function()
            local path = trim(dialog:getInputText())
            UIManager:close(dialog)
            runNetwork(state, context, _("Uploading avatar…"), function()
                local result, err = uploadImageNow(state, path, "avatar", nil, "Avatar")
                if not result then state.status = err or _("Avatar upload failed."); return end
                -- The media Edge Function writes profiles.avatar_path itself. Refresh it,
                -- rather than issuing a competing direct PATCH from the client.
                local refreshed, refresh_code, refresh_err = restRequest(state, "GET", "profiles", "id=eq." .. urlEncode(state.session.user.id) .. "&select=id,display_name,bio,avatar_path")
                state.profile = type(refreshed) == "table" and refreshed[1] or state.profile or { id = state.session.user.id }
                state.profile.avatar_path = state.profile.avatar_path or result.path
                state.pending_image_path = nil
                if validManagedPath(old_avatar) and old_avatar ~= state.profile.avatar_path then
                    -- Server verifies the current profile path before clearing it.
                    rawRequest("/functions/v1/inkblog-media?bucket=inkblog-avatars&path=" .. urlEncode(old_avatar), "DELETE", nil, authHeaders(state.session))
                end
                state.status = _("Avatar uploaded. Tap Avatar laden to cache it locally.")
            end, true)
        end } } },
    }
    showInput(dialog)
end

local function syncEditor(state, context, publish)
    local record, local_err = captureLocalDraft(state)
    if not record then state.status = local_err; requestRebuild(context); return end
    local title = trim(state.editor.title or "")
    if title == "" then state.status = _("Give the post a title before syncing."); requestRebuild(context); return end
    runNetwork(state, context, publish and _("Publishing ink…") or _("Saving draft…"), function()
        local fields = { title = state.editor.title, markdown = state.editor.body, status = publish and "published" or "draft", updated_at = utcNow() }
        if publish then fields.published_at = utcNow() end
        local result, code, err
        if validUuid(state.editor.remote_id) then
            result, code, err = restRequest(state, "PATCH", "posts", "id=eq." .. urlEncode(state.editor.remote_id), fields, { ["prefer"] = "return=representation" })
        else
            fields.author_id = state.session.user.id
            result, code, err = restRequest(state, "POST", "posts", nil, fields, { ["prefer"] = "return=representation" })
        end
        if type(result) ~= "table" or not result[1] then
            state.status = err or _("Sync failed. The complete draft remains local for retry.")
            return
        end
        state.editor.remote_id, record.remote_id = result[1].id, result[1].id
        if publish then
            removeLocalDraft(state, record.local_id)
            state.selected_post, state.view, state.status = result[1], "article", _("Published. Read in peace.")
        else
            captureLocalDraft(state)
            state.status = _("Draft saved locally and to InkBlog.")
        end
    end, true)
end

local function deletePost(state, context, post)
    if type(post) ~= "table" or not validUuid(post.id) then return end
    runNetwork(state, context, _("Deleting post…"), function()
        -- Read managed paths while the post_images rows still exist. Cleanup is
        -- deliberately best effort: a successful post deletion stays successful.
        local image_rows = restRequest(state, "GET", "post_images", "post_id=eq." .. urlEncode(post.id) .. "&select=path,author_id")
        local result, code, err = restRequest(state, "DELETE", "posts", "id=eq." .. urlEncode(post.id))
        if code and code >= 200 and code < 300 then
            for _, image in ipairs(type(image_rows) == "table" and image_rows or {}) do
                if validManagedPath(image.path) then
                    rawRequest("/functions/v1/inkblog-media?bucket=inkblog-images&path=" .. urlEncode(image.path), "DELETE", nil, authHeaders(state.session))
                end
            end
            state.view, state.selected_post, state.status = "profile", nil, _("Post deleted.")
            for index = #state.posts, 1, -1 do if state.posts[index].id == post.id then table.remove(state.posts, index) end end
        else state.status = err or _("Post could not be deleted.") end
    end, true)
end

local function confirmDeletePost(state, context, post)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this post permanently? Its margin notes may also disappear. This cannot be undone."),
        ok_text = _("Delete post"), ok_callback = function() deletePost(state, context, post) end,
    })
end

local function toggleLike(state, context, item, target_type)
    if not item or not validUuid(item.id) then return end
    runNetwork(state, context, item.liked and _("Removing Klecks…") or _("Adding Klecks…"), function()
        local result, code, err
        if item.liked then
            result, code, err = restRequest(state, "DELETE", "likes", "user_id=eq." .. urlEncode(state.session.user.id) .. "&target_type=eq." .. target_type .. "&target_id=eq." .. urlEncode(item.id))
        else
            result, code, err = restRequest(state, "POST", "likes", nil, { user_id = state.session.user.id, target_type = target_type, target_id = item.id })
        end
        if code and code >= 200 and code < 300 then
            item.liked = not item.liked
            item.like_count = math.max(0, (tonumber(item.like_count) or 0) + (item.liked and 1 or -1))
            state.status = item.liked and _("Klecks added.") or _("Klecks removed.")
        else state.status = err or _("Klecks could not be changed.") end
    end, true)
end

local function promptComment(state, context, parent)
    local post = state.selected_post
    if not post or not validUuid(post.id) then return end
    local dialog
    dialog = InputDialog:new{
        title = parent and _("Reply in the margin") or _("Add a margin note"), input = "", input_hint = _("A thoughtful note"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Send"), is_enter_default = true, callback = function()
            local body = dialog:getInputText()
            UIManager:close(dialog)
            if trim(body) == "" or #body > 6000 then state.status = _("Use a margin note up to 6,000 bytes."); requestRebuild(context); return end
            runNetwork(state, context, _("Writing margin note…"), function()
                local payload = { post_id = post.id, author_id = state.session.user.id, body = body }
                if parent and validUuid(parent.id) and not parent.parent_id then payload.parent_id = parent.id end
                local result, code, err = restRequest(state, "POST", "comments", nil, payload, { ["prefer"] = "return=representation" })
                if type(result) == "table" and result[1] then
                    state.comments[#state.comments + 1] = result[1]
                    state.status = _("Margin note added.")
                else state.status = err or _("Margin note could not be added.") end
            end, true)
        end } } },
    }
    showInput(dialog)
end

local function deleteComment(state, context, comment)
    if not comment or not validUuid(comment.id) then return end
    runNetwork(state, context, _("Deleting margin note…"), function()
        local result, code, err = restRequest(state, "DELETE", "comments", "id=eq." .. urlEncode(comment.id))
        if code and code >= 200 and code < 300 then
            state.status = _("Margin note deleted.")
            for index = #state.comments, 1, -1 do if state.comments[index].id == comment.id then table.remove(state.comments, index) end end
        else state.status = err or _("Margin note could not be deleted.") end
    end, true)
end

local function confirmDeleteComment(state, context, comment)
    UIManager:show(ConfirmBox:new{ text = _("Delete this margin note permanently?"), ok_text = _("Delete note"), ok_callback = function() deleteComment(state, context, comment) end })
end

local function promptReport(state, context, item, target_type)
    if not item or not validUuid(item.id) then return end
    local dialog
    dialog = InputDialog:new{
        title = _("Report"), input = "", input_hint = _("Reason for moderation"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Report"), is_enter_default = true, callback = function()
            local reason = trim(dialog:getInputText())
            UIManager:close(dialog)
            if reason == "" or #reason > 500 then state.status = _("Give a report reason up to 500 bytes."); requestRebuild(context); return end
            runNetwork(state, context, _("Sending report…"), function()
                local result, code, err = restRequest(state, "POST", "reports", nil, { reporter_id = state.session.user.id, target_type = target_type, target_id = item.id, reason = reason })
                state.status = code and code >= 200 and code < 300 and _("Report sent to moderation.") or (err or _("Report could not be sent."))
            end, true)
        end } } },
    }
    showInput(dialog)
end

local function promptCommentActions(state, context, comment)
    if not comment then return end
    local may_delete = (state.selected_post and state.selected_post.author_id == state.session.user.id) or comment.author_id == state.session.user.id
    local dialog
    dialog = InputDialog:new{
        title = _("Margin note"), input = tostring(comment.body or ""), input_hint = _("Read-only note"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = comment.liked and _("Klecks entfernen") or _("Klecks"), callback = function() UIManager:close(dialog); toggleLike(state, context, comment, "comment") end },
            { text = _("Antwort"), callback = function() UIManager:close(dialog); if not comment.parent_id then promptComment(state, context, comment) else state.status = _("Replies may be one level deep."); requestRebuild(context) end end },
            { text = may_delete and _("Löschen") or _("Melden"), is_enter_default = true, callback = function()
                UIManager:close(dialog)
                if may_delete then confirmDeleteComment(state, context, comment) else promptReport(state, context, comment, "comment") end
            end } } },
    }
    showInput(dialog)
end

local function toggleFollow(state, context)
    local profile = state.author_profile
    if not profile or not validUuid(profile.id) then return end
    runNetwork(state, context, profile.followed and _("Unfollowing…") or _("Following…"), function()
        local result, code, err
        if profile.followed then
            result, code, err = restRequest(state, "DELETE", "follows", "follower_id=eq." .. urlEncode(state.session.user.id) .. "&following_id=eq." .. urlEncode(profile.id))
        else
            result, code, err = restRequest(state, "POST", "follows", nil, { follower_id = state.session.user.id, following_id = profile.id })
        end
        if code and code >= 200 and code < 300 then profile.followed = not profile.followed; state.status = profile.followed and _("Following this blog.") or _("No longer following this blog.") else state.status = err or _("Follow state could not be changed.") end
    end, true)
end

local function toggleBlock(state, context)
    local profile = state.author_profile
    if not profile or not validUuid(profile.id) then return end
    runNetwork(state, context, profile.blocked and _("Unblocking author…") or _("Blocking author…"), function()
        local result, code, err
        if profile.blocked then
            result, code, err = restRequest(state, "DELETE", "blocks", "blocker_id=eq." .. urlEncode(state.session.user.id) .. "&blocked_id=eq." .. urlEncode(profile.id))
        else
            result, code, err = restRequest(state, "POST", "blocks", nil, { blocker_id = state.session.user.id, blocked_id = profile.id })
        end
        if code and code >= 200 and code < 300 then profile.blocked = not profile.blocked; state.status = profile.blocked and _("Author blocked.") or _("Author unblocked.") else state.status = err or _("Block state could not be changed.") end
    end, true)
end

local function loadNotifications(state, context)
    state.view = "notifications"
    runNetwork(state, context, _("Loading notifications…"), function()
        local query = "recipient_id=eq." .. urlEncode(state.session.user.id) .. "&select=id,actor_id,kind,target_type,target_id,read_at,created_at&order=created_at.desc&limit=60"
        local result, code, err = restRequest(state, "GET", "notifications", query)
        if type(result) == "table" then state.notifications, state.list_page, state.status = result, 0, (#result == 0 and _("No notifications.") or _("Notifications loaded.")) else state.status = err or _("Notifications could not be loaded.") end
    end, true)
    requestRebuild(context)
end

local function openNotification(state, context, note)
    if not note then return end
    if not note.read_at and validUuid(note.id) then
        runNetwork(state, context, _("Marking notification read…"), function()
            local result, code, err = restRequest(state, "PATCH", "notifications", "id=eq." .. urlEncode(note.id), { read_at = utcNow() })
            if code and code >= 200 and code < 300 then note.read_at = utcNow() end
            if note.target_type == "post" and validUuid(note.target_id) then
                local post, post_code, post_err = restRequest(state, "GET", "posts", "id=eq." .. urlEncode(note.target_id) .. "&select=id,author_id,title,markdown,status,created_at,updated_at,published_at")
                if type(post) == "table" and post[1] then
                    state.selected_post, state.article_page, state.article_tab, state.view, state.status = post[1], 1, "read", "article", _("Post opened.")
                else state.status = post_err or _("That post is no longer available.") end
            else state.status = _("This notification has no openable post.") end
        end, true)
    elseif note.target_type == "post" then
        getPostAndOpen(state, context, note.target_id)
    end
end

local function cacheImageNow(state, managed_path, kind)
    if not validManagedPath(managed_path) then return nil, _("Unsafe image path was rejected.") end
    if state.image_cache[managed_path] then return true end
    if not ensureDir(IMAGE_DIR) then return nil, _("Image cache is unavailable.") end
    local bucket = kind == "avatar" and "inkblog-avatars" or "inkblog-images"
    -- The deployment’s media endpoint enforces RLS and returns an optimized PNG.
    -- It accepts an anon apikey for public reads and a user JWT for private reads.
    local suffix = "/functions/v1/inkblog-media?bucket=" .. bucket .. "&path=" .. urlEncode(managed_path)
    local body, code, err = rawRequest(suffix, "GET", nil, authHeaders(state.session), true)
    if type(body) ~= "string" or #body < 8 then return nil, err or _("Image could not be downloaded.") end
    if body:sub(1, 8) ~= "\137PNG\r\n\26\n" and body:sub(1, 2) ~= "\255\216" then return nil, _("The media endpoint returned an invalid image.") end
    local extension = body:sub(1, 8) == "\137PNG\r\n\26\n" and "png" or "jpg"
    local local_path = IMAGE_DIR .. "/inkblog_" .. randomHex(12) .. "." .. extension
    local file = io.open(local_path, "wb")
    if not file then return nil, _("Cached image could not be opened.") end
    local wrote = file:write(body); file:close()
    if not wrote then pcall(os.remove, local_path); return nil, _("Cached image could not be written.") end
    state.image_cache[managed_path] = { file = local_path, kind = kind }
    state.image_order[#state.image_order + 1] = managed_path
    while #state.image_order > MAX_CACHED_IMAGES do
        local oldest = table.remove(state.image_order, 1)
        local stale = state.image_cache[oldest]
        if stale and stale.file then pcall(os.remove, stale.file) end
        state.image_cache[oldest] = nil
    end
    return true
end

local function downloadArticleImages(state, context)
    local post = state.selected_post
    if not post then return end
    local images = markdownImagePaths(post.markdown or "")
    if #images == 0 then state.status = _("This post has no managed images."); requestRebuild(context); return end
    runNetwork(state, context, _("Loading grayscale images…"), function()
        local loaded, last_err = 0, nil
        for index, image in ipairs(images) do
            if index <= MAX_CACHED_IMAGES then
                local ok, err = cacheImageNow(state, image.path, "post")
                if ok then loaded = loaded + 1 else last_err = err end
            end
        end
        state.status = loaded > 0 and string.format(_("%d image(s) cached in grayscale."), loaded) or (last_err or _("No images could be cached."))
    end)
end

local function downloadAvatar(state, context, profile)
    if not profile or not validManagedPath(profile.avatar_path) then state.status = _("No managed avatar is available."); requestRebuild(context); return end
    runNetwork(state, context, _("Loading avatar…"), function()
        local ok, err = cacheImageNow(state, profile.avatar_path, "avatar")
        state.status = ok and _("Avatar cached in grayscale.") or (err or _("Avatar could not be cached."))
    end)
end

local function ownPost(state, post)
    return post and state.session.user and post.author_id == state.session.user.id
end

local function postPreview(post, width_chars)
    local source = plainInlineText(post and post.markdown or "")
    local head, tail = utf8Cut(source, width_chars or 130)
    return tail ~= "" and head .. " …" or head
end

local function blockHtml(block)
    local text = block.kind == "code" and escapeHtml(block.text or "") or inlineHtml(block.text or "")
    if block.kind == "heading" then return "<h" .. tostring(block.level or 1) .. ">" .. text .. "</h" .. tostring(block.level or 1) .. ">" end
    if block.kind == "quote" then return "<blockquote>" .. text .. "</blockquote>" end
    if block.kind == "code" then return "<pre>" .. text .. "</pre>" end
    if block.kind == "list" then return "<p>" .. text .. "</p>" end
    return "<p>" .. text .. "</p>"
end

local function nativeHtmlPage(blocks, width, height, px, context)
    if not ok_html or type(HtmlBoxWidget) ~= "table" then return nil end
    local html = { "<article>" }
    for _, block in ipairs(blocks or {}) do html[#html + 1] = blockHtml(block) end
    html[#html + 1] = "</article>"
    local created, widget = pcall(function()
        return HtmlBoxWidget:new{ html_body = table.concat(html), css = "body { background: #FFFFFF; color: #000000; font-family: serif; line-height: 1.35; } h1,h2,h3 { color: #000000; } blockquote { border-left: 3px solid #666666; padding-left: .6em; color: #333333; } pre { background: #CCCCCC; color: #000000; white-space: pre-wrap; }", width = width, height = height, default_font_size = math.max(16, px(18)), dialog = context and context.host }
    end)
    return created and widget or nil
end

-- Inline 64×64 1-bit feather/drop mark supplied by InkBlog assets (1 = black).
local LOGO_ROWS = {
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0000000000000000000000000000000110000000000000000000000000000000",
    "0000000000000000000000000000000110000000000000000000000000000000",
    "0000000000000000000000000000001111000000000000000000000000000000",
    "0000000000000000000000000000011111100000000000000000000000000000",
    "0000000000000000000000000000011111100000000000000000000000000000",
    "0000000000000000000000000000111111110000000000000000000000000000",
    "0000000000000000000000000001111111111000000000000000000000000000",
    "0000000000000000000000000011111111111100000000000000000000000000",
    "0000000000000000000000000111111111111110000000000000000000000000",
    "0000000000000000000000000111111111111110000000000000000000000000",
    "0000000000000000000000001111111111111111000000000000000000000000",
    "0000000000000000000000011111111111111111100000000000000000000000",
    "0000000000000000000000111111111111111111110000000000000000000000",
    "0000000000000000000001111111111111111111111000000000000000000000",
    "0000000000000000000001111111111111111111111000000000000000000000",
    "0000000000000000000011111111111111111111111100000000000000000000",
    "0000000000000000000111111111111111111111111110000000000000000000",
    "0000000000000000001111111111111111111111111111000000000000000000",
    "0000000000000000001111111111111001111111111111000000000000000000",
    "0000000000000000011111111111111001111111111111100000000000000000",
    "0000000000000000111111111111110000111111111111110000000000000000",
    "0000000000000000111111111111110000111111111111110000000000000000",
    "0000000000000001111111111111100000011111111111111000000000000000",
    "0000000000000011111111111111100000011111111111111100000000000000",
    "0000000000000011111111111111000000001111111111111100000000000000",
    "0000000000000111111111111111000000001111111111111110000000000000",
    "0000000000000111111111111110000110000111111111111110000000000000",
    "0000000000001111111111111100001111000011111111111111000000000000",
    "0000000000001111111111111100001111000011111111111111000000000000",
    "0000000000011111111111111000001111000001111111111111100000000000",
    "0000000000011111111111111000000110000001111111111111100000000000",
    "0000000000011111111111110000000110000000111111111111100000000000",
    "0000000000111111111111110000000110000000111111111111110000000000",
    "0000000000111111111111100000000110000000011111111111110000000000",
    "0000000000111111111111100000000110000000011111111111110000000000",
    "0000000000111111111111000000000110000000001111111111110000000000",
    "0000000000111111111111000000000110000000001111111111110000000000",
    "0000000000111111111111100000000110000000011111111111110000000000",
    "0000000000111111111111110000000110000000111111111111110000000000",
    "0000000000111111111111110000000110000000111111111111110000000000",
    "0000000000111111111111111000000110000001111111111111110000000000",
    "0000000000011111111111111100000110000011111111111111100000000000",
    "0000000000011111111111111100000110000011111111111111100000000000",
    "0000000000011111111111111110000110000111111111111111100000000000",
    "0000000000001111111111111111000110001111111111111111000000000000",
    "0000000000001111111111111111000110001111111111111111000000000000",
    "0000000000000111111111111111100110011111111111111110000000000000",
    "0000000000000111111111111111111111111111111111111110000000000000",
    "0000000000000011111111111111111111111111111111111100000000000000",
    "0000000000000001111111111111111111111111111111111000000000000000",
    "0000000000000001111111111111111111111111111111111000000000000000",
    "0000000000000000111111111111111111111111111111110000000000000000",
    "0000000000000000011111111111111111111111111111100000000000000000",
    "0000000000000000000111111111111111111111111110000000000000000000",
    "0000000000000000000011111111111111111111111100000000000000000000",
    "0000000000000000000000111111111111111111110000000000000000000000",
    "0000000000000000000000001111111111111111000000000000000000000000",
    "0000000000000000000000000001111111111000000000000000000000000000",
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0000000000000000000000000000000000000000000000000000000000000000",
}

local InkLogo = WidgetContainer:extend{ width = nil, height = nil, dimen = nil }
function InkLogo:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function InkLogo:paintTo(bb, x, y)
    if not bb or type(bb.paintRect) ~= "function" then return end
    local unit = math.max(1, math.floor(math.min(self.width, self.height) / 64))
    local draw_w, draw_h = unit * 64, unit * 64
    local start_x, start_y = x + math.floor((self.width - draw_w) / 2), y + math.floor((self.height - draw_h) / 2)
    -- Draw horizontal runs rather than individual pixels to keep E-Ink painting quiet.
    for row_index, row in ipairs(LOGO_ROWS) do
        local column = 1
        while column <= 64 do
            local first = row:find("1", column, true)
            if not first then break end
            local last = first
            while last < 64 and row:sub(last + 1, last + 1) == "1" do last = last + 1 end
            bb:paintRect(start_x + (first - 1) * unit, start_y + (row_index - 1) * unit, (last - first + 1) * unit, unit, BLACK)
            column = last + 1
        end
    end
end

local function buildBase(width, height)
    local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
    local layer = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false }
    layer[#layer + 1] = FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = WHITE, CenterContainer:new{ dimen = pane.dimen, HorizontalSpan:new{ width = 0 } } }
    pane[1] = layer
    return pane, layer
end

local function addHeader(layer, state, width, px, label)
    local margin, logo_size = px(12), px(31)
    local logo = InkLogo:new{ width = logo_size, height = logo_size }
    logo.overlap_offset = { margin, px(8) }
    layer[#layer + 1] = logo
    addText(layer, label or _("InkBlog"), margin + logo_size + px(7), px(10), width - margin * 2 - logo_size - px(7), px(20), { serif = true, bold = true })
    addText(layer, _("Write in ink. Read in peace."), margin + logo_size + px(7), px(33), width - margin * 2 - logo_size - px(7), px(10), { color = GRAY_666 })
end

local function addStatus(layer, state, width, y, px)
    local prefix = state.loading and _("Working · ") or ""
    addText(layer, prefix .. tostring(state.status or ""), px(12), y, width - px(24), px(10), { color = GRAY_666 })
end

local function navTo(state, context, view)
    if state.loading then return end
    state.view = view
    state.settings.last_mode = view
    saveSettings(state.settings)
    if view == "feed" then listPosts(state, context, "feed", nil)
    elseif view == "discover" then listPosts(state, context, "discover", nil)
    elseif view == "write" then beginNewPost(state, context)
    elseif view == "profile" then loadOwnProfile(state, context)
    elseif view == "notifications" then loadNotifications(state, context)
    end
end

local function addNavigation(layer, state, context, width, height, px)
    local margin, gap, nav_height = px(8), px(3), px(44)
    local labels = { { "feed", _("Feed") }, { "discover", _("Entdecken") }, { "write", _("Schreiben") }, { "profile", _("Profil") }, { "notifications", _("Hinweise") } }
    local button_width = math.max(px(43), math.floor((width - margin * 2 - gap * 4) / 5))
    for index, entry in ipairs(labels) do
        addButton(layer, entry[2], margin + (index - 1) * (button_width + gap), height - nav_height - px(6), button_width, nav_height, function() navTo(state, context, entry[1]) end, state.view == entry[1])
    end
end

local function addPagination(layer, state, context, page, total, width, y, px, setter, can_previous)
    local margin, gap, button_width = px(12), px(7), math.floor((width - 2 * px(12) - px(7)) / 2)
    addButton(layer, _("‹ Vorherige"), margin, y, button_width, px(44), function() setter(page - 1); requestRebuild(context) end, false, nil, page <= 1 and not can_previous)
    addButton(layer, _("Nächste ›"), margin + button_width + gap, y, button_width, px(44), function() setter(math.min(total, page + 1)); requestRebuild(context) end, false, nil, page >= total)
end

local function renderPostList(layer, state, context, width, top, bottom, px, title)
    local margin, gap = px(12), px(7)
    addText(layer, title, margin, top, width - 2 * margin, px(16), { serif = true, bold = true })
    local toolbar_y, toolbar_h = top + px(25), px(44)
    local half = math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, state.settings.sort == "popular" and _("Beliebt · ✓") or _("Beliebt"), margin, toolbar_y, half, toolbar_h, function() state.settings.sort = state.settings.sort == "popular" and "newest" or "popular"; saveSettings(state.settings); listPosts(state, context, state.mode, state.mode == "blog" and state.selected_author_id or nil) end, state.settings.sort == "popular")
    addButton(layer, _("Laden"), margin + half + gap, toolbar_y, half, toolbar_h, function() listPosts(state, context, state.mode, state.mode == "blog" and state.selected_author_id or nil) end, true)
    local available = bottom - (toolbar_y + toolbar_h) - px(52)
    local card_height = math.max(px(66), math.min(px(106), math.floor(available / 3)))
    local per_page = math.max(1, math.floor(available / (card_height + gap)))
    local local_total = math.max(1, math.ceil(#state.posts / per_page))
    local total = local_total + (state.posts_has_more and 1 or 0)
    local page = clamp((state.list_page or 0) + 1, 1, total)
    state.list_page = page - 1
    local first = (page - 1) * per_page + 1
    local y = toolbar_y + toolbar_h + gap
    if #state.posts == 0 then
        addBox(layer, _("No cached posts. Tap Laden; network is only used after that explicit action."), margin, y + px(10), width - 2 * margin, math.max(px(62), available - px(20)), px(14), { serif = true, color = GRAY_333 })
    else
        for index = first, math.min(#state.posts, first + per_page - 1) do
            local post = state.posts[index]
            local author = post.display_name or _("Unknown author")
            local meta = author .. " · " .. tostring(post.like_count or 0) .. " Klecks · " .. tostring(post.comment_count or 0) .. " Randnotizen"
            local card = ActionButton:new{ title = "", body = tostring(post.title or _("Untitled")) .. "\n" .. meta .. "\n" .. postPreview(post, math.max(48, math.floor(width / px(5)))), width = width - 2 * margin, height = card_height, callback = function() openPost(state, context, post) end }
            card.overlap_offset = { margin, y }
            layer[#layer + 1] = card
            y = y + card_height + gap
        end
    end
    addPagination(layer, state, context, page, total, width, bottom - px(44), px, function(value)
        if value > local_total then changePostBatch(state, context, (state.list_offset or 0) + PAGE_SIZE)
        elseif value < 1 and (state.list_offset or 0) > 0 then changePostBatch(state, context, state.list_offset - PAGE_SIZE)
        else state.list_page = clamp(value - 1, 0, local_total - 1) end
    end, (state.list_offset or 0) > 0)
end

local function renderFallbackBlocks(layer, blocks, x, y, width, height, px)
    local cursor = y
    for _, block in ipairs(blocks or {}) do
        local size = blockFontSize(block, px)
        local factor = block.kind == "heading" and .58 or (block.kind == "code" and .60 or .52)
        local chars_per_line = math.max(4, math.floor(width / math.max(1, size * factor)))
        local lines = physicalLineCount(block.text or "", chars_per_line)
        local h = math.max(px(20), lines * math.max(px(17), math.floor(size * 1.35)) + px(5))
        if cursor + h > y + height then break end
        local options = { serif = block.kind ~= "code", color = block.kind == "quote" and GRAY_333 or BLACK, bg = block.kind == "code" and GRAY_CCC or WHITE, line_height = .30 }
        addBox(layer, plainInlineText(block.text), x + (block.kind == "quote" and px(9) or 0), cursor, width - (block.kind == "quote" and px(9) or 0), h, size, options)
        cursor = cursor + h + px(4)
    end
end

local function renderArticle(layer, state, context, width, top, bottom, px)
    local post = state.selected_post
    local margin, gap = px(12), px(6)
    if not post then state.view = "feed"; return end
    local title_height = px(52)
    addText(layer, tostring(post.title or _("Untitled")), margin, top, width - 2 * margin, px(22), { serif = true, bold = true })
    local author = post.display_name or _("Author")
    addText(layer, author .. " · " .. tostring(post.published_at or post.created_at or ""), margin, top + px(29), width - 2 * margin, px(10), { color = GRAY_666 })
    local actions_y, action_h = top + title_height, px(44)
    local w4 = math.floor((width - 2 * margin - 3 * gap) / 4)
    addButton(layer, _("‹ Liste"), margin, actions_y, w4, action_h, function() state.view = state.mode == "blog" and "author" or "feed"; requestRebuild(context) end)
    addButton(layer, post.liked and _("Klecks ✓") or _("Klecks"), margin + (w4 + gap), actions_y, w4, action_h, function() toggleLike(state, context, post, "post") end, post.liked)
    addButton(layer, _("Randnotiz"), margin + 2 * (w4 + gap), actions_y, w4, action_h, function() state.article_tab = "comments"; loadComments(state, context, post.id) end)
    addButton(layer, ownPost(state, post) and _("Löschen") or _("Autor"), margin + 3 * (w4 + gap), actions_y, w4, action_h, function()
        if ownPost(state, post) then confirmDeletePost(state, context, post) else loadAuthor(state, context, post.author_id) end
    end)
    local row2_y = actions_y + action_h + gap
    local half = math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, state.article_tab == "comments" and _("Lesen") or _("Bilder laden"), margin, row2_y, half, action_h, function()
        if state.article_tab == "comments" then state.article_tab = "read"; requestRebuild(context) else downloadArticleImages(state, context) end
    end)
    addButton(layer, ownPost(state, post) and _("Bearbeiten") or _("Melden"), margin + half + gap, row2_y, half, action_h, function()
        if ownPost(state, post) then editPost(state, context, post) else promptReport(state, context, post, "post") end
    end, ownPost(state, post))
    local content_y, content_h = row2_y + action_h + px(7), bottom - (row2_y + action_h + px(58))
    if state.article_tab == "comments" then
        local comments = state.comments or {}
        local card_h = math.max(px(52), math.floor(content_h / 3))
        local per_page = math.max(1, math.floor(content_h / (card_h + gap)))
        local local_total = math.max(1, math.ceil(#comments / per_page))
        local total = local_total + (state.comments_has_more and 1 or 0)
        local page = clamp((state.comment_page or 0) + 1, 1, total)
        local y = content_y
        if #comments == 0 then addBox(layer, _("No margin notes cached. Tap Randnotiz again to load them."), margin, y, width - 2 * margin, card_h, px(14), { serif = true }) end
        for index = (page - 1) * per_page + 1, math.min(#comments, page * per_page) do
            local comment = comments[index]
            local inset = comment.parent_id and px(16) or 0
            local copy = ActionButton:new{ title = "", body = (comment.display_name or _("Reader")) .. " · " .. tostring(comment.like_count or 0) .. " Klecks\n" .. postPreview({ markdown = comment.body }, math.max(36, math.floor(width / px(6)))), width = width - 2 * margin - inset, height = card_h, callback = function() promptCommentActions(state, context, comment) end }
            copy.overlap_offset = { margin + inset, y }; layer[#layer + 1] = copy
            y = y + card_h + gap
        end
        addPagination(layer, state, context, page, total, width, bottom - px(44), px, function(value)
            if value > local_total then changeCommentBatch(state, context, (state.comment_offset or 0) + COMMENT_SIZE)
            elseif value < 1 and (state.comment_offset or 0) > 0 then changeCommentBatch(state, context, state.comment_offset - COMMENT_SIZE)
            else state.comment_page = clamp(value - 1, 0, local_total - 1) end
        end, (state.comment_offset or 0) > 0)
    else
        local blocks = markdownBlocks(post.markdown or "")
        local pages = paginateBlocks(blocks, width - 2 * margin, content_h, px)
        state.article_page = clamp(state.article_page or 1, 1, #pages)
        local page_blocks = pages[state.article_page]
        local native = nativeHtmlPage(page_blocks, width - 2 * margin, content_h, px, context)
        if native then native.overlap_offset = { margin, content_y }; layer[#layer + 1] = native else renderFallbackBlocks(layer, page_blocks, margin, content_y, width - 2 * margin, content_h, px) end
        addPagination(layer, state, context, state.article_page, #pages, width, bottom - px(44), px, function(value) state.article_page = value end)
    end
end

local function promptProfileEdit(state, context)
    local profile = state.profile or { display_name = "", bio = "" }
    local name_dialog
    name_dialog = InputDialog:new{
        title = _("Profile name"), input = profile.display_name or "", input_hint = _("Display name"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(name_dialog) end }, { text = _("Next"), is_enter_default = true, callback = function()
            local display_name = trim(name_dialog:getInputText())
            UIManager:close(name_dialog)
            if display_name == "" or #display_name > 80 then state.status = _("Use a display name up to 80 bytes."); requestRebuild(context); return end
            local bio_dialog
            bio_dialog = InputDialog:new{
                title = _("Profile bio"), input = profile.bio or "", input_hint = _("A few words"),
                buttons = { { { text = _("Cancel"), callback = function() UIManager:close(bio_dialog) end }, { text = _("Save"), is_enter_default = true, callback = function()
                    local bio = bio_dialog:getInputText()
                    UIManager:close(bio_dialog)
                    if #bio > 1000 then state.status = _("Bios are limited to 1,000 bytes."); requestRebuild(context); return end
                    runNetwork(state, context, _("Saving profile…"), function()
                        local result, code, err = restRequest(state, "PATCH", "profiles", "id=eq." .. urlEncode(state.session.user.id), { display_name = display_name, bio = bio }, { ["prefer"] = "return=representation" })
                        if type(result) == "table" and result[1] then state.profile, state.status = result[1], _("Profile saved.") else state.status = err or _("Profile could not be saved.") end
                    end, true)
                end } } },
            }
            showInput(bio_dialog)
        end } } },
    }
    showInput(name_dialog)
end

local function renderWrite(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(6)
    addText(layer, _("Neue Tinte aufnehmen"), margin, top, width - 2 * margin, px(18), { serif = true, bold = true })
    local actions_y, actions_h = top + px(25), px(44)
    local w4 = math.floor((width - 2 * margin - 3 * gap) / 4)
    addButton(layer, _("Titel"), margin, actions_y, w4, actions_h, function() promptEditorTitle(state, context) end)
    addButton(layer, _("Text"), margin + (w4 + gap), actions_y, w4, actions_h, function() promptEditorBody(state, context) end, true)
    addButton(layer, _("Entwurf"), margin + 2 * (w4 + gap), actions_y, w4, actions_h, function() syncEditor(state, context, false) end)
    addButton(layer, _("Publizieren"), margin + 3 * (w4 + gap), actions_y, w4, actions_h, function() syncEditor(state, context, true) end, true)
    local marks_y = actions_y + actions_h + gap
    local marks = { { "H", "heading" }, { "B", "bold" }, { "I", "italic" }, { "Liste", "list" }, { "Zitat", "quote" }, { "Code", "code" }, { "Link", "link" }, { "Bild", "image" } }
    local mark_w = math.max(px(42), math.floor((width - 2 * margin - (#marks - 1) * gap) / #marks))
    for index, mark in ipairs(marks) do
        addButton(layer, mark[1], margin + (index - 1) * (mark_w + gap), marks_y, mark_w, actions_h, function()
            if mark[2] == "image" then promptPostImage(state, context) else insertFormat(state, context, mark[2]) end
        end)
    end
    local content_y, content_h = marks_y + actions_h + px(7), bottom - (marks_y + actions_h + px(58))
    local title = trim(state.editor.title or "")
    addText(layer, title ~= "" and title or _("Untitled"), margin, content_y, width - 2 * margin, px(20), { serif = true, bold = true })
    local blocks = markdownBlocks(state.editor.body or "")
    local preview_blocks = paginateBlocks(blocks, width - 2 * margin, math.max(px(48), content_h - px(29)), px)[1]
    renderFallbackBlocks(layer, preview_blocks, margin, content_y + px(28), width - 2 * margin, math.max(px(48), content_h - px(29)), px)
    addButton(layer, _("Verwerfen"), margin, bottom - px(44), math.floor((width - 2 * margin - gap) / 2), px(44), function() beginNewPost(state, context) end)
    addButton(layer, _("Vorschau"), margin + math.floor((width - 2 * margin - gap) / 2) + gap, bottom - px(44), math.floor((width - 2 * margin - gap) / 2), px(44), function() state.status = _("The reading view is a paginated Markdown preview; all source text stays in the editor."); requestRebuild(context) end, true)
end

local function renderProfile(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(7)
    if state.session.user.id == "" then
        addText(layer, _("InkBlog account"), margin, top, width - 2 * margin, px(18), { serif = true, bold = true })
        addBox(layer, _("InkBlog uses the TBS account already signed in on this reader. On first use, your InkBlog account and profile are created automatically—no extra password or email registration."), margin, top + px(31), width - 2 * margin, px(84), px(14), { serif = true })
        addButton(layer, _("TBS-Konto verwenden"), margin, top + px(124), width - 2 * margin, px(44), function() loadOwnProfile(state, context) end, true)
        addButton(layer, _("Existing InkBlog email account"), margin, top + px(176), width - 2 * margin, px(44), function() promptCredentials(state, context, false) end)
        return
    end
    local profile = state.profile or { id = state.session.user.id, display_name = state.session.user.email:match("^([^@]+)") or _("Reader"), bio = _("Tap Profil bearbeiten to add a bio.") }
    local avatar = avatarWidget(profile, state, px(58)); avatar.overlap_offset = { margin, top }; layer[#layer + 1] = avatar
    addText(layer, profile.display_name or _("Reader"), margin + px(69), top + px(3), width - margin * 2 - px(69), px(19), { serif = true, bold = true })
    addText(layer, profile.bio or "", margin + px(69), top + px(28), width - margin * 2 - px(69), px(11), { color = GRAY_333 })
    local buttons_y, half = top + px(68), math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, _("Profil bearbeiten"), margin, buttons_y, half, px(44), function() promptProfileEdit(state, context) end)
    addButton(layer, _("Avatar"), margin + half + gap, buttons_y, half, px(44), function() promptAvatarUpload(state, context) end)
    addButton(layer, _("Avatar laden"), margin, buttons_y + px(51), half, px(44), function() downloadAvatar(state, context, profile) end)
    addButton(layer, _("Abmelden"), margin + half + gap, buttons_y + px(51), half, px(44), function() logout(state, context) end)
    local below = buttons_y + px(106)
    addText(layer, _("Eigene Tinte"), margin, below, width - 2 * margin, px(16), { serif = true, bold = true })
    local item_w = math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, _("Meine Beiträge"), margin, below + px(23), item_w, px(44), function() state.view = "mine"; listPosts(state, context, "mine", nil) end, true)
    addButton(layer, string.format(_("Entwürfe (%d)"), #state.drafts), margin + item_w + gap, below + px(23), item_w, px(44), function() state.view = "drafts"; requestRebuild(context) end)
    if state.pending_image_path then addText(layer, _("Image handover ready: ") .. state.pending_image_path:match("([^/]+)$"), margin, below + px(76), width - 2 * margin, px(10), { color = GRAY_666 }) end
end

local function renderDrafts(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(7)
    addText(layer, _("Lokale Entwürfe"), margin, top, width - 2 * margin, px(18), { serif = true, bold = true })
    addButton(layer, _("‹ Profil"), margin, top + px(26), width - 2 * margin, px(44), function() state.view = "profile"; requestRebuild(context) end)
    local y, card_h = top + px(78), math.max(px(60), math.floor((bottom - top - px(130)) / 3))
    if #state.drafts == 0 then addBox(layer, _("No local drafts. A failed publish is always kept here for retry."), margin, y, width - 2 * margin, card_h, px(14), { serif = true }) end
    for index, draft in ipairs(state.drafts) do
        if index > 3 then break end
        local card = ActionButton:new{ title = "", body = (draft.title ~= "" and draft.title or _("Untitled")) .. "\n" .. postPreview({ markdown = draft.body }, 120), width = width - 2 * margin, height = card_h, callback = function() editDraft(state, context, draft) end }
        card.overlap_offset = { margin, y }; layer[#layer + 1] = card; y = y + card_h + gap
    end
end

local function renderAuthor(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(7)
    local profile = state.author_profile or { id = state.selected_author_id, display_name = _("Author"), bio = _("Tap Laden to fetch this blog.") }
    local avatar = avatarWidget(profile, state, px(54)); avatar.overlap_offset = { margin, top }; layer[#layer + 1] = avatar
    addText(layer, profile.display_name or _("Author"), margin + px(64), top + px(2), width - 2 * margin - px(64), px(18), { serif = true, bold = true })
    addText(layer, profile.bio or "", margin + px(64), top + px(27), width - 2 * margin - px(64), px(10), { color = GRAY_333 })
    local half = math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, profile.followed and _("Folge ich ✓") or _("Folgen"), margin, top + px(62), half, px(44), function() toggleFollow(state, context) end, profile.followed)
    addButton(layer, profile.blocked and _("Blockiert ✓") or _("Blockieren"), margin + half + gap, top + px(62), half, px(44), function() toggleBlock(state, context) end, profile.blocked)
    addButton(layer, _("Avatar laden"), margin, top + px(113), width - 2 * margin, px(44), function() downloadAvatar(state, context, profile) end)
    renderPostList(layer, state, context, width, top + px(164), bottom, px, _("Blog"))
end

local function renderNotifications(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(7)
    addText(layer, _("Benachrichtigungen"), margin, top, width - 2 * margin, px(18), { serif = true, bold = true })
    addButton(layer, _("Laden"), margin, top + px(26), width - 2 * margin, px(44), function() loadNotifications(state, context) end, true)
    local y, card_h = top + px(78), math.max(px(55), math.floor((bottom - top - px(130)) / 3))
    if #state.notifications == 0 then addBox(layer, _("No cached notifications. Tap Laden to check InkBlog."), margin, y, width - 2 * margin, card_h, px(14), { serif = true }) end
    for index, note in ipairs(state.notifications) do
        if index > 3 then break end
        local marker = note.read_at and "" or "• "
        local body = marker .. tostring(note.kind or _("Activity")) .. "\n" .. tostring(note.created_at or "")
        local card = ActionButton:new{ title = "", body = body, width = width - 2 * margin, height = card_h, callback = function() openNotification(state, context, note) end, primary = not note.read_at }
        card.overlap_offset = { margin, y }; layer[#layer + 1] = card; y = y + card_h + gap
    end
end

local function buildPane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local pane, layer = buildBase(width, height)
    local top, nav_space = px(52), px(56)
    local bottom = height - nav_space
    addHeader(layer, state, width, px, state.view == "article" and _("InkBlog · Lesen") or _("InkBlog"))
    if state.view == "feed" then renderPostList(layer, state, context, width, top, bottom, px, _("Feed"))
    elseif state.view == "discover" then renderPostList(layer, state, context, width, top, bottom, px, _("Entdecken"))
    elseif state.view == "write" then renderWrite(layer, state, context, width, top, bottom, px)
    elseif state.view == "profile" then renderProfile(layer, state, context, width, top, bottom, px)
    elseif state.view == "drafts" then renderDrafts(layer, state, context, width, top, bottom, px)
    elseif state.view == "mine" then renderPostList(layer, state, context, width, top, bottom, px, _("Meine Beiträge und Entwürfe"))
    elseif state.view == "author" then renderAuthor(layer, state, context, width, top, bottom, px)
    elseif state.view == "notifications" then renderNotifications(layer, state, context, width, top, bottom, px)
    elseif state.view == "article" then renderArticle(layer, state, context, width, top, bottom, px)
    else state.view = "feed"; renderPostList(layer, state, context, width, top, bottom, px, _("Feed")) end
    addStatus(layer, state, width, height - nav_space - px(15), px)
    addNavigation(layer, state, context, width, height, px)
    return pane
end

local function acceptFile(instance, path)
    if type(path) ~= "string" or #path > 1024 then return false, _("Choose a local PNG or JPEG image.") end
    local mime = imageMimeForPath(path)
    if not mime then return false, _("InkBlog accepts PNG and JPEG images only.") end
    local data, checked_mime, err = readUploadImage(path)
    if not data then return false, err end
    local state = stateFor(instance)
    state.pending_image_path = path
    state.status = _("Image handover is ready. Open Schreiben or Profil to upload it.")
    return true
end

return {
    id = APP_ID,
    version = "1.1.0",
    title = "InkBlog",
    subtitle = "Write in ink. Read in peace.",
    symbol = "I",
    logo = "notes",
    requires_tbs_account = true,
    buildPane = buildPane,
    openFile = acceptFile,
    _test = {
        ActionButton = ActionButton, InkLogo = InkLogo, COLORS = { black = BLACK, white = WHITE, gray333 = GRAY_333, gray666 = GRAY_666, grayccc = GRAY_CCC },
        stateFor = stateFor, markdownBlocks = markdownBlocks, paginateBlocks = paginateBlocks, utf8Cut = utf8Cut, utf8Length = utf8Length,
        validManagedPath = validManagedPath, imageMimeForPath = imageMimeForPath, restPath = restPath, applySessionResult = applySessionResult,
        getTbsIdentity = function() return getTbsIdentity and getTbsIdentity() end,
        captureLocalDraft = captureLocalDraft, loadDrafts = loadDrafts, saveDrafts = saveDrafts, buildPane = buildPane,
        rawRequest = rawRequest, cacheImageNow = cacheImageNow, LOGO_ROWS = LOGO_ROWS,
    },
}
