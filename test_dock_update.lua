local root = "/tmp/dock_update_test_data"
unpack = unpack or table.unpack
loadstring = loadstring or load
os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root .. "/plugins/appdock.koplugin")

local function quote(path) return "'" .. tostring(path):gsub("'", "'\\''") .. "'" end
local function directory(path)
    local process = io.popen("[ -d " .. quote(path) .. " ] && printf directory")
    local result = process:read("*a"); process:close()
    return result == "directory"
end
local function mode(path)
    if directory(path) then return "directory" end
    local file = io.open(path, "rb")
    if file then file:close(); return "file" end
end
local function fileSize(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end
local function listDirectory(path)
    local process = io.popen("find " .. quote(path) .. " -mindepth 1 -maxdepth 1 -printf '%f\\n' 2>/dev/null")
    local names = {}
    for name in process:lines() do names[#names + 1] = name end
    process:close()
    local index = 0
    return function() index = index + 1; return names[index] end
end

local function class(proto)
    proto = proto or {}; proto.__index = proto
    function proto:extend(child) child = child or {}; child.__index = child; setmetatable(child, { __index = self }); return child end
    function proto:new(values) local value = values or {}; setmetatable(value, self); if value.init then value:init() end; return value end
    return proto
end
local Widget = class({})
function Widget:getSize()
    local size = self.face and self.face.size or 12
    return { w = #tostring(self.text or "") * size * .5, h = size }
end
local WidgetContainer = Widget:extend({})
local InputContainer = WidgetContainer:extend({})
function InputContainer:paintTo() end
local InputDialog = Widget:extend({})
function InputDialog:getInputText() return self.input or "" end
function InputDialog:onShowKeyboard() self.keyboard_shown = true end
local function simpleModule() return WidgetContainer end
local log = { shown = nil, rebuilds = 0, requests = {}, timeouts = {}, large_file_failure = false }

local required = {
    "_meta.lua", "main.lua", "appdock_recovery.lua", "appdock_order.lua",
    "appdock_appstore.lua", "appdock_browser.lua",
    "appdock_dapps.lua", "appdock_filemanager.lua", "appdock_groups.lua", "appdock_homescreen.lua",
    "appdock_logo.lua", "appdock_manager.lua", "appdock_quicksettings.lua",
    "appdock_theme.lua", "appdock_notifications.lua", "appdock_help.lua", "appdock_boot.lua",
    "appdock_wallpaper.lua", "appdock_lockscreen.lua", "appdock_device_controls.lua",
    "appdock_audio.lua", "appdock_bwr.lua", "appdock_dither.lua", "appdock_player.lua", "appdock_youtube.lua",
    "appdock_ytmusic.lua", "appdock_dialogs.lua", "appdock_draw.lua", "appdock_stylus.lua",
    "appdock_suggestions.lua", "appdock_setup.lua", "appdock_tbs_account.lua", "appdock_keyboard.lua", "appdock_layout.lua", "appdock_motion.lua",
    "appdock_sleepscreen.lua", "appdock_sleepscreen_catalog.lua",
    "appdock_sleepscreen_editor.lua", "appdock_sleepscreen_presets.lua",
    "appdock_sleepscreen_renderer.lua", "appdock_sleepscreen_store.lua",
    "appdock_suggestions.db", "features.adf",
}
local optional_sources = {
}
local versioned_sources = {
    "appdock_bluetooth.lua", "appdock_sleepscreen_weather.lua", "appdock_transfer.lua",
    "appdock_text.lua", "appdock_youtube_shorts.lua", "appdock_netsurf.lua", "appdock_doom.lua",
    "appdock_media.lua", "appdock_whatsnew.lua", "appdock_glass.lua", "appdock_anim.lua",
}
local future_sources = { "appdock_gradient.lua", "appdock_rotation.lua" }
local jpeg_assets = { "assets/lockscreen/appdock_lockscreen_aurora.jpg" }
local upcoming_sources = { "appdock_health.lua" }
local release_97_sources = {
    "appdock_color.lua", "appdock_features.lua", "appdock_filechooser.lua",
    "appdock_pet.lua", "appdock_shutdown.lua", "appdock_skin.lua",
}
local skin_assets = {
    "assets/skin/cyber_circuit.png", "assets/skin/cyber_city.png", "assets/skin/cyber_grid.png",
    "assets/skin/cyber_hex.png", "assets/skin/cyber_scan.png",
}
local png_assets = {
    "assets/lockscreen/appdock_lockscreen_hero.png",
    "assets/logos/analog_clock.png", "assets/logos/app_store.png",
    "assets/logos/appdock.png", "assets/logos/battery.png",
    "assets/logos/calculator.png", "assets/logos/calendar.png",
    "assets/logos/dchat.png", "assets/logos/display.png",
    "assets/logos/dockupdate.png", "assets/logos/document.png",
    "assets/logos/file_manager.png", "assets/logos/help.png",
    "assets/logos/minecraft.png", "assets/logos/music.png",
    "assets/logos/network.png", "assets/logos/notes.png",
    "assets/logos/settings.png", "assets/logos/web_browser.png",
    "assets/screensaver/happy_ereader_01.png", "assets/screensaver/happy_ereader_02.png",
    "assets/screensaver/happy_ereader_03.png", "assets/screensaver/happy_ereader_04.png",
}
local sources = {}
for _, name in ipairs(required) do
    sources[name] = "-- staged " .. name .. "\nreturn {}\n"
end
for _, name in ipairs(upcoming_sources) do
    sources[name] = "-- staged " .. name .. "\nreturn {}\n"
end
sources["main.lua"] = "-- new main\nreturn { name = 'appdock' }\n"
sources["_meta.lua"] = "return { version = '7.9.14' }\n"
sources["appdock_suggestions.db"] = "# AppDock offline bilingual suggestion database v1\n# language<TAB>frequency<TAB>word\nde\t7.4\tdie\nen\t7.4\tthe\n"
local packaged_sources = {}
for _, name in ipairs(required) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
for _, name in ipairs(optional_sources) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
for _, name in ipairs(versioned_sources) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
for _, name in ipairs(upcoming_sources) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
for _, name in ipairs(future_sources) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
for _, name in ipairs(release_97_sources) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
-- Match the AppDock 9.5.2 DApp-host module size to cover the large-file path.
packaged_sources["appdock_dapps.lua"] = "--" .. string.rep("x", 299653) .. "\n"
assert(#packaged_sources["appdock_dapps.lua"] == 299656, "The AppDock 9.5.2 host fixture must match its published byte size")
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-8.2.1' }\n"
packaged_sources["_meta.lua"] = "return { version = '8.2.1' }\n"
packaged_sources["appdock_suggestions.db"] = "# AppDock offline suggestion database v1\n# language<TAB>frequency<TAB>word\nde\t7.4\tdie\nen\t7.4\tthe\n"
packaged_sources["features.adf"] = "# AppDock news\n[page]\ntitle=AppDock update\ntext=New features are ready.\nbuttons=Done\n"
local png_signature = "\137PNG\r\n\26\nfixture"
local jpeg_signature = "\255\216\255fixture"
for _, asset in ipairs(png_assets) do packaged_sources[asset] = png_signature end
for _, asset in ipairs(jpeg_assets) do packaged_sources[asset] = jpeg_signature end
for _, asset in ipairs(skin_assets) do packaged_sources[asset] = png_signature end
local feed = [[<feed><entry>
<id>tag:github.com,2008:Repository/1345844414/v8.2.1</id>
<updated>2026-10-11T07:53:22Z</updated>
<link rel="alternate" type="text/html" href="https://github.com/arduinodude456/appdock.koplugin/releases/tag/v8.2.1"/>
<title>AppDock 8.2.1</title>
<content type="html">&lt;h1&gt;AppDock 8.2.1&lt;/h1&gt;&lt;p&gt;Sleepscreen catalogue and editor loading fix&lt;/p&gt;</content>
</entry></feed>]]

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dark", COLOR_LIGHT_GRAY = "light", COLOR_GRAY_8 = "g8" } end
package.preload["datastorage"] = function() return { getDataDir = function() return root end } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, value) return value end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size or 12 } end } end
package.preload["ui/geometry"] = function() return { new = function(_, values) return values end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, values) return values end } end
package.preload["ui/widget/container/centercontainer"] = simpleModule
package.preload["ui/widget/container/framecontainer"] = simpleModule
package.preload["ui/widget/horizontalspan"] = simpleModule
package.preload["ui/widget/confirmbox"] = simpleModule
package.preload["ui/widget/infomessage"] = simpleModule
package.preload["ui/widget/inputdialog"] = function() return InputDialog end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/overlapgroup"] = simpleModule
package.preload["ui/widget/textboxwidget"] = simpleModule
package.preload["ui/widget/textviewer"] = simpleModule
package.preload["ui/widget/textwidget"] = simpleModule
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["ui/uimanager"] = function() return { show = function(_, item) log.shown = item end, close = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            local result = mode(path)
            if attribute == "mode" then return result end
            if attribute == "size" then return result == "file" and fileSize(path) or nil end
            return result and { mode = result } or nil
        end,
        mkdir = function(path) os.execute("mkdir " .. quote(path)); return directory(path) end,
        rmdir = function(path) os.execute("rmdir " .. quote(path) .. " 2>/dev/null"); return not directory(path) end,
        dir = listDirectory,
    }
end
package.preload["socket.url"] = function() return { parse = function(url) local scheme, host = url:match("^(https?)://([^/%?#]+)"); return scheme and { scheme = scheme, host = host } or {} end } end
package.preload["socket"] = function() return { skip = function(_, a, code, headers, status) return code, headers, status end } end
package.preload["socketutil"] = function() return { USER_AGENT = "DockUpdateTest", set_timeout = function(_, _, timeout) log.timeouts[#log.timeouts + 1] = timeout end, reset_timeout = function() end } end
package.preload["ssl.https"] = function()
    return { request = function(request)
        log.requests[#log.requests + 1] = request.url
        if request.url:find("/appdock.koplugin/appdock_dapps.lua", 1, true) and not log.large_file_failure then
            log.large_file_failure = true
            error("simulated connection reset")
        end
        if request.url:find("releases.atom", 1, true) then request.sink(feed)
        else
            local packaged = request.url:find("/appdock.koplugin/", 1, true) ~= nil
            local name = request.url:match("/([^/]+%.lua)$") or request.url:match("/([^/]+%.png)$") or request.url:match("/([^/]+%.jpg)$") or request.url:match("/([^/]+%.svg)$") or request.url:match("/([^/]+%.db)$") or request.url:match("/([^/]+%.adf)$")
            local relative = request.url:match("/v[%d.]+/appdock%.koplugin/(.+)$")
            local source = packaged and packaged_sources[relative or name] or sources[name]
            assert(name and source, "unexpected source URL " .. request.url)
            request.sink(source)
        end
        request.sink(nil)
        return 1, 200, { ["content-type"] = "application/json" }, "OK"
    end }
end

local active = root .. "/plugins/appdock.koplugin"
local old_main = assert(io.open(active .. "/main.lua", "wb")); old_main:write("-- old main\nreturn {}\n"); old_main:close()
for _, name in ipairs(required) do
    if name ~= "main.lua" then local old = assert(io.open(active .. "/" .. name, "wb")); old:write("-- old " .. name .. "\nreturn {}\n"); old:close() end
end

local dock_update_path = os.getenv("DOCK_UPDATE_SOURCE") or "dock_update.lua"
local app = dofile(dock_update_path)
assert(app.id == "dock_update" and app.version == "2.2.0" and app.logo == "dockupdate", "DockUpdate must satisfy the Store DApp contract")
local function findAction(pane, title)
    for _, child in ipairs(pane) do
        if type(child) == "table" and child.title == title then return child end
    end
end
local archive_file = io.open("netsurf.zip", "rb")
if archive_file then
    archive_file:close()
    local archive_names = assert(app._test.listNetsurfZip("netsurf.zip"), "DockUpdate must parse the NetSurf ZIP without unzip -Z1")
    assert(archive_names["netsurf/bin/netsurf-fb"] and archive_names["netsurf/cacert.pem"], "The published NetSurf archive must contain its browser binary and CA bundle")
end
local doom_archive = io.open("doom-kobo.zip", "rb")
if doom_archive then
    doom_archive:close()
    local doom_names = assert(app._test.listDoomZip("doom-kobo.zip"), "DockUpdate must parse the Doom ZIP")
    assert(doom_names[".adds/doom/bin/doomgeneric-640"] and doom_names[".adds/doom/bin/doomgeneric-960"], "The Doom archive must contain both Kobo binaries")
    assert(doom_names[".adds/doom/freedoom1.wad"] and doom_names[".adds/doom/freedoom2.wad"], "The Doom archive must contain the Freedoom IWADs")
end
local dock_update_source = assert(io.open(dock_update_path, "rb")):read("*a")
local required_source_block = assert(dock_update_source:match("local REQUIRED_FILES = {(.-)\n}"))
local required_count = 0
for _ in required_source_block:gmatch('"[^\"]+"') do required_count = required_count + 1 end
assert(required_count == 92, "DockUpdate must declare the complete current plugin file set")
for _, asset in ipairs(png_assets) do
    assert(required_source_block:find('"' .. asset .. '"', 1, true), "Every current PNG asset must be required: " .. asset)
end
for _, asset in ipairs(jpeg_assets) do
    assert(required_source_block:find('"' .. asset .. '"', 1, true), "Every current JPEG asset must be required: " .. asset)
end
assert(required_source_block:find('"appdock_order.lua"', 1, true), "The launcher ordering module is required for AppDock startup")
assert(required_source_block:find('"appdock_recovery.lua"', 1, true), "Boot recovery must survive every DockUpdate install")
assert(required_source_block:find('"appdock_text.lua"', 1, true), "Transparent text support must survive every DockUpdate install")
assert(required_source_block:find('"appdock_health.lua"', 1, true), "Health & reading must be included in the AppDock 9.5.1 package")
assert(dock_update_source:find('["appdock_health.lua"] = true', 1, true), "DockUpdate must allow the Health & reading module")
assert(required_source_block:find('"appdock_gradient.lua"', 1, true) and required_source_block:find('"appdock_rotation.lua"', 1, true), "DockUpdate must require both AppDock 9.6.0 modules")
assert(dock_update_source:find('["appdock_gradient.lua"] = true', 1, true) and dock_update_source:find('["appdock_rotation.lua"] = true', 1, true), "DockUpdate must allow both new Lua modules")
assert(dock_update_source:find('["appdock_gradient.lua"] = "9.6.0"', 1, true) and dock_update_source:find('["appdock_rotation.lua"] = "9.6.0"', 1, true), "The new Lua modules must be version-gated")
assert(dock_update_source:find('["assets/lockscreen/appdock_lockscreen_aurora.jpg"] = true', 1, true), "DockUpdate must allow the Aurora JPEG asset")
assert(dock_update_source:find('["assets/lockscreen/appdock_lockscreen_aurora.jpg"] = "9.6.0"', 1, true), "The Aurora JPEG must be version-gated")
assert(dock_update_source:find('["appdock_text.lua"] = true', 1, true), "DockUpdate must allow the transparent text module")
assert(dock_update_source:find('["appdock_netsurf.lua"] = true', 1, true), "DockUpdate must allow the NetSurf browser module")
assert(dock_update_source:find('["appdock_doom.lua"] = true', 1, true), "DockUpdate must allow the Doom module")
assert(dock_update_source:find("and not included[path]", 1, true), "The updater must reject a release when a required module is not allowlisted")
assert(dock_update_source:find("MAX_FILE_BYTES = 512 * 1024", 1, true), "DockUpdate must accept the current AppDock module size with a bounded per-file limit")
assert(dock_update_source:find("MAX_RELEASE_FILES = 96", 1, true), "DockUpdate must accept the current bounded AppDock package")
assert(dock_update_source:find("total_bytes > MAX_TOTAL_BYTES", 1, true), "DockUpdate must enforce the cumulative download-size limit")
assert(dock_update_source:find('["appdock_suggestions.db"] = true', 1, true), "DockUpdate must allow the suggestion database")
assert(dock_update_source:find('["appdock_tbs_account.lua"] = true', 1, true), "DockUpdate must allow the TBS account client")
for _, module in ipairs({ "appdock_sleepscreen.lua", "appdock_sleepscreen_catalog.lua", "appdock_sleepscreen_editor.lua", "appdock_sleepscreen_presets.lua", "appdock_sleepscreen_renderer.lua", "appdock_sleepscreen_store.lua", "appdock_sleepscreen_weather.lua", "appdock_bluetooth.lua", "appdock_transfer.lua", "appdock_youtube_shorts.lua", "appdock_keyboard.lua", "appdock_layout.lua", "appdock_motion.lua" }) do
    assert(required_source_block:find('"' .. module .. '"', 1, true), "DockUpdate must require the AppDock module " .. module)
    assert(dock_update_source:find('["' .. module .. '"] = true', 1, true), "DockUpdate must allow the AppDock module " .. module)
end
for _, module in ipairs({ "appdock_media.lua", "appdock_whatsnew.lua", "appdock_glass.lua" }) do
    assert(required_source_block:find('"' .. module .. '"', 1, true), "DockUpdate must require the AppDock 9.1.1 module " .. module)
    assert(dock_update_source:find('["' .. module .. '"] = true', 1, true), "DockUpdate must allow the AppDock 9.1.1 module " .. module)
end
assert(required_source_block:find('"appdock_anim.lua"', 1, true), "DockUpdate must require the AppDock 9.3.0 animation module")
assert(dock_update_source:find('["appdock_anim.lua"] = true', 1, true), "DockUpdate must allow the AppDock 9.3.0 animation module")
assert(dock_update_source:find('["appdock_groups.lua"] = true', 1, true), "DockUpdate must allow the AppDock group model")
assert(not dock_update_source:find('assets/wallpaper/appdock_default.svg', 1, true), "DockUpdate must not require or request the removed default wallpaper")
assert(dock_update_source:find('kind = "data"', 1, true), "DockUpdate must stage data files without Lua execution")
assert(required_source_block:find('"features.adf"', 1, true), "DockUpdate must require the AppDock feature pages")
assert(dock_update_source:find('["features.adf"] = true', 1, true), "DockUpdate must explicitly allowlist the AppDock feature pages")
for _, module in ipairs({ "appdock_audio.lua", "appdock_bwr.lua", "appdock_player.lua", "appdock_youtube.lua", "appdock_ytmusic.lua", "appdock_dialogs.lua", "appdock_draw.lua", "appdock_stylus.lua" }) do
    assert(dock_update_source:find('["' .. module .. '"] = true', 1, true),
        "DockUpdate must explicitly allow the AppDock module " .. module)
end
for _, module in ipairs(release_97_sources) do
    assert(required_source_block:find('"' .. module .. '"', 1, true), "DockUpdate must require AppDock 9.7.0 module " .. module)
    assert(dock_update_source:find('["' .. module .. '"] = true', 1, true), "DockUpdate must allow AppDock 9.7.0 module " .. module)
    assert(dock_update_source:find('["' .. module .. '"] = "9.7.0"', 1, true), "DockUpdate must version-gate AppDock 9.7.0 module " .. module)
end
for _, asset in ipairs(skin_assets) do
    assert(required_source_block:find('"' .. asset .. '"', 1, true), "DockUpdate must require AppDock 9.7.0 skin asset " .. asset)
    assert(dock_update_source:find('["' .. asset .. '"] = true', 1, true), "DockUpdate must allow AppDock 9.7.0 skin asset " .. asset)
    assert(dock_update_source:find('["' .. asset .. '"] = "9.7.0"', 1, true), "DockUpdate must version-gate AppDock 9.7.0 skin asset " .. asset)
end
for _, marker in ipairs({
    '["appdock_bluetooth.lua"] = "7.9.32"',
    '["appdock_transfer.lua"] = "8.0.1"',
    '["appdock_sleepscreen_weather.lua"] = "8.2.10"',
    '["appdock_text.lua"] = "8.2.13"',
    '["appdock_youtube_shorts.lua"] = "8.2.22"',
    '["appdock_netsurf.lua"] = "8.5.2"',
    '["appdock_doom.lua"] = "8.5.3"',
    '["appdock_media.lua"] = "9.0.0"',
    '["appdock_whatsnew.lua"] = "9.0.0"',
    '["appdock_anim.lua"] = "9.3.0"',
    '["appdock_health.lua"] = "9.5.1"',
}) do
    assert(dock_update_source:find(marker, 1, true), "DockUpdate must only request versioned files after their first AppDock release: " .. marker)
end
assert(dock_update_source:find('["appdock_media.lua"] = "9.0.0"', 1, true), "Media support must start with AppDock 9.0.0")
assert(dock_update_source:find('["appdock_whatsnew.lua"] = "9.0.0"', 1, true), "What's new support must start with AppDock 9.0.0")
assert(dock_update_source:find('["appdock_glass.lua"] = "9.1.1"', 1, true), "Glass support must start with AppDock 9.1.1")
assert(not dock_update_source:find("UPDATE_PASSWORD", 1, true), "DockUpdate must not require a password")
assert(not dock_update_source:find("input_type = \"password\"", 1, true), "DockUpdate must not show a password prompt")
local context = {
    dimen = { w = 600, h = 760 },
    manager = { appdock = { path = active, version = "7.9.14" } },
    requestRebuild = function() log.rebuilds = log.rebuilds + 1 end,
}
local instance = {}
local pane = app.buildPane(instance, context)
assert(pane and pane.dimen and pane.dimen.w == 600, "DockUpdate must build inside the assigned AppDock dimensions")
local check, notes, install = findAction(pane, "Check updates"), findAction(pane, "Release Notes"), findAction(pane, "Up to date")
assert(check.title == "Check updates" and notes.title == "Release Notes" and install.title == "Up to date", "DockUpdate must expose its expected action tiles before a check")
local retry_pane = app.buildPane({}, { dimen = { w = 600, h = 760 }, manager = { appdock = { version = "8.5.3" } } })
local doom_action = findAction(retry_pane, "Install Doom")
assert(doom_action and doom_action.title == "Install Doom", "An AppDock 8.5.3 installation must be able to install Doom separately")
doom_action.callback()
assert(log.shown and log.shown.text:find("Install the Doom package", 1, true), "The Doom installation must require explicit confirmation")
assert(type(check.callback) == "function", "DockUpdate action labels must be direct OverlapGroup children")
local split_context = {
    dimen = { w = 600, h = 360 },
    manager = context.manager,
    requestRebuild = function() log.rebuilds = log.rebuilds + 1 end,
}
local split_pane = app.buildPane({}, split_context)
assert(split_pane and split_pane.dimen and split_pane.dimen.h == 360 and findAction(split_pane, "Check updates"), "DockUpdate must build visible controls inside a split pane")

check.callback()
pane = app.buildPane(instance, context); check, notes, install = findAction(pane, "Check updates"), findAction(pane, "Release Notes"), findAction(pane, "Install update")
assert(install.title == "Install update" and install.subtitle == "AppDock 8.2.1", "DockUpdate must detect a newer stable release")
notes.callback()
assert(log.shown and log.shown.text:find("Sleepscreen", 1, true) and log.shown.title:find("v8.2.1", 1, true), "DockUpdate must display the complete release notes")

install.callback()
assert(log.shown and log.shown.ok_callback, "DockUpdate must require explicit confirmation before installation")
log.shown.ok_callback()
local new_main = assert(io.open(active .. "/main.lua", "rb")):read("*a")
assert(new_main:find("packaged main", 1, true), "DockUpdate must atomically replace the active AppDock folder with the current packaged sources")
local new_meta = assert(io.open(active .. "/_meta.lua", "rb")):read("*a")
assert(new_meta:find("8.2.1", 1, true), "DockUpdate must prefer the current packaged release over the stale root mirror")
for _, module in ipairs({ "appdock_dialogs.lua", "appdock_draw.lua", "appdock_dither.lua", "appdock_setup.lua", "appdock_ytmusic.lua", "appdock_sleepscreen.lua", "appdock_sleepscreen_catalog.lua", "appdock_sleepscreen_editor.lua", "appdock_sleepscreen_presets.lua", "appdock_sleepscreen_renderer.lua", "appdock_sleepscreen_store.lua" }) do
    local installed = assert(io.open(active .. "/" .. module, "rb")):read("*a")
        assert(installed:find("packaged " .. module, 1, true), "DockUpdate must install required AppDock 8.2.1 module " .. module)
end
local new_logo = assert(io.open(active .. "/assets/logos/appdock.png", "rb")):read("*a")
assert(new_logo == png_signature, "DockUpdate must stage bundled PNG assets alongside AppDock source files")
local new_wallpaper = io.open(active .. "/assets/wallpaper/appdock_default.svg", "rb")
assert(not new_wallpaper, "DockUpdate must install AppDock successfully without the optional default wallpaper")
local new_database = assert(io.open(active .. "/appdock_suggestions.db", "rb")):read("*a")
assert(new_database:find("# AppDock offline suggestion database", 1, true) and new_database:find("de\t7.4", 1, true) and new_database:find("en\t7.4", 1, true), "DockUpdate must atomically install the current keyboard suggestion database")
local new_features = assert(io.open(active .. "/features.adf", "rb")):read("*a")
assert(new_features == packaged_sources["features.adf"], "DockUpdate must atomically install the AppDock feature pages")
local backup = active .. ".appdock-backup-7.9.14"
local backed_up_main = assert(io.open(backup .. "/main.lua", "rb")):read("*a")
assert(backed_up_main:find("old main", 1, true), "DockUpdate must retain the old AppDock folder as a rollback backup")
assert(log.shown and log.shown.text:find("Restart KOReader", 1, true), "DockUpdate must require a restart after a successful core swap")
local retry_large_file_requests, saw_large_file_timeout = 0, false
for _, url in ipairs(log.requests) do
    if url:find("/appdock.koplugin/appdock_dapps.lua", 1, true) then retry_large_file_requests = retry_large_file_requests + 1 end
end
for _, timeout in ipairs(log.timeouts) do if timeout == 90 then saw_large_file_timeout = true end end
assert(log.large_file_failure and retry_large_file_requests == 2, "A transient appdock_dapps.lua network failure must be retried successfully")
assert(saw_large_file_timeout, "The large appdock_dapps.lua request must use the extended receive timeout")
assert(#log.requests == 1 + #required + 2 + #optional_sources + #png_assets + 1,
    "DockUpdate must fetch the Atom feed and only the fixed allowlisted release files")
local catalog = assert(io.open("dapps.txt", "rb")):read("*a")
assert(catalog:find("dock_update.lua | 2.2.0 | dockupdate", 1, true), "The DApps catalog must publish DockUpdate 2.2.0")
for _, url in ipairs(log.requests) do
    assert(not url:find("api.github.com", 1, true), "DockUpdate must never use the rate-limited GitHub REST API")
    assert(not url:find("appdock_default.svg", 1, true), "DockUpdate must not request the optional default wallpaper")
    assert(not url:find("appdock_text.lua", 1, true), "Older AppDock releases must not require a nonexistent text module")
    assert(not url:find("appdock_sleepscreen_weather.lua", 1, true), "Older releases must not request sleep-screen weather before 8.2.10")
    assert(not url:find("appdock_youtube_shorts.lua", 1, true), "Older releases must not request YouTube Shorts before 8.2.22")
    assert(not url:find("appdock_glass.lua", 1, true), "Older releases must not request Glass before 9.1.1")
    assert(not url:find("appdock_health.lua", 1, true), "Older releases must not request Health & reading before 9.5.1")
end

-- Starting with 8.2.13, the same bounded updater must include the new helper.
feed = feed:gsub("8%.2%.1", "8.2.13")
packaged_sources["_meta.lua"] = "return { version = '8.2.13' }\n"
packaged_sources["appdock_text.lua"] = "-- transparent text helper\nreturn {}\n"
log.requests = {}
local text_instance = {}
findAction(app.buildPane(text_instance, context), "Check updates").callback()
local text_pane = app.buildPane(text_instance, context)
findAction(text_pane, "Install update").callback()
assert(log.shown and log.shown.ok_callback, "New AppDock releases must still require installation confirmation: " .. tostring(log.shown and log.shown.text))
log.shown.ok_callback()
local installed_text = assert(io.open(active .. "/appdock_text.lua", "rb")):read("*a")
assert(installed_text == packaged_sources["appdock_text.lua"], "DockUpdate must atomically install the transparent text helper")
local text_requests = 0
for _, url in ipairs(log.requests) do
    if url:find("appdock_text.lua", 1, true) then text_requests = text_requests + 1 end
end
assert(text_requests == 1, "The new helper must be fetched exactly once from the fixed allowlist")
for _, module in ipairs({ "appdock_bluetooth.lua", "appdock_transfer.lua", "appdock_sleepscreen_weather.lua" }) do
    local requests = 0
    for _, url in ipairs(log.requests) do if url:find(module, 1, true) then requests = requests + 1 end end
    assert(requests == 1, "AppDock 8.2.13 must fetch the available module exactly once: " .. module)
end
for _, url in ipairs(log.requests) do
    assert(not url:find("appdock_youtube_shorts.lua", 1, true), "AppDock 8.2.13 must not request a module first released in 8.2.22")
end

-- Verify the complete current AppDock 9.3.0 package, including all newly
-- versioned modules, all 23 PNG assets, and both inert AppDock data files.
feed = feed:gsub("8%.2%.13", "9.3.0")
packaged_sources["_meta.lua"] = "return { version = '9.3.0' }\n"
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-9.3.0' }\n"
log.requests = {}
local current_instance = {}
findAction(app.buildPane(current_instance, context), "Check updates").callback()
local current_pane = app.buildPane(current_instance, context)
findAction(current_pane, "Install update").callback()
assert(log.shown and log.shown.ok_callback, "Installing the current AppDock release must still require explicit confirmation")
log.shown.ok_callback()
assert(#required + #versioned_sources + #png_assets == 77, "The current AppDock 9.3.0 fixture must represent all 77 files in the live plugin tree")
assert(#log.requests == 1 + #required + #versioned_sources + #png_assets, "DockUpdate must fetch every current plugin file exactly once")
for _, name in ipairs(required) do
    local installed = assert(io.open(active .. "/" .. name, "rb")):read("*a")
    assert(installed == packaged_sources[name], "DockUpdate must install the complete current package file " .. name)
end
for _, name in ipairs(versioned_sources) do
    local installed = assert(io.open(active .. "/" .. name, "rb")):read("*a")
    assert(installed == packaged_sources[name], "DockUpdate must install current versioned module " .. name)
end
for _, name in ipairs(png_assets) do
    local installed = assert(io.open(active .. "/" .. name, "rb")):read("*a")
    assert(installed == packaged_sources[name], "DockUpdate must install current bundled asset " .. name)
end

-- AppDock 9.5.1 adds Health & reading while keeping older releases' file sets valid.
feed = feed:gsub("9%.3%.0", "9.5.1")
packaged_sources["_meta.lua"] = "return { version = '9.5.1' }\n"
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-9.5.1' }\n"
packaged_sources["appdock_health.lua"] = "-- packaged Health & reading\nreturn { id = 'health' }\n"
log.requests = {}
local health_instance = {}
findAction(app.buildPane(health_instance, context), "Check updates").callback()
local health_pane = app.buildPane(health_instance, context)
local health_install = findAction(health_pane, "Install update")
assert(health_install and health_install.subtitle == "AppDock 9.5.1", "DockUpdate must detect AppDock 9.5.1")
health_install.callback()
assert(log.shown and log.shown.ok_callback, "AppDock 9.5.1 installation must require explicit confirmation")
log.shown.ok_callback()
local installed_health = assert(io.open(active .. "/appdock_health.lua", "rb")):read("*a")
assert(installed_health == packaged_sources["appdock_health.lua"], "DockUpdate must install the new Health & reading module")
local health_requests = 0
for _, url in ipairs(log.requests) do
    if url:find("appdock_health.lua", 1, true) then health_requests = health_requests + 1 end
end
assert(health_requests == 1, "AppDock 9.5.1 must fetch appdock_health.lua exactly once")
assert(#log.requests == 1 + #required + #versioned_sources + #upcoming_sources + #png_assets,
    "DockUpdate must fetch the complete bounded AppDock 9.5.1 package")

-- AppDock 9.5.2 reuses the same allowlisted 78-file package while shipping a
-- larger DApp host and the in-app navigation changes in existing modules.
feed = feed:gsub("9%.5%.1", "9.5.2")
packaged_sources["_meta.lua"] = "return { version = '9.5.2' }\n"
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-9.5.2' }\n"
log.requests = {}
local navigation_instance = {}
findAction(app.buildPane(navigation_instance, context), "Check updates").callback()
local navigation_pane = app.buildPane(navigation_instance, context)
local navigation_install = findAction(navigation_pane, "Install update")
assert(navigation_install and navigation_install.subtitle == "AppDock 9.5.2", "DockUpdate must detect AppDock 9.5.2")
navigation_install.callback()
assert(log.shown and log.shown.ok_callback, "AppDock 9.5.2 installation must require explicit confirmation")
log.shown.ok_callback()
local installed_host = assert(io.open(active .. "/appdock_dapps.lua", "rb")):read("*a")
assert(#installed_host == 299656, "DockUpdate must accept and install the complete AppDock 9.5.2 DApp host")
assert(#log.requests == 1 + #required + #versioned_sources + #upcoming_sources + #png_assets,
    "DockUpdate must fetch every allowlisted AppDock 9.5.2 file")
for _, path in ipairs({ "appdock_gradient.lua", "appdock_rotation.lua", "appdock_lockscreen_aurora.jpg" }) do
    for _, url in ipairs(log.requests) do assert(not url:find(path, 1, true), "AppDock 9.5.2 must not request a file first released in 9.6.0: " .. path) end
end

-- AppDock 9.6.0 adds two Lua modules and a version-gated Aurora JPEG asset.
feed = feed:gsub("9%.5%.2", "9.6.0")
packaged_sources["_meta.lua"] = "return { version = '9.6.0' }\n"
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-9.6.0' }\n"
packaged_sources["appdock_dapps.lua"] = "--" .. string.rep("x", 302369) .. "\n"
assert(#packaged_sources["appdock_dapps.lua"] == 302372, "The AppDock 9.6.0 host fixture must match its published byte size")
for _, name in ipairs(future_sources) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
for _, asset in ipairs(jpeg_assets) do packaged_sources[asset] = jpeg_signature end
log.requests = {}
local aurora_instance = {}
findAction(app.buildPane(aurora_instance, context), "Check updates").callback()
local aurora_pane = app.buildPane(aurora_instance, context)
local aurora_install = findAction(aurora_pane, "Install update")
assert(aurora_install and aurora_install.subtitle == "AppDock 9.6.0", "DockUpdate must detect AppDock 9.6.0")
aurora_install.callback()
assert(log.shown and log.shown.ok_callback, "AppDock 9.6.0 installation must require explicit confirmation")
log.shown.ok_callback()
for _, name in ipairs(future_sources) do
    local installed = assert(io.open(active .. "/" .. name, "rb")):read("*a")
    assert(installed == packaged_sources[name], "DockUpdate must install the new AppDock source " .. name)
end
for _, asset in ipairs(jpeg_assets) do
    local installed = assert(io.open(active .. "/" .. asset, "rb")):read("*a")
    assert(installed == jpeg_signature, "DockUpdate must validate and install the Aurora JPEG asset")
end
local installed_96_host = assert(io.open(active .. "/appdock_dapps.lua", "rb")):read("*a")
assert(#installed_96_host == 302372, "DockUpdate must accept and install the complete AppDock 9.6.0 DApp host")
assert(#log.requests == 1 + #required + #versioned_sources + #upcoming_sources + #future_sources + #png_assets + #jpeg_assets,
    "DockUpdate must fetch every allowlisted AppDock 9.6.0 file exactly once")
for _, path in ipairs(release_97_sources) do
    for _, url in ipairs(log.requests) do assert(not url:find(path, 1, true), "AppDock 9.6.0 must not request a file first released in 9.7.0: " .. path) end
end
for _, path in ipairs(skin_assets) do
    for _, url in ipairs(log.requests) do assert(not url:find(path, 1, true), "AppDock 9.6.0 must not request a skin asset first released in 9.7.0: " .. path) end
end

-- AppDock 9.7.0 adds feature/color/file-picker/pet/skin modules and five Cyber skin PNGs.
feed = feed:gsub("9%.6%.0", "9.7.0")
packaged_sources["_meta.lua"] = "return { version = '9.7.0' }\n"
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-9.7.0' }\n"
packaged_sources["appdock_dapps.lua"] = "--" .. string.rep("x", 307282) .. "\n"
assert(#packaged_sources["appdock_dapps.lua"] == 307285, "The AppDock 9.7.0 host fixture must match its published byte size")
log.requests = {}
local latest_instance = {}
findAction(app.buildPane(latest_instance, context), "Check updates").callback()
local latest_pane = app.buildPane(latest_instance, context)
local latest_install = findAction(latest_pane, "Install update")
assert(latest_install and latest_install.subtitle == "AppDock 9.7.0", "DockUpdate must detect AppDock 9.7.0")
latest_install.callback()
assert(log.shown and log.shown.ok_callback, "AppDock 9.7.0 installation must require explicit confirmation")
log.shown.ok_callback()
for _, name in ipairs(release_97_sources) do
    local installed = assert(io.open(active .. "/" .. name, "rb")):read("*a")
    assert(installed == packaged_sources[name], "DockUpdate must install the AppDock 9.7.0 source " .. name)
end
for _, asset in ipairs(skin_assets) do
    local installed = assert(io.open(active .. "/" .. asset, "rb")):read("*a")
    assert(installed == png_signature, "DockUpdate must validate and install the AppDock 9.7.0 skin asset " .. asset)
end
local installed_97_host = assert(io.open(active .. "/appdock_dapps.lua", "rb")):read("*a")
assert(#installed_97_host == 307285, "DockUpdate must accept and install the complete AppDock 9.7.0 DApp host")
assert(#log.requests == 1 + #required + #versioned_sources + #upcoming_sources + #future_sources
    + #release_97_sources + #png_assets + #jpeg_assets + #skin_assets,
    "DockUpdate must fetch every allowlisted AppDock 9.7.0 file exactly once")

os.execute("rm -rf " .. root)
print("DockUpdate test: OK")
