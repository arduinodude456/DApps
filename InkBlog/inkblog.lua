--[[--
InkBlog for AppDock.

A quiet, monochrome InkBlog reader and writer, typeset like a small press: real
serif type, an illuminated drop cap, ornaments, ink-ripple empty pages and a
reading-progress rule.  This is a single
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
local ok_theme, Theme = pcall(require, "appdock_theme")
local _ = require("gettext")
local ok_appdock_keyboard, AppDockKeyboard = pcall(require, "appdock_keyboard")
if not ok_appdock_keyboard then AppDockKeyboard = nil end

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then pcall(function() lfs = require("lfs") end) end
local ok_html, HtmlBoxWidget = pcall(require, "ui/widget/htmlboxwidget")
local ok_image, ImageWidget = pcall(require, "ui/widget/imagewidget")
local ok_pathchooser, PathChooser = pcall(require, "ui/widget/pathchooser")
local ok_rendertext, RenderText = pcall(require, "ui/rendertext")

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
local MAX_TITLE_BYTES = 240 * 4
local MAX_IMAGE_BYTES = 700 * 1024
local MAX_CACHED_IMAGES = 16
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

-- Follow DChat's AppDock contract: use the resolved pane palette (or the
-- optional AppDock theme module), with named KOReader colors as fallbacks.
local C = {
    WHITE = Blitbuffer.COLOR_WHITE,
    BLACK = Blitbuffer.COLOR_BLACK,
    GRAY_333 = Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
    GRAY_666 = Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
    GRAY_CCC = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
}
C.THEME_GREEN = Blitbuffer.COLOR_DARK_GREEN or C.GRAY_666
C.THEME_NAVY = Blitbuffer.COLOR_DARK_BLUE or C.THEME_GREEN
C.THEME_TEAL = Blitbuffer.COLOR_DARK_CYAN or C.THEME_GREEN
C.THEME_GOLD = Blitbuffer.COLOR_DARK_YELLOW or C.THEME_GREEN
C.PAPER, C.PAPER_CARD, C.PARCHMENT = C.WHITE, C.GRAY_CCC, C.GRAY_666
C.SEPIA, C.INK_BLUE, C.OCHRE, C.MOSS = C.GRAY_333, C.BLACK, C.THEME_GOLD, C.THEME_GREEN

local function paletteFor(context)
    if context and type(context.palette) == "table" then return context.palette end
    local appdock = context and context.manager and context.manager.appdock
    if ok_theme and type(Theme) == "table" and type(Theme.getPalette) == "function" then
        local ok, palette = pcall(Theme.getPalette, appdock)
        if ok and type(palette) == "table" then return palette end
    end
    return {
        background = C.WHITE, surface = C.GRAY_CCC, surface_variant = C.GRAY_666,
        primary = C.THEME_GREEN, on_primary = C.WHITE,
        secondary = C.THEME_NAVY, on_secondary = C.WHITE,
        tertiary = C.THEME_TEAL, on_tertiary = C.WHITE,
        on_surface = C.BLACK, on_variant = C.GRAY_333,
    }
end

local function applyPalette(context)
    local palette = paletteFor(context)
    C.active_palette = {
        background = palette.background or C.WHITE,
        surface = palette.surface or C.GRAY_CCC,
        surface_variant = palette.surface_variant or palette.tertiary or C.GRAY_666,
        primary = palette.primary or C.THEME_GREEN,
        on_primary = palette.on_primary or C.WHITE,
        secondary = palette.secondary or C.THEME_NAVY,
        on_secondary = palette.on_secondary or C.WHITE,
        tertiary = palette.tertiary or C.THEME_TEAL,
        on_tertiary = palette.on_tertiary or C.WHITE,
        on_surface = palette.on_surface or C.BLACK,
        on_variant = palette.on_variant or palette.on_surface or C.GRAY_333,
    }
    C.PAPER, C.PAPER_CARD, C.PARCHMENT = C.active_palette.background, C.active_palette.surface, C.active_palette.surface_variant
    C.SEPIA, C.INK_BLUE, C.OCHRE, C.MOSS = C.active_palette.on_variant, C.active_palette.on_surface, C.active_palette.tertiary, C.active_palette.secondary
    C.GRAY_333, C.GRAY_666, C.GRAY_CCC = C.active_palette.on_variant, C.active_palette.secondary, C.active_palette.surface
end

local function scale(value)
    return Device.screen:scaleBySize(value)
end

-- Every InkBlog design helper lives on this one table (see the local-variable note).
local Ink = {}

-- ---------------------------------------------------------------------------
-- Typography.  KOReader ships Noto Serif, but its "cfont" is a sans.  InkBlog
-- asks for true serif faces and quietly falls back to the stock UI fonts, so a
-- missing file can never break a page.
-- ---------------------------------------------------------------------------
Ink.faces = {
    display = { "NotoSerif-Bold.ttf", "tfont" },
    serif = { "NotoSerif-Regular.ttf", "cfont" },
    italic = { "NotoSerif-Italic.ttf", "NotoSerif-Regular.ttf", "cfont" },
    mono = { "DroidSansMono.ttf", "smallinfofont" },
    sans = { "smallinfofont" },
}
Ink.choice = {}
function Ink.face(role, size)
    size = math.max(1, math.floor(tonumber(size) or 14))
    local names = Ink.faces[role] or Ink.faces.sans
    local remembered = Ink.choice[role]
    if remembered then
        local ok, face = pcall(Font.getFace, Font, names[remembered], size)
        if ok and face then return face end
    end
    for index, name in ipairs(names) do
        local ok, face = pcall(Font.getFace, Font, name, size)
        if ok and face then Ink.choice[role] = index; return face end
    end
    return Font:getFace("cfont", size)
end

-- Old call sites say { serif = true, bold = true } or face_name = "tfont";
-- map those onto the typographic roles above.
function Ink.role(options)
    options = options or {}
    if options.role then return options.role end
    if options.face_name == "tfont" then return "display" end
    if options.serif then return options.bold and "display" or (options.italic and "italic" or "serif") end
    return "sans"
end

function Ink.measure(widget, fallback_w, fallback_h)
    local ok, size = pcall(function() return widget:getSize() end)
    if ok and type(size) == "table" then return tonumber(size.w) or fallback_w, tonumber(size.h) or fallback_h end
    return fallback_w, fallback_h
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

local function textField(value, maximum)
    if type(value) ~= "string" then return "" end
    value = value:gsub("%z", "")
    if #value <= maximum then return value end
    local position, safe_end = 1, 0
    while position <= #value do
        local next_position = utf8Next(value, position)
        if next_position - 1 > maximum then break end
        safe_end, position = next_position - 1, next_position
    end
    return value:sub(1, safe_end)
end

local function displayNameFor(value, fallback)
    local name = trim(textField(value, 80))
    return name ~= "" and name or fallback
end

local function postTitleFor(post)
    local title = type(post) == "table" and trim(textField(post.title, MAX_TITLE_BYTES)) or ""
    if title == "" then return _("Untitled") end
    if utf8Length(title) <= 240 then return title end
    local visible = utf8Cut(title, 240)
    return visible
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
        status = _("Tap Refresh to receive the latest ink."), loading = false,
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
    if context and type(context.requestRebuild) == "function" then
        pcall(context.requestRebuild, "ui")
    end
end

local function showInput(dialog)
    if AppDockKeyboard and type(AppDockKeyboard.attach) == "function" then
        pcall(AppDockKeyboard.attach, dialog)
    end
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
    local request_headers = { ["accept"] = binary and "image/*" or "application/json", ["apikey"] = PUBLISHABLE_KEY, ["user-agent"] = "AppDock-InkBlog/1.5.1" }
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
            local checked, authenticated, auth_error = pcall(ensureAccess, state)
            if not checked then
                state.loading = false
                state.status = _("InkBlog could not verify the account. Check the TBS account and retry.")
                requestRebuild(context)
                return
            end
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
    if UIManager and type(UIManager.tickAfterNext) == "function" then
        local scheduled = pcall(UIManager.tickAfterNext, UIManager, job)
        if not scheduled then
            state.loading = false
            state.status = _("InkBlog could not start that request. Check the connection and retry.")
            requestRebuild(context)
        end
    else
        job()
    end
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
        if target:match("^inkblog:") then return "[Image: " .. alt .. "]" end
        return "[External image not loaded: " .. alt .. "]"
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
        return "[Image: " .. alt .. "]"
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
            local image_alt, image_target = line:match("^%s*!%[([^%]]*)%]%(([^%)]+)%)%s*$")
            local image_path = image_target and image_target:match("^inkblog:(.+)$")
            local marks, heading = line:match("^%s*(#+)%s+(.+)%s*$")
            local quote = line:match("^%s*>%s?(.*)$")
            local bullet = line:match("^%s*[-*+]%s+(.+)%s*$")
            local ordered = line:match("^%s*%d+[%.%)]%s+(.+)%s*$")
            if image_path and validManagedPath(image_path) then
                closeParagraph(); blocks[#blocks + 1] = { kind = "image", path = image_path, alt = trim(image_alt):sub(1, 160), text = "" }
            elseif marks then
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

-- Characters per physical line for a block, honouring hanging indents (drop
-- caps, list markers, quote marks and code insets).
function Ink.cpl(block, width, px)
    local kind = block.kind or "paragraph"
    local size = blockFontSize(block, px)
    local factor = kind == "heading" and .62 or (kind == "code" and .62 or .56)
    local usable = width - (tonumber(block.indent) or 0)
    return math.max(4, math.floor(usable / math.max(1, size * factor)))
end

-- Count physical display lines, preserving hard newlines (especially code).
-- This deterministic estimator deliberately avoids constructing TextBoxWidget
-- instances while paginating. A near-limit unbroken post would otherwise make
-- hundreds of native layouts before the first visible page, which can exhaust
-- KOReader's renderer memory during the publish-to-reader transition.
local function physicalLineCount(text, chars_per_line)
    -- Greedy word wrap, like the real TextBoxWidget: words move to the next
    -- line as a whole; only words longer than a line are broken by character.
    text = tostring(text or "")
    chars_per_line = math.max(1, chars_per_line)
    local lines = 0
    for segment in (text .. "\n"):gmatch("(.-)\n") do
        local segment_lines, column = 1, 0
        for word in segment:gmatch("%S+") do
            local length = utf8Length(word)
            local needed = column == 0 and length or column + 1 + length
            if needed <= chars_per_line then
                column = needed
            elseif length > chars_per_line then
                if column > 0 then segment_lines = segment_lines + 1 end
                local extra = math.floor((length - 1) / chars_per_line)
                segment_lines = segment_lines + extra
                column = length - extra * chars_per_line
            else
                segment_lines, column = segment_lines + 1, length
            end
        end
        lines = lines + segment_lines
    end
    return lines
end

-- Real pixel metrics: words are measured with the actual face, so wrapping is
-- right on every screen size, DPI and font fallback (falls back to a
-- conservative character estimate when KOReader's RenderText is unavailable).
Ink.widths = Ink.widths or {}
function Ink.metric(block, width, px)
    local kind = block.kind or "paragraph"
    if kind == "code" or kind == "image" or not (ok_rendertext and RenderText) then return nil end
    local size = blockFontSize(block, px)
    local role = kind == "heading" and "display" or (kind == "quote" and "italic" or "serif")
    local face_ok, face = pcall(Ink.face, role, size)
    if not face_ok or not face then return nil end
    local key = role .. ":" .. size
    local cache = Ink.widths[key]
    if not cache then cache = {}; Ink.widths[key] = cache end
    local function measure(word)
        local known = cache[word]
        if known then return known end
        local ok, result = pcall(RenderText.sizeUtf8Text, RenderText, 0, 100000, face, word, true, false)
        local value = ok and type(result) == "table" and tonumber(result.x) or nil
        if not value or value <= 0 then value = utf8Length(word) * size * .56 end
        cache[word] = value
        return value
    end
    local usable = math.max(8, width - (tonumber(block.indent) or 0))
    return { measure = measure, space = measure(" "), limit = usable * .94 }
end

-- Place one word on the greedy-wrapped layout; false when it would need more
-- than max_lines lines (the state is left untouched in that case).
function Ink.placeWord(state, metric, word, max_lines)
    local width = metric.measure(word)
    local lines, column = state.lines, state.col
    if column > 0 then
        if column + metric.space + width <= metric.limit then state.col = column + metric.space + width; return true end
        lines, column = lines + 1, 0
    end
    if lines > max_lines then return false end
    if width > metric.limit then
        local extra = math.floor((width - 1) / metric.limit)
        lines = lines + extra
        if lines > max_lines then return false end
        column = width - extra * metric.limit
    else
        column = width
    end
    state.lines, state.col = lines, column
    return true
end

function Ink.countLines(block, text, width, px, chars_per_line)
    text = tostring(text or "")
    local metric = Ink.metric(block, width, px)
    if not metric then return physicalLineCount(text, chars_per_line or Ink.cpl(block, width, px)) end
    local lines = 0
    for segment in (text .. "\n"):gmatch("(.-)\n") do
        local state = { lines = 1, col = 0 }
        for word in segment:gmatch("%S+") do Ink.placeWord(state, metric, word, math.huge) end
        lines = lines + state.lines
    end
    return lines
end

local function measureBlockLines(block, content_width, px, chars_per_line)
    if block and block.kind == "image" then return block.image_lines or 8 end
    local lines = Ink.countLines(block or {}, block and block.text or "", content_width, px, chars_per_line)
    return math.max(lines, tonumber(block and block.min_lines) or 0)
end

-- Split exact UTF-8 source into pieces that individually fit a physical-line
-- capacity.  Unlike the old recursive splitter it always consumes input, so a
-- 600-line code block or an unbroken long heading cannot recurse forever.
local function splitBlockChars(block, max_lines, chars_per_line)
    local source, pieces, position = tostring(block.text or ""), {}, 1
    if source == "" then return { copyTable(block) } end
    chars_per_line = math.max(1, chars_per_line)
    while position <= #source do
        -- Continuation pages never start with blank space.
        if #pieces > 0 and block.kind ~= "code" then
            position = source:find("[^%s]", position) or (#source + 1)
            if position > #source then break end
        end
        local first, lines, column, full = position, 1, 0, false
        while position <= #source and not full do
            local character = source:sub(position, position)
            if character == "\n" then
                if lines >= max_lines then full = true
                else lines, column, position = lines + 1, 0, position + 1 end
            elseif character:match("%s") then
                column, position = math.min(chars_per_line, column + 1), position + 1
            else
                -- Words are placed whole so a page never ends inside a word.
                local word_end = source:find("%s", position) or (#source + 1)
                local length = utf8Length(source:sub(position, word_end - 1))
                if length <= chars_per_line then
                    if column + length <= chars_per_line then
                        column, position = column + length, word_end
                    elseif lines >= max_lines then
                        full = true
                    else
                        lines, column, position = lines + 1, length, word_end
                    end
                else
                    -- Overlong word (URL, unbroken text): break by character.
                    while position < word_end do
                        local _, next_position = hardUtf8Cut(source, position)
                        if column >= chars_per_line then
                            if lines >= max_lines then full = true; break end
                            lines, column = lines + 1, 0
                        end
                        column, position = column + 1, next_position
                    end
                end
            end
        end
        if position == first then
            local _, next_position = hardUtf8Cut(source, position)
            position = next_position
        end
        local piece = copyTable(block)
        -- Marker and drop cap belong to the first piece only.
        if #pieces > 0 then piece.marker, piece.drop, piece.min_lines = nil, nil, nil end
        piece.text = source:sub(first, position - 1):gsub("%s+$", "")
        if piece.text == "" then piece.text = " " end
        pieces[#pieces + 1] = piece
    end
    if #pieces == 0 then pieces[1] = copyTable(block) end
    return pieces
end

local function splitBlockWords(block, max_lines, metric)
    local source = tostring(block.text or "")
    -- Words wider than a whole line are cut into line-sized chunks first.
    source = source:gsub("%S+", function(word)
        if metric.measure(word) <= metric.limit then return nil end
        local chars = utf8Length(word)
        local chunk = math.max(1, math.floor(chars * metric.limit / metric.measure(word) * .9))
        local out, position, count, first = {}, 1, 0, 1
        while position <= #word do
            local _, next_position = hardUtf8Cut(word, position)
            count, position = count + 1, next_position
            if count >= chunk then out[#out + 1] = word:sub(first, position - 1); first, count = position, 0 end
        end
        if first <= #word then out[#out + 1] = word:sub(first) end
        return table.concat(out, " ")
    end)
    local pieces, position = {}, 1
    while position <= #source do
        if #pieces > 0 then
            position = source:find("[^%s]", position) or (#source + 1)
            if position > #source then break end
        end
        local first, state = position, { lines = 1, col = 0 }
        while position <= #source do
            local character = source:sub(position, position)
            if character == "\n" then
                if state.lines >= max_lines then break end
                state.lines, state.col, position = state.lines + 1, 0, position + 1
            elseif character:match("%s") then
                position = position + 1
            else
                local word_end = source:find("%s", position) or (#source + 1)
                if not Ink.placeWord(state, metric, source:sub(position, word_end - 1), max_lines) then break end
                position = word_end
            end
        end
        if position == first then position = (source:find("%s", position) or (#source + 1)) end
        local piece = copyTable(block)
        if #pieces > 0 then piece.marker, piece.drop, piece.min_lines = nil, nil, nil end
        piece.text = source:sub(first, position - 1):gsub("%s+$", "")
        if piece.text == "" then piece.text = " " end
        pieces[#pieces + 1] = piece
    end
    if #pieces == 0 then pieces[1] = copyTable(block) end
    return pieces
end

local function splitBlock(block, max_lines, chars_per_line, content_width, px)
    local metric = content_width and Ink.metric(block, content_width, px)
    if metric then return splitBlockWords(block, max_lines, metric) end
    return splitBlockChars(block, max_lines, chars_per_line)
end

-- Pagination works in pixels and mirrors renderFallbackBlocks exactly, so a
-- page never holds more than the renderer can draw (on any screen size).
local function paginateBlocks(blocks, content_width, content_height, px)
    local pages, page, used = {}, {}, 0
    local function lineHeightFor(block) return math.max(px(17), math.floor(blockFontSize(block, px) * 1.35)) end
    local function heightFor(block, lines) return math.max(px(20), lines * lineHeightFor(block) + px(5)) end
    local function addFittingBlock(block)
        local lines = measureBlockLines(block, content_width, px, Ink.cpl(block, content_width, px))
        local h = heightFor(block, lines)
        local gap = (block.kind == "heading" and used > 0) and px(6) or 0
        if used > 0 and used + gap + h > content_height then
            pages[#pages + 1] = page; page, used, gap = {}, 0, 0
        end
        page[#page + 1] = block
        used = used + gap + h + px(5)
    end
    for _, block in ipairs(blocks or {}) do
        local line_height = lineHeightFor(block)
        local capacity = math.max(1, math.floor((content_height - px(5)) / line_height))
        if block.kind == "image" then
            block.image_lines = math.max(2, math.min(capacity, math.floor(content_height * 0.6 / line_height)))
        end
        local chars_per_line = Ink.cpl(block, content_width, px)
        local lines = measureBlockLines(block, content_width, px, chars_per_line)
        if lines > capacity then
            for _, piece in ipairs(splitBlock(block, capacity, chars_per_line, content_width, px)) do addFittingBlock(piece) end
        else
            addFittingBlock(block)
        end
    end
    if #page > 0 or #pages == 0 then pages[#pages + 1] = page end
    return pages
end

local ActionButton = InputContainer:extend{ width = nil, height = nil, title = "", body = nil, callback = nil, primary = false, disabled = false, dimen = nil, state = nil, context = nil, button_background = nil, button_foreground = nil, button_border = nil, variant = nil, serif = false }

function ActionButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local palette = C.active_palette or paletteFor()
    local variant = self.variant or "button"
    if variant == "hit" then
        -- Invisible tap target: entries draw their own typography on top of it.
        self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, HorizontalSpan:new{ width = 0 } }
    elseif variant == "tab" then
        local background = self.primary and palette.primary or palette.background
        local foreground = self.primary and palette.on_primary or palette.on_surface
        if self.disabled then foreground = C.SEPIA end
        self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, background = background,
            CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or "", face = Font:getFace("cfont", math.max(14, math.floor(self.height * .26))), fgcolor = foreground, bold = true, max_width = math.max(1, self.width - scale(4)) } } }
    else
        local background = self.disabled and palette.background or self.button_background or (self.primary and palette.primary or palette.background)
        local foreground = self.disabled and C.SEPIA or self.button_foreground or (self.primary and palette.on_primary or palette.on_surface)
        local border = self.disabled and C.PARCHMENT or self.button_border or (self.primary and palette.primary or palette.on_surface)
        local inset = math.max(2, math.floor(math.min(self.width, self.height) * .12))
        local content
        if self.body then
            local body_font_size = math.min(18, math.max(14, math.floor(self.height * .16)))
            content = TextBoxWidget:new{ text = self.body, width = math.max(1, self.width - inset * 2), height = math.max(1, self.height - inset * 2), face = Ink.face(self.serif and "serif" or "sans", body_font_size), fgcolor = foreground, bgcolor = background, line_height = 0.31, alignment = "left" }
        else
            content = CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", math.max(14, math.floor(self.height * .32))), fgcolor = foreground, bold = true, max_width = math.max(1, self.width - inset * 2) } }
        end
        self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = self.body and inset or 0, bordersize = self.primary and 0 or math.max(1, scale(1)), color = border, radius = math.max(2, scale(2)), background = background, content }
    end
    self.ges_events = { TapInkBlogAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function ActionButton:paintTo(bb, x, y)
    local range = self.ges_events.TapInkBlogAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function ActionButton:onTapInkBlogAction()
    if not self.disabled and self.callback then
        local ok = pcall(self.callback)
        if not ok then
            if type(self.state) == "table" then
                self.state.loading = false
                self.state.status = _("InkBlog could not complete that action. Your local content remains available.")
            end
            requestRebuild(self.context)
        end
    end
    return true
end

local function rectanglesOverlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- All interactive geometry is derived from the caller's px function.  A
-- compact pane may intentionally choose smaller controls; this helper never
-- replaces their requested height with Device.screen's unrelated scale.
local function addButton(layer, title, x, y, width, height, callback, primary, body, disabled, style)
    x, y = math.floor(tonumber(x) or -1), math.floor(tonumber(y) or -1)
    width, height = math.floor(tonumber(width) or 0), math.floor(tonumber(height) or 0)
    local bounds = layer and layer.dimen
    if not bounds or x < 0 or y < 0 or width < 1 or height < 1 or x + width > bounds.w or y + height > bounds.h then return nil end
    local candidate = { x = x, y = y, w = width, h = height }
    layer._inkblog_button_bounds = layer._inkblog_button_bounds or {}
    for _, occupied in ipairs(layer._inkblog_button_bounds) do if rectanglesOverlap(candidate, occupied) then return nil end end
    style = type(style) == "table" and style or {}
    local button = ActionButton:new{ title = title, body = body, width = width, height = height, callback = callback, primary = primary == true, disabled = disabled == true, state = layer._inkblog_state, context = layer._inkblog_context, button_background = style.background, button_foreground = style.foreground, button_border = style.border, variant = style.variant, serif = style.serif == true }
    button.overlap_offset = { x, y }
    layer[#layer + 1] = button
    layer._inkblog_button_bounds[#layer._inkblog_button_bounds + 1] = candidate
    return button
end

local function addText(layer, text, x, y, width, size, options)
    options = options or {}
    local font_size = math.max(14, math.floor(tonumber(size) or 14))
    local role = Ink.role(options)
    layer[#layer + 1] = TextWidget:new{ text = tostring(text or ""), face = Ink.face(role, font_size), fgcolor = options.color or C.INK_BLUE, bold = role == "sans" and options.bold == true, max_width = math.max(1, width), overlap_offset = { x, y } }
end

-- Right-aligned single line (datelines, counters).
function Ink.textRight(layer, text, right_edge, y, max_width, size, options)
    options = options or {}
    local font_size = math.max(14, math.floor(tonumber(size) or 14))
    local role = Ink.role(options)
    local widget = TextWidget:new{ text = tostring(text or ""), face = Ink.face(role, font_size), fgcolor = options.color or C.INK_BLUE, bold = role == "sans" and options.bold == true, max_width = math.max(1, max_width) }
    local text_width = Ink.measure(widget, max_width, font_size)
    widget.overlap_offset = { right_edge - math.min(text_width, max_width), y }
    layer[#layer + 1] = widget
end

local function addBox(layer, text, x, y, width, height, size, options)
    options = options or {}
    local role = Ink.role(options)
    local font_size = math.max(role ~= "sans" and 16 or 14, math.floor(tonumber(size) or 14))
    local box = TextBoxWidget:new{ text = tostring(text or ""), width = math.max(1, width), height = math.max(1, height), face = Ink.face(role, font_size), fgcolor = options.color or C.INK_BLUE, bgcolor = options.bg or C.PAPER_CARD, line_height = options.line_height or .30, alignment = options.alignment or "left" }
    box.overlap_offset = { x, y }
    layer[#layer + 1] = box
    return box
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function fmtDate(value)
    local year, month, day = tostring(value or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    local month_number = tonumber(month)
    if not year or not month_number or month_number < 1 or month_number > 12 then return "" end
    return string.format("%d %s %s", tonumber(day), MONTHS[month_number], year)
end

Ink.weekdays = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
function Ink.dateline()
    local ok, now = pcall(os.date, "*t")
    if not ok or type(now) ~= "table" or not now.wday or not now.month then return "" end
    return string.format("%s · %d %s %d", Ink.weekdays[now.wday] or "", now.day or 0, MONTHS[now.month] or "", now.year or 0):upper()
end

function Ink.words(value)
    local count = 0
    for _ in tostring(value or ""):gmatch("%S+") do count = count + 1 end
    return count
end

function Ink.minutes(markdown)
    local words = Ink.words(markdown)
    if words == 0 then return 0 end
    return math.max(1, math.ceil(words / 200))
end

-- Solid rectangle used for rules, markers and quote bars.
local function addRule(layer, x, y, width, thickness, color)
    if not width or width < 1 then return end
    local rule = FrameContainer:new{ width = math.floor(width), height = math.max(1, math.floor(thickness or 1)), padding = 0, bordersize = 0, background = color or C.INK_BLUE, HorizontalSpan:new{ width = 0 } }
    rule.overlap_offset = { x, y }
    layer[#layer + 1] = rule
end

-- Painted ornaments, one widget each: a dotted hairline, a diamond fleuron
-- flanked by hairlines, and a trio of diamonds that closes an article.
Ink.Ornament = WidgetContainer:extend{ width = nil, height = nil, dimen = nil, kind = "dots", color = nil, soft = nil }

function Ink.Ornament:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function Ink.diamond(bb, cx, cy, radius, color)
    for dy = -radius, radius do
        local half = radius - math.abs(dy)
        bb:paintRect(cx - half, cy + dy, half * 2 + 1, 1, color)
    end
end

function Ink.Ornament:paintTo(bb, x, y)
    if not bb or type(bb.paintRect) ~= "function" then return end
    local w, h = math.floor(self.width or 0), math.floor(self.height or 0)
    if w < 6 or h < 1 then return end
    local ink, soft = self.color or C.INK_BLUE, self.soft or C.PARCHMENT
    local cy = y + math.floor(h / 2)
    if self.kind == "dots" then
        local dot = math.max(1, scale(1))
        local step = dot * 4
        local count = math.max(1, math.floor((w - dot) / step) + 1)
        local start = x + math.floor((w - ((count - 1) * step + dot)) / 2)
        for index = 0, count - 1 do bb:paintRect(start + index * step, cy, dot, dot, soft) end
        return
    end
    if h < 5 then return end
    local radius = math.max(2, math.min(math.floor((h - 1) / 2), math.floor(w / 12)))
    local cx = x + math.floor(w / 2)
    if self.kind == "trio" then
        local pitch = radius * 3
        Ink.diamond(bb, cx, cy, radius, ink)
        Ink.diamond(bb, cx - pitch, cy, math.max(2, radius - 2), soft)
        Ink.diamond(bb, cx + pitch, cy, math.max(2, radius - 2), soft)
        return
    end
    -- fleuron: hairline, satellite, diamond, satellite, hairline
    local gap = radius * 2
    local line_w = math.floor(w / 2) - radius - gap
    if line_w > 0 then
        bb:paintRect(x, cy, line_w, 1, soft)
        bb:paintRect(x + w - line_w, cy, line_w, 1, soft)
    end
    Ink.diamond(bb, cx, cy, radius, ink)
    local offset = radius + math.floor(gap / 2)
    bb:paintRect(cx - offset - 1, cy - 1, 3, 3, ink)
    bb:paintRect(cx + offset - 1, cy - 1, 3, 3, ink)
end

function Ink.ornament(layer, kind, x, y, width, height, color, soft)
    if not width or width < 6 then return end
    local ornament = Ink.Ornament:new{ width = math.floor(width), height = math.max(1, math.floor(height or 8)), kind = kind, color = color, soft = soft }
    ornament.overlap_offset = { x, y }
    layer[#layer + 1] = ornament
end

local function authorProfileFor(post, fallback, expected_author_id)
    post = type(post) == "table" and post or {}
    fallback = type(fallback) == "table" and fallback or {}
    local author_id = validUuid(expected_author_id) and expected_author_id
        or (validUuid(post.author_id) and post.author_id or nil)
    local matching_fallback = validUuid(fallback.id) and fallback.id == author_id and fallback or {}
    local avatar_path = validManagedPath(post.avatar_path) and post.avatar_path
        or (validManagedPath(matching_fallback.avatar_path) and matching_fallback.avatar_path or nil)
    return {
        id = author_id,
        display_name = displayNameFor(post.display_name, displayNameFor(matching_fallback.display_name, _("Author"))),
        bio = textField(post.bio, 1000) ~= "" and textField(post.bio, 1000) or textField(matching_fallback.bio, 1000),
        avatar_path = avatar_path,
    }
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
        interior = CenterContainer:new{ dimen = Geom:new{ w = size - scale(4), h = size - scale(4) }, TextWidget:new{ text = initialFor(profile and profile.display_name), face = Ink.face("display", math.max(scale(14), math.floor(size * .45))), fgcolor = C.INK_BLUE, bold = false, max_width = size - scale(8) } }
    end
    return FrameContainer:new{ width = size, height = size, padding = scale(2), bordersize = math.max(1, scale(1)), color = C.INK_BLUE, radius = math.floor(size / 2), background = C.PAPER, interior }
end

local function normalizedPost(record, fallback_profile)
    if type(record) ~= "table" or not validUuid(record.id) or not validUuid(record.author_id) then return nil end
    local profile = authorProfileFor(record, fallback_profile)
    return {
        id = record.id,
        author_id = record.author_id,
        title = textField(record.title, MAX_TITLE_BYTES),
        markdown = textField(record.markdown, MAX_POST_BYTES),
        status = record.status == "draft" and "draft" or "published",
        created_at = textField(record.created_at, 80),
        updated_at = textField(record.updated_at, 80),
        published_at = textField(record.published_at, 80),
        display_name = profile.display_name,
        avatar_path = profile.avatar_path,
        like_count = math.max(0, math.floor(tonumber(record.like_count) or 0)),
        comment_count = math.max(0, math.floor(tonumber(record.comment_count) or 0)),
        liked = record.liked == true,
        followed = record.followed == true,
    }
end

-- PostgREST returns only post columns after INSERT/PATCH. Resolve the public
-- profile before opening the reader, while keeping a complete safe fallback if
-- that second, best-effort request is unavailable.
local function enrichPostWithProfile(state, record)
    local fallback = state and state.profile or nil
    local post = normalizedPost(record, fallback)
    if not post then return nil end
    local profiles = restRequest(state, "GET", "profiles", "id=eq." .. urlEncode(post.author_id) .. "&select=id,display_name,bio,avatar_path")
    if type(profiles) == "table" and type(profiles[1]) == "table" then
        local profile = profiles[1]
        local resolved = authorProfileFor(profile, nil, post.author_id)
        post.display_name, post.avatar_path = resolved.display_name, resolved.avatar_path
        if state and state.session and post.author_id == state.session.user.id then state.profile = profile end
    end
    return post
end

local cacheImageNow
local cachePostAvatars
local openPost
local postPreview

-- One typographic entry: avatar or unread mark, serif headline, byline, italic
-- excerpt, and a dotted hairline underneath.
local function addEntry(layer, state, context, x, y, w, h, spec, px)
    local hit = addButton(layer, "", x, y, w, h, spec.callback, false, nil, false, { variant = "hit" })
    if not hit then return nil end
    local text_x = x + px(8)
    if spec.unread then addRule(layer, x + px(1), y + px(11), px(6), px(6), C.INK_BLUE) end
    if spec.profile then
        local size = math.max(px(28), math.min(px(40), math.floor(h * .44)))
        local avatar = avatarWidget(spec.profile, state, size)
        avatar.inkblog_avatar_path, avatar.inkblog_avatar_owner = spec.profile.avatar_path, spec.profile.id
        avatar.overlap_offset = { x + px(2), y + px(8) }
        layer[#layer + 1] = avatar
        text_x = x + size + px(12)
    end
    local text_w = math.max(1, x + w - text_x - px(4))
    local line = y + px(6)
    addText(layer, spec.title or "", text_x, line, text_w, px(18), { role = "display" })
    line = line + px(25)
    if spec.meta and spec.meta ~= "" then
        addText(layer, spec.meta, text_x, line, text_w, px(11), { color = C.SEPIA })
        line = line + px(20)
    end
    local remaining = y + h - line - px(4)
    if spec.excerpt and spec.excerpt ~= "" and remaining >= px(16) then
        addBox(layer, spec.excerpt, text_x, line, text_w, remaining, px(13), { role = "italic", bg = C.PAPER, color = C.INK_BLUE, line_height = .25 })
    end
    Ink.ornament(layer, "dots", x, y + h, w, px(2))
    return hit
end

local function addPostPreviewCard(layer, state, context, post, x, y, width, height, px)
    local profile = authorProfileFor(post)
    local when = fmtDate(post.published_at)
    if when == "" then when = fmtDate(post.created_at) end
    local likes = math.max(0, math.floor(tonumber(post.like_count) or 0))
    local notes = math.max(0, math.floor(tonumber(post.comment_count) or 0))
    local minutes = Ink.minutes(post.markdown)
    local meta = profile.display_name .. (when ~= "" and (" · " .. when) or "")
        .. (minutes > 0 and (" · " .. minutes .. " min") or "")
        .. " · " .. likes .. (likes == 1 and " blot" or " blots")
        .. " · " .. notes .. (notes == 1 and " note" or " notes")
    return addEntry(layer, state, context, x, y, width, height, {
        title = postTitleFor(post), meta = meta,
        excerpt = postPreview(post, math.max(60, math.floor(width / math.max(1, px(5))) * 3)),
        callback = function() openPost(state, context, post) end, profile = profile,
    }, px)
end

local function listPosts(state, context, mode, author_id)
    state.mode, state.list_page, state.list_offset = mode, 0, 0
    runNetwork(state, context, _("Loading ink…"), function()
        local result, code, err = rpcRequest(state, "inkblog_list_posts", { p_mode = mode, p_author = author_id, p_sort = state.settings.sort, p_limit = PAGE_SIZE, p_offset = 0 })
        if type(result) ~= "table" then state.status = err or _("Posts could not be loaded."); return end
        state.posts = result
        if cachePostAvatars then cachePostAvatars(state, state.posts, 3) end
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
        if cachePostAvatars then cachePostAvatars(state, state.posts, 3) end
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
        if cacheImageNow and validManagedPath(state.author_profile.avatar_path) then cacheImageNow(state, state.author_profile.avatar_path, "avatar") end
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
        if type(posts) == "table" then
            state.posts, state.list_page, state.list_offset, state.posts_has_more = posts, 0, 0, #posts == PAGE_SIZE
            if cachePostAvatars then cachePostAvatars(state, state.posts, 3) end
            state.status = _("Author blog loaded.")
        else state.status = post_err or _("The author profile loaded, but not the posts.") end
    end)
    requestRebuild(context)
end

-- Download (once) every managed image of a post into the local grayscale cache.
local function cachePostImagesNow(state, post)
    local images = markdownImagePaths(post and post.markdown or "")
    local loaded, last_err = 0, nil
    for index, image in ipairs(images) do
        if index > MAX_CACHED_IMAGES then break end
        if state.image_cache[image.path] then
            loaded = loaded + 1
        else
            local ok, err = cacheImageNow(state, image.path, "post")
            if ok then loaded = loaded + 1 else last_err = err end
        end
    end
    return loaded, last_err, #images
end

openPost = function(state, context, post)
    if type(post) ~= "table" or not validUuid(post.id) then return end
    state.selected_post, state.article_page, state.article_tab, state.comments = post, 1, "read", {}
    state.view = "article"
    requestRebuild(context)
    if #markdownImagePaths(post.markdown or "") > 0 then
        runNetwork(state, context, _("Loading images…"), function()
            local loaded, err, total = cachePostImagesNow(state, post)
            state.status = loaded == total and "" or (err or _("Some images could not be loaded."))
        end)
    end
end

local function getPostAndOpen(state, context, post_id)
    if not validUuid(post_id) then state.status = _("This notification has no readable post."); requestRebuild(context); return end
    runNetwork(state, context, _("Opening post…"), function()
        local result, code, err = restRequest(state, "GET", "posts", "id=eq." .. urlEncode(post_id) .. "&select=id,author_id,title,markdown,status,created_at,updated_at,published_at")
        local post = type(result) == "table" and enrichPostWithProfile(state, result[1]) or nil
        if not post then state.status = err or _("That post is no longer available."); return end
        if cacheImageNow and validManagedPath(post.avatar_path) then cacheImageNow(state, post.avatar_path, "avatar") end
        state.selected_post, state.article_page, state.article_tab, state.view = post, 1, "read", "article"
        pcall(cachePostImagesNow, state, post)
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
    if #title > MAX_TITLE_BYTES or #body > MAX_POST_BYTES then return nil, _("A title or draft is too long to store safely.") end
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

local function openEditorField(state, context, field)
    if not AppDockKeyboard or type(AppDockKeyboard.open) ~= "function" then
        state.status = _("The AppDock keyboard is unavailable. Update AppDock and try again.")
        requestRebuild(context)
        return
    end
    if type(AppDockKeyboard.isEnabled) == "function" and not AppDockKeyboard.isEnabled() then
        state.status = _("Enable the AppDock keyboard in AppDock settings to edit this field.")
        requestRebuild(context)
        return
    end
    local is_body = field == "body"
    local keyboard
    local options = {
        value = tostring(state.editor[field] or ""),
        title = is_body and _("Write in ink · Markdown") or _("Post title"),
        placeholder = is_body and _("Type Markdown; ↵ adds a new line") or _("A quiet, clear title"),
        multiline = is_body,
        on_cancel = function()
            if keyboard then UIManager:close(keyboard) end
            requestRebuild(context)
        end,
        on_submit = function(value)
            if keyboard then UIManager:close(keyboard) end
            value = tostring(value or "")
            local limit = is_body and MAX_POST_BYTES or MAX_TITLE_BYTES
            if #value > limit or (not is_body and utf8Length(trim(value)) > 240) then
                state.status = is_body and _("Posts are limited to 96 KiB.") or _("Titles are limited to 240 characters.")
            else
                state.editor[field] = value
                state.status = is_body and _("Markdown text kept locally.") or _("Title kept locally.")
            end
            requestRebuild(context)
        end,
    }
    local ok, opened_keyboard = pcall(AppDockKeyboard.open, options)
    keyboard = opened_keyboard
    if not ok or not keyboard then
        state.status = _("The AppDock keyboard could not be opened. Update AppDock and try again.")
        requestRebuild(context)
    end
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

local function base64EncodeBlock(data)
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

local function base64Encode(data)
    if type(data) ~= "string" or data == "" then return "" end
    -- 12 KiB is divisible by three, so blocks need no internal padding. This
    -- keeps a 700 KiB upload to a few dozen chunks instead of ~239,000 Lua
    -- table entries and avoids an avoidable low-memory KOReader crash.
    local block_size, chunks = 12 * 1024, {}
    for first = 1, #data, block_size do
        chunks[#chunks + 1] = base64EncodeBlock(data:sub(first, math.min(#data, first + block_size - 1)))
    end
    return table.concat(chunks)
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

-- File browser for image attachments (falls back to a path field when the
-- host KOReader has no PathChooser).
local function startBrowseDir(state)
    local candidates = {}
    if type(state.last_image_dir) == "string" then candidates[#candidates + 1] = state.last_image_dir end
    if type(state.pending_image_path) == "string" then candidates[#candidates + 1] = state.pending_image_path:match("^(.*)/[^/]*$") end
    pcall(function()
        if G_reader_settings then
            candidates[#candidates + 1] = G_reader_settings:readSetting("home_dir")
            candidates[#candidates + 1] = G_reader_settings:readSetting("lastdir")
        end
    end)
    candidates[#candidates + 1] = DataStorage:getDataDir()
    for _, dir in ipairs(candidates) do
        if type(dir) == "string" and dir ~= "" and lfs then
            local ok, attributes = pcall(lfs.attributes, dir)
            if ok and attributes and attributes.mode == "directory" then return dir end
        end
    end
    return "/"
end

local function pickImagePath(state, title, on_path)
    if ok_pathchooser and PathChooser then
        local chooser
        local created = pcall(function()
            chooser = PathChooser:new{
                title = title,
                path = startBrowseDir(state),
                select_directory = false,
                select_file = true,
                show_files = true,
                file_filter = function(filename) return imageMimeForPath(filename) ~= nil end,
                onConfirm = function(file_path)
                    if chooser then pcall(UIManager.close, UIManager, chooser) end
                    file_path = trim(file_path)
                    if file_path == "" then return end
                    state.last_image_dir = file_path:match("^(.*)/[^/]*$") or state.last_image_dir
                    on_path(file_path)
                end,
            }
        end)
        if created and chooser then UIManager:show(chooser); return end
    end
    local dialog
    dialog = InputDialog:new{
        title = title, input = state.pending_image_path or "", input_hint = _("PNG/JPEG full path or use file handover"),
        buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Next"), is_enter_default = true, callback = function()
            local path = trim(dialog:getInputText())
            UIManager:close(dialog)
            on_path(path)
        end } } },
    }
    showInput(dialog)
end

local function promptPostImage(state, context)
    if not state.editor or not validUuid(state.editor.remote_id) then
        state.status = _("Save the draft to InkBlog first; then add its image.")
        requestRebuild(context)
        return
    end
    pickImagePath(state, _("Add ink image"), function(path)
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
    end)
end

local function promptAvatarUpload(state, context)
    local old_avatar = state.profile and state.profile.avatar_path
    pickImagePath(state, _("Avatar image"), function(path)
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
            state.status = _("Avatar uploaded. Tap Load avatar to cache it locally.")
        end, true)
    end)
end

local function syncEditor(state, context, publish)
    if type(state.editor) ~= "table" then
        state.status = _("The editor is not ready yet. Your local content remains available.")
        requestRebuild(context)
        return
    end
    local record, local_err = captureLocalDraft(state)
    if not record then state.status = local_err; requestRebuild(context); return end
    local title = trim(textField(state.editor.title, MAX_TITLE_BYTES))
    if title == "" or utf8Length(title) > 240 then
        state.status = title == "" and _("Give the post a title before syncing.") or _("Titles are limited to 240 characters.")
        requestRebuild(context)
        return
    end
    runNetwork(state, context, publish and _("Publishing ink…") or _("Saving draft…"), function()
        local fields = { title = title, markdown = record.body, status = publish and "published" or "draft", updated_at = utcNow() }
        if publish then fields.published_at = utcNow() end
        local result, code, err
        if validUuid(state.editor.remote_id) then
            result, code, err = restRequest(state, "PATCH", "posts", "id=eq." .. urlEncode(state.editor.remote_id), fields, { ["prefer"] = "return=representation" })
        else
            fields.author_id = state.session.user.id
            result, code, err = restRequest(state, "POST", "posts", nil, fields, { ["prefer"] = "return=representation" })
        end
        local saved = type(result) == "table" and enrichPostWithProfile(state, result[1]) or nil
        if not saved then
            state.status = err or _("Sync failed. The complete draft remains local for retry.")
            return
        end
        state.editor.remote_id, record.remote_id = saved.id, saved.id
        if publish then
            removeLocalDraft(state, record.local_id)
            if cacheImageNow and validManagedPath(saved.avatar_path) then cacheImageNow(state, saved.avatar_path, "avatar") end
            state.selected_post, state.view, state.status = saved, "article", _("Published. Read in peace.")
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
    runNetwork(state, context, item.liked and _("Removing blot…") or _("Adding blot…"), function()
        local result, code, err
        if item.liked then
            result, code, err = restRequest(state, "DELETE", "likes", "user_id=eq." .. urlEncode(state.session.user.id) .. "&target_type=eq." .. target_type .. "&target_id=eq." .. urlEncode(item.id))
        else
            result, code, err = restRequest(state, "POST", "likes", nil, { user_id = state.session.user.id, target_type = target_type, target_id = item.id })
        end
        if code and code >= 200 and code < 300 then
            item.liked = not item.liked
            item.like_count = math.max(0, (tonumber(item.like_count) or 0) + (item.liked and 1 or -1))
            state.status = item.liked and _("Blot added.") or _("Blot removed.")
        else state.status = err or _("The blot could not be changed.") end
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
                    local created = result[1]
                    created.display_name = created.display_name or (state.profile and state.profile.display_name)
                    created.like_count = created.like_count or 0
                    state.comments[#state.comments + 1] = created
                    post.comment_count = (tonumber(post.comment_count) or 0) + 1
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
            { text = comment.liked and _("Remove blot") or _("Blot"), callback = function() UIManager:close(dialog); toggleLike(state, context, comment, "comment") end },
            { text = _("Reply"), callback = function() UIManager:close(dialog); if not comment.parent_id then promptComment(state, context, comment) else state.status = _("Replies may be one level deep."); requestRebuild(context) end end },
            { text = may_delete and _("Delete") or _("Report"), is_enter_default = true, callback = function()
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
                local selected = type(post) == "table" and enrichPostWithProfile(state, post[1]) or nil
                if selected then
                    if cacheImageNow and validManagedPath(selected.avatar_path) then cacheImageNow(state, selected.avatar_path, "avatar") end
                    state.selected_post, state.article_page, state.article_tab, state.view, state.status = selected, 1, "read", "article", _("Post opened.")
                    pcall(cachePostImagesNow, state, selected)
                else state.status = post_err or _("That post is no longer available.") end
            else state.status = _("This notification has no openable post.") end
        end, true)
    elseif note.target_type == "post" then
        getPostAndOpen(state, context, note.target_id)
    end
end

cacheImageNow = function(state, managed_path, kind)
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

cachePostAvatars = function(state, posts, maximum)
    local seen, loaded = {}, 0
    maximum = math.max(1, math.min(MAX_CACHED_IMAGES, math.floor(tonumber(maximum) or 3)))
    for _, post in ipairs(type(posts) == "table" and posts or {}) do
        if loaded >= maximum then break end
        local profile = authorProfileFor(post)
        local path = profile.avatar_path
        if path and not seen[path] and not state.image_cache[path] then
            seen[path] = true
            local cached = cacheImageNow(state, path, "avatar")
            if cached then loaded = loaded + 1 end
        end
    end
    return loaded
end

local function downloadArticleImages(state, context)
    local post = state.selected_post
    if not post then return end
    if #markdownImagePaths(post.markdown or "") == 0 then state.status = _("This post has no managed images."); requestRebuild(context); return end
    runNetwork(state, context, _("Loading grayscale images…"), function()
        local loaded, last_err, total = cachePostImagesNow(state, post)
        state.status = loaded > 0 and string.format(_("%d of %d image(s) loaded."), loaded, total) or (last_err or _("No images could be cached."))
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

postPreview = function(post, width_chars)
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

local InkLogo = WidgetContainer:extend{ width = nil, height = nil, dimen = nil, color = nil }
function InkLogo:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function InkLogo:paintTo(bb, x, y)
    if not bb or type(bb.paintRect) ~= "function" then return end
    local size = math.max(8, math.min(self.width, self.height))
    local factor = size / 64
    local start_x, start_y = x + math.floor((self.width - size) / 2), y + math.floor((self.height - size) / 2)
    local color = self.color or C.INK_BLUE
    -- Horizontal runs keep e-ink painting quiet; ceil() on both edges avoids seams when scaled.
    for row_index, row in ipairs(LOGO_ROWS) do
        local top = math.floor((row_index - 1) * factor)
        local row_h = math.max(1, math.ceil(row_index * factor) - top)
        local column = 1
        while column <= 64 do
            local first = row:find("1", column, true)
            if not first then break end
            local last = first
            while last < 64 and row:sub(last + 1, last + 1) == "1" do last = last + 1 end
            local left = math.floor((first - 1) * factor)
            bb:paintRect(start_x + left, start_y + top, math.max(1, math.ceil(last * factor) - left), row_h, color)
            column = last + 1
        end
    end
end

-- The ink drop with water-like ripples: InkBlog's signature on every quiet page.
Ink.Drop = WidgetContainer:extend{ width = nil, height = nil, dimen = nil, color = nil }

function Ink.Drop:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local size = math.min(self.width, self.height)
    self.logo_size = math.max(8, math.floor(size * .5))
    self.logo = InkLogo:new{ width = self.logo_size, height = self.logo_size, color = self.color }
end

function Ink.Drop:paintTo(bb, x, y)
    if not bb then return end
    local size = math.min(self.width, self.height)
    local cx, cy = x + math.floor(self.width / 2), y + math.floor(self.height / 2)
    if type(bb.paintCircle) == "function" then
        local outer = math.floor(size / 2) - 1
        local inner = math.floor(self.logo_size / 2) + math.max(2, scale(3))
        if outer > inner + 2 then
            local middle = inner + math.floor((outer - inner) * .5)
            pcall(bb.paintCircle, bb, cx, cy, inner, C.PARCHMENT, math.max(1, scale(2)))
            pcall(bb.paintCircle, bb, cx, cy, middle, C.PAPER_CARD, math.max(1, scale(1)))
            pcall(bb.paintCircle, bb, cx, cy, outer, C.PAPER_CARD, math.max(1, scale(1)))
        end
    end
    local half = math.floor(self.logo_size / 2)
    self.logo:paintTo(bb, cx - half, cy - half)
end

local function centerText(layer, text, x, y, width, size, options)
    options = options or {}
    local font_size = math.max(14, math.floor(tonumber(size) or 14))
    local role = Ink.role(options)
    local widget = TextWidget:new{ text = tostring(text or ""), face = Ink.face(role, font_size), fgcolor = options.color or C.INK_BLUE, bold = role == "sans" and options.bold == true, max_width = math.max(1, width) }
    local measured, text_width = pcall(function() return widget:getSize().w end)
    text_width = measured and tonumber(text_width) or width
    widget.overlap_offset = { x + math.max(0, math.floor((width - text_width) / 2)), y }
    layer[#layer + 1] = widget
end

-- Friendly empty page: an ink drop sending out ripples, a serif headline, a
-- small fleuron and one quiet italic sentence.
local function addEmptyState(layer, x, y, w, h, title, text, px)
    local cursor = y + px(4)
    local drop_size = (h >= px(104) + px(112)) and px(104) or ((h >= px(72) + px(96)) and px(72) or nil)
    if drop_size then
        local drop = Ink.Drop:new{ width = drop_size, height = drop_size, color = C.PARCHMENT }
        drop.overlap_offset = { x + math.floor((w - drop_size) / 2), cursor }
        layer[#layer + 1] = drop
        cursor = cursor + drop_size + px(8)
    end
    centerText(layer, title, x, cursor, w, px(19), { role = "display" })
    cursor = cursor + px(30)
    if y + h - cursor >= px(48) then
        Ink.ornament(layer, "fleuron", x + math.floor(w * .2), cursor, math.floor(w * .6), px(9))
        cursor = cursor + px(16)
    end
    local remaining = y + h - cursor
    if remaining >= px(20) then
        addBox(layer, text, x + px(6), cursor, math.max(1, w - px(12)), remaining, px(13), { role = "italic", bg = C.PAPER, color = C.SEPIA, alignment = "center" })
    end
end

local function buildBase(width, height)
    local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
    local layer = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false }
    layer[#layer + 1] = FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = C.PAPER, CenterContainer:new{ dimen = pane.dimen, HorizontalSpan:new{ width = 0 } } }
    pane[1] = layer
    return pane, layer
end

-- Masthead: ink drop, a two-voice wordmark ("Ink" italic, "Blog" bold), an
-- inked stamp with the current section, and a newspaper double rule below.
local function addHeader(layer, state, width, px, label)
    local margin, logo_size = px(12), math.max(px(32), 48)
    local logo = InkLogo:new{ width = logo_size, height = logo_size }
    logo.overlap_offset = { margin, px(1) }
    layer[#layer + 1] = logo
    local word_x = margin + logo_size + px(6)
    local room = math.max(1, width - word_x - margin)
    local ink = TextWidget:new{ text = "Ink", face = Ink.face("italic", px(24)), fgcolor = C.INK_BLUE, max_width = room }
    local ink_w = Ink.measure(ink, px(34), px(24))
    ink.overlap_offset = { word_x, 0 }
    layer[#layer + 1] = ink
    addText(layer, "Blog", word_x + ink_w + px(1), 0, math.max(1, room - ink_w - px(1)), px(24), { role = "display" })
    addText(layer, _("Write in ink. Read in peace."), word_x, px(30), room, px(10), { role = "italic", color = C.SEPIA })
    if label and label ~= "" then
        local tag = TextWidget:new{ text = tostring(label):upper(), face = Ink.face("sans", math.max(14, px(10))), fgcolor = C.PAPER, bold = true, max_width = math.floor(width * .34) }
        local tag_w, tag_h = Ink.measure(tag, px(60), px(18))
        local pad_x = px(7)
        local stamp_w, stamp_h = tag_w + pad_x * 2, math.max(px(22), tag_h + px(4))
        local stamp_x, stamp_y = width - margin - stamp_w, px(9)
        addRule(layer, stamp_x, stamp_y, stamp_w, stamp_h, C.INK_BLUE)
        tag.overlap_offset = { stamp_x + pad_x, stamp_y + math.floor((stamp_h - tag_h) / 2) }
        layer[#layer + 1] = tag
    end
    local thick = math.max(2, scale(2))
    local rule_y = px(44)
    addRule(layer, margin, rule_y, width - 2 * margin, thick, C.INK_BLUE)
    addRule(layer, margin, rule_y + thick + math.max(2, scale(1)), width - 2 * margin, 1, C.INK_BLUE)
end

local function addStatus(layer, state, width, y, px)
    local prefix = state.loading and _("Working · ") or ""
    Ink.ornament(layer, "dots", px(12), y - px(4), width - px(24), px(3))
    addText(layer, prefix .. tostring(state.status or ""), px(12), y, width - px(24), px(10), { role = "italic", color = C.SEPIA })
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

-- Flat tab bar under a heavy rule; the current section is a solid ink block.
local function addNavigation(layer, state, context, width, height, px)
    local margin, nav_height = px(8), px(44)
    local y = height - nav_height - px(6)
    local unread = 0
    for _, note in ipairs(state.notifications or {}) do
        if type(note) == "table" and not note.read_at then unread = unread + 1 end
    end
    local alerts_label = unread > 0 and (_("Alerts") .. " · " .. math.min(unread, 99)) or _("Alerts")
    local labels = { { "feed", _("Feed") }, { "discover", _("Discover") }, { "write", _("Write") }, { "profile", _("Profile") }, { "notifications", alerts_label } }
    local active = state.view
    if active == "mine" or active == "drafts" then
        active = "profile"
    elseif active == "article" or active == "author" then
        active = (state.mode == "discover" and "discover") or (state.mode == "feed" and "feed") or (state.mode == "mine" and "profile") or nil
    end
    local total = width - margin * 2
    local button_width = math.floor(total / 5)
    addRule(layer, margin, y - px(4), total, math.max(2, scale(2)), C.INK_BLUE)
    for index, entry in ipairs(labels) do
        addButton(layer, entry[2], margin + (index - 1) * button_width, y, button_width, nav_height, function() navTo(state, context, entry[1]) end, active == entry[1], nil, false, { variant = "tab" })
    end
end

local function addPagination(layer, state, context, page, total, width, y, px, setter, can_previous, label)
    local margin, gap, height = px(12), px(6), px(44)
    local usable = width - 2 * margin
    local side = label and math.floor((usable - 2 * gap) * .34) or math.floor((usable - gap) / 2)
    addButton(layer, _("‹ Previous"), margin, y, side, height, function() setter(page - 1); requestRebuild(context) end, false, nil, page <= 1 and not can_previous)
    if label then
        centerText(layer, label, margin + side + gap, y + px(12), usable - 2 * side - 2 * gap, px(14), { serif = true, bold = true, color = C.SEPIA })
        addButton(layer, _("Next ›"), margin + usable - side, y, side, height, function() setter(math.min(total, page + 1)); requestRebuild(context) end, false, nil, page >= total)
    else
        addButton(layer, _("Next ›"), margin + side + gap, y, side, height, function() setter(math.min(total, page + 1)); requestRebuild(context) end, false, nil, page >= total)
    end
end

local function renderPostList(layer, state, context, width, top, bottom, px, title)
    local margin, gap = px(12), px(4)
    local compact = bottom - top < px(200)
    local function reload() listPosts(state, context, state.mode, state.mode == "blog" and state.selected_author_id or nil) end
    addText(layer, title, margin, top, width - 2 * margin, px(18), { role = "display" })
    Ink.textRight(layer, Ink.dateline(), width - margin, top + px(3), math.floor((width - 2 * margin) * .6), px(10), { color = C.SEPIA })
    if compact then
        local row_y, row_h, side, g = top + px(24), px(38), px(56), px(5)
        local middle = width - 2 * margin - 2 * side - 2 * g
        local current = state.list_page or 0
        addButton(layer, "‹", margin, row_y, side, row_h, function() state.list_page = math.max(0, current - 1); requestRebuild(context) end, false, nil, current <= 0)
        addButton(layer, _("Refresh"), margin + side + g, row_y, middle, row_h, reload, true)
        addButton(layer, "›", margin + side + g + middle + g, row_y, side, row_h, function() state.list_page = math.min(#state.posts - 1, current + 1); requestRebuild(context) end, false, nil, current >= #state.posts - 1)
        local y = row_y + row_h + gap
        local remaining = bottom - y
        if #state.posts == 0 then
            addEmptyState(layer, margin, y, width - 2 * margin, math.max(1, remaining), _("Nothing here yet"), _("Tap Refresh to fetch posts. The network is only used after that action."), px)
        else
            local post = state.posts[clamp(current + 1, 1, #state.posts)]
            if type(post) == "table" and validUuid(post.id) then
                addPostPreviewCard(layer, state, context, post, margin, y, width - 2 * margin, math.max(1, math.min(px(104), remaining)), px)
            end
        end
        return
    end
    local toolbar_y, toolbar_h, g = top + px(26), px(38), px(5)
    local third = math.floor((width - 2 * margin - 2 * g) / 3)
    local function setSort(value)
        if state.settings.sort ~= value then state.settings.sort = value; saveSettings(state.settings) end
        reload()
    end
    addButton(layer, _("Newest"), margin, toolbar_y, third, toolbar_h, function() setSort("newest") end, state.settings.sort ~= "popular")
    addButton(layer, _("Popular"), margin + third + g, toolbar_y, third, toolbar_h, function() setSort("popular") end, state.settings.sort == "popular")
    addButton(layer, _("Refresh"), margin + 2 * (third + g), toolbar_y, width - margin - (margin + 2 * (third + g)), toolbar_h, reload, false)
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
        addEmptyState(layer, margin, y, width - 2 * margin, math.max(px(62), available), _("Nothing here yet"), _("Tap Refresh to fetch posts. The network is only used after that action."), px)
    else
        for index = first, math.min(#state.posts, first + per_page - 1) do
            local post = state.posts[index]
            if type(post) == "table" and validUuid(post.id) then
                addPostPreviewCard(layer, state, context, post, margin, y, width - 2 * margin, card_height, px)
                y = y + card_height + gap
            end
        end
    end
    addPagination(layer, state, context, page, total, width, bottom - px(44), px, function(value)
        if value > local_total then changePostBatch(state, context, (state.list_offset or 0) + PAGE_SIZE)
        elseif value < 1 and (state.list_offset or 0) > 0 then changePostBatch(state, context, state.list_offset - PAGE_SIZE)
        else state.list_page = clamp(value - 1, 0, local_total - 1) end
    end, (state.list_offset or 0) > 0)
end

-- The first letter of the opening paragraph becomes an "illuminated" initial:
-- reversed white serif on an ink-black square.  Only real letters qualify.
function Ink.dropCap(text)
    local plain = trim(plainInlineText(text))
    local first = plain:byte(1)
    if not first then return nil end
    local letter = (first >= 65 and first <= 90) or (first >= 97 and first <= 122)
        or (first >= 0xC3 and first <= 0xDF) or (first >= 0xE3 and first <= 0xED)
    if not letter then return nil end
    local stop = utf8Next(plain, 1) - 1
    local initial, rest = plain:sub(1, stop), plain:sub(stop + 1)
    if rest == "" then return nil end
    if first < 128 then initial = initial:upper() end
    return initial, rest
end

-- Layout hints (hanging indents, markers, drop cap) are attached after
-- markdownBlocks so that parser output stays a plain, stable structure.
function Ink.decorate(blocks, px, allow_cap)
    local capped = not allow_cap
    for index, block in ipairs(blocks or {}) do
        if block.kind == "list" then
            local marker, rest = tostring(block.text or ""):match("^(%S+)%s+(.*)$")
            if marker and rest then block.marker, block.text, block.indent = marker, rest, px(18) end
        elseif block.kind == "quote" then
            block.indent = px(28)
        elseif block.kind == "code" then
            block.indent = px(10)
        elseif block.kind == "paragraph" and not capped and index <= 2 then
            capped = true
            local initial, rest = Ink.dropCap(block.text)
            if initial then block.drop, block.text, block.indent, block.min_lines = initial, rest, px(42) + px(10), 2 end
        end
    end
    return blocks
end

-- Draw one page of blocks; returns the y just below the last drawn block.
local function renderFallbackBlocks(layer, blocks, x, y, width, height, px, state)
    local cursor = y
    for _, block in ipairs(blocks or {}) do
        local kind = block.kind or "paragraph"
        local size = blockFontSize(block, px)
        local chars_per_line = Ink.cpl(block, width, px)
        local lines = measureBlockLines(block, width, px, chars_per_line)
        local h = math.max(px(20), lines * math.max(px(17), math.floor(size * 1.35)) + px(5))
        local top_gap = (kind == "heading" and cursor > y) and px(6) or 0
        if cursor + top_gap + h > y + height then break end
        cursor = cursor + top_gap
        if kind == "image" then
            local box_h = math.max(1, h - px(5))
            local cached = state and state.image_cache and state.image_cache[block.path]
            local drawn = false
            if cached and cached.file and ok_image and ImageWidget then
                local created, holder = pcall(function()
                    local picture = ImageWidget:new{ file = cached.file, width = width, height = box_h, scale_factor = 0, dither = true, file_do_cache = false }
                    return CenterContainer:new{ dimen = Geom:new{ w = width, h = box_h }, picture }
                end)
                if created and holder then
                    holder.overlap_offset = { x, cursor }
                    layer[#layer + 1] = holder
                    drawn = true
                end
            end
            if not drawn then
                addBox(layer, "[" .. _("Image") .. ": " .. (block.alt ~= "" and block.alt or "…") .. "]", x, cursor, width, box_h, size, { role = "italic", color = C.SEPIA, bg = C.PAPER, line_height = .30 })
            end
            cursor = cursor + h + px(5)
        else
        local indent = tonumber(block.indent) or 0
        local role = kind == "heading" and "display" or (kind == "code" and "mono" or (kind == "quote" and "italic" or "serif"))
        local options = { role = role, color = kind == "quote" and C.SEPIA or C.INK_BLUE, bg = kind == "code" and C.PAPER_CARD or C.PAPER, line_height = .30 }
        if kind == "quote" then
            addText(layer, "“", x, cursor - px(8), indent, px(38), { role = "display", color = C.PARCHMENT })
        elseif kind == "code" then
            addRule(layer, x, cursor, math.max(2, px(3)), h, C.INK_BLUE)
        elseif block.marker then
            addText(layer, block.marker, x + px(2), cursor, indent, size, { role = "display" })
        elseif block.drop then
            local cap = px(42)
            local cap_box = FrameContainer:new{ width = cap, height = cap, padding = 0, bordersize = 0, background = C.INK_BLUE,
                CenterContainer:new{ dimen = Geom:new{ w = cap, h = cap }, TextWidget:new{ text = block.drop, face = Ink.face("display", px(30)), fgcolor = C.PAPER, max_width = cap } } }
            cap_box.overlap_offset = { x, cursor + px(3) }
            layer[#layer + 1] = cap_box
        end
        addBox(layer, plainInlineText(block.text), x + indent, cursor, math.max(1, width - indent), h, size, options)
        cursor = cursor + h + px(5)
        end
    end
    return cursor
end

local function renderArticle(layer, state, context, width, top, bottom, px)
    local post = state.selected_post
    local margin, gap = px(12), px(6)
    if type(post) ~= "table" or not validUuid(post.id) then
        state.selected_post = nil
        state.view = state.mode == "blog" and "author" or "feed"
        state.status = _("That post is unavailable; returned to the list.")
        return
    end
    local compact = bottom - top < px(300)
    local profile = authorProfileFor(post)
    local when = fmtDate(post.published_at)
    if when == "" then when = fmtDate(post.created_at) end
    local avatar_size = px(compact and 38 or 46)
    local byline_x = margin + avatar_size + px(10)
    local byline_w = width - margin - byline_x
    local avatar_y, head_h
    -- The title wraps over as many lines as its real pixel width needs (any
    -- screen size); only an extreme title is capped to a third of the pane.
    local title_text = postTitleFor(post)
    local title_line_h = math.max(px(17), math.floor(px(20) * 1.35))
    local title_lines = Ink.countLines({ kind = "heading", level = 2, text = title_text }, title_text, width - 2 * margin, px)
    title_lines = math.max(1, math.min(title_lines, math.floor((bottom - top) * 0.35 / title_line_h)))
    local title_h = title_lines * title_line_h
    addBox(layer, title_text, margin, top, width - 2 * margin, title_h, px(20), { role = "display", bg = C.PAPER, line_height = .20 })
    avatar_y = top + title_h + px(6)
    head_h = title_h + px(6) + (compact and px(44) or px(60))
    local avatar = avatarWidget(profile, state, avatar_size)
    avatar.inkblog_avatar_path, avatar.inkblog_avatar_owner = profile.avatar_path, profile.id
    avatar.overlap_offset = { margin, avatar_y }
    layer[#layer + 1] = avatar
    local minutes = Ink.minutes(post.markdown)
    local dateline = when .. ((when ~= "" and minutes > 0) and " · " or "") .. (minutes > 0 and (minutes .. " min read") or "")
    addText(layer, profile.display_name, byline_x, avatar_y + px(2), byline_w, px(15), { role = "display" })
    addText(layer, dateline, byline_x, avatar_y + px(compact and 20 or 25), byline_w, px(11), { role = "italic", color = C.SEPIA })
    if compact then
        Ink.ornament(layer, "dots", margin, top + head_h - px(4), width - 2 * margin, px(2))
    else
        Ink.ornament(layer, "fleuron", margin, top + head_h - px(12), width - 2 * margin, px(8))
    end

    local actions_y, action_h = top + head_h, px(44)
    local w4 = math.floor((width - 2 * margin - 3 * gap) / 4)
    addButton(layer, _("‹ Back"), margin, actions_y, w4, action_h, function() state.view = state.mode == "blog" and "author" or "feed"; requestRebuild(context) end)
    addButton(layer, post.liked and _("Blot ✓") or _("Blot"), margin + (w4 + gap), actions_y, w4, action_h, function() toggleLike(state, context, post, "post") end, post.liked)
    addButton(layer, _("Notes"), margin + 2 * (w4 + gap), actions_y, w4, action_h, function()
        if compact and state.article_tab == "comments" then state.article_tab = "read"; requestRebuild(context); return end
        state.article_tab = "comments"; loadComments(state, context, post.id)
    end)
    local author_action = addButton(layer, ownPost(state, post) and _("Delete") or _("Author"), margin + 3 * (w4 + gap), actions_y, w4, action_h, function()
        if ownPost(state, post) then confirmDeletePost(state, context, post) else loadAuthor(state, context, post.author_id) end
    end)
    if author_action then author_action.inkblog_action = ownPost(state, post) and "delete_post" or "open_author_profile" end
    local content_y = actions_y + action_h + px(7)
    if not compact then
        local row2_y = actions_y + action_h + gap
        local half = math.floor((width - 2 * margin - gap) / 2)
        addButton(layer, state.article_tab == "comments" and _("Read") or _("Load images"), margin, row2_y, half, action_h, function()
            if state.article_tab == "comments" then state.article_tab = "read"; requestRebuild(context) else downloadArticleImages(state, context) end
        end)
        addButton(layer, ownPost(state, post) and _("Edit") or _("Report"), margin + half + gap, row2_y, half, action_h, function()
            if ownPost(state, post) then editPost(state, context, post) else promptReport(state, context, post, "post") end
        end, ownPost(state, post))
        content_y = row2_y + action_h + px(7)
    end
    local content_h = math.max(1, bottom - px(52) - content_y)
    if state.article_tab == "comments" then
        -- Entry point for new top-level notes (replies live in the note menu).
        local note_h = px(44)
        addButton(layer, _("+ Write a margin note"), margin, content_y, width - 2 * margin, note_h, function()
            promptComment(state, context, nil)
        end, true)
        content_y = content_y + note_h + px(7)
        content_h = math.max(1, content_h - note_h - px(7))
        local comments = state.comments or {}
        local card_h = math.max(px(60), math.floor(content_h / 3))
        local per_page = math.max(1, math.floor(content_h / (card_h + gap)))
        local local_total = math.max(1, math.ceil(#comments / per_page))
        local total = local_total + (state.comments_has_more and 1 or 0)
        local page = clamp((state.comment_page or 0) + 1, 1, total)
        local y = content_y
        if #comments == 0 then
            addEmptyState(layer, margin, y, width - 2 * margin, math.max(px(62), content_h), _("No margin notes yet"), _("Tap Notes again to load them, or leave the first one."), px)
        end
        for index = (page - 1) * per_page + 1, math.min(#comments, page * per_page) do
            local comment = comments[index]
            local inset = comment.parent_id and px(16) or 0
            local stamp = fmtDate(comment.created_at)
            local likes = math.max(0, math.floor(tonumber(comment.like_count) or 0))
            local meta = (stamp ~= "" and (stamp .. " · ") or "") .. likes .. (likes == 1 and " blot" or " blots") .. (comment.parent_id and " · reply" or "")
            if comment.parent_id then addRule(layer, margin + px(4), y, px(2), card_h, C.PARCHMENT) end
            addEntry(layer, state, context, margin + inset, y, width - 2 * margin - inset, card_h, {
                title = displayNameFor(comment.display_name, _("Reader")), meta = meta,
                excerpt = plainInlineText(textField(comment.body, 600)),
                callback = function() promptCommentActions(state, context, comment) end,
            }, px)
            y = y + card_h + gap
        end
        addPagination(layer, state, context, page, total, width, bottom - px(44), px, function(value)
            if value > local_total then changeCommentBatch(state, context, (state.comment_offset or 0) + COMMENT_SIZE)
            elseif value < 1 and (state.comment_offset or 0) > 0 then changeCommentBatch(state, context, state.comment_offset - COMMENT_SIZE)
            else state.comment_page = clamp(value - 1, 0, local_total - 1) end
        end, (state.comment_offset or 0) > 0)
    else
        local blocks = Ink.decorate(markdownBlocks(post.markdown or ""), px, content_h >= px(180))
        local pages = paginateBlocks(blocks, width - 2 * margin, content_h, px)
        state.article_page = clamp(state.article_page or 1, 1, #pages)
        local page_blocks = pages[state.article_page]
        -- Keep article pages on the same KOReader TextBoxWidget path as the rest
        -- of the DApp. HtmlBoxWidget can fail later during pane painting on
        -- some AppDock/KOReader hosts, outside the constructor's pcall boundary.
        local cursor = renderFallbackBlocks(layer, page_blocks, margin, content_y, width - 2 * margin, content_h, px, state)
        -- The last page ends with a colophon: three diamonds and the author's name.
        if state.article_page == #pages and cursor and cursor + px(46) <= content_y + content_h then
            Ink.ornament(layer, "trio", margin, cursor + px(8), width - 2 * margin, px(10))
            centerText(layer, "— " .. profile.display_name, margin, cursor + px(24), width - 2 * margin, px(13), { role = "italic", color = C.SEPIA })
        end
        -- Reading progress: an ink rule that grows across a pale track.
        local track_w, rule_h = width - 2 * margin, math.max(2, scale(2))
        addRule(layer, margin, bottom - px(49), track_w, rule_h, C.PAPER_CARD)
        addRule(layer, margin, bottom - px(49), math.max(rule_h, math.floor(track_w * state.article_page / #pages)), rule_h, C.INK_BLUE)
        addPagination(layer, state, context, state.article_page, #pages, width, bottom - px(44), px, function(value) state.article_page = value end, false, state.article_page .. " / " .. #pages)
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
    addText(layer, _("New post"), margin, top, width - 2 * margin, px(18), { serif = true, bold = true })
    local compact = bottom - top < px(400)
    local actions_h = px(compact and 40 or 44)
    local actions_y = bottom - actions_h - px(6)
    local half = math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, _("Save draft"), margin, actions_y, half, actions_h, function() syncEditor(state, context, false) end)
    addButton(layer, _("Publish"), margin + half + gap, actions_y, half, actions_h, function() syncEditor(state, context, true) end, true)

    local label_w = math.floor((width - 2 * margin) * .55)
    local title_label_y = top + px(26)
    local title_y = title_label_y + px(17)
    local title_h = px(compact and 36 or 44)
    addText(layer, _("TITLE · TAP TO EDIT"), margin, title_label_y, width - 2 * margin, px(10), { bold = true, color = C.SEPIA })
    local title = trim(state.editor.title or "")
    local title_field = addButton(layer, _("Title"), margin, title_y, width - 2 * margin, title_h,
        function() openEditorField(state, context, "title") end, false,
        title ~= "" and title or _("Give your post a title …"), false, { serif = true })
    if title_field then title_field.inkblog_editor_field = "title" end

    local body_label_y = title_y + title_h + px(7)
    local body_y = body_label_y + px(17)
    local marks_h = compact and 0 or px(40)
    local marks_y = actions_y - (compact and px(7) or marks_h + px(8))
    local body_bottom = marks_y - px(7)
    local body_h = math.max(px(56), body_bottom - body_y)
    local body = tostring(state.editor.body or "")
    addText(layer, _("TEXT · MARKDOWN"), margin, body_label_y, label_w, px(10), { bold = true, color = C.SEPIA })
    addText(layer, string.format(_("%d words · %.1f / 96 KiB"), Ink.words(body), #body / 1024), margin + label_w, body_label_y, width - 2 * margin - label_w, px(10), { color = C.SEPIA })
    local body_preview
    if body == "" then
        body_preview = _("Tap here and write, one line at a time …")
    else
        local head, tail = utf8Cut(body, compact and 220 or 700)
        body_preview = head .. (tail ~= "" and "\n…" or "")
    end
    local body_field = addButton(layer, _("Edit text"), margin, body_y, width - 2 * margin, body_h,
        function() openEditorField(state, context, "body") end, false, body_preview, false, { serif = true })
    if body_field then body_field.inkblog_editor_field = "body" end

    if not compact then
        local marks = { { "H", "heading" }, { "B", "bold" }, { "I", "italic" }, { "List", "list" }, { "Quote", "quote" }, { "Code", "code" }, { "Link", "link" }, { "Image", "image" } }
        local mark_w = math.max(px(42), math.floor((width - 2 * margin - (#marks - 1) * gap) / #marks))
        for index, mark in ipairs(marks) do
            addButton(layer, mark[1], margin + (index - 1) * (mark_w + gap), marks_y, mark_w, marks_h, function()
                if mark[2] == "image" then promptPostImage(state, context) else insertFormat(state, context, mark[2]) end
            end)
        end
    end
end

local function renderProfile(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(7)
    if state.session.user.id == "" then
        local buttons_h = px(44) * 2 + gap
        addEmptyState(layer, margin, top, width - 2 * margin, math.max(px(60), bottom - top - buttons_h - px(10)), _("Welcome to InkBlog"),
            _("InkBlog uses the TBS account already signed in on this reader. Your profile is created automatically — no extra password, no email registration."), px)
        local y = bottom - buttons_h
        addButton(layer, _("Use TBS account"), margin, y, width - 2 * margin, px(44), function() loadOwnProfile(state, context) end, true)
        addButton(layer, _("Existing InkBlog email account"), margin, y + px(44) + gap, width - 2 * margin, px(44), function() promptCredentials(state, context, false) end)
        return
    end
    local profile = state.profile or { id = state.session.user.id, display_name = state.session.user.email:match("^([^@]+)") or _("Reader"), bio = _("Tap Edit profile to add a bio.") }
    local avatar = avatarWidget(profile, state, px(58)); avatar.overlap_offset = { margin, top }; layer[#layer + 1] = avatar
    local text_x = margin + px(70)
    addText(layer, profile.display_name or _("Reader"), text_x, top + px(2), width - margin - text_x, px(20), { serif = true, bold = true })
    addBox(layer, textField(profile.bio, 300), text_x, top + px(30), width - margin - text_x, px(34), px(12), { role = "italic", bg = C.PAPER, color = C.SEPIA })
    local buttons_y, half = top + px(70), math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, _("Edit profile"), margin, buttons_y, half, px(44), function() promptProfileEdit(state, context) end)
    addButton(layer, _("Avatar"), margin + half + gap, buttons_y, half, px(44), function() promptAvatarUpload(state, context) end)
    addButton(layer, _("Load avatar"), margin, buttons_y + px(51), half, px(44), function() downloadAvatar(state, context, profile) end)
    addButton(layer, _("Sign out"), margin + half + gap, buttons_y + px(51), half, px(44), function() logout(state, context) end)
    local below = buttons_y + px(112)
    addRule(layer, margin, below - px(6), width - 2 * margin, 1, C.PARCHMENT)
    addText(layer, _("Your ink"), margin, below, width - 2 * margin, px(17), { serif = true, bold = true })
    local item_w = math.floor((width - 2 * margin - gap) / 2)
    addButton(layer, _("My posts"), margin, below + px(26), item_w, px(44), function() state.view = "mine"; listPosts(state, context, "mine", nil) end, true)
    addButton(layer, string.format(_("Drafts (%d)"), #state.drafts), margin + item_w + gap, below + px(26), item_w, px(44), function() state.view = "drafts"; state.list_page = 0; requestRebuild(context) end)
    if state.pending_image_path then addText(layer, _("Image handover ready: ") .. state.pending_image_path:match("([^/]+)$"), margin, below + px(79), width - 2 * margin, px(10), { color = C.SEPIA }) end
end

local function renderDrafts(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(4)
    addText(layer, _("Local drafts"), margin, top, width - 2 * margin, px(18), { serif = true, bold = true })
    addButton(layer, _("‹ Profile"), margin, top + px(26), width - 2 * margin, px(40), function() state.view = "profile"; requestRebuild(context) end)
    local y0 = top + px(26) + px(40) + gap
    local available = bottom - y0 - px(52)
    local card_h = math.max(px(60), math.floor(available / 3))
    local per_page = math.max(1, math.floor(available / (card_h + gap)))
    local total = math.max(1, math.ceil(#state.drafts / per_page))
    local page = clamp((state.list_page or 0) + 1, 1, total)
    state.list_page = page - 1
    if #state.drafts == 0 then
        addEmptyState(layer, margin, y0, width - 2 * margin, math.max(px(62), available), _("No local drafts"), _("A post that fails to publish is always kept here, ready for another try."), px)
    end
    local y = y0
    for index = (page - 1) * per_page + 1, math.min(#state.drafts, page * per_page) do
        local draft = state.drafts[index]
        local stamp = fmtDate(draft.updated_at)
        addEntry(layer, state, context, margin, y, width - 2 * margin, card_h, {
            title = draft.title ~= "" and draft.title or _("Untitled"),
            meta = (stamp ~= "" and (stamp .. " · ") or "") .. (validUuid(draft.remote_id) and _("saved to InkBlog") or _("on this reader only")),
            excerpt = postPreview({ markdown = draft.body }, 120),
            callback = function() editDraft(state, context, draft) end,
        }, px)
        y = y + card_h + gap
    end
    if total > 1 then
        addPagination(layer, state, context, page, total, width, bottom - px(44), px, function(value) state.list_page = clamp(value - 1, 0, total - 1) end, false, page .. " / " .. total)
    end
end

local function renderAuthor(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(7)
    local compact = bottom - top < px(300)
    local profile = state.author_profile or { id = state.selected_author_id, display_name = _("Author"), bio = _("Tap Refresh to fetch this blog.") }
    local avatar_size = px(compact and 38 or 54)
    local avatar = avatarWidget(profile, state, avatar_size); avatar.overlap_offset = { margin, top }; layer[#layer + 1] = avatar
    local profile_left = margin + avatar_size + px(10)
    addText(layer, profile.display_name or _("Author"), profile_left, top + px(2), width - margin - profile_left, px(18), { serif = true, bold = true })
    addText(layer, textField(profile.bio, 200), profile_left, top + px(27), width - margin - profile_left, px(10), { role = "italic", color = C.SEPIA })
    local half = math.floor((width - 2 * margin - gap) / 2)
    local actions_y, actions_h = top + px(compact and 45 or 62), px(compact and 40 or 44)
    addButton(layer, profile.followed and _("Following ✓") or _("Follow"), margin, actions_y, half, actions_h, function() toggleFollow(state, context) end, profile.followed)
    addButton(layer, profile.blocked and _("Blocked ✓") or _("Block"), margin + half + gap, actions_y, half, actions_h, function() toggleBlock(state, context) end, profile.blocked)
    if compact then
        renderPostList(layer, state, context, width, actions_y + actions_h + px(9), bottom, px, _("Posts"))
        return
    end
    addButton(layer, _("Load avatar"), margin, top + px(113), width - 2 * margin, px(44), function() downloadAvatar(state, context, profile) end)
    renderPostList(layer, state, context, width, top + px(164), bottom, px, _("Posts"))
end

local function notificationTitle(kind)
    local text = tostring(kind or ""):lower()
    if text:find("like", 1, true) or text:find("blot", 1, true) then return _("Someone left a blot on your writing") end
    if text:find("repl", 1, true) then return _("Someone replied to a margin note") end
    if text:find("comment", 1, true) or text:find("note", 1, true) then return _("New margin note on your post") end
    if text:find("follow", 1, true) then return _("You have a new follower") end
    if text:find("post", 1, true) then return _("A blog you follow has new ink") end
    return text ~= "" and (text:sub(1, 1):upper() .. text:sub(2)) or _("Activity")
end

local function renderNotifications(layer, state, context, width, top, bottom, px)
    local margin, gap = px(12), px(4)
    addText(layer, _("Notifications"), margin, top, width - 2 * margin, px(18), { serif = true, bold = true })
    addButton(layer, _("Refresh"), margin, top + px(26), width - 2 * margin, px(40), function() loadNotifications(state, context) end, true)
    local y0 = top + px(26) + px(40) + gap
    local available = bottom - y0 - px(52)
    local card_h = math.max(px(52), math.floor(available / 4))
    local per_page = math.max(1, math.floor(available / (card_h + gap)))
    local total = math.max(1, math.ceil(#state.notifications / per_page))
    local page = clamp((state.list_page or 0) + 1, 1, total)
    state.list_page = page - 1
    if #state.notifications == 0 then
        addEmptyState(layer, margin, y0, width - 2 * margin, math.max(px(62), available), _("All quiet"), _("No notifications cached. Tap Refresh to check InkBlog."), px)
    end
    local y = y0
    for index = (page - 1) * per_page + 1, math.min(#state.notifications, page * per_page) do
        local note = state.notifications[index]
        local stamp = fmtDate(note.created_at)
        addEntry(layer, state, context, margin, y, width - 2 * margin, card_h, {
            title = notificationTitle(note.kind),
            meta = (stamp ~= "" and stamp or "") .. (note.read_at and "" or (stamp ~= "" and " · new" or "new")),
            unread = not note.read_at,
            callback = function() openNotification(state, context, note) end,
        }, px)
        y = y + card_h + gap
    end
    if total > 1 then
        addPagination(layer, state, context, page, total, width, bottom - px(44), px, function(value) state.list_page = clamp(value - 1, 0, total - 1) end, false, page .. " / " .. total)
    end
end

local function buildPane(instance, context)
    applyPalette(context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local pane, layer = buildBase(width, height)
    layer._inkblog_state, layer._inkblog_context = state, context
    local top, nav_space = px(52), px(56)
    local bottom = height - nav_space - px(20)
    if state.view == "article" and (type(state.selected_post) ~= "table" or not validUuid(state.selected_post.id)) then
        state.selected_post = nil
        state.view = state.mode == "blog" and "author" or "feed"
        state.status = _("That post is unavailable; returned to the list.")
    end
    local VIEW_LABELS = { feed = _("Feed"), discover = _("Discover"), write = _("Write"), profile = _("Profile"), drafts = _("Drafts"), mine = _("My posts"), author = _("Author"), notifications = _("Alerts"), article = _("Reading") }
    addHeader(layer, state, width, px, VIEW_LABELS[state.view] or "")
    if state.view == "feed" then renderPostList(layer, state, context, width, top, bottom, px, _("Feed"))
    elseif state.view == "discover" then renderPostList(layer, state, context, width, top, bottom, px, _("Discover"))
    elseif state.view == "write" then renderWrite(layer, state, context, width, top, bottom, px)
    elseif state.view == "profile" then renderProfile(layer, state, context, width, top, bottom, px)
    elseif state.view == "drafts" then renderDrafts(layer, state, context, width, top, bottom, px)
    elseif state.view == "mine" then renderPostList(layer, state, context, width, top, bottom, px, _("My posts"))
    elseif state.view == "author" then renderAuthor(layer, state, context, width, top, bottom, px)
    elseif state.view == "notifications" then renderNotifications(layer, state, context, width, top, bottom, px)
    elseif state.view == "article" then renderArticle(layer, state, context, width, top, bottom, px)
    else state.view = "feed"; renderPostList(layer, state, context, width, top, bottom, px, _("Feed")) end
    addStatus(layer, state, width, height - nav_space - px(17), px)
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
    state.status = _("Image handover is ready. Open Write or Profile to upload it.")
    return true
end

return {
    id = APP_ID,
    version = "1.5.1",
    title = "InkBlog",
    subtitle = "Write in ink. Read in peace.",
    symbol = "I",
    logo = "notes",
    requires_tbs_account = true,
    buildPane = buildPane,
    openFile = acceptFile,
    _test = {
        ActionButton = ActionButton, InkLogo = InkLogo, Ink = Ink,
        getColors = function() return { black = C.BLACK, white = C.WHITE, gray333 = C.GRAY_333, gray666 = C.GRAY_666, grayccc = C.GRAY_CCC, ink = C.INK_BLUE, paper = C.PAPER, parchment = C.PARCHMENT, sepia = C.SEPIA, ochre = C.OCHRE, moss = C.MOSS } end,
        stateFor = stateFor, markdownBlocks = markdownBlocks, paginateBlocks = paginateBlocks, utf8Cut = utf8Cut, utf8Length = utf8Length,
        validManagedPath = validManagedPath, imageMimeForPath = imageMimeForPath, restPath = restPath, applySessionResult = applySessionResult, normalizedPost = normalizedPost, enrichPostWithProfile = enrichPostWithProfile,
        getTbsIdentity = function() return getTbsIdentity and getTbsIdentity() end,
        captureLocalDraft = captureLocalDraft, loadDrafts = loadDrafts, saveDrafts = saveDrafts, buildPane = buildPane,
        rawRequest = rawRequest, cacheImageNow = cacheImageNow, base64Encode = base64Encode, LOGO_ROWS = LOGO_ROWS,
    },
}
