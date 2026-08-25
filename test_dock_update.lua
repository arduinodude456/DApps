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
local function simpleModule() return WidgetContainer end
local log = { shown = nil, rebuilds = 0, requests = {} }

local required = {
    "_meta.lua", "main.lua", "appdock_appstore.lua", "appdock_browser.lua",
    "appdock_dapps.lua", "appdock_filemanager.lua", "appdock_homescreen.lua",
    "appdock_logo.lua", "appdock_manager.lua", "appdock_quicksettings.lua",
    "appdock_theme.lua", "appdock_notifications.lua", "appdock_help.lua", "appdock_boot.lua",
}
local sources = {}
for _, name in ipairs(required) do
    sources[name] = "-- staged " .. name .. "\nreturn {}\n"
end
sources["main.lua"] = "-- new main\nreturn { name = 'appdock' }\n"
sources["_meta.lua"] = "return { version = '1.7.0' }\n"
local packaged_sources = {}
for _, name in ipairs(required) do packaged_sources[name] = "-- packaged " .. name .. "\nreturn {}\n" end
packaged_sources["main.lua"] = "-- packaged main\nreturn { name = 'appdock-1.8.1' }\n"
packaged_sources["_meta.lua"] = "return { version = '1.8.1' }\n"
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
            if body == "release" then return { tag_name = "1.7.0", name = "AppDock 1.7", body = "# AppDock 1.7\n\n- Safer updates\n- Better Files", published_at = "2026-08-25T11:03:25Z", html_url = "https://github.com/arduinodude456/appdock.koplugin/releases/tag/1.7.0", draft = false, prerelease = false } end
            if body == "tree" then
                if tree_mode == "bad" then return { tree = { { type = "blob", path = "../escape.lua", size = 10 } } } end
                local tree = {}
                for _, name in ipairs(required) do tree[#tree + 1] = { type = "blob", path = name, size = #sources[name] } end
                tree[#tree + 1] = { type = "blob", path = "README.md", size = 4096 }
                for _, name in ipairs(required) do tree[#tree + 1] = { type = "blob", path = "appdock.koplugin/" .. name, size = #packaged_sources[name] } end
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
            local name = request.url:match("/([^/]+%.lua)$")
            local source = packaged and packaged_sources[name] or sources[name]
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

local app = dofile("/home/ubuntu/dapps-store-repo/dock_update.lua")
assert(app.id == "dock_update" and app.version == "1.0.5" and app.logo == "download", "DockUpdate must satisfy the Store DApp contract")
local context = {
    dimen = { w = 600, h = 760 },
    manager = { appdock = { path = active, version = "1.6.0" } },
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
assert(install.title == "Install update" and install.subtitle == "AppDock 1.7.0", "DockUpdate must detect a newer stable release")
notes.callback()
assert(log.shown and log.shown.text:find("Safer updates", 1, true) and log.shown.title:find("1.7.0", 1, true), "DockUpdate must display the complete release notes")

install.callback()
assert(log.shown and log.shown.ok_callback, "DockUpdate must require explicit confirmation before downloading or replacing AppDock")
log.shown.ok_callback()
local new_main = assert(io.open(active .. "/main.lua", "rb")):read("*a")
assert(new_main:find("packaged main", 1, true), "DockUpdate must atomically replace the active AppDock folder with the current packaged sources")
local backup = active .. ".appdock-backup-1.6.0"
local backed_up_main = assert(io.open(backup .. "/main.lua", "rb")):read("*a")
assert(backed_up_main:find("old main", 1, true), "DockUpdate must retain the old AppDock folder as a rollback backup")
assert(log.shown and log.shown.text:find("Restart KOReader", 1, true), "DockUpdate must require a restart after a successful core swap")
assert(#log.requests == 16, "DockUpdate must fetch only release metadata, one tree, and the validated fourteen source files")

-- A malformed tree must be rejected before confirmation and leave the active release intact.
tree_mode = "bad"
local guarded = {}
local guarded_pane = app.buildPane(guarded, context)
guarded_pane[5].callback()
guarded_pane = app.buildPane(guarded, context)
guarded_pane[7].callback()
assert(log.shown and log.shown.text:find("unsupported file", 1, true), "DockUpdate must reject paths outside the fixed AppDock Lua release layout")
assert(assert(io.open(active .. "/main.lua", "rb")):read("*a"):find("packaged main", 1, true), "Rejected release metadata must not modify the active AppDock folder")

os.execute("rm -rf " .. root)
print("DockUpdate test: OK")
