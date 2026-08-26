local function class(prototype)
    prototype = prototype or {}; prototype.__index = prototype
    function prototype:extend(child) child = child or {}; child.__index = child; setmetatable(child, { __index = self }); return child end
    function prototype:new(args) local instance = setmetatable(args or {}, self); if instance.init then instance:init() end; return instance end
    function prototype:getSize() return self.dimen or { w = self.width or 0, h = self.height or 0 } end
    return prototype
end

local Widget = class({})
local WidgetContainer = Widget:extend({})
local freed = 0
local history = { hist = {} }

package.preload["ffi/blitbuffer"] = function() return { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_DARK_GRAY = "dark" } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, value) return value end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, args) return args end } end
package.preload["ui/widget/container/framecontainer"] = function() return WidgetContainer end
package.preload["ui/widget/imagewidget"] = function() return WidgetContainer end
package.preload["ui/widget/overlapgroup"] = function() return WidgetContainer end
package.preload["ui/widget/textwidget"] = function() return WidgetContainer end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["readhistory"] = function() return history end

local widget = dofile("/home/ubuntu/dapps-store-repo/random_book_covers_widget.lua")
assert(#widget._test.historyEntries() == 0, "The cover widget must show no invented books when local reading history is empty")
local empty = widget.buildWidget({}, { dimen = { w = 560, h = 130 }, appdock = { ui = {} } })
assert(empty and empty.dimen.w == 560, "The empty cover widget must stay within its assigned dimensions")

history.hist = {
    { file = "/books/One.epub", text = "One" },
    { file = "/books/Two.epub", text = "Two" },
    { file = "/books/Three.epub", text = "Three" },
    { file = "/books/One.epub", text = "Duplicate" },
    { file = "/books/Deleted.epub", text = "Deleted", dim = true },
}
local function cover()
    return { getWidth = function() return 80 end, getHeight = function() return 120 end, free = function() freed = freed + 1 end }
end
local requests = {}
local context = {
    dimen = { w = 560, h = 130 },
    appdock = { ui = { bookinfo = { getCoverImage = function(_, _, file)
        requests[#requests + 1] = file
        if file == "/books/Two.epub" then return nil end
        return cover()
    end } } },
}
local books = widget._test.selectBooks(context)
assert(#books == 3, "The cover widget must choose three distinct real local history entries when available")
local seen = {}
for _, book in ipairs(books) do assert(not seen[book.file], "Selected books must be unique"); seen[book.file] = true end
local card = widget.buildWidget({}, context)
assert(card and card.dimen.w == 560 and #requests >= 3, "The cover widget must build three local cover slots within its assigned dimensions")
assert(freed == 0, "The widget must transfer valid cover ownership to ImageWidget instead of freeing it before rendering")
print("Random Book Covers widget test: OK")
