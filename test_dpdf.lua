local function generic()
    local T = {}
    function T:new(args) args = args or {}; setmetatable(args, { __index = self }); if args.init then args:init() end; return args end
    function T:extend(args) args = args or {}; setmetatable(args, { __index = self }); return args end
    return T
end

local opened_path, closed = nil, false
local root = "/tmp/dpdf-test"
os.execute("mkdir -p " .. root)
local pdf = assert(io.open(root .. "/sample.pdf", "wb")); pdf:write("%PDF-test"); pdf:close()
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_LIGHT_GRAY = "light", COLOR_DARK_GRAY = "dark", COLOR_GRAY_8 = "gray" } end
package.preload["ui/font"] = function() return { getFace = function(_, size) return { size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, args) return args end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, args) return args end } end
package.preload["ui/widget/container/centercontainer"] = generic
package.preload["ui/widget/container/framecontainer"] = generic
package.preload["ui/widget/container/inputcontainer"] = generic
package.preload["ui/widget/overlapgroup"] = generic
package.preload["ui/widget/textwidget"] = generic
package.preload["ui/widget/container/widgetcontainer"] = generic
package.preload["ui/widget/horizontalspan"] = generic
package.preload["ui/widget/inputdialog"] = function() local T = generic(); function T:onShowKeyboard() end; function T:getInputText() return self.input end; return T end
package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["document/documentregistry"] = function() return { openDocument = function(_, path)
    opened_path = path
    return { getPageCount = function() return 3 end, getNativePageDimensions = function() return { w = 600, h = 800 } end, getPageDimensions = function(_, _, zoom) return { w = math.floor(600 * zoom), h = math.floor(800 * zoom) } end, drawPage = function() end, close = function() closed = true end }
end } end

local app = dofile("dpdf.lua")
assert(app.id == "dpdf" and app.version == "1.0.0" and app.logo == "document", "DPdf must satisfy the Store DApp contract")
assert(app._test.isPdfPath("/mnt/onboard/book.PDF") and not app._test.isPdfPath("https://example.org/file.pdf") and not app._test.isPdfPath("/tmp/a.epub"), "DPdf must restrict input to local PDF paths")
assert(not app._test.localPdfPath("/tmp/missing.pdf"), "DPdf must reject unreadable files")
local rebuilds, px_calls = 0, 0
local context = { dimen = { w = 600, h = 340 }, px = function(value) px_calls = px_calls + 1; return math.max(1, math.floor(value * .65 + .5)) end, requestRebuild = function(kind) assert(kind == "ui"); rebuilds = rebuilds + 1 end }
local instance = {}
assert(app.openFile(instance, root .. "/sample.pdf") and opened_path == root .. "/sample.pdf", "DPdf must open a verified local PDF through DocumentRegistry")
local pane = app.buildPane(instance, context)
assert(pane and pane.dimen.h == 340 and px_calls > 0, "DPdf must build a relative short split-pane layout")
local next_action
for _, child in ipairs(pane[1]) do if child.title == "Next ›" then next_action = child; break end end
assert(next_action and next_action.callback, "DPdf must expose local page navigation")
next_action.callback()
assert(instance.dpdf.page == 2 and rebuilds == 1, "DPdf must navigate pages locally")
pane:onDeactivate()
assert(closed, "DPdf must close its document when the pane deactivates")
print("DPdf DApp test: OK")
