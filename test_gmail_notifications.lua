local function extend(base)
    local cls = {}; cls.__index = cls; setmetatable(cls, { __index = base })
    function cls:new(args) args = args or {}; setmetatable(args, self); if args.init then args:init() end; return args end
    return cls
end
local Widget = {}; Widget.__index = Widget
function Widget:new(args) args = args or {}; setmetatable(args, self); if args.init then args:init() end; return args end
Widget.extend = extend
local InputContainer = extend(Widget)
function InputContainer:paintTo() end
local function generic() return extend(Widget) end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dark", COLOR_LIGHT_GRAY = "light", COLOR_GRAY_8 = "gray" } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, value) return value end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, args) return args end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, args) return args end } end
package.preload["ui/widget/container/centercontainer"] = function() return generic() end
package.preload["ui/widget/container/framecontainer"] = function() return generic() end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/container/widgetcontainer"] = function() return generic() end
package.preload["ui/widget/horizontalspan"] = function() return generic() end
package.preload["ui/widget/confirmbox"] = function() return generic() end
package.preload["ui/widget/inputdialog"] = function() return generic() end
package.preload["ui/widget/overlapgroup"] = function() return generic() end
package.preload["ui/widget/textwidget"] = function() return generic() end
package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["socket.url"] = function() return { parse = function(value)
    local scheme, remainder = value:match("^(https?)://(.+)$")
    if not scheme or not remainder then return nil end
    local slash = remainder:find("/", 1, true)
    local authority = slash and remainder:sub(1, slash - 1) or remainder
    local path = slash and remainder:sub(slash) or nil
    return { scheme = scheme, host = authority, path = path }
end } end
G_reader_settings = { readSetting = function(_, _, fallback) return fallback end, saveSetting = function() end }

local app = dofile("gmail_notifications.lua")
local test = app._test
assert(app.id == "gmail_notifications" and app.version == "1.0.0")
assert(test.validEndpoint("https://adapter.home:8443") == "https://adapter.home:8443")
assert(test.validEndpoint("http://adapter.home") == nil, "HTTP endpoints must be rejected")
assert(test.validEndpoint("https://adapter.home/path") == nil, "Endpoint paths must be rejected")
assert(test.validCAPath("/mnt/onboard/.adds/appdock/gmail-local-ca.pem") == "/mnt/onboard/.adds/appdock/gmail-local-ca.pem")
assert(test.validCAPath("relative-ca.pem") == nil, "Only absolute local CA paths are allowed")
assert(test.normalizeMessage({ id = "mail_1", from = "Alice", subject = "Hello" }).subject == "Hello")
assert(test.normalizeMessage({ id = "bad id", from = "Alice", subject = "Hello" }) == nil, "Malformed IDs must be rejected")
local pane = app.buildPane({}, { dimen = { w = 600, h = 700 }, notify = function() return true end, requestRebuild = function() end })
assert(pane and pane[1], "Gmail Notifications must build its configured manual-check pane")
local store = test.cloneStore({ seen_ids = { "old_mail" }, initialized = false })
local fresh, first_scan, received = test.mergeMessages(store, { { id = "mail_1", from = "Alice", subject = "Hello" }, { id = "mail_2", from = "Bob", subject = "Status" } })
assert(#fresh == 0 and first_scan == false and received == 2 and store.initialized, "First scan must create a quiet baseline")
fresh, first_scan, received = test.mergeMessages(store, { { id = "mail_3", from = "Carol", subject = "New" }, { id = "mail_2", from = "Bob", subject = "Status" } })
assert(first_scan == true and received == 2 and #fresh == 1 and fresh[1].id == "mail_3", "Later scans must emit only unseen IDs")
print("Gmail Notifications DApp test: OK")
