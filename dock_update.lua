--[[--
DockUpdate for AppDock.

A local, explicit-confirmation updater for the AppDock core plugin. It reads
release metadata only from the pinned public GitHub repository, displays the
release notes, validates a small root-level Lua release tree plus bundled PNG
assets, stages every file, and atomically swaps the active plugin folder only
after the user confirms. The previous plugin folder is kept as a nearby
rollback backup.
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
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local Screen = Device.screen
local REPOSITORY = "arduinodude456/appdock.koplugin"
local RAW_ROOT = "https://raw.githubusercontent.com/" .. REPOSITORY
-- GitHub's unauthenticated REST API is limited per public IP.  Use the
-- public Atom feed for release metadata and raw.githubusercontent.com for the
-- fixed, local allowlist instead; neither endpoint consumes the REST quota.
local RELEASE_URL = "https://github.com/" .. REPOSITORY .. "/releases.atom"
local MAX_METADATA_BYTES = 128 * 1024
-- AppDock 7.9.21's appdock_dapps.lua is 205,636 bytes. Keep a strict bounded
-- source limit with headroom for the current DApp host and modest growth.
local MAX_FILE_BYTES = 256 * 1024
local MAX_ASSET_BYTES = 3 * 1024 * 1024
local MAX_DATA_BYTES = 512 * 1024
local MAX_TOTAL_BYTES = 16 * 1024 * 1024
-- The AppDock 7.9.21 package has 53 allowlisted files (30 Lua modules and
-- 23 PNG assets). Keep a hard cap with room for modest future additions.
local MAX_RELEASE_FILES = 64
local MAX_RELEASE_NOTES = 16 * 1024
local REQUIRED_FILES = {
    "_meta.lua", "main.lua", "appdock_appstore.lua", "appdock_browser.lua",
    "appdock_dapps.lua", "appdock_filemanager.lua", "appdock_groups.lua", "appdock_homescreen.lua",
    "appdock_logo.lua", "appdock_manager.lua", "appdock_quicksettings.lua",
    "appdock_theme.lua", "appdock_notifications.lua", "appdock_help.lua", "appdock_boot.lua",
    "appdock_wallpaper.lua", "appdock_lockscreen.lua", "appdock_device_controls.lua",
    "appdock_audio.lua", "appdock_bwr.lua", "appdock_player.lua", "appdock_youtube.lua",
    "appdock_ytmusic.lua", "appdock_dialogs.lua", "appdock_draw.lua", "appdock_stylus.lua",
    "appdock_suggestions.lua", "appdock_tbs_account.lua", "appdock_suggestions.db",
}
local ALLOWED_SOURCE_FILES = {
    ["_meta.lua"] = true, ["main.lua"] = true,
    ["appdock_appstore.lua"] = true, ["appdock_boot.lua"] = true,
    ["appdock_browser.lua"] = true, ["appdock_dapps.lua"] = true,
    ["appdock_filemanager.lua"] = true, ["appdock_groups.lua"] = true, ["appdock_help.lua"] = true,
    ["appdock_homescreen.lua"] = true, ["appdock_keyboard.lua"] = true,
    ["appdock_layout.lua"] = true, ["appdock_lockscreen.lua"] = true,
    ["appdock_logo.lua"] = true, ["appdock_manager.lua"] = true,
    ["appdock_motion.lua"] = true, ["appdock_notifications.lua"] = true,
    ["appdock_order.lua"] = true, ["appdock_quicksettings.lua"] = true,
    ["appdock_sleepscreen.lua"] = true,
    ["appdock_theme.lua"] = true, ["appdock_wallpaper.lua"] = true,
    ["appdock_device_controls.lua"] = true,
    ["appdock_audio.lua"] = true, ["appdock_bwr.lua"] = true,
    ["appdock_player.lua"] = true, ["appdock_youtube.lua"] = true,
    ["appdock_dialogs.lua"] = true, ["appdock_draw.lua"] = true,
    ["appdock_ytmusic.lua"] = true, ["appdock_stylus.lua"] = true,
    ["appdock_suggestions.lua"] = true, ["appdock_tbs_account.lua"] = true,
}
local ALLOWED_DATA_FILES = {
    ["appdock_suggestions.db"] = true,
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
    ["assets/wallpaper/appdock_default.svg"] = true,
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

local function fetch(url, limit, accept)
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

local function releaseEntries()
    local entries = {}
    for path in pairs(ALLOWED_SOURCE_FILES) do
        entries[#entries + 1] = { path = path, source_path = "appdock.koplugin/" .. path, kind = "source" }
    end
    for path in pairs(ALLOWED_ASSET_FILES) do
        entries[#entries + 1] = { path = path, source_path = "appdock.koplugin/" .. path, kind = "asset" }
    end
    for path in pairs(ALLOWED_DATA_FILES) do
        entries[#entries + 1] = { path = path, source_path = "appdock.koplugin/" .. path, kind = "data" }
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
local function isSafeSvg(content)
    if type(content) ~= "string" or #content == 0 or #content > MAX_ASSET_BYTES then return false end
    local lower = content:lower()
    if not lower:match("^%s*<%?xml[^>]*>%s*<svg[%s>]") and not lower:match("^%s*<svg[%s>]") then return false end
    -- The bundled wallpaper is deliberately static. Do not permit executable,
    -- event-bound or remotely fetched SVG content through the update channel.
    return not lower:find("<script", 1, true)
        and not lower:find("<foreignobject", 1, true)
        and not lower:find("href%s*=%s*[\"']https?://")
        and not lower:find("url%s*%(%s*[\"']?https?://")
        and not lower:find("on[%a_%-]+%s*=")
end
local function validAsset(path, content)
    if type(path) ~= "string" then return false end
    if path:match("%.png$") then return isPng(content) end
    if path == "assets/wallpaper/appdock_default.svg" then return isSafeSvg(content) end
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

local function activePlugin(context)
    local appdock = context and context.manager and context.manager.appdock
    local path = appdock and appdock.path
    if type(path) ~= "string" or path == "" or path:match("[%z\r\n]") then return nil, _("DockUpdate cannot identify the active AppDock plugin folder.") end
    if path:match("([^/]+)$") ~= "appdock.koplugin" or lfs.attributes(path, "mode") ~= "directory" then
        return nil, _("The active AppDock plugin folder is unavailable.")
    end
    return path, tostring(appdock.version or "?")
end

local function stageRelease(release, entries, target)
    local safe_tag = release.tag:gsub("^v", "")
    local stage = target .. ".appdock-stage-" .. safe_tag
    local cleaned, clean_err = removeTree(stage)
    if not cleaned then return nil, clean_err or _("An old update staging folder could not be removed.") end
    local created, mkdir_err = lfs.mkdir(stage)
    if not created then return nil, mkdir_err or _("The update staging folder could not be created.") end

    for entry_index, entry in ipairs(entries) do
        local is_asset = entry.kind == "asset"
        local is_data = entry.kind == "data"
        local max_size = is_asset and MAX_ASSET_BYTES or (is_data and MAX_DATA_BYTES or MAX_FILE_BYTES)
        local accept = is_asset and "image/png,image/svg+xml,*/*;q=0.1" or "text/plain,text/x-lua;q=0.9,*/*;q=0.1"
        local source, fetch_err = fetch(RAW_ROOT .. "/" .. release.tag .. "/" .. (entry.source_path or entry.path), max_size, accept)
        if not source then removeTree(stage); return nil, _("Could not download ") .. entry.path .. ": " .. tostring(fetch_err) end
        if entry.size and #source ~= entry.size then removeTree(stage); return nil, _("Downloaded file size does not match release metadata: ") .. entry.path end
        if is_asset then
            if not validAsset(entry.path, source) then removeTree(stage); return nil, _("Downloaded asset is invalid: ") .. entry.path end
        elseif is_data then
            if not isSuggestionDatabase(source) then
                removeTree(stage); return nil, _("Downloaded suggestion database has an invalid format: ") .. entry.path
            end
        else
            local chunk, syntax_err = loadstring(source, "@dockupdate/" .. entry.path)
            if not chunk then removeTree(stage); return nil, _("Downloaded source has invalid Lua syntax: ") .. entry.path .. "\n" .. tostring(syntax_err) end
        end
        local parent_ok, parent_err = ensureParentDirectories(stage, entry.path)
        if not parent_ok then removeTree(stage); return nil, _("Could not create the asset directory for ") .. entry.path .. ": " .. tostring(parent_err) end
        local saved, save_err = writeFile(stage .. "/" .. entry.path, source)
        if not saved then removeTree(stage); return nil, _("Could not stage ") .. entry.path .. ": " .. tostring(save_err) end
    end

    -- Verify the staged files once more from disk before touching the active plugin.
    for entry_index, entry in ipairs(entries) do
        if entry.kind == "asset" then
            local file = io.open(stage .. "/" .. entry.path, "rb")
            local content = file and file:read("*a") or nil
            if file then file:close() end
            if not content or (entry.size and #content ~= entry.size) or not validAsset(entry.path, content) then
                removeTree(stage)
                return nil, _("Staged asset validation failed: ") .. entry.path
            end
        elseif entry.kind == "data" then
            local file = io.open(stage .. "/" .. entry.path, "rb")
            local content = file and file:read("*a") or nil
            if file then file:close() end
            if not isSuggestionDatabase(content) then
                removeTree(stage)
                return nil, _("Staged suggestion database validation failed: ") .. entry.path
            end
        else
            local chunk, syntax_err = loadfile(stage .. "/" .. entry.path)
            if not chunk then removeTree(stage); return nil, _("Staged source validation failed: ") .. entry.path .. "\n" .. tostring(syntax_err) end
        end
    end
    return stage
end

local function installRelease(release, entries, target, installed_version)
    local stage, stage_err = stageRelease(release, entries, target)
    if not stage then return nil, stage_err end
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

local Action = InputContainer:extend{ title = nil, subtitle = nil, callback = nil, width = nil, height = nil, background = nil, foreground = nil, dimen = nil }
function Action:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local inset = scale(7)
    local layers = {
        TextWidget:new{
            text = self.title or "",
            face = Font:getFace("smallinfofont", scale(11)),
            bold = true,
            fgcolor = self.foreground or Blitbuffer.COLOR_BLACK,
            max_width = self.width - 2 * inset,
            overlap_offset = { inset, math.max(scale(4), math.floor(self.height * 0.23)) },
        },
    }
    if self.subtitle and self.subtitle ~= "" then
        layers[#layers + 1] = TextWidget:new{
            text = self.subtitle,
            face = Font:getFace("smallinfofont", scale(8)),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = self.width - 2 * inset,
            overlap_offset = { inset, math.max(scale(18), math.floor(self.height * 0.58)) },
        }
    end
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = 0,
        radius = math.max(scale(4), math.floor(self.height * .22)),
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
function Action:onTapDockUpdateAction() if self.callback then self.callback() end; return true end

local function stateFor(instance)
    if instance.dock_update then return instance.dock_update end
    instance.dock_update = { release = nil, files = nil, error = nil, checked = false, updating = false }
    return instance.dock_update
end

local function requestRebuild(context)
    if context and context.requestRebuild then context.requestRebuild("ui") end
end

local function showMessage(text)
    UIManager:show(InfoMessage:new{ text = text })
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
    local entries, tree_err = releaseEntries()
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
    UIManager:show(ConfirmBox:new{
            text = _("Install the trusted AppDock update now?\n\n")
                .. _("Installed: ") .. tostring(installed_version_or_err) .. "\n"
                .. _("Release: ") .. release.version .. "\n"
                .. _("Validated source files: ") .. #entries
                .. _("\n\nEach source file will be downloaded over HTTPS, syntax-checked, staged, then swapped atomically. Your current AppDock folder will be retained as a rollback backup. Restart KOReader after the update."),
            ok_text = _("Install update"),
            ok_callback = function()
                state.updating = true
                requestRebuild(context)
                local backup, update_err = installRelease(release, entries, target, installed_version_or_err)
                state.updating = false
                if not backup then
                    state.error = _("AppDock update failed: ") .. tostring(update_err)
                    showMessage(state.error)
                else
                    state.error = nil
                    showMessage(_("AppDock was updated to ") .. release.version .. _(".\n\nRestart KOReader now to load the new plugin files.\n\nRollback backup:\n") .. backup)
                end
                requestRebuild(context)
            end,
    })
end

local function background(width, height)
    return FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) }
end

local function buildPane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or scale
    local margin, gap = px(8), px(5)
    local title_h = math.max(px(24), math.floor(height * .09))
    local button_h = math.max(px(30), math.floor(height * .13))
    local footer_y = height - margin - button_h
    local notes_y = margin + title_h + gap + math.max(px(42), math.floor(height * .17)) + gap
    local notes_h = math.max(px(26), footer_y - notes_y - gap)
    local current_version = (context.manager and context.manager.appdock and context.manager.appdock.version) or "?"
    local release = state.release
    local latest = release and release.version or _("Not checked")
    local relation = release and compareVersions(release.version, tostring(current_version)) or nil
    local status
    if state.updating then status = _("Installing staged update…")
    elseif state.error then status = shorten(state.error, 170)
    elseif not state.checked then status = _("Check GitHub for the latest stable AppDock release.")
    elseif relation == 1 then status = _("A newer AppDock release is ready to install after confirmation.")
    elseif relation == 0 then status = _("This AppDock installation is up to date.")
    elseif relation == -1 then status = _("This installation is newer than the latest published release.")
    else status = _("Release found. The installed version could not be compared automatically.") end
    local notes = release and shorten(release.notes:gsub("\r", ""), 700) or _("Release Notes appear here after a check. Use the notes button to read the complete release announcement.")
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    local install_title = relation == 1 and _("Install update") or _("Up to date")
    local install_subtitle = relation == 1 and (_("AppDock ") .. latest) or _("Confirmation required")
    local elements = {
        background(width, height),
        TextWidget:new{ text = _("DockUpdate"), face = Font:getFace("cfont", px(18)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, margin } },
        TextWidget:new{ text = _("Installed: ") .. tostring(current_version) .. "    " .. _("Latest: ") .. latest, face = Font:getFace("smallinfofont", px(10)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + title_h } },
        TextBoxWidget:new{ text = status .. "\n\n" .. notes, face = Font:getFace("smallinfofont", px(9)), width = width - 2 * margin, height = notes_h, line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, notes_y } },
        Action:new{ title = _("Check updates"), subtitle = _("GitHub release"), width = third, height = button_h, callback = function() checkForRelease(instance, context) end, overlap_offset = { margin, footer_y } },
        Action:new{ title = _("Release Notes"), subtitle = release and release.tag or _("Check first"), width = third, height = button_h, callback = function() showNotes(instance, context) end, overlap_offset = { margin + third + gap, footer_y } },
        Action:new{ title = install_title, subtitle = install_subtitle, width = third, height = button_h, background = relation == 1 and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY, callback = function() confirmInstall(instance, context) end, overlap_offset = { margin + 2 * (third + gap), footer_y } },
    }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

return {
    id = "dock_update",
    version = "1.3.1",
    title = "DockUpdate",
    subtitle = "AppDock release updates",
    symbol = "U",
    logo = "dockupdate",
    buildPane = buildPane,
    backgroundTick = safeBackgroundTick,
    onAutostart = safeBackgroundTick,
}
