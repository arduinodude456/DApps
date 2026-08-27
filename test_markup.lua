local function class(proto)
    proto = proto or {}
    proto.__index = proto
    function proto:extend(child)
        child = child or {}
        child.__index = child
        setmetatable(child, { __index = self })
        return child
    end
    function proto:new(values)
        local value = values or {}
        setmetatable(value, self)
        if value.init then value:init() end
        return value
    end
    return proto
end

local WidgetContainer = class({})
local InputContainer = WidgetContainer:extend({})
local function widgetModule() return WidgetContainer end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_LIGHT_GRAY = "light", COLOR_GRAY_8 = "gray8", ColorRGB32 = function() return "rgb" end }
end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, value) return value end, isColorEnabled = function() return false end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/geometry"] = function() return { new = function(_, values) return values end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, values) return values end } end
package.preload["ui/widget/container/centercontainer"] = widgetModule
package.preload["ui/widget/container/framecontainer"] = widgetModule
package.preload["ui/widget/horizontalspan"] = widgetModule
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/infomessage"] = widgetModule
package.preload["ui/widget/overlapgroup"] = widgetModule
package.preload["ui/widget/scrollhtmlwidget"] = widgetModule
package.preload["ui/widget/textwidget"] = widgetModule
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["ui/uimanager"] = function() return { show = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local source_path = os.getenv("MARKUP_SOURCE") or "/home/ubuntu/dapps-markup-release/markup.lua"
local source = assert(io.open(source_path, "rb")):read("*a")
assert(not source:find("ui/widget/inputwidget", 1, true) and not source:find("ui/widget/inputdialog", 1, true), "MarkUP must not import KOReader's native text input widgets")
local MarkUP = dofile(source_path)

assert(MarkUP.id == "markup" and MarkUP.version == "1.0.0" and MarkUP.openFile, "MarkUP must expose a file-open capable Store DApp contract")
assert(MarkUP.test.isMarkdownFile("/mnt/onboard/note.md") and MarkUP.test.isMarkdownFile("/mnt/onboard/note.markdown") and not MarkUP.test.isMarkdownFile("/mnt/onboard/note.txt"), "MarkUP must accept only supported Markdown suffixes")
assert(MarkUP.test.validSavePath("/mnt/onboard/note.md") == "/mnt/onboard/note.md", "MarkUP must accept absolute Markdown save paths")
assert(not MarkUP.test.validSavePath("relative.md") and not MarkUP.test.validSavePath("/mnt/onboard/../secret.md") and not MarkUP.test.validSavePath("/mnt/onboard/note.txt"), "MarkUP must reject relative, parent-directory and non-Markdown save paths")

local rendered = MarkUP.test.markdownToHtml([[# Title

**bold** and _emphasis_ with [KOReader](https://koreader.rocks).

> A quote

- one
- two

```lua
print("safe")
```

| Name | Value |
| --- | --- |
| One | 1 |

<script>never()</script>]])
assert(rendered:find("<h1>Title</h1>", 1, true) and rendered:find("<strong>bold</strong>", 1, true) and rendered:find("<em>emphasis</em>", 1, true), "MarkUP must render headings and inline Markdown")
assert(rendered:find("href=\"https://koreader.rocks\"", 1, true) and rendered:find("<blockquote>", 1, true) and rendered:find("<ul>", 1, true) and rendered:find("<pre><code>", 1, true) and rendered:find("<table>", 1, true), "MarkUP must render links, quotes, lists, code and tables")
assert(rendered:find("&lt;script&gt;never()&lt;/script&gt;", 1, true), "MarkUP must escape raw HTML rather than executing or injecting it")

local fixture = "/tmp/markup-contract-fixture.md"
os.remove(fixture)
assert(MarkUP.test.atomicWrite(fixture, "# Saved\n\nText"), "MarkUP must write a new Markdown file atomically")
local saved = assert(MarkUP.test.readMarkdownFile(fixture))
assert(saved == "# Saved\n\nText", "MarkUP must read back its saved Markdown content")
local opened_instance = {}
assert(MarkUP.openFile(opened_instance, fixture), "MarkUP must accept a Markdown file through the Store DApp openFile contract")
assert(opened_instance.markup.path == fixture and opened_instance.markup.content == saved and not opened_instance.markup.dirty, "MarkUP must retain opened file state without marking it dirty")
opened_instance.markup.dirty = true
assert(MarkUP.canClose(opened_instance) == false, "MarkUP must refuse closing when the current document has unsaved changes")
opened_instance.markup.dirty = false
local pane = MarkUP.buildPane(opened_instance, { dimen = { w = 320, h = 420 }, px = function(value) return value end, requestRebuild = function() end })
assert(pane and pane.dimen and pane.dimen.w == 320 and pane.dimen.h == 420, "MarkUP must build its own UI within the supplied split-pane dimensions")
os.remove(fixture)
print("MarkUP test: OK")
