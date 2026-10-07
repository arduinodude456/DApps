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
local InputDialog = require("ui/widget/inputdialog")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local JSON = require("json")
local _ = require("gettext")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local Screen = Device.screen
local REPOSITORY = "arduinodude456/appdock.koplugin"
local API_ROOT = "https://api.github.com/repos/" .. REPOSITORY
local RAW_ROOT = "https://raw.githubusercontent.com/" .. REPOSITORY
local RELEASE_URL = API_ROOT .. "/releases/latest"
local MAX_METADATA_BYTES = 128 * 1024
-- Keep enough headroom for the growing AppDock DApp host while retaining a
-- strict per-file bound for downloaded Lua source.
local MAX_FILE_BYTES = 192 * 1024
local MAX_ASSET_BYTES = 3 * 1024 * 1024
local MAX_TOTAL_BYTES = 16 * 1024 * 1024
local UPDATE_PASSWORD = "b8-adt73548"
-- A current AppDock release contains the core Lua modules plus bundled
-- logos, lockscreen art and raster surface assets. Keep the count bounded,
-- but do not reject that explicit package layout as "too many source files".
local MAX_SOURCE_FILES = 48
local MAX_RELEASE_NOTES = 16 * 1024
local REQUIRED_FILES = {
    "_meta.lua", "main.lua", "appdock_appstore.lua", "appdock_browser.lua",
    "appdock_dapps.lua", "appdock_filemanager.lua", "appdock_homescreen.lua",
    "appdock_logo.lua", "appdock_manager.lua", "appdock_quicksettings.lua",
    "appdock_theme.lua", "appdock_notifications.lua", "appdock_help.lua", "appdock_boot.lua",
    "appdock_wallpaper.lua", "appdock_lockscreen.lua", "appdock_device_controls.lua",
}
local ALLOWED_SOURCE_FILES = {
    ["_meta.lua"] = true, ["main.lua"] = true,
    ["appdock_appstore.lua"] = true, ["appdock_boot.lua"] = true,
    ["appdock_browser.lua"] = true, ["appdock_dapps.lua"] = true,
    ["appdock_filemanager.lua"] = true, ["appdock_help.lua"] = true,
    ["appdock_homescreen.lua"] = true, ["appdock_keyboard.lua"] = true,
    ["appdock_layout.lua"] = true, ["appdock_lockscreen.lua"] = true,
    ["appdock_logo.lua"] = true, ["appdock_manager.lua"] = true,
    ["appdock_motion.lua"] = true, ["appdock_notifications.lua"] = true,
    ["appdock_order.lua"] = true, ["appdock_quicksettings.lua"] = true,
    ["appdock_sleepscreen.lua"] = true, ["appdock_surface.lua"] = true,
    ["appdock_theme.lua"] = true, ["appdock_wallpaper.lua"] = true,
    ["appdock_device_controls.lua"] = true,
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

local function decodeJSON(body)
    local ok, decoded = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok or type(decoded) ~= "table" then return nil, _("The update metadata is not valid JSON.") end
    return decoded
end

local function releaseFromJSON(body)
    local raw, err = decodeJSON(body)
    if not raw then return nil, err end
    if raw.draft or raw.prerelease then return nil, _("The latest AppDock release is not a stable release.") end
    local tag = trim(raw.tag_name)
    if not normalizedVersion(tag) then return nil, _("The release tag has an unsupported version format.") end
    local notes = type(raw.body) == "string" and raw.body:sub(1, MAX_RELEASE_NOTES) or ""
    return {
        tag = tag,
        version = tag:gsub("^v", ""),
        name = trim(raw.name) ~= "" and trim(raw.name) or ("AppDock " .. tag),
        notes = notes ~= "" and notes or _("This release has no notes."),
        published = trim(raw.published_at),
        url = trim(raw.html_url),
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

local function releasePathKind(path)
    if safeSourcePath(path) then return "source" end
    if safeAssetPath(path) then return "asset" end
    return nil
end

local function sourceTreeFromJSON(body)
    local raw, err = decodeJSON(body)
    if not raw then return nil, err end
    if raw.truncated then return nil, _("The release file list is incomplete.") end
    if type(raw.tree) ~= "table" then return nil, _("The release contains no readable file list.") end

    -- Some repository layouts contain both the source files at the root and a
    -- packaged appdock.koplugin/ mirror. Prefer the complete packaged mirror:
    -- in AppDock 1.8.1 it contains the current _meta.lua while the old root
    -- mirror does not. The destination is still the active plugin root.
    local packaged = {}
    for item_index, item in ipairs(raw.tree) do
        if type(item) == "table" and item.type == "blob" and type(item.path) == "string" then
            local inner = item.path:match("^appdock%.koplugin/(.+)$")
            if inner and releasePathKind(inner) then packaged[inner] = true end
        end
    end
    local use_packaged = true
    for required_index, required in ipairs(REQUIRED_FILES) do
        if not packaged[required] then use_packaged = false; break end
    end

    local entries, seen, total = {}, {}, 0
    for item_index, item in ipairs(raw.tree) do
        if type(item) == "table" and item.type == "blob" then
            local original_path, path, size = item.path, item.path, tonumber(item.size)
            local source_path = original_path
            if use_packaged then
                path = type(original_path) == "string" and original_path:match("^appdock%.koplugin/(.+)$") or nil
                if not path then
                    -- Root files are an older repository mirror when a complete
                    -- package directory exists; they must not override it.
                    path = nil
                else
                    source_path = original_path
                end
            end
            if path and not path:match("%.md$") then
                local kind = releasePathKind(path)
                if not kind then return nil, _("The release contains an unsupported file: ") .. tostring(original_path) end
                local max_size = kind == "asset" and MAX_ASSET_BYTES or MAX_FILE_BYTES
                if not size or size < 1 or size > max_size then return nil, kind == "asset" and _("A release PNG asset has an invalid size.") or _("A release source file has an invalid size.") end
                if seen[path] then return nil, _("The release contains duplicate source files.") end
                seen[path] = true
                total = total + size
                if total > MAX_TOTAL_BYTES then return nil, _("The release source package is too large.") end
                entries[#entries + 1] = { path = path, source_path = source_path, size = size, kind = kind }
                if #entries > MAX_SOURCE_FILES then return nil, _("The release contains too many source files.") end
            end
        end
    end
    for required_index, required in ipairs(REQUIRED_FILES) do
        if not seen[required] then return nil, _("The release lacks a required AppDock module: ") .. required end
    end
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
        local max_size = is_asset and MAX_ASSET_BYTES or MAX_FILE_BYTES
        local accept = is_asset and "image/png,*/*;q=0.1" or "text/plain,text/x-lua;q=0.9,*/*;q=0.1"
        local source, fetch_err = fetch(RAW_ROOT .. "/" .. release.tag .. "/" .. (entry.source_path or entry.path), max_size, accept)
        if not source then removeTree(stage); return nil, _("Could not download ") .. entry.path .. ": " .. tostring(fetch_err) end
        if #source ~= entry.size then removeTree(stage); return nil, _("Downloaded file size does not match release metadata: ") .. entry.path end
        if is_asset then
            if not isPng(source) then removeTree(stage); return nil, _("Downloaded PNG asset has an invalid signature: ") .. entry.path end
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
            if not content or #content ~= entry.size or not isPng(content) then
                removeTree(stage)
                return nil, _("Staged PNG asset validation failed: ") .. entry.path
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
    local body, fetch_err = fetch(RELEASE_URL, MAX_METADATA_BYTES, "application/vnd.github+json")
    if not body then
        state.release, state.error, state.checked = nil, _("Could not check AppDock releases: ") .. tostring(fetch_err), true
        requestRebuild(context)
        return
    end
    local release, parse_err = releaseFromJSON(body)
    state.release, state.error, state.checked = release, parse_err, true
    requestRebuild(context)
end

local function backgroundTick(instance, context)
    local state = stateFor(instance)
    local body = fetch(RELEASE_URL, MAX_METADATA_BYTES, "application/vnd.github+json")
    if not body then return false end
    local release = releaseFromJSON(body)
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
    local url = API_ROOT .. "/git/trees/" .. state.release.tag .. "?recursive=1"
    local body, fetch_err = fetch(url, MAX_METADATA_BYTES, "application/vnd.github+json")
    if not body then return nil, _("Could not read the release file list: ") .. tostring(fetch_err) end
    local entries, tree_err = sourceTreeFromJSON(body)
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

local function promptForPassword(on_success)
    local dialog
    dialog = InputDialog:new{
        title = _("AppDock update password"),
        input = "",
        input_hint = _("Enter the password to authorize this update"),
        input_type = "password",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Authorize"), is_enter_default = true, callback = function()
                local entered = dialog:getInputText() or ""
                UIManager:close(dialog)
                if entered ~= UPDATE_PASSWORD then
                    showMessage(_("Incorrect update password. The AppDock files were not changed."))
                    return
                end
                on_success()
                end },
        },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
    promptForPassword(function()
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
    end)
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
    version = "1.2.0",
    title = "DockUpdate",
    subtitle = "AppDock release updates",
    symbol = "U",
    logo = "dockupdate",
    buildPane = buildPane,
    backgroundTick = safeBackgroundTick,
    onAutostart = safeBackgroundTick,
}
