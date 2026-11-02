--[[--
DockUpdate for AppDock.

A local, explicit-confirmation updater for the AppDock core plugin. It reads
release metadata only from the pinned public GitHub repository, displays the
release notes, validates a small root-level Lua release tree plus bundled PNG
assets and AppDock data files, stages every file, and atomically swaps the
active plugin folder only after the user confirms. The previous plugin folder
is kept as a nearby rollback backup. The Gallery and DChat DApps are installed
alongside, and a live progress bar follows every download and install step.
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
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
-- New AppDock hosts composite glyphs transparently; older hosts use the
-- explicit surface bgcolor below instead of KOReader's implicit white buffer.
local ok_text, AppDockText = pcall(require, "appdock_text")
if ok_text and type(AppDockText) == "table" and type(AppDockText.TextBoxWidget) == "table" then
    TextBoxWidget = AppDockText.TextBoxWidget
end
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local Screen = Device.screen
local REPOSITORY = "arduinodude456/appdock.koplugin"
local RAW_HOST = "raw.githubusercontent.com"
local RAW_ROOT = "https://" .. RAW_HOST .. "/" .. REPOSITORY
-- NetSurf is a ~7 MB download and by far the slowest part of a first update.
-- Set to false to skip it during updates (it stays installable separately).
local INSTALL_NETSURF_WITH_UPDATE = true
-- GitHub's unauthenticated REST API is limited per public IP.  Use the
-- public Atom feed for release metadata and raw.githubusercontent.com for the
-- fixed, local allowlist instead; neither endpoint consumes the REST quota.
local RELEASE_URL = "https://github.com/" .. REPOSITORY .. "/releases.atom"
local MAX_METADATA_BYTES = 128 * 1024
-- The current AppDock 8.3.5 package has 69 files. Keep explicit headroom while
-- preserving a strict upper bound against unexpected release trees.
local MAX_FILE_BYTES = 256 * 1024
local MAX_ASSET_BYTES = 3 * 1024 * 1024
local MAX_DATA_BYTES = 512 * 1024
local MAX_TOTAL_BYTES = 16 * 1024 * 1024
-- Keep the fixed package bounded even as the explicit module and asset lists evolve.
local MAX_RELEASE_FILES = 80
local MAX_RELEASE_NOTES = 16 * 1024
local NETSURF_URL = "https://raw.githubusercontent.com/arduinodude456/DApps/main/netsurf.zip"
local NETSURF_MAX_ARCHIVE_BYTES = 7 * 1024 * 1024
local DOOM_URL = "https://raw.githubusercontent.com/arduinodude456/DApps/main/doom-kobo.zip"
local DOOM_MAX_ARCHIVE_BYTES = 24 * 1024 * 1024
-- DApps installed together with every core update (same repository and
-- validation path as the AppStore).
local DAPP_ROOT = "https://raw.githubusercontent.com/arduinodude456/DApps/main/"
local MAX_DAPP_BYTES = 2 * 1024 * 1024
local COMPANION_DAPPS = {
    { path = "gallery.lua", title = "Gallery" },
    { path = "dchat.lua", title = "DChat" },
}
local REQUIRED_FILES = {
    "_meta.lua", "main.lua", "appdock_recovery.lua", "appdock_setup.lua", "appdock_order.lua",
    "appdock_appstore.lua", "appdock_audio.lua", "appdock_doom.lua", "appdock_netsurf.lua", "appdock_bluetooth.lua", "appdock_browser.lua",
    "appdock_dapps.lua", "appdock_filemanager.lua", "appdock_groups.lua", "appdock_homescreen.lua",
    "appdock_logo.lua", "appdock_manager.lua", "appdock_quicksettings.lua",
    "appdock_theme.lua", "appdock_notifications.lua", "appdock_help.lua", "appdock_boot.lua",
    "appdock_wallpaper.lua", "appdock_lockscreen.lua", "appdock_device_controls.lua",
    "appdock_bwr.lua", "appdock_player.lua", "appdock_youtube.lua",
    "appdock_ytmusic.lua", "appdock_dialogs.lua", "appdock_text.lua", "appdock_draw.lua", "appdock_dither.lua", "appdock_stylus.lua",
    "appdock_suggestions.lua", "appdock_tbs_account.lua", "appdock_keyboard.lua", "appdock_layout.lua", "appdock_motion.lua",
    "appdock_sleepscreen.lua", "appdock_sleepscreen_catalog.lua",
    "appdock_sleepscreen_editor.lua", "appdock_sleepscreen_presets.lua",
    "appdock_sleepscreen_renderer.lua", "appdock_sleepscreen_store.lua", "appdock_sleepscreen_weather.lua",
    "appdock_transfer.lua", "appdock_youtube_shorts.lua",
    "appdock_suggestions.db", "features.adf",
    "assets/lockscreen/appdock_lockscreen_hero.png",
    "assets/logos/analog_clock.png", "assets/logos/app_store.png", "assets/logos/appdock.png",
    "assets/logos/battery.png", "assets/logos/calculator.png", "assets/logos/calendar.png",
    "assets/logos/dchat.png", "assets/logos/display.png", "assets/logos/dockupdate.png",
    "assets/logos/document.png", "assets/logos/file_manager.png", "assets/logos/help.png",
    "assets/logos/minecraft.png", "assets/logos/music.png", "assets/logos/network.png",
    "assets/logos/notes.png", "assets/logos/settings.png", "assets/logos/web_browser.png",
    "assets/screensaver/happy_ereader_01.png", "assets/screensaver/happy_ereader_02.png",
    "assets/screensaver/happy_ereader_03.png", "assets/screensaver/happy_ereader_04.png",
}
local ALLOWED_SOURCE_FILES = {
    ["_meta.lua"] = true, ["main.lua"] = true,
    ["appdock_recovery.lua"] = true, ["appdock_setup.lua"] = true, ["appdock_doom.lua"] = true, ["appdock_netsurf.lua"] = true,
    ["appdock_appstore.lua"] = true, ["appdock_boot.lua"] = true,
    ["appdock_browser.lua"] = true, ["appdock_dapps.lua"] = true,
    ["appdock_filemanager.lua"] = true, ["appdock_groups.lua"] = true, ["appdock_help.lua"] = true,
    ["appdock_homescreen.lua"] = true, ["appdock_keyboard.lua"] = true,
    ["appdock_layout.lua"] = true, ["appdock_lockscreen.lua"] = true,
    ["appdock_logo.lua"] = true, ["appdock_manager.lua"] = true,
    ["appdock_motion.lua"] = true, ["appdock_notifications.lua"] = true,
    ["appdock_order.lua"] = true, ["appdock_quicksettings.lua"] = true,
    ["appdock_sleepscreen.lua"] = true,
    ["appdock_sleepscreen_catalog.lua"] = true,
    ["appdock_sleepscreen_editor.lua"] = true,
    ["appdock_sleepscreen_presets.lua"] = true,
    ["appdock_sleepscreen_renderer.lua"] = true,
    ["appdock_sleepscreen_store.lua"] = true,
    ["appdock_theme.lua"] = true, ["appdock_wallpaper.lua"] = true,
    ["appdock_device_controls.lua"] = true,
    ["appdock_audio.lua"] = true, ["appdock_bluetooth.lua"] = true, ["appdock_bwr.lua"] = true,
    ["appdock_player.lua"] = true, ["appdock_youtube.lua"] = true,
    ["appdock_transfer.lua"] = true, ["appdock_youtube_shorts.lua"] = true,
    ["appdock_sleepscreen_weather.lua"] = true,
    ["appdock_dialogs.lua"] = true,
    ["appdock_text.lua"] = true,
    ["appdock_draw.lua"] = true,
    ["appdock_dither.lua"] = true,
    ["appdock_ytmusic.lua"] = true, ["appdock_stylus.lua"] = true,
    ["appdock_suggestions.lua"] = true, ["appdock_tbs_account.lua"] = true,
}
-- Modules added after older stable releases are allowlisted but requested only
-- from the first tag that contains them. This keeps updates from old installs
-- working without silently skipping files from today's package.
local SOURCE_MIN_VERSION = {
    ["appdock_bluetooth.lua"] = "7.9.32",
    ["appdock_transfer.lua"] = "8.0.1",
    ["appdock_sleepscreen_weather.lua"] = "8.2.10",
    ["appdock_text.lua"] = "8.2.13",
    ["appdock_youtube_shorts.lua"] = "8.2.22",
    ["appdock_netsurf.lua"] = "8.5.2",
    ["appdock_doom.lua"] = "8.5.3",
}
local ALLOWED_DATA_FILES = {
    ["appdock_suggestions.db"] = true,
    ["features.adf"] = true,
}
local ALLOWED_ASSET_FILES = {
    ["assets/lockscreen/appdock_lockscreen_hero.png"] = true,
    ["assets/logos/analog_clock.png"] = true, ["assets/logos/app_store.png"] = true,
    ["assets/logos/appdock.png"] = true, ["assets/logos/display.png"] = true,
    ["assets/logos/file_manager.png"] = true, ["assets/logos/help.png"] = true,
    ["assets/logos/network.png"] = true, ["assets/logos/notes.png"] = true,
    ["assets/logos/settings.png"] = true, ["assets/logos/web_browser.png"] = true,
    ["assets/logos/battery.png"] = true, ["assets/logos/calendar.png"] = true,
    ["assets/logos/calculator.png"] = true, ["assets/logos/document.png"] = true,
    ["assets/logos/music.png"] = true, ["assets/logos/dchat.png"] = true,
    ["assets/logos/dockupdate.png"] = true, ["assets/logos/minecraft.png"] = true,
    ["assets/screensaver/happy_ereader_01.png"] = true,
    ["assets/screensaver/happy_ereader_02.png"] = true,
    ["assets/screensaver/happy_ereader_03.png"] = true,
    ["assets/screensaver/happy_ereader_04.png"] = true,
}

local function scale(value) return Screen:scaleBySize(value) end
local function trim(value) return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or "" end
local function shorten(value, limit)
    value = value or ""
    if #value <= limit then return value end
    return value:sub(1, math.max(0, limit - 1)) .. "…"
end
local function empty(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local function formatBytes(count)
    count = tonumber(count) or 0
    if count >= 1048576 then return string.format("%.1f MB", count / 1048576) end
    return string.format("%d KB", math.max(1, math.floor(count / 1024 + .5)))
end

local function clockNow()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.time()
end

-- Weighted progress across the whole install. The work blocks the UI thread,
-- so each update rebuilds the pane and forces a full-refresh repaint (throttled for E-Ink).
local Progress = {}
Progress.__index = Progress

local function newProgress(state, context, total)
    return setmetatable({
        state = state, context = context, total = math.max(1, total),
        base = 0, weight = 0, frac = 0, label = "", detail = "", phase = nil, last = 0,
    }, Progress)
end

function Progress:fraction()
    return math.max(0, math.min(1, (self.base + self.weight * self.frac) / self.total))
end

-- A full flashing refresh costs far more time than the downloads it reports,
-- so only the first frame and phase changes flash. All other frames use a
-- light "ui" refresh and are throttled to this interval.
local PROGRESS_REFRESH_INTERVAL = 1.0

function Progress:publish(force)
    local current = clockNow()
    if not force and current - self.last < PROGRESS_REFRESH_INTERVAL then return end
    self.last = current
    self.state.progress = {
        fraction = self:fraction(), label = self.label, detail = self.detail, phase = self.phase,
    }
    if self.context and self.context.requestRebuild then pcall(self.context.requestRebuild, "ui") end
    if UIManager and type(UIManager.setDirty) == "function" then
        local mode = force == "full" and "full" or "ui"
        pcall(function() UIManager:setDirty("all", mode) end)
    end
    if UIManager and type(UIManager.forceRePaint) == "function" then
        pcall(function() UIManager:forceRePaint() end)
    end
end

function Progress:begin(label, weight, phase)
    self.base = self.base + self.weight
    self.weight, self.frac = weight or 1, 0
    self.label, self.detail = label or "", ""
    local flash = self.last == 0 or (phase ~= nil and phase ~= self.phase)
    if phase then self.phase = phase end
    self:publish(flash and "full" or false)
end

function Progress:set(frac, detail)
    self.frac = math.max(0, math.min(1, frac or 0))
    if detail then self.detail = detail end
    self:publish()
end

-- Download size is unknown up front, so a download only reports bytes; the
-- bar advances when the step completes.
function Progress:bytes(received)
    self.detail = formatBytes(received)
    self:publish()
end

function Progress:finish()
    self.base, self.weight, self.frac = self.total, 0, 0
    self.label, self.detail = "", ""
    self:publish("full")
end

local function normalizedVersion(value)
    if type(value) ~= "string" then return nil end
    local clean = value:match("^v?(%d+%.?%d*%.?%d*)$")
    if not clean then return nil end
    local parts = {}
    for part in clean:gmatch("%d+") do parts[#parts + 1] = tonumber(part) end
    return #parts > 0 and parts or nil
end

local function compareVersions(left, right)
    local a, b = normalizedVersion(left), normalizedVersion(right)
    if not a or not b then return nil end
    for index = 1, math.max(#a, #b) do
        local first, second = a[index] or 0, b[index] or 0
        if first ~= second then return first > second and 1 or -1 end
    end
    return 0
end

local function fetch(url, limit, accept, on_chunk)
    local socket_url = require("socket.url")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local parsed = socket_url.parse(url)
    if not parsed or parsed.scheme ~= "https" or parsed.host == nil then return nil, _("Only HTTPS update sources are allowed.") end
    local https = require("ssl.https")
    local chunks, received = {}, 0
    local function sink(chunk)
        if chunk then
            received = received + #chunk
            if received > limit then return nil, "response too large" end
            chunks[#chunks + 1] = chunk
            if on_chunk then pcall(on_chunk, received) end
        end
        return 1
    end
    socketutil:set_timeout(12, 30)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, https.request{
            url = url,
            method = "GET",
            sink = sink,
            headers = {
                ["user-agent"] = socketutil.USER_AGENT,
                ["accept"] = accept or "application/json",
            },
        })
    end)
    socketutil:reset_timeout()
    if not ok or not headers then return nil, status or _("Network request failed.") end
    if not code or code < 200 or code > 299 then return nil, status or _("Update source is unavailable.") end
    return table.concat(chunks)
end

-- ---------------------------------------------------------------------------
-- Persistent HTTPS connection
-- ---------------------------------------------------------------------------
-- The stock ssl.https client opens a brand-new TLS connection for every
-- request. On an e-reader CPU each handshake costs a second or more, and an
-- update fetches ~70 small files from the same host. A Session keeps one
-- connection open (HTTP/1.1 keep-alive) and reuses it. Any problem falls back
-- to the regular fetch(), so behaviour never gets worse than before.
local Session = {}
Session.__index = Session

local function newSession(host)
    return setmetatable({ host = host, conn = nil, failures = 0, disabled = false }, Session)
end

function Session:close()
    local conn = self.conn
    self.conn = nil
    if conn then pcall(function() conn:close() end) end
end

function Session:open()
    self:close()
    local socket = require("socket")
    local ssl = require("ssl")
    local tcp = socket.tcp()
    tcp:settimeout(12)
    local connected, connect_err = tcp:connect(self.host, 443)
    if not connected then pcall(function() tcp:close() end); return nil, connect_err end
    -- Same TLS parameters as the stock ssl.https client.
    local conn, wrap_err = ssl.wrap(tcp, {
        mode = "client", protocol = "any", verify = "none",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
    })
    if not conn then pcall(function() tcp:close() end); return nil, wrap_err end
    if conn.sni then pcall(function() conn:sni(self.host) end) end
    conn:settimeout(30)
    local ok, handshake_err = conn:dohandshake()
    if not ok then pcall(function() conn:close() end); return nil, handshake_err end
    self.conn = conn
    return true
end

function Session:request(path, limit, accept, on_chunk)
    local conn = self.conn
    if not conn then return nil, "not connected" end
    local function abort(err) self:close(); return nil, tostring(err or "connection error") end
    local ok_util, socketutil = pcall(require, "socketutil")
    local agent = ok_util and type(socketutil) == "table" and socketutil.USER_AGENT or "AppDock"
    local request = "GET " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. self.host .. "\r\n"
        .. "User-Agent: " .. agent .. "\r\n"
        .. "Accept: " .. (accept or "*/*") .. "\r\n"
        .. "Accept-Encoding: identity\r\n"
        .. "Connection: keep-alive\r\n\r\n"
    local sent, send_err = conn:send(request)
    if not sent then return abort(send_err) end
    local status_line, status_err = conn:receive("*l")
    if not status_line then return abort(status_err) end
    local code = tonumber(status_line:match("^HTTP/1%.[01] (%d%d%d)"))
    if not code then return abort("invalid HTTP response") end
    local length, chunked, close_after
    while true do
        local line, header_err = conn:receive("*l")
        if not line then return abort(header_err) end
        if line == "" then break end
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name then
            name, value = name:lower(), value:lower()
            if name == "content-length" then length = tonumber(value)
            elseif name == "transfer-encoding" and value:find("chunked", 1, true) then chunked = true
            elseif name == "connection" and value:find("close", 1, true) then close_after = true end
        end
    end
    if code < 200 or code > 299 then return abort("HTTP " .. code) end
    if length and length > limit then return abort("response too large") end
    local parts, received = {}, 0
    local function readBytes(count)
        local remaining = count
        while remaining > 0 do
            local data, err, partial = conn:receive(math.min(remaining, 16384))
            data = data or partial
            if not data or #data == 0 then return nil, err or "connection closed" end
            remaining = remaining - #data
            received = received + #data
            if received > limit then return nil, "response too large" end
            parts[#parts + 1] = data
            if on_chunk then pcall(on_chunk, received) end
        end
        return true
    end
    if chunked then
        while true do
            local size_line, size_err = conn:receive("*l")
            if not size_line then return abort(size_err) end
            local size = tonumber(size_line:match("^%s*(%x+)"), 16)
            if not size then return abort("invalid chunk header") end
            if size == 0 then
                repeat
                    local trailer = conn:receive("*l")
                until not trailer or trailer == ""
                break
            end
            local got, read_err = readBytes(size)
            if not got then return abort(read_err) end
            if not conn:receive(2) then return abort("invalid chunk end") end
        end
    elseif length then
        local got, read_err = readBytes(length)
        if not got then return abort(read_err) end
    else
        return abort("unsupported response framing")
    end
    if close_after then self:close() end
    return table.concat(parts)
end

-- Fetch through the shared connection when possible (one retry on a stale
-- connection), otherwise through the regular one-request-per-connection path.
local function fetchPersistent(session, url, limit, accept, on_chunk)
    if session and not session.disabled then
        local host, path = url:match("^https://([^/]+)(/.*)$")
        if host and host == session.host then
            for _attempt = 1, 2 do
                if not session.conn and not session:open() then break end
                local body = session:request(path, limit, accept, on_chunk)
                if body then session.failures = 0; return body end
            end
            session.failures = session.failures + 1
            if session.failures >= 2 then session.disabled = true end
        end
    end
    return fetch(url, limit, accept, on_chunk)
end

local function xmlUnescape(value)
    return tostring(value or ""):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
end

local function atomText(entry, tag)
    local value = entry:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
    return trim(xmlUnescape(value))
end

local function releaseFromAtom(body)
    if type(body) ~= "string" then return nil, _("The release feed is invalid.") end
    local entry = body:match("<entry[^>]*>(.-)</entry>")
    if not entry then return nil, _("The release feed contains no releases.") end
    local tag, selected
    -- The feed is newest-first. Skip prerelease-style tags and select the
    -- first strict numeric version, which is our stable-release equivalent.
    for candidate in entry:gmatch("<id[^>]*>.-/(v?%d[%d%.]*)</id>") do
        if normalizedVersion(candidate) then tag = candidate; break end
    end
    if not tag then return nil, _("The latest AppDock release is not a stable release.") end
    local title = atomText(entry, "title")
    local content = atomText(entry, "content")
    content = content:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"):gsub("<li>", "- "):gsub("</li>", "\n")
    content = content:gsub("<[^>]+>", "")
    return {
        tag = tag,
        version = tag:gsub("^v", ""),
        name = title ~= "" and title or ("AppDock " .. tag),
        notes = trim(content) ~= "" and trim(content):sub(1, MAX_RELEASE_NOTES) or _("This release has no notes."),
        published = atomText(entry, "updated"),
        url = (entry:match('<link[^>]-rel="alternate"[^>]-href="([^"]+)"') or ""),
    }
end

local function safeSourcePath(path)
    if type(path) ~= "string" or #path == 0 or #path > 160 then return false end
    -- AppDock releases use an explicit module allowlist. This blocks tests,
    -- documentation, archives and unrelated repository Lua files.
    return ALLOWED_SOURCE_FILES[path] == true
end

local function safeAssetPath(path)
    if type(path) ~= "string" or #path == 0 or #path > 160 then return false end
    -- Only the assets used by the current AppDock plugin are accepted.
    return ALLOWED_ASSET_FILES[path] == true
end

local function safeDataPath(path)
    if type(path) ~= "string" or #path == 0 or #path > 160 then return false end
    return ALLOWED_DATA_FILES[path] == true
end

local function releasePathKind(path)
    if safeSourcePath(path) then return "source" end
    if safeAssetPath(path) then return "asset" end
    if safeDataPath(path) then return "data" end
    return nil
end

local function releaseEntries(tag)
    local entries = {}
    local included = {}
    local function availableAtTag(path)
        local minimum = SOURCE_MIN_VERSION[path]
        return not minimum or compareVersions(tag, minimum) >= 0
    end
    for path in pairs(ALLOWED_SOURCE_FILES) do
        if availableAtTag(path) then
            entries[#entries + 1] = { path = path, source_path = "appdock.koplugin/" .. path, kind = "source" }
            included[path] = true
        end
    end
    for path in pairs(ALLOWED_ASSET_FILES) do
        entries[#entries + 1] = { path = path, source_path = "appdock.koplugin/" .. path, kind = "asset" }
        included[path] = true
    end
    for path in pairs(ALLOWED_DATA_FILES) do
        entries[#entries + 1] = { path = path, source_path = "appdock.koplugin/" .. path, kind = "data" }
        included[path] = true
    end
    for _, path in ipairs(REQUIRED_FILES) do
        if availableAtTag(path) and not included[path] then
            return nil, _("The fixed AppDock file list is missing a required module: ") .. path
        end
    end
    if #entries > MAX_RELEASE_FILES then return nil, _("The fixed AppDock file list is too large.") end
    table.sort(entries, function(left, right) return left.path < right.path end)
    return entries
end

local function removeTree(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then return true end
    if mode == "file" then return os.remove(path) end
    if mode ~= "directory" then return nil, _("An update path has an unsupported file type.") end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local ok, err = removeTree(path .. "/" .. name)
            if not ok then return nil, err end
        end
    end
    return lfs.rmdir(path)
end

local function writeFile(path, content)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(content)
    file:close()
    if not ok then return nil, write_err end
    return true
end

local function ensureParentDirectories(root, path)
    local current = root
    local parts = {}
    for part in path:gmatch("([^/]+)") do parts[#parts + 1] = part end
    for index = 1, #parts - 1 do
        current = current .. "/" .. parts[index]
        if not lfs.attributes(current, "mode") then
            local created, mkdir_err = lfs.mkdir(current)
            if not created then return nil, mkdir_err end
        end
    end
    return true
end

local function isPng(content)
    return type(content) == "string" and content:sub(1, 8) == "\137PNG\r\n\26\n"
end
local function validAsset(path, content)
    if type(path) ~= "string" then return false end
    if path:match("%.png$") then return isPng(content) end
    return false
end

local function isSuggestionDatabase(content)
    return type(content) == "string"
        and (content:match("^# AppDock offline bilingual suggestion database")
            or content:match("^# AppDock offline suggestion database"))
        and content:match("\n# language<TAB>frequency<TAB>word")
        and content:match("\nde\t[%d%.]+\t[^\r\n]+")
        and content:match("\nen\t[%d%.]+\t[^\r\n]+")
end
local function isFeaturePagesFile(content)
    if type(content) ~= "string" or #content == 0 or content:find("%z") then return false end
    content = content:gsub("\r\n", "\n")
    if not content:match("^# AppDock news[%s\r\n]") or not content:find("[page]", 1, true) then return false end
    return content:match("%[page%].-\ntitle=[^\r\n]+") ~= nil
        and content:match("%[page%].-\ntext=[^\r\n]+") ~= nil
end
local function validDataFile(path, content)
    if path == "appdock_suggestions.db" then return isSuggestionDatabase(content) end
    if path == "features.adf" then return isFeaturePagesFile(content) end
    return false
end
local function activePlugin(context)
    local appdock = context and context.manager and context.manager.appdock
    local path = appdock and appdock.path
    if type(path) ~= "string" or path == "" or path:match("[%z\r\n]") then return nil, _("DockUpdate cannot identify the active AppDock plugin folder.") end
    if path:match("([^/]+)$") ~= "appdock.koplugin" or lfs.attributes(path, "mode") ~= "directory" then
        return nil, _("The active AppDock plugin folder is unavailable.")
    end
    return path, tostring(appdock.version or "?")
end

local function stageRelease(release, entries, target, progress, session)
    local safe_tag = release.tag:gsub("^v", "")
    local stage = target .. ".appdock-stage-" .. safe_tag
    local cleaned, clean_err = removeTree(stage)
    if not cleaned then return nil, clean_err or _("An old update staging folder could not be removed.") end
    local created, mkdir_err = lfs.mkdir(stage)
    if not created then return nil, mkdir_err or _("The update staging folder could not be created.") end

    local total_bytes = 0
    for entry_index, entry in ipairs(entries) do
        local is_asset = entry.kind == "asset"
        local is_data = entry.kind == "data"
        local max_size = is_asset and MAX_ASSET_BYTES or (is_data and MAX_DATA_BYTES or MAX_FILE_BYTES)
        local accept = is_asset and "image/png,*/*;q=0.1" or "text/plain,text/x-lua;q=0.9,*/*;q=0.1"
        if progress then progress:begin(string.format(_("Downloading %s"), entry.path), 1, "core") end
        local source, fetch_err = fetchPersistent(session, RAW_ROOT .. "/" .. release.tag .. "/" .. (entry.source_path or entry.path), max_size, accept,
            progress and function(received) progress:bytes(received) end or nil)
        if not source then removeTree(stage); return nil, _("Could not download ") .. entry.path .. ": " .. tostring(fetch_err) end
        total_bytes = total_bytes + #source
        if total_bytes > MAX_TOTAL_BYTES then
            removeTree(stage)
            return nil, _("The AppDock release exceeds the total download limit.")
        end
        if entry.size and #source ~= entry.size then removeTree(stage); return nil, _("Downloaded file size does not match release metadata: ") .. entry.path end
        if is_asset then
            if not validAsset(entry.path, source) then removeTree(stage); return nil, _("Downloaded asset is invalid: ") .. entry.path end
        elseif is_data then
            if not validDataFile(entry.path, source) then
                removeTree(stage); return nil, _("Downloaded AppDock data file has an invalid format: ") .. entry.path
            end
        else
            local chunk, syntax_err = loadstring(source, "@dockupdate/" .. entry.path)
            if not chunk then removeTree(stage); return nil, _("Downloaded source has invalid Lua syntax: ") .. entry.path .. "\n" .. tostring(syntax_err) end
        end
        local parent_ok, parent_err = ensureParentDirectories(stage, entry.path)
        if not parent_ok then removeTree(stage); return nil, _("Could not create the asset directory for ") .. entry.path .. ": " .. tostring(parent_err) end
        local saved, save_err = writeFile(stage .. "/" .. entry.path, source)
        if not saved then removeTree(stage); return nil, _("Could not stage ") .. entry.path .. ": " .. tostring(save_err) end
        entry.staged_size = #source
    end

    -- Every file was already validated in memory (Lua syntax, PNG header, data
    -- format) before it was written. Re-parsing them all from disk doubled the
    -- CPU time, so confirm only that each file was written completely.
    if progress then progress:begin(_("Verifying staged files"), 2, "core") end
    for _index, entry in ipairs(entries) do
        if lfs.attributes(stage .. "/" .. entry.path, "size") ~= entry.staged_size then
            removeTree(stage)
            return nil, _("Staged file verification failed: ") .. entry.path
        end
    end
    return stage
end

-- Atomically swaps the already staged and verified release into place.
local function commitRelease(stage, target, installed_version)
    local backup_version = tostring(installed_version or "unknown"):gsub("[^%w%._%-]", "_")
    local backup = target .. ".appdock-backup-" .. backup_version
    local removed, remove_err = removeTree(backup)
    if not removed then removeTree(stage); return nil, remove_err or _("The previous rollback backup could not be removed.") end
    local moved_old, old_err = os.rename(target, backup)
    if not moved_old then removeTree(stage); return nil, old_err or _("The current AppDock folder could not be backed up.") end
    local moved_new, new_err = os.rename(stage, target)
    if not moved_new then
        os.rename(backup, target)
        removeTree(stage)
        return nil, new_err or _("The staged update could not replace AppDock. The previous version was restored.")
    end
    return backup
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function zipU16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a + b * 256
end

local function zipU32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- Read ZIP central-directory names directly. Some reader unzip builds can
-- extract archives but do not implement Info-ZIP's optional `unzip -Z1` mode.
local function listArchive(path, root_prefix)
    local file = io.open(path, "rb")
    if not file then return nil, "invalid" end
    local size = file:seek("end")
    if not size or size < 22 then file:close(); return nil, "invalid" end
    local tail_start = math.max(0, size - 65557)
    file:seek("set", tail_start)
    local tail = file:read("*a") or ""
    local eocd, scan = nil, 1
    while true do
        local found = tail:find("PK\005\006", scan, true)
        if not found then break end
        local comment_length = zipU16(tail, found + 20)
        if comment_length and found + 21 + comment_length == #tail then eocd = found end
        scan = found + 1
    end
    if not eocd then file:close(); return nil, "invalid" end
    local disk = zipU16(tail, eocd + 4)
    local directory_disk = zipU16(tail, eocd + 6)
    local disk_entries = zipU16(tail, eocd + 8)
    local entry_count = zipU16(tail, eocd + 10)
    local directory_size = zipU32(tail, eocd + 12)
    local directory_offset = zipU32(tail, eocd + 16)
    local eocd_offset = tail_start + eocd - 1
    if disk ~= 0 or directory_disk ~= 0 or disk_entries ~= entry_count
        or not entry_count or entry_count == 0 or entry_count > 128
        or directory_size == 4294967295 or directory_offset == 4294967295
        or directory_offset + directory_size > eocd_offset then
        file:close(); return nil, "invalid"
    end
    file:seek("set", directory_offset)
    local names = {}
    for _ = 1, entry_count do
        local header = file:read(46)
        if not header or #header ~= 46 or header:sub(1, 4) ~= "PK\001\002" then
            file:close(); return nil, "invalid"
        end
        local flags = zipU16(header, 9)
        local name_length = zipU16(header, 29)
        local extra_length = zipU16(header, 31)
        local comment_length = zipU16(header, 33)
        local external_attributes = zipU32(header, 39)
        if not flags or flags % 2 ~= 0 or not name_length or name_length == 0 then
            file:close(); return nil, "invalid"
        end
        local name = file:read(name_length)
        if not name or #name ~= name_length then file:close(); return nil, "invalid" end
        local unix_mode = math.floor((external_attributes or 0) / 65536)
        local file_type = math.floor(unix_mode / 4096)
        if (root_prefix and name:sub(1, #root_prefix) ~= root_prefix) or name:sub(1, 1) == "/"
            or name:find("\\", 1, true) or name:find(string.char(0), 1, true) or file_type == 10 then
            file:close(); return nil, "unsafe"
        end
        for component in name:gmatch("[^/]+") do
            if component == "." or component == ".." then file:close(); return nil, "unsafe" end
        end
        names[name] = true
        if not file:seek("cur", extra_length + comment_length) then
            file:close(); return nil, "invalid"
        end
    end
    file:close()
    return names
end

local function listNetsurfZip(path)
    return listArchive(path, "netsurf/")
end

local function listDoomZip(path)
    return listArchive(path, nil)
end

local function installNetsurf(progress)
    local root = "/mnt/onboard/.adds"
    local target = root .. "/netsurf"
    if lfs.attributes("/mnt/onboard", "mode") ~= "directory" then
        return nil, _("The reader's onboard storage is unavailable.")
    end
    if lfs.attributes(target, "mode") then
        return nil, _("Netsurf is already present in .adds; DockUpdate will not overwrite it.")
    end
    local made_adds = lfs.attributes(root, "mode") ~= "directory"
    if made_adds then
        local made, mkdir_err = lfs.mkdir(root)
        if not made then return nil, _("Could not create .adds: ") .. tostring(mkdir_err) end
    end
    local archive = root .. "/.netsurf-download.zip"
    local stage = root .. "/.netsurf-stage"
    os.remove(archive)
    if progress then progress:begin(_("Downloading NetSurf"), 6, "netsurf") end
    local body, download_err = fetch(NETSURF_URL, NETSURF_MAX_ARCHIVE_BYTES, "application/zip,application/octet-stream;q=0.9",
        progress and function(received) progress:bytes(received) end or nil)
    if not body then return nil, _("Could not download Netsurf: ") .. tostring(download_err) end
    local saved, save_err = writeFile(archive, body)
    if not saved then return nil, _("Could not save the Netsurf archive: ") .. tostring(save_err) end
    local names, list_err = listNetsurfZip(archive)
    if not names then
        os.remove(archive)
        if list_err == "unsafe" then return nil, _("The Netsurf archive contains an unsafe path.") end
        return nil, _("The Netsurf archive is incomplete or invalid.")
    end
    if not names["netsurf/bin/netsurf-fb"] or not names["netsurf/cacert.pem"] then
        os.remove(archive)
        return nil, _("The Netsurf archive is incomplete or invalid.")
    end
    if progress then progress:begin(_("Extracting NetSurf"), 2, "netsurf") end
    removeTree(stage)
    if not lfs.mkdir(stage) then os.remove(archive); return nil, _("Could not create the Netsurf staging folder.") end
    local binary = stage .. "/netsurf/bin/netsurf-fb"
    local command = "unzip -o -q " .. shellQuote(archive) .. " -d " .. shellQuote(stage)
        .. " >/dev/null 2>&1 && chmod 755 " .. shellQuote(binary) .. " >/dev/null 2>&1"
    local process = io.popen(command .. "; printf '\n%d' $?", "r")
    local result = process and process:read("*a") or ""
    if process then process:close() end
    if tonumber(result:match("(%d+)%s*$")) ~= 0 or not lfs.attributes(binary, "mode") then
        removeTree(stage); os.remove(archive)
        return nil, _("Could not validate or extract Netsurf.")
    end
    local moved, move_err = os.rename(stage .. "/netsurf", target)
    removeTree(stage); os.remove(archive)
    if not moved then return nil, _("Could not install Netsurf in .adds: ") .. tostring(move_err) end
    return true
end

local DOOM_ARCHIVE_FILES = {
    [".adds/"] = true, [".adds/doom/"] = true, [".adds/doom/bin/"] = true,
    [".adds/doom/lib/"] = true, [".adds/doom/home/"] = true,
    [".adds/doom/bin/doomgeneric-640"] = true,
    [".adds/doom/bin/doomgeneric-960"] = true,
    [".adds/doom/freedoom1.wad"] = true, [".adds/doom/freedoom2.wad"] = true,
    [".adds/doom/DOOMGENERIC-LICENSE.txt"] = true,
    [".adds/doom/FREEDOOM-LICENSE.txt"] = true,
}

local function installDoom(progress)
    local root = "/mnt/onboard/.adds"
    local target = root .. "/doom"
    if lfs.attributes("/mnt/onboard", "mode") ~= "directory" then
        return nil, _("The reader's onboard storage is unavailable.")
    end
    if lfs.attributes(target, "mode") then
        return nil, _("Doom is already present in .adds; DockUpdate will not overwrite it.")
    end
    local made_adds = lfs.attributes(root, "mode") ~= "directory"
    if made_adds then
        local made, mkdir_err = lfs.mkdir(root)
        if not made then return nil, _("Could not create .adds: ") .. tostring(mkdir_err) end
    end
    local archive = root .. "/.doom-download.zip"
    local stage = root .. "/.doom-stage"
    os.remove(archive)
    if progress then progress:begin(_("Downloading Doom"), 8, "doom") end
    local body, download_err = fetch(DOOM_URL, DOOM_MAX_ARCHIVE_BYTES, "application/zip,application/octet-stream;q=0.9",
        progress and function(received) progress:bytes(received) end or nil)
    if not body then return nil, _("Could not download Doom: ") .. tostring(download_err) end
    local saved, save_err = writeFile(archive, body)
    if not saved then return nil, _("Could not save the Doom archive: ") .. tostring(save_err) end
    local names, list_err = listDoomZip(archive)
    if not names then
        os.remove(archive)
        if list_err == "unsafe" then return nil, _("The Doom archive contains an unsafe path.") end
        return nil, _("The Doom archive is incomplete or invalid.")
    end
    for name in pairs(names) do
        if not DOOM_ARCHIVE_FILES[name] then
            os.remove(archive)
            return nil, _("The Doom archive contains an unexpected file.")
        end
    end
    for _, required in ipairs({
        ".adds/doom/bin/doomgeneric-640", ".adds/doom/bin/doomgeneric-960",
        ".adds/doom/freedoom1.wad", ".adds/doom/freedoom2.wad",
    }) do
        if not names[required] then
            os.remove(archive)
            return nil, _("The Doom archive is incomplete or invalid.")
        end
    end
    if progress then progress:begin(_("Extracting Doom"), 2, "doom") end
    removeTree(stage)
    if not lfs.mkdir(stage) then os.remove(archive); return nil, _("Could not create the Doom staging folder.") end
    local binary_640 = stage .. "/.adds/doom/bin/doomgeneric-640"
    local binary_960 = stage .. "/.adds/doom/bin/doomgeneric-960"
    local command = "unzip -o -q " .. shellQuote(archive) .. " -d " .. shellQuote(stage)
        .. " >/dev/null 2>&1 && chmod 755 " .. shellQuote(binary_640) .. " " .. shellQuote(binary_960)
        .. " >/dev/null 2>&1"
    local process = io.popen(command .. "; printf '\n%d' $?", "r")
    local result = process and process:read("*a") or ""
    if process then process:close() end
    if tonumber(result:match("(%d+)%s*$")) ~= 0
        or not lfs.attributes(binary_640, "mode") or not lfs.attributes(binary_960, "mode") then
        removeTree(stage); os.remove(archive)
        return nil, _("Could not validate or extract Doom.")
    end
    local moved, move_err = os.rename(stage .. "/.adds/doom", target)
    removeTree(stage); os.remove(archive)
    if not moved then return nil, _("Could not install Doom in .adds: ") .. tostring(move_err) end
    return true
end

-- ---------------------------------------------------------------------------
-- Companion DApps (Gallery, DChat)
-- ---------------------------------------------------------------------------

local function companionDirectory()
    local path = DataStorage:getDataDir() .. "/appdock_dapps"
    if lfs.attributes(path, "mode") ~= "directory" then lfs.mkdir(path) end
    return path
end

local function managerSupportsDApps(manager)
    return type(manager) == "table"
        and type(manager.inspectStoreDApp) == "function"
        and type(manager.loadStoreDApp) == "function"
        and type(manager.getStoreDAppBySource) == "function"
end

-- true = installed, false = missing, nil = cannot be determined
local function companionInstalled(context, entry)
    local manager = context and context.manager
    if not managerSupportsDApps(manager) then return nil end
    local ok, _definition, record = pcall(manager.getStoreDAppBySource, manager, entry.path)
    if not ok then return nil end
    return record ~= nil
end

local function missingCompanions(context)
    local missing = {}
    for _index, entry in ipairs(COMPANION_DAPPS) do
        if companionInstalled(context, entry) == false then missing[#missing + 1] = entry end
    end
    return missing
end

-- Mirrors the AppStore install path: download, syntax check, inspect, swap the
-- file in with a rollback copy, then register it with the DApp manager.
-- Returns "installed" | "updated" | "current", or nil plus an error text.
local function installCompanionDApp(context, entry, progress, session)
    local manager = context and context.manager
    if not managerSupportsDApps(manager) then
        return nil, _("This AppDock version cannot install DApps from DockUpdate.")
    end
    if progress then progress:begin(string.format(_("Downloading %s"), entry.title), 3, "dapps") end
    local source, fetch_err = fetchPersistent(session, DAPP_ROOT .. entry.path, MAX_DAPP_BYTES,
        "text/plain,text/x-lua;q=0.9,*/*;q=0.1",
        progress and function(received) progress:bytes(received) end or nil)
    if not source then return nil, tostring(fetch_err) end
    local chunk, syntax_err = loadstring(source, "@dockupdate/" .. entry.path)
    if not chunk then return nil, _("Invalid Lua syntax: ") .. tostring(syntax_err) end
    if progress then progress:set(.6, _("Validating")) end

    local filename = entry.path:gsub("[^%w%._%-]", "_")
    local target = companionDirectory() .. "/" .. filename
    local temporary = target .. ".tmp"
    os.remove(temporary)
    local saved, save_err = writeFile(temporary, source)
    if not saved then return nil, tostring(save_err) end

    local ok_inspect, definition, inspect_err = pcall(manager.inspectStoreDApp, manager, temporary)
    if not ok_inspect then definition, inspect_err = nil, definition end
    if not definition then
        os.remove(temporary)
        return nil, _("Not a valid AppDock DApp: ") .. tostring(inspect_err)
    end

    local record
    local ok_state, installed_definition, installed_record = pcall(manager.getStoreDAppBySource, manager, entry.path)
    if ok_state and installed_record then
        record = installed_record
        if installed_definition and installed_definition.id ~= definition.id then
            os.remove(temporary)
            return nil, _("The update would change the DApp identity and was rejected.")
        end
        local installed_version = record.version or (installed_definition and installed_definition.version)
        if compareVersions(tostring(definition.version or ""), tostring(installed_version or "")) ~= 1 then
            os.remove(temporary)
            if progress then progress:set(1, _("Already up to date")) end
            return "current"
        end
    end

    if progress then progress:set(.8, _("Installing")) end
    local backup = target .. ".previous"
    os.remove(backup)
    local had_target = lfs.attributes(target) ~= nil
    if had_target and not os.rename(target, backup) then
        os.remove(temporary)
        return nil, _("The existing DApp could not be prepared for update.")
    end
    if not os.rename(temporary, target) then
        if had_target then os.rename(backup, target) end
        os.remove(temporary)
        return nil, _("The downloaded DApp could not replace the previous version.")
    end
    local ok_load, loaded, load_err = pcall(manager.loadStoreDApp, manager, target, entry.path, false,
        definition.id, record ~= nil, target)
    if not ok_load or not loaded then
        os.remove(target)
        if had_target then os.rename(backup, target) end
        return nil, _("Registration failed: ") .. tostring(ok_load and load_err or loaded)
    end
    os.remove(backup)
    if progress then progress:set(1, _("Done")) end
    return record and "updated" or "installed"
end

local function companionResultText(result)
    local name = result.entry.title
    if result.status == "installed" then return name .. ": " .. _("installed") end
    if result.status == "updated" then return name .. ": " .. _("updated") end
    if result.status == "current" then return name .. ": " .. _("already up to date") end
    return name .. ": " .. _("failed") .. " (" .. tostring(result.err) .. ")"
end

-- ---------------------------------------------------------------------------
-- State and actions
-- ---------------------------------------------------------------------------

local function stateFor(instance)
    if instance.dock_update then return instance.dock_update end
    instance.dock_update = { release = nil, files = nil, error = nil, checked = false, updating = false, progress = nil }
    return instance.dock_update
end

local function requestRebuild(context, mode)
    if context and context.requestRebuild then context.requestRebuild(mode or "ui") end
end

local function showMessage(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function closePopup(widget)
    if not widget or not UIManager or type(UIManager.close) ~= "function" then return end
    pcall(function() UIManager:close(widget) end)
    -- The install blocks the UI thread: repaint now so the dialog is really
    -- gone before the first progress frame is drawn.
    if type(UIManager.forceRePaint) == "function" then
        pcall(function() UIManager:forceRePaint() end)
    end
end

-- Runs `work(progress)` with live progress. The work blocks the UI thread, so
-- Progress repaints the pane itself after each step and download chunk.
local function withProgress(state, context, total, work)
    state.updating, state.error, state.progress = true, nil, nil
    local progress = newProgress(state, context, total)
    local ok, first, second = pcall(work, progress)
    state.updating, state.progress = false, nil
    requestRebuild(context)
    if not ok then return nil, tostring(first) end
    return first, second
end

local function checkForRelease(instance, context)
    local state = stateFor(instance)
    state.error, state.files = nil, nil
    local body, fetch_err = fetch(RELEASE_URL, MAX_METADATA_BYTES, "application/atom+xml,text/xml;q=0.9")
    if not body then
        state.release, state.error, state.checked = nil, _("Could not check AppDock releases: ") .. tostring(fetch_err), true
        requestRebuild(context)
        return
    end
    local release, parse_err = releaseFromAtom(body)
    state.release, state.error, state.checked = release, parse_err, true
    requestRebuild(context)
end

local function backgroundTick(instance, context)
    local state = stateFor(instance)
    local body = fetch(RELEASE_URL, MAX_METADATA_BYTES, "application/atom+xml,text/xml;q=0.9")
    if not body then return false end
    local release = releaseFromAtom(body)
    if not release then return false end
    state.background_checked_at = os.time()
    local installed = context and context.appdock and context.appdock.version
    local relation = compareVersions(release.version, tostring(installed or ""))
    if relation == 1 and state.background_notified_tag ~= release.tag then
        state.background_notified_tag = release.tag
        if context.notify then
            context.notify({
                title = _("AppDock update available"),
                message = _("Version ") .. release.version .. _(" is ready. Open DockUpdate to review notes and confirm installation."),
                priority = "normal",
            })
        end
    end
    return true
end

local function safeBackgroundTick(instance, context)
    local ok, result = pcall(backgroundTick, instance, context)
    return ok and result or false
end

local function prepareRelease(state)
    if not state.release then return nil, _("Check for an AppDock release first.") end
    if state.files then return state.files end
    local entries, tree_err = releaseEntries(state.release.tag)
    if not entries then return nil, tree_err end
    state.files = entries
    return entries
end

local function showNotes(instance, context)
    local state = stateFor(instance)
    if not state.release then showMessage(_("Check for an AppDock release first.")); return end
    local release = state.release
    UIManager:show(TextViewer:new{
        title = release.name .. " (" .. release.tag .. ")",
        title_multilines = true,
        text = release.notes,
        text_type = "lookup",
        height = math.max(scale(180), context.dimen.h - scale(18)),
        add_default_buttons = true,
    })
end

local function netsurfInstalled()
    return lfs.attributes("/mnt/onboard/.adds/netsurf", "mode") ~= nil
end

local function doomInstalled()
    return lfs.attributes("/mnt/onboard/.adds/doom", "mode") ~= nil
end

local function confirmDoomInstall(instance, context)
    local state = stateFor(instance)
    local current_version = context and context.manager and context.manager.appdock and context.manager.appdock.version
    local supported = compareVersions(tostring(current_version or ""), "8.5.3")
    if supported == nil or supported < 0 then
        showMessage(_("Update AppDock to version 8.5.3 or newer before installing Doom."))
        return
    end
    if doomInstalled() then
        showMessage(_("Doom is already present in .adds; DockUpdate will not overwrite it."))
        return
    end
    local dialog
    dialog = ConfirmBox:new{
        text = _("Install the Doom package to /mnt/onboard/.adds/doom now?\n\n")
            .. _("DockUpdate will validate the fixed archive contents, extract it to a staging folder, set both Doom binaries executable, then move it into place. Existing installations are never overwritten."),
        ok_text = _("Install Doom"),
        ok_callback = function()
            closePopup(dialog)
            local installed, install_err = withProgress(state, context, 10, function(progress)
                return installDoom(progress)
            end)
            if installed then
                showMessage(_("Doom was extracted to /mnt/onboard/.adds/doom. Close and reopen the Doom app to launch it."))
            else
                state.error = _("Doom installation failed: ") .. tostring(install_err)
                showMessage(state.error)
            end
            requestRebuild(context)
        end,
    }
    UIManager:show(dialog)
end

local function confirmNetsurfInstall(instance, context)
    local state = stateFor(instance)
    local current_version = context and context.manager and context.manager.appdock and context.manager.appdock.version
    local supported = compareVersions(tostring(current_version or ""), "8.5.2")
    if supported == nil or supported < 0 then
        showMessage(_("Update AppDock to version 8.5.2 or newer before installing NetSurf."))
        return
    end
    if netsurfInstalled() then
        showMessage(_("NetSurf is already present in .adds; DockUpdate will not overwrite it."))
        return
    end
    local dialog
    dialog = ConfirmBox:new{
        text = _("Install the NetSurf package to /mnt/onboard/.adds/netsurf now?\n\n")
            .. _("DockUpdate will validate the archive, extract it to a staging folder, set the browser binary executable, then move it into place. Existing installations are never overwritten."),
        ok_text = _("Install NetSurf"),
        ok_callback = function()
            closePopup(dialog)
            local installed, install_err = withProgress(state, context, 8, function(progress)
                return installNetsurf(progress)
            end)
            if installed then
                showMessage(_("NetSurf was extracted to /mnt/onboard/.adds/netsurf. Close and reopen the AppDock browser to launch it."))
            else
                state.error = _("NetSurf installation failed: ") .. tostring(install_err)
                showMessage(state.error)
            end
            requestRebuild(context)
        end,
    }
    UIManager:show(dialog)
end

local function confirmCompanionInstall(instance, context)
    local state = stateFor(instance)
    local missing = missingCompanions(context)
    if #missing == 0 then
        showMessage(_("Gallery and DChat are already installed."))
        return
    end
    local names = {}
    for _index, entry in ipairs(missing) do names[#names + 1] = "- " .. entry.title end
    local dialog
    dialog = ConfirmBox:new{
        text = _("Install these DApps from the AppDock DApps repository?\n\n") .. table.concat(names, "\n")
            .. _("\n\nEach file is downloaded over HTTPS, syntax-checked and validated before it is registered with AppDock."),
        ok_text = _("Install DApps"),
        ok_callback = function()
            closePopup(dialog)
            local results = withProgress(state, context, 3 * #missing, function(progress)
                local collected = {}
                local session = newSession(RAW_HOST)
                for _index, entry in ipairs(missing) do
                    local ok, status, err = pcall(installCompanionDApp, context, entry, progress, session)
                    if not ok then status, err = nil, status end
                    collected[#collected + 1] = { entry = entry, status = status, err = err }
                end
                session:close()
                progress:finish()
                return collected
            end)
            if type(results) ~= "table" then
                state.error = _("DApp installation failed: ") .. tostring(select(2, results))
                showMessage(state.error)
            else
                local lines = {}
                for _index, result in ipairs(results) do lines[#lines + 1] = companionResultText(result) end
                showMessage(table.concat(lines, "\n"))
            end
            requestRebuild(context)
        end,
    }
    UIManager:show(dialog)
end

-- Gallery and DChat are part of AppDock: whenever one is missing it is
-- installed without asking (silently at startup, with the progress bar when
-- the DockUpdate pane is open). Two attempts per session at most.
local function autoInstallCompanions(instance, context, visible)
    local state = stateFor(instance)
    if state.auto_running or state.updating or (state.auto_attempts or 0) >= 2 then return end
    local missing = missingCompanions(context)
    if #missing == 0 then return end
    state.auto_attempts = (state.auto_attempts or 0) + 1
    state.auto_running = true
    local function work(progress)
        local session = newSession(RAW_HOST)
        for _index, entry in ipairs(missing) do
            pcall(installCompanionDApp, context, entry, progress, session)
        end
        session:close()
        if progress then progress:finish() end
        return true
    end
    if visible then
        withProgress(state, context, 3 * #missing, work)
    else
        pcall(work, nil)
    end
    state.auto_running = false
    if visible then requestRebuild(context) end
end

local function confirmInstall(instance, context)
    local state = stateFor(instance)
    local target, installed_version_or_err = activePlugin(context)
    if not target then showMessage(installed_version_or_err); return end
    local release = state.release
    if not release then showMessage(_("Check for an AppDock release first.")); return end
    local relation = compareVersions(release.version, installed_version_or_err)
    if relation == nil then
        showMessage(_("DockUpdate cannot compare the installed AppDock version safely."))
        return
    end
    if relation ~= 1 then
        showMessage(relation == 0 and _("AppDock is already up to date.") or _("The installed AppDock version is newer than this release."))
        return
    end
    local entries, prepare_err = prepareRelease(state)
    if not entries then showMessage(prepare_err); return end
    local dialog
    dialog = ConfirmBox:new{
        text = _("Install the trusted AppDock update now?\n\n")
            .. _("Installed: ") .. tostring(installed_version_or_err) .. "\n"
            .. _("Release: ") .. release.version .. "\n"
            .. _("Validated source files: ") .. #entries
            .. _("\n\nAppDock source files will be downloaded over HTTPS, syntax-checked, staged, then swapped atomically. The Gallery and DChat DApps are installed alongside, plus NetSurf (existing installations are never overwritten)."),
        ok_text = _("Install update"),
        ok_callback = function()
            closePopup(dialog)
            local installed_version = installed_version_or_err
            -- Weights: one per core file, 2 verify, 3 per DApp, 8 NetSurf, 1 swap.
            local total = #entries + 2 + 3 * #COMPANION_DAPPS + (INSTALL_NETSURF_WITH_UPDATE and 8 or 0) + 1
            local session = newSession(RAW_HOST)
            local result, update_err = withProgress(state, context, total, function(progress)
                progress:begin(_("Preparing update"), 0, "core")
                local stage, stage_err = stageRelease(release, entries, target, progress, session)
                if not stage then return nil, stage_err end
                local outcome = { companions = {} }
                -- Optional extras never block the core update.
                for _index, entry in ipairs(COMPANION_DAPPS) do
                    local ok, status, err = pcall(installCompanionDApp, context, entry, progress, session)
                    if not ok then status, err = nil, status end
                    outcome.companions[#outcome.companions + 1] = { entry = entry, status = status, err = err }
                end
                session:close()
                if not INSTALL_NETSURF_WITH_UPDATE then
                    outcome.netsurf = nil
                elseif netsurfInstalled() then
                    outcome.netsurf = "present"
                else
                    local ok, installed, err = pcall(installNetsurf, progress)
                    if not ok then installed, err = nil, installed end
                    outcome.netsurf = installed and "installed" or "failed"
                    outcome.netsurf_err = err
                end
                progress:begin(_("Switching to the new version"), 1, "core")
                local backup, commit_err = commitRelease(stage, target, installed_version)
                if not backup then return nil, commit_err end
                progress:finish()
                outcome.backup = backup
                return outcome
            end)
            session:close()
            if not result then
                state.error = _("AppDock update failed: ") .. tostring(update_err)
                showMessage(state.error)
            else
                state.error = nil
                local lines = {}
                for _index, item in ipairs(result.companions) do lines[#lines + 1] = "- " .. companionResultText(item) end
                if result.netsurf == "installed" then lines[#lines + 1] = "- NetSurf: " .. _("installed")
                elseif result.netsurf == "present" then lines[#lines + 1] = "- NetSurf: " .. _("already present")
                elseif result.netsurf == "failed" then lines[#lines + 1] = "- NetSurf: " .. _("failed") .. " (" .. tostring(result.netsurf_err) .. ")" end
                showMessage(_("AppDock was updated to ") .. release.version .. ".\n\n" .. table.concat(lines, "\n")
                    .. _("\n\nRestart KOReader now to load the new plugin files.\n\nRollback backup:\n") .. result.backup)
            end
            requestRebuild(context)
        end,
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

-- The pane follows the active AppDock design, so dark store designs keep text
-- and surfaces consistent. Falls back to neutral grays when it is unavailable.
local function themePalette(context)
    local source = {}
    local ok_theme, Theme = pcall(require, "appdock_theme")
    if ok_theme and type(Theme) == "table" and type(Theme.getPalette) == "function" then
        local ok, result = pcall(Theme.getPalette, context and context.manager and context.manager.appdock)
        if ok and type(result) == "table" then source = result end
    end
    return {
        background = source.background or Blitbuffer.COLOR_WHITE,
        card = source.surface or Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_WHITE,
        card_alt = source.surface_variant or Blitbuffer.COLOR_LIGHT_GRAY,
        accent = source.button or source.primary or Blitbuffer.COLOR_DARK_GRAY,
        on_accent = source.on_button or source.on_primary or Blitbuffer.COLOR_WHITE,
        text = source.on_surface or Blitbuffer.COLOR_BLACK,
        muted = source.on_variant or Blitbuffer.COLOR_DARK_GRAY,
        line = source.outline or Blitbuffer.COLOR_DARK_GRAY,
    }
end

local Action = InputContainer:extend{
    title = nil, subtitle = nil, callback = nil, width = nil, height = nil,
    background = nil, foreground = nil, subtitle_color = nil, border_color = nil,
    border = 2, disabled = false, dimen = nil,
}
function Action:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local inset = scale(9)
    local title = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("smallinfofont", scale(11)),
        bold = true,
        fgcolor = self.foreground or Blitbuffer.COLOR_BLACK,
        max_width = self.width - 2 * inset,
        padding = 0,
    }
    local layers = { }
    local has_subtitle = self.subtitle and self.subtitle ~= ""
    local subtitle
    if has_subtitle then
        subtitle = TextWidget:new{
            text = self.subtitle,
            face = Font:getFace("smallinfofont", scale(8)),
            fgcolor = self.subtitle_color or self.foreground or Blitbuffer.COLOR_DARK_GRAY,
            max_width = self.width - 2 * inset,
            padding = 0,
        }
    end
    local block_h = title:getSize().h + (subtitle and (scale(2) + subtitle:getSize().h) or 0)
    local top = math.max(0, math.floor((self.height - block_h) / 2))
    title.overlap_offset = { inset, top }
    layers[#layers + 1] = title
    if subtitle then
        subtitle.overlap_offset = { inset, top + title:getSize().h + scale(2) }
        layers[#layers + 1] = subtitle
    end
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0,
        bordersize = math.max(1, self.border or 2),
        color = self.border_color or Blitbuffer.COLOR_DARK_GRAY,
        radius = math.max(scale(6), math.floor(self.height * .30)),
        background = self.background or Blitbuffer.COLOR_LIGHT_GRAY,
        OverlapGroup:new{ dimen = self.dimen, allow_mirroring = false, unpack(layers) },
    }
    self.ges_events = { TapDockUpdateAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:paintTo(bb, x, y)
    local range = self.ges_events.TapDockUpdateAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.width, self.height
    return InputContainer.paintTo(self, bb, x, y)
end
function Action:onTapDockUpdateAction()
    if self.callback and not self.disabled then self.callback() end
    return true
end

local PHASE_TITLES = {
    core = _("AppDock core"), dapps = _("DApps"), netsurf = _("NetSurf"), doom = _("Doom"),
}

local function buildPane(instance, context)
    local state = stateFor(instance)
    local pal = themePalette(context)
    if not state.auto_scheduled and not state.updating then
        state.auto_scheduled = true
        if #missingCompanions(context) > 0 then
            UIManager:scheduleIn(0.6, function() pcall(autoInstallCompanions, instance, context, true) end)
        end
    end
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap = px(10), px(8)
    local inner_w = width - 2 * margin
    local border = math.max(1, px(2))
    local elements = {}

    local function add(widget, x, y)
        widget.overlap_offset = { x, y }
        elements[#elements + 1] = widget
        return widget
    end
    local function text(value, face, size, color, bold, max_w)
        return TextWidget:new{
            text = value, face = Font:getFace(face, size), fgcolor = color,
            bold = bold, max_width = max_w, padding = 0,
        }
    end
    local function panel(x, y, w, h, background, bordered, radius)
        return add(FrameContainer:new{
            width = w, height = h, padding = 0,
            bordersize = bordered and border or 0, color = pal.line,
            radius = radius or px(12), background = background, empty(w, h),
        }, x, y)
    end

    -- Release facts -----------------------------------------------------
    local current_version = tostring((context.manager and context.manager.appdock and context.manager.appdock.version) or "?")
    local release = state.release
    local latest = release and release.version or _("Not checked")
    local relation = release and compareVersions(release.version, current_version) or nil
    local netsurf_version_relation = compareVersions(current_version, "8.5.2")
    local missing_dapps = missingCompanions(context)
    local offer_dapps = relation ~= 1 and #missing_dapps > 0
    local offer_doom = relation ~= 1 and not offer_dapps and netsurf_version_relation ~= nil
        and netsurf_version_relation >= 0 and not doomInstalled()
    local offer_netsurf = relation ~= 1 and not offer_dapps and netsurf_version_relation ~= nil
        and netsurf_version_relation >= 0 and doomInstalled() and not netsurfInstalled()

    local status
    if state.updating then status = _("Installing — please keep the reader awake.")
    elseif state.error then status = shorten(state.error, 170)
    elseif not state.checked then status = _("Check GitHub for the latest stable AppDock release.")
    elseif relation == 1 then status = _("A newer AppDock release is ready to install after confirmation.")
    elseif relation == 0 then status = _("This AppDock installation is up to date.")
    elseif relation == -1 then status = _("This installation is newer than the latest published release.")
    else status = _("Release found. The installed version could not be compared automatically.") end
    local notes = release and shorten(release.notes:gsub("\r", ""), 700)
        or _("Release notes appear here after a check. Use the notes button to read the complete release announcement.")

    local chip_text, chip_hot
    if state.updating then chip_text, chip_hot = _("Installing"), true
    elseif state.error then chip_text, chip_hot = _("Error"), false
    elseif not state.checked then chip_text, chip_hot = _("Not checked"), false
    elseif relation == 1 then chip_text, chip_hot = _("Update available"), true
    elseif relation == 0 then chip_text, chip_hot = _("Up to date"), false
    else chip_text, chip_hot = _("Local build"), false end

    -- Background ---------------------------------------------------------
    add(FrameContainer:new{
        width = width, height = height, padding = 0, bordersize = 0,
        background = pal.background, empty(width, height),
    }, 0, 0)

    -- Header -------------------------------------------------------------
    local y = margin
    local header_h = math.max(px(46), math.min(px(64), math.floor(height * .12)))
    panel(margin, y, inner_w, header_h, pal.card, true)
    local text_x = margin + px(14)
    local ok_logo, DAppLogo = pcall(require, "appdock_logo")
    if ok_logo and type(DAppLogo) == "table" and DAppLogo.new then
        local logo_size = header_h - px(16)
        local ok_widget, logo = pcall(function()
            return DAppLogo:new{ kind = "dockupdate", size = logo_size, ink = pal.text }
        end)
        if ok_widget and logo then
            add(logo, margin + px(12), y + math.floor((header_h - logo_size) / 2))
            text_x = margin + px(12) + logo_size + px(12)
        end
    end
    local chip = text(chip_text, "smallinfofont", px(10), chip_hot and pal.on_accent or pal.text, true)
    local chip_size = chip:getSize()
    local chip_w, chip_h = chip_size.w + 2 * px(12), chip_size.h + 2 * px(5)
    local chip_x = margin + inner_w - px(12) - chip_w
    add(FrameContainer:new{
        width = chip_w, height = chip_h, padding = 0,
        bordersize = chip_hot and 0 or math.max(1, px(1)), color = pal.line,
        radius = math.floor(chip_h / 2),
        background = chip_hot and pal.accent or pal.card_alt, empty(chip_w, chip_h),
    }, chip_x, y + math.floor((header_h - chip_h) / 2))
    add(chip, chip_x + px(12), y + math.floor((header_h - chip_size.h) / 2))
    local title_w = math.max(px(40), chip_x - text_x - px(8))
    local title_widget = text(_("DockUpdate"), "cfont", px(17), pal.text, true, title_w)
    local sub_widget = text(_("AppDock release updates"), "smallinfofont", px(9), pal.muted, false, title_w)
    local title_block = title_widget:getSize().h + px(1) + sub_widget:getSize().h
    local title_y = y + math.max(0, math.floor((header_h - title_block) / 2))
    add(title_widget, text_x, title_y)
    add(sub_widget, text_x, title_y + title_widget:getSize().h + px(1))
    y = y + header_h + gap

    -- Version cards -------------------------------------------------------
    local card_w = math.floor((inner_w - gap) / 2)
    local function versionCard(x, caption, value, hot)
        local fg = hot and pal.on_accent or pal.text
        local cap = text(caption:upper(), "smallinfofont", px(8), hot and pal.on_accent or pal.muted, true, card_w - px(20))
        local val = text(value, "cfont", px(18), fg, true, card_w - px(20))
        local h = px(8) + cap:getSize().h + px(2) + val:getSize().h + px(8)
        panel(x, y, card_w, h, hot and pal.accent or pal.card, not hot)
        add(cap, x + px(12), y + px(8))
        add(val, x + px(12), y + px(8) + cap:getSize().h + px(2))
        return h
    end
    local version_h = versionCard(margin, _("Installed"), current_version, false)
    versionCard(margin + card_w + gap, _("Latest"), latest, relation == 1)
    y = y + version_h + gap

    -- Footer geometry -----------------------------------------------------
    local button_h = math.max(px(36), math.floor(height * .12))
    local footer_y = height - margin - button_h
    local avail_bottom = footer_y - gap

    -- Companion list --------------------------------------------------------
    local function stateLabel(installed)
        if installed == true then return _("Installed"), pal.text end
        if installed == false then return _("Not installed"), pal.muted end
        return _("Unavailable"), pal.muted
    end
    local extras = {
        { title = COMPANION_DAPPS[1].title, installed = companionInstalled(context, COMPANION_DAPPS[1]) },
        { title = COMPANION_DAPPS[2].title, installed = companionInstalled(context, COMPANION_DAPPS[2]) },
        { title = "NetSurf", installed = netsurfInstalled() },
    }
    local row_h = px(21)
    local extras_caption = text(_("INSTALLED ALONGSIDE APPDOCK"), "smallinfofont", px(8), pal.muted, true, inner_w - px(24))
    local extras_h = px(9) + extras_caption:getSize().h + px(4) + #extras * row_h + px(6)

    local function drawExtras(top)
        panel(margin, top, inner_w, extras_h, pal.card, true)
        add(extras_caption, margin + px(12), top + px(9))
        local row_y = top + px(9) + extras_caption:getSize().h + px(4)
        for index, extra in ipairs(extras) do
            if index > 1 then
                add(FrameContainer:new{
                    width = inner_w - px(24), height = math.max(1, px(1)), padding = 0, bordersize = 0,
                    background = pal.card_alt, empty(inner_w - px(24), math.max(1, px(1))),
                }, margin + px(12), row_y)
            end
            local label_text, label_color = stateLabel(extra.installed)
            local name = text(extra.title, "smallinfofont", px(11), pal.text, true, math.floor(inner_w * .5))
            local value = text(label_text, "smallinfofont", px(10), label_color, extra.installed == true,
                math.floor(inner_w * .4))
            add(name, margin + px(12), row_y + math.floor((row_h - name:getSize().h) / 2))
            add(value, margin + inner_w - px(12) - value:getSize().w,
                row_y + math.floor((row_h - value:getSize().h) / 2))
            row_y = row_y + row_h
        end
    end

    if state.updating then
        -- Live progress card ---------------------------------------------
        local progress = state.progress or { fraction = 0, label = _("Starting…"), detail = "" }
        local percent = math.floor(math.max(0, math.min(1, progress.fraction or 0)) * 100 + .5)
        local percent_widget = text(percent .. "%", "cfont", px(16), pal.text, true)
        local percent_w = percent_widget:getSize().w
        local label_widget = text(shorten(progress.label or "", 60), "smallinfofont", px(11), pal.text, true,
            inner_w - px(24) - percent_w - px(10))
        local bar_h = math.max(px(14), px(12))
        local detail_widget = text(progress.detail or "", "smallinfofont", px(9), pal.muted, false, math.floor(inner_w * .5))
        local phase_text = PHASE_TITLES[progress.phase or ""] or ""
        local phase_widget = text(phase_text, "smallinfofont", px(9), pal.muted, true, math.floor(inner_w * .4))
        local head_h = math.max(percent_widget:getSize().h, label_widget:getSize().h)
        local card_h = px(10) + head_h + px(8) + bar_h + px(6) + math.max(detail_widget:getSize().h, phase_widget:getSize().h) + px(10)
        panel(margin, y, inner_w, card_h, pal.card, true)
        add(label_widget, margin + px(12), y + px(10) + math.floor((head_h - label_widget:getSize().h) / 2))
        add(percent_widget, margin + inner_w - px(12) - percent_w, y + px(10) + math.floor((head_h - percent_widget:getSize().h) / 2))
        local bar_x, bar_y, bar_w = margin + px(12), y + px(10) + head_h + px(8), inner_w - px(24)
        add(FrameContainer:new{
            width = bar_w, height = bar_h, padding = 0,
            bordersize = math.max(1, px(1)), color = pal.line,
            radius = math.floor(bar_h / 2), background = pal.card_alt, empty(bar_w, bar_h),
        }, bar_x, bar_y)
        local bar_border = math.max(1, px(1))
        local fill_max = bar_w - 2 * bar_border
        local fill_h = bar_h - 2 * bar_border
        local fill_w = math.floor(fill_max * math.max(0, math.min(1, progress.fraction or 0)))
        if (progress.fraction or 0) > 0 then fill_w = math.max(fill_w, fill_h) end
        fill_w = math.min(fill_w, fill_max)
        if fill_w > 0 then
            add(FrameContainer:new{
                width = fill_w, height = fill_h, padding = 0, bordersize = 0,
                radius = math.floor(fill_h / 2), background = pal.accent, empty(fill_w, fill_h),
            }, bar_x + bar_border, bar_y + bar_border)
        end
        local line_y = bar_y + bar_h + px(6)
        add(detail_widget, margin + px(12), line_y)
        add(phase_widget, margin + inner_w - px(12) - phase_widget:getSize().w, line_y)
        y = y + card_h + gap
        if y + extras_h <= avail_bottom then drawExtras(y) end
    else
        -- Notes card ------------------------------------------------------
        local show_extras = avail_bottom - y - extras_h - gap >= px(56)
        local notes_h = avail_bottom - y - (show_extras and (extras_h + gap) or 0)
        notes_h = math.max(px(40), notes_h)
        panel(margin, y, inner_w, notes_h, pal.card, true)
        add(TextBoxWidget:new{
            bgcolor = pal.card,
            text = status .. "\n\n" .. notes,
            face = Font:getFace("smallinfofont", px(9)),
            width = inner_w - px(24),
            height = math.max(px(20), notes_h - px(20)),
            line_height = 0.32,
            alignment = "left",
            fgcolor = pal.text,
        }, margin + px(12), y + px(10))
        y = y + notes_h + gap
        if show_extras then drawExtras(y) end
    end

    -- Buttons ---------------------------------------------------------------
    local third = math.floor((inner_w - 2 * gap) / 3)
    local primary_ready = relation == 1 or offer_dapps or offer_doom or offer_netsurf
    local install_title, install_subtitle, install_callback
    if relation == 1 then
        install_title, install_subtitle = _("Install update"), _("AppDock ") .. latest
        install_callback = function() confirmInstall(instance, context) end
    elseif offer_dapps then
        local names = {}
        for _index, entry in ipairs(missing_dapps) do names[#names + 1] = entry.title end
        install_title, install_subtitle = _("Install DApps"), table.concat(names, " · ")
        install_callback = function() confirmCompanionInstall(instance, context) end
    elseif offer_doom then
        install_title, install_subtitle = _("Install Doom"), _("Separate game package")
        install_callback = function() confirmDoomInstall(instance, context) end
    elseif offer_netsurf then
        install_title, install_subtitle = _("Install NetSurf"), _("Retry NetSurf setup")
        install_callback = function() confirmNetsurfInstall(instance, context) end
    else
        install_title, install_subtitle = _("Up to date"), _("Nothing to install")
        install_callback = function() confirmInstall(instance, context) end
    end
    local busy = state.updating == true
    local function button(index, title, subtitle, callback, primary)
        local hot = primary and not busy
        add(Action:new{
            title = title, subtitle = subtitle, width = third, height = button_h,
            background = hot and pal.accent or pal.card,
            foreground = hot and pal.on_accent or (busy and pal.muted or pal.text),
            subtitle_color = hot and pal.on_accent or pal.muted,
            border_color = pal.line, border = border, disabled = busy,
            callback = callback,
        }, margin + (index - 1) * (third + gap), footer_y)
    end
    button(1, _("Check updates"), _("GitHub release"), function() checkForRelease(instance, context) end, false)
    button(2, _("Release Notes"), release and release.tag or _("Check first"), function() showNotes(instance, context) end, false)
    button(3, install_title, install_subtitle, install_callback, primary_ready)

    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

return {
    id = "dock_update",
    version = "2.1.0",
    title = "DockUpdate",
    subtitle = "AppDock release updates",
    symbol = "U",
    logo = "dockupdate",
    buildPane = buildPane,
    backgroundTick = safeBackgroundTick,
    onAutostart = function(instance, context)
        local result = safeBackgroundTick(instance, context)
        pcall(autoInstallCompanions, instance, context, false)
        return result
    end,
    _test = { listNetsurfZip = listNetsurfZip, listDoomZip = listDoomZip },
}
