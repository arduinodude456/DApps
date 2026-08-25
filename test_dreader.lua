local root = "/tmp/dreader_test_data"
os.execute("rm -rf " .. root)
os.execute("mkdir -p " .. root .. "/appdock_dreader")

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

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dark", COLOR_LIGHT_GRAY = "light", COLOR_GRAY_7 = "g7", COLOR_GRAY_8 = "g8" } end
package.preload["datastorage"] = function() return { getDataDir = function() return root end } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, n) return n end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size or 12 } end } end
package.preload["ui/geometry"] = function() return { new = function(_, values) return values end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, values) return values end } end
package.preload["ui/widget/container/centercontainer"] = simpleModule
package.preload["ui/widget/container/framecontainer"] = simpleModule
package.preload["ui/widget/horizontalspan"] = simpleModule
package.preload["ui/widget/infomessage"] = simpleModule
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/inputdialog"] = simpleModule
package.preload["ui/widget/imagewidget"] = simpleModule
package.preload["ui/widget/overlapgroup"] = simpleModule
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["ui/widget/verticalgroup"] = simpleModule
package.preload["ui/widget/verticalspan"] = simpleModule
package.preload["ui/widget/textwidget"] = simpleModule
package.preload["ui/widget/textboxwidget"] = simpleModule
package.preload["ui/uimanager"] = function() return { show = function() end, close = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["util"] = function() return { htmlEntitiesToUtf8 = function(value) return value:gsub("&amp;", "&") end } end
package.preload["libs/libkoreader-lfs"] = function() return { attributes = function(path) local file = io.open(path, "rb"); if file then local size = file:seek("end"); file:close(); return { mode = "file", size = size } end; if path == root or path == root .. "/appdock_dreader" then return { mode = "directory" } end end, mkdir = function(path) os.execute("mkdir -p " .. path); return true end } end

local archive_data = {
    ["META-INF/container.xml"] = [[<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]],
    ["OEBPS/content.opf"] = [[<package><metadata><dc:title>Fixture EPUB</dc:title></metadata><manifest><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>]],
    ["OEBPS/nav.xhtml"] = [[<html><nav><a href="one.xhtml">Opening</a><a href="two.xhtml">Second chapter</a></nav></html>]],
    ["OEBPS/one.xhtml"] = [[<html><head><title>Opening</title></head><body><h1>Opening</h1><p>First paragraph &amp; safe text.</p><script>bad()</script><p>Second paragraph.</p></body></html>]],
    ["OEBPS/two.xhtml"] = [[<html><head><title>Second chapter</title></head><body><h1>Second chapter</h1><p>Another readable chapter.</p></body></html>]],
}
package.preload["ffi/archiver"] = function()
    local Reader = {}
    function Reader:new() return setmetatable({ entries = {}, size = 0 }, { __index = self }) end
    function Reader:open(path) if path:match("bad%.epub$") then self.err = "fixture archive error"; return nil end; self.filepath = path; self.index = 0; return true end
    function Reader:iterate()
        local keys = {}; for key in pairs(archive_data) do keys[#keys + 1] = key end; table.sort(keys)
        local index = 0
        return function()
            index = index + 1
            local key = keys[index]
            if not key then return nil end
            local item = { path = key, mode = "file", size = #archive_data[key], index = index }
            self.entries[key] = item
            return item
        end
    end
    function Reader:extractToMemory(path) return archive_data[path] end
    function Reader:close() self.closed = true end
    return { Reader = Reader }
end

local html_path = root .. "/sample.html"
local html = assert(io.open(html_path, "wb"))
html:write([[<html><head><title>Sample HTML</title><style>body{font-family:MissingFont;font-size:12px;color:#202020} h1{font-size:24px}</style></head><body><h1>Start</h1><img src="cover.png" alt="Cover"><p>Hello &amp; welcome.</p><h2>Next</h2><img src="back.png" alt="Back"><p>More words for pagination.</p><script>alert(1)</script></body></html>]])
local cover = assert(io.open(root .. "/cover.png", "wb")); cover:write("not-a-real-image"); cover:close()
local back = assert(io.open(root .. "/back.png", "wb")); back:write("not-a-real-image"); back:close()
html:close()
local epub_path = root .. "/fixture.epub"
local epub = assert(io.open(epub_path, "wb")); epub:write("fixture"); epub:close()
local bad_epub_path = root .. "/bad.epub"
local bad_epub = assert(io.open(bad_epub_path, "wb")); bad_epub:write("broken"); bad_epub:close()

local app = dofile("/home/ubuntu/dapps-store-repo/dreader.lua")
assert(app.id == "dreader" and app.version == "2.0.3" and type(app.openFile) == "function", "DReader must satisfy the Store DApp contract")
local context = { dimen = { w = 600, h = 760 }, requestRebuild = function() end, requestRefresh = function() end }
local html_instance = {}
assert(app.openFile(html_instance, html_path), "DReader must open supported HTML")
assert(html_instance.dreader.book.title == "Sample HTML" and #html_instance.dreader.book.chapters == 2, "DReader must split HTML headings into selectable chapters; got " .. #html_instance.dreader.book.chapters .. " first=" .. tostring(html_instance.dreader.book.chapters[1] and html_instance.dreader.book.chapters[1].title))
assert(html_instance.dreader.book.html_chapters[2].title == "Next" and html_instance.dreader.book.html_chapters[2].text:find("More words", 1, true), "DReader must retain the correct text for each HTML chapter")
assert(html_instance.dreader.book.style.family == "MissingFont" and html_instance.dreader.book.style.base_font == 12 and html_instance.dreader.book.style.heading_ratio == 2, "DReader must parse safe HTML/CSS style metadata")
assert(html_instance.dreader.book.image_cache[1][1] == root .. "/cover.png", "DReader must resolve the first local HTML image path")
assert(html_instance.dreader.book.image_cache[2][1] == root .. "/cover.png" and html_instance.dreader.book.image_cache[2][2] == root .. "/back.png", "DReader must preserve the global HTML image order for every chapter")
assert(html_instance.dreader.book.html_chapters[1].text:find("@@DREADER_IMAGE_1@@", 1, true), "DReader must retain the first image marker in the first chapter")
assert(html_instance.dreader.book.html_chapters[2].text:find("@@DREADER_IMAGE_2@@", 1, true), "DReader must retain the second global image marker in the later chapter")
assert(not html_instance.dreader.book.html_chapters[1].text:find("alert", 1, true), "DReader must remove scripts from HTML text")
local html_pane = app.buildPane(html_instance, context)
assert(html_pane and html_pane.dimen and html_pane.dimen.w == 600, "DReader must build a reader pane using only context dimensions")
local font_minus
for _, child in ipairs(html_pane) do if child.title == "A−" then font_minus = child; break end end
assert(font_minus and font_minus[1] and font_minus[1][1] and font_minus[1][1][1] and font_minus[1][1][1][1] and font_minus[1][1][1][1].text == "A−", "DReader button labels must be direct VerticalGroup children")
local split_context = { dimen = { w = 600, h = 360 }, requestRebuild = function() end, requestRefresh = function() end }
local split_pane = app.buildPane(html_instance, split_context)
assert(split_pane and split_pane.dimen.h == 360, "DReader must build the reader pane in a split height")
html_pane:onDeactivate()
assert(io.open(root .. "/appdock_dreader/library.lua", "rb"), "DReader must persist reading state atomically on deactivation")

local epub_instance = {}
assert(app.openFile(epub_instance, epub_path), "DReader must open an EPUB through container, OPF and spine")
local book = epub_instance.dreader.book
assert(book.title == "Fixture EPUB" and #book.chapters == 2 and book.chapters[1].title == "Opening", "DReader must parse EPUB metadata, navigation and spine")
local epub_pane = app.buildPane(epub_instance, context)
assert(epub_pane and epub_instance.dreader.pages and #epub_instance.dreader.pages >= 1, "DReader must paginate EPUB chapter text")
assert(app.openFile({}, bad_epub_path) == false, "DReader must reject a damaged EPUB without crashing")
assert(app.openFile({}, root .. "/unsupported.pdf") == false, "DReader must reject unsupported formats")
Book = nil
os.execute("rm -rf " .. root)
print("DReader test: OK")
