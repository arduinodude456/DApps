local root = "/tmp/dock_update_test_data"
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
local WidgetContainer = Widget:extend({})
local InputContainer = WidgetContainer:extend({})
function InputContainer:paintTo() end
local InputDialog = Widget:extend({})
function InputDialog:getInputText() return self.input or "" end
function InputDialog:onShowKeyboard() self.keyboard_shown = true end
local function simpleModule() return WidgetContainer end
local log = { shown = nil, rebuilds = 0, requests = {} }

local required = {
    "_meta.lua", "main.lua", "appdock_appstore.lua", "appdock_browser.lua",
    "appdock_dapps.lua", "appdock_filemanager.lua", "appdock_homescreen.lua",
    "appdock_logo.lua", "appdock_manager.lua", "appdock_quicksettings.lua",
    "appdock_theme.lua", "appdock_notifications.lua", "appdock_help.lua", "appdock_boot.lua",
    "appdock_wallpaper.lua", "appdock_lockscreen.lua", "appdock_device_controls.lua",
    "appdock_audio.lua", "appdock_bwr.lua", "appdock_player.lua", "appdock_youtube.lua",
    "appdock_ytmusic.lua", "appdock_dialogs.lua", "appdock_draw.lua",
}
local optional_sources = {
    "appdock_keyboard.lua", "appdock_layout.lua", "appdock_motion.lua",
    "appdock_order.lua", "appdock_sleepscreen.lua",
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
sources["main.lua"] = "-- new main\nreturn { name = 'appdock' }\n"
sources["_meta.lua"] = "return { version = '7.9.14' }\n"
local packaged_sources = {}
for _, name in ipairs(required) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
for _, name in ipairs(optional_sources) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
-- Match the actual AppDock 7.9.15 DApp-host module size so this exact release
-- proves acceptance under the bounded per-file size limit.
packaged_sources["appdock_dapps.lua"] = "--" .. string.rep("x", 205633) .. "\n"
assert(#packaged_sources["appdock_dapps.lua"] == 205636, "The AppDock 7.9.15 host fixture must match its published byte size")
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-7.9.15' }\n"
packaged_sources["_meta.lua"] = "return { version = '7.9.15' }\n"
local png_signature = "\137PNG\r\n\26\nfixture"
for _, asset in ipairs(png_assets) do packaged_sources[asset] = png_signature end
local tree_mode = "valid"

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
package.preload["json"] = function()
    local decode = setmetatable({ simple = {} }, {
        __call = function(_, body)
            if body == "release" then return { tag_name = "v7.9.15", name = "AppDock 7.9.15", body = "# AppDock 7.9.15\n\n- YouTube Music search partial results, metadata-only search and redesigned player", published_at = "2026-10-10T20:02:04Z", html_url = "https://github.com/arduinodude456/appdock.koplugin/releases/tag/v7.9.15", draft = false, prerelease = false } end
            if body == "tree" then
                if tree_mode == "bad" then return { tree = { { type = "blob", path = "../escape.lua", size = 10 } } } end
                local tree = {}
                for _, name in ipairs(required) do tree[#tree + 1] = { type = "blob", path = name, size = #sources[name] } end
                tree[#tree + 1] = { type = "blob", path = "README.md", size = 4096 }
                for _, name in ipairs(required) do tree[#tree + 1] = { type = "blob", path = "appdock.koplugin/" .. name, size = #packaged_sources[name] } end
                for _, name in ipairs(optional_sources) do tree[#tree + 1] = { type = "blob", path = "appdock.koplugin/" .. name, size = #packaged_sources[name] } end
                for _, asset in ipairs(png_assets) do tree[#tree + 1] = { type = "blob", path = "appdock.koplugin/" .. asset, size = #packaged_sources[asset] } end
                return { tree = tree }
            end
            error("unexpected JSON fixture: " .. tostring(body))
        end,
    })
    return { decode = decode }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, attribute)
            local result = mode(path)
            if attribute == "mode" then return result end
            return result and { mode = result } or nil
        end,
        mkdir = function(path) os.execute("mkdir " .. quote(path)); return directory(path) end,
        rmdir = function(path) os.execute("rmdir " .. quote(path) .. " 2>/dev/null"); return not directory(path) end,
        dir = listDirectory,
    }
end
package.preload["socket.url"] = function() return { parse = function(url) local scheme, host = url:match("^(https?)://([^/%?#]+)"); return scheme and { scheme = scheme, host = host } or {} end } end
package.preload["socket"] = function() return { skip = function(_, a, code, headers, status) return code, headers, status end } end
package.preload["socketutil"] = function() return { USER_AGENT = "DockUpdateTest", set_timeout = function() end, reset_timeout = function() end } end
package.preload["ssl.https"] = function()
    return { request = function(request)
        log.requests[#log.requests + 1] = request.url
        if request.url:find("releases/latest", 1, true) then request.sink("release")
        elseif request.url:find("/git/trees/", 1, true) then request.sink("tree")
        else
            local packaged = request.url:find("/appdock.koplugin/", 1, true) ~= nil
            local name = request.url:match("/([^/]+%.lua)$") or request.url:match("/([^/]+%.png)$")
            local relative = request.url:match("/v7%.9%.15/appdock%.koplugin/(.+)$")
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
assert(app.id == "dock_update" and app.version == "1.2.6" and app.logo == "dockupdate", "DockUpdate must satisfy the Store DApp contract")
local dock_update_source = assert(io.open(dock_update_path, "rb")):read("*a")
assert(dock_update_source:find("MAX_FILE_BYTES = 256 * 1024", 1, true), "DockUpdate must accept the current AppDock module size with a bounded per-file limit")
assert(dock_update_source:find("MAX_RELEASE_FILES = 64", 1, true), "DockUpdate must accept the current bounded 52-file AppDock package")
for _, module in ipairs({ "appdock_audio.lua", "appdock_bwr.lua", "appdock_player.lua", "appdock_youtube.lua", "appdock_ytmusic.lua", "appdock_dialogs.lua", "appdock_draw.lua" }) do
    assert(dock_update_source:find('["' .. module .. '"] = true', 1, true),
        "DockUpdate must explicitly allow the AppDock module " .. module)
end
assert(dock_update_source:find("UPDATE_PASSWORD = \"b8-adt73548\"", 1, true), "DockUpdate must require the configured update password")
assert(dock_update_source:find("input_type = \"password\"", 1, true), "DockUpdate password entry must be masked")
local context = {
    dimen = { w = 600, h = 760 },
    manager = { appdock = { path = active, version = "7.9.14" } },
    requestRebuild = function() log.rebuilds = log.rebuilds + 1 end,
}
local instance = {}
local pane = app.buildPane(instance, context)
assert(pane and pane.dimen and pane.dimen.w == 600, "DockUpdate must build inside the assigned AppDock dimensions")
local check, notes, install = pane[5], pane[6], pane[7]
assert(check.title == "Check updates" and notes.title == "Release Notes" and install.title == "Up to date", "DockUpdate must expose its expected action tiles before a check")
assert(check[1] and check[1][1] and check[1][1][1] and check[1][1][1].text == "Check updates", "DockUpdate action labels must be direct OverlapGroup children")
local split_context = {
    dimen = { w = 600, h = 360 },
    manager = context.manager,
    requestRebuild = function() log.rebuilds = log.rebuilds + 1 end,
}
local split_pane = app.buildPane({}, split_context)
assert(split_pane and split_pane.dimen and split_pane.dimen.h == 360 and split_pane[5].title == "Check updates", "DockUpdate must build visible controls inside a split pane")

check.callback()
pane = app.buildPane(instance, context); check, notes, install = pane[5], pane[6], pane[7]
assert(install.title == "Install update" and install.subtitle == "AppDock 7.9.15", "DockUpdate must detect a newer stable release")
notes.callback()
assert(log.shown and log.shown.text:find("partial results", 1, true) and log.shown.title:find("v7.9.15", 1, true), "DockUpdate must display the complete release notes")

install.callback()
assert(log.shown and log.shown.getInputText and log.shown.buttons, "DockUpdate must request the update password before installation")
log.shown.input = "wrong-password"
log.shown.buttons[1][2].callback()
assert(log.shown.text and log.shown.text:find("Incorrect update password", 1, true), "DockUpdate must reject an incorrect password")
install.callback()
log.shown.input = "b8-adt73548"
log.shown.buttons[1][2].callback()
assert(log.shown and log.shown.ok_callback, "DockUpdate must require explicit confirmation after password authorization")
log.shown.ok_callback()
local new_main = assert(io.open(active .. "/main.lua", "rb")):read("*a")
assert(new_main:find("packaged main", 1, true), "DockUpdate must atomically replace the active AppDock folder with the current packaged sources")
local new_meta = assert(io.open(active .. "/_meta.lua", "rb")):read("*a")
assert(new_meta:find("7.9.15", 1, true), "DockUpdate must prefer the current packaged release over the stale root mirror")
for _, module in ipairs({ "appdock_dialogs.lua", "appdock_draw.lua", "appdock_ytmusic.lua" }) do
    local installed = assert(io.open(active .. "/" .. module, "rb")):read("*a")
    assert(installed:find("packaged " .. module, 1, true), "DockUpdate must install required AppDock 7.9.15 module " .. module)
end
local new_logo = assert(io.open(active .. "/assets/logos/appdock.png", "rb")):read("*a")
assert(new_logo == png_signature, "DockUpdate must stage bundled PNG assets alongside AppDock source files")
local backup = active .. ".appdock-backup-7.9.14"
local backed_up_main = assert(io.open(backup .. "/main.lua", "rb")):read("*a")
assert(backed_up_main:find("old main", 1, true), "DockUpdate must retain the old AppDock folder as a rollback backup")
assert(log.shown and log.shown.text:find("Restart KOReader", 1, true), "DockUpdate must require a restart after a successful core swap")
assert(#log.requests == 54, "DockUpdate must fetch only release metadata, one tree, twenty-nine source files, and twenty-three validated PNG assets")

-- A malformed tree must be rejected before confirmation and leave the active release intact.
tree_mode = "bad"
local guarded = {}
local guarded_pane = app.buildPane(guarded, context)
guarded_pane[5].callback()
guarded_pane = app.buildPane(guarded, context)
guarded_pane[7].callback()
log.shown.input = "b8-adt73548"
log.shown.buttons[1][2].callback()
assert(log.shown and log.shown.text:find("unsupported file", 1, true), "DockUpdate must reject paths outside the fixed AppDock Lua release layout")
assert(assert(io.open(active .. "/main.lua", "rb")):read("*a"):find("packaged main", 1, true), "Rejected release metadata must not modify the active AppDock folder")

os.execute("rm -rf " .. root)
print("DockUpdate test: OK")
