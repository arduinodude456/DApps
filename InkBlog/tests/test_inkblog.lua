-- InkBlog isolated Lua 5.1 contract tests. Run from dapps with:
-- lua5.1 InkBlog/tests/test_inkblog.lua

local temp_root = "/tmp/inkblog-test-" .. tostring(os.time())
os.execute("mkdir -p " .. string.format("%q", temp_root))

local function class(parent)
    local cls = {}
    cls.__index = cls
    setmetatable(cls, { __index = parent })
    function cls:extend(properties)
        properties = properties or {}
        properties.__index = properties
        setmetatable(properties, { __index = self })
        return properties
    end
    function cls:new(properties)
        local object = properties or {}
        setmetatable(object, self)
        if object.init then object:init() end
        return object
    end
    return cls
end

local Widget = class()
local InputContainer = class(Widget)
function InputContainer:paintTo(bb, x, y)
    self.last_paint = { bb = bb, x = x, y = y }
    return true
end

local function simpleJson(value)
    local kind = type(value)
    if kind == "string" then return string.format("%q", value) end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "null" end
    local array, count = true, 0
    for key, item in pairs(value) do count = count + 1; if type(key) ~= "number" then array = false end end
    local parts = {}
    if array then
        for index = 1, #value do parts[#parts + 1] = simpleJson(value[index]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do parts[#parts + 1] = string.format("%q", tostring(key)) .. ":" .. simpleJson(item) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local Decode = setmetatable({ simple = {} }, { __call = function(_, raw) return {} end })
package.preload["json"] = function() return { encode = simpleJson, decode = Decode } end
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "#FFF", COLOR_BLACK = "#000", COLOR_DARK_GRAY = "#333", COLOR_GRAY_8 = "#666", COLOR_LIGHT_GRAY = "#CCC" } end
package.preload["ui/widget/container/centercontainer"] = function() return Widget end
package.preload["ui/widget/confirmbox"] = function() return Widget end
package.preload["datastorage"] = function() return { getDataDir = function() return temp_root end } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, value) return value end } } end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/widget/container/framecontainer"] = function() return Widget end
package.preload["ui/geometry"] = function() return { new = function(_, value) return value end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, value) return value end } end
package.preload["ui/widget/horizontalspan"] = function() return Widget end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/inputdialog"] = function() return Widget end
package.preload["ui/widget/overlapgroup"] = function() return Widget end
package.preload["ui/widget/textboxwidget"] = function() return Widget end
package.preload["ui/widget/textwidget"] = function() return Widget end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, tickAfterNext = function(_, callback) callback() end }
end
package.preload["ui/widget/container/widgetcontainer"] = function() return Widget end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            if os.execute("test -d " .. string.format("%q", path)) == 0 then return { mode = "directory" } end
            local file = io.open(path, "rb")
            if file then file:close(); return { mode = "file" } end
            return nil
        end,
        mkdir = function(path) return os.execute("mkdir -p " .. string.format("%q", path)) == 0 end,
    }
end

local http_required = 0
package.preload["ssl.https"] = function()
    http_required = http_required + 1
    return { request = function() error("network must not occur in buildPane") end }
end
package.preload["socket"] = function() return { skip = function(_, value) return value end } end
package.preload["ltn12"] = function() return { source = { string = function(value) return value end } } end
package.preload["socketutil"] = function() return { set_timeout = function() end, reset_timeout = function() end } end

_G.G_reader_settings = {
    readSetting = function(_, _, fallback) return fallback end,
    saveSetting = function() end,
}

local test_file = debug.getinfo(1, "S").source:sub(2)
local app = dofile(test_file:gsub("tests/test_inkblog.lua$", "inkblog.lua"))

local function check(condition, message)
    if not condition then error("TEST FAILED: " .. message, 2) end
end

local function context(width, height)
    return {
        dimen = { w = width, h = height },
        px = function(value) return value end,
        requestRebuild = function() end,
    }
end

check(app.requires_tbs_account == true, "AppDock requires the existing TBS account before launch")
check(app.version == "1.1.1", "catalog version exposes the TBS-linked release")
local TBS_ACCOUNT_ID = "323e4567-e89b-12d3-a456-426614174000"
package.loaded["appdock_tbs_account"] = nil
package.preload["appdock_tbs_account"] = function()
    return {
        isSignedIn = function() return true end,
        get = function() return { account_id = TBS_ACCOUNT_ID, device_id = "tbs_test_device_0123456789", device_secret = "test_secret_never_persist_this_value" } end,
    }
end
local tbs_identity = app._test.getTbsIdentity()
check(tbs_identity and tbs_identity.account_id == TBS_ACCOUNT_ID, "InkBlog reads the existing AppDock TBS account")
check(tbs_identity and tbs_identity.device_id == "tbs_test_device_0123456789", "InkBlog obtains device credentials only through the official TBS client")
local switched = app._test.stateFor({ inkblog = {
    session = { access_token = "stale", refresh_token = "stale", tbs_account_id = "123e4567-e89b-12d3-a456-426614174000", user = { id = "123e4567-e89b-12d3-a456-426614174000" } },
    posts = { { id = "private-cache" } }, comments = {}, notifications = {}, drafts = {}, image_cache = {}, image_order = {},
} })
check(switched.session.user.id == "" and #switched.posts == 0, "switching TBS identities clears old session and account-specific post cache")

-- buildPane must remain a pure visual build: it may not require or request HTTPS.
local normal_instance = {}
local pane = app.buildPane(normal_instance, context(600, 760))
check(pane.dimen.w == 600 and pane.dimen.h == 760, "600x760 pane geometry")
check(http_required == 0, "no network module/request in normal buildPane")
local small_pane = app.buildPane({}, context(600, 350))
check(small_pane.dimen.w == 600 and small_pane.dimen.h == 350, "600x350 split-pane geometry")
check(http_required == 0, "no network module/request in split buildPane")
local small_layer = small_pane[1]
check(#(small_layer._inkblog_button_bounds or {}) >= 5, "small-pane navigation retains usable buttons")
for _, rect in ipairs(small_layer._inkblog_button_bounds or {}) do
    check(rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= 600 and rect.y + rect.h <= 350, "small-pane button remains within pane bounds")
end
for _, widget in ipairs(small_layer) do
    if widget.ges_events and widget.dimen and widget.overlap_offset then
        local x, y = widget.overlap_offset[1], widget.overlap_offset[2]
        check(x >= 0 and y >= 0 and x + widget.dimen.w <= 600 and y + widget.dimen.h <= 350, "interactive card remains within split-pane bounds")
    end
end

-- Auth errors should be readable and a later successful retry should persist a session.
local auth_state = { session = {}, status = "" }
check(not app._test.applySessionResult(auth_state, nil, nil, "bad password", "signin"), "auth error is rejected")
check(auth_state.status:match("bad password") ~= nil, "auth error retained for retry")
check(app._test.applySessionResult(auth_state, {
    access_token = "access", refresh_token = "refresh", expires_in = 3600,
    user = { id = "123e4567-e89b-12d3-a456-426614174000", email = "reader@example.org" },
}, 200, nil, "signin"), "auth retry accepts valid session")
check(auth_state.session.access_token == "access" and auth_state.session.refresh_token == "refresh", "refresh token stored locally")

-- Local drafts must preserve all text byte-for-byte, including real UTF-8.
local draft_instance = {}
local draft_state = app._test.stateFor(draft_instance)
local full_text = "# Über Tinte\n\nMäßig? Nein — vollständig.\n\n> Grüßer aus Köln."
draft_state.editor = { title = "Über", body = full_text, images = {} }
local record, draft_err = app._test.captureLocalDraft(draft_state)
check(record and not draft_err, "offline draft persisted atomically")
check(record.body == full_text and draft_state.drafts[1].body == full_text, "draft text preserved exactly")

-- Markdown and page splitting must never cut UTF-8 bytes or lose source text.
local head, tail = app._test.utf8Cut("äöüß", 2)
check(head == "äö" and tail == "üß", "UTF-8 cut respects character boundaries")
local blocks = app._test.markdownBlocks("# Über\n\n" .. string.rep("äöüß ", 120) .. "\n\n> Zitat")
local pages = app._test.paginateBlocks(blocks, 250, 90, function(value) return value end)
check(#pages > 1, "long Markdown is paginated without ScrollHtmlWidget")
local function validUtf8(source)
    local position = 1
    while position <= #source do
        local byte = source:byte(position)
        local extra = byte < 0x80 and 0 or (byte < 0xE0 and 1 or (byte < 0xF0 and 2 or (byte < 0xF8 and 3 or -1)))
        if extra < 0 or position + extra > #source then return false end
        for offset = 1, extra do
            local continuation = source:byte(position + offset)
            if not continuation or continuation < 0x80 or continuation >= 0xC0 then return false end
        end
        position = position + extra + 1
    end
    return true
end
for _, page_blocks in ipairs(pages) do
    for _, block in ipairs(page_blocks) do
        check(validUtf8(tostring(block.text)), "page block contains valid complete UTF-8 sequences")
    end
end

-- Unbroken headings and newline-heavy code must preserve every character and progress.
local long_heading = string.rep("A", 240)
local long_code = string.rep("print('ink')\n", 55):sub(1, -2)
local stress_pages = app._test.paginateBlocks({
    { kind = "heading", level = 1, text = long_heading },
    { kind = "code", text = long_code },
}, 184, 100, function(value) return value end)
check(#stress_pages > 10, "small E-Ink pane paginates long heading and code")
local seen_heading, seen_code = {}, {}
for _, group in ipairs(stress_pages) do
    for _, block in ipairs(group) do
        check(validUtf8(block.text), "stress pagination preserves UTF-8")
        if block.kind == "heading" then seen_heading[#seen_heading + 1] = block.text end
        if block.kind == "code" then seen_code[#seen_code + 1] = block.text end
    end
end
check(table.concat(seen_heading) == long_heading, "long heading text remains intact")
check(table.concat(seen_code) == long_code, "code newlines remain intact")
check(app._test.restPath("posts", "limit=8") == "/rest/v1/inkblog_posts?limit=8", "PostgREST path uses the InkBlog table")
check(app._test.restPath("profiles", nil) == "/rest/v1/inkblog_profiles", "profile route uses the InkBlog table")
check(app._test.restPath("dchat_direct_messages", nil) == nil, "unknown legacy tables are refused")
check(app._test.validManagedPath("123e4567-e89b-12d3-a456-426614174000/123e4567-e89b-12d3-a456-426614174001.png"), "strict processed avatar path is accepted")
check(not app._test.validManagedPath("../dchat/messages.png"), "storage path traversal is rejected")

-- Gesture coordinates must be absolute after paint, like a real KOReader touch target.
local button = app._test.ActionButton:new{ width = 120, height = 44, title = "Tap" }
button:paintTo({}, 37, 91)
local range = button.ges_events.TapInkBlogAction[1].range
check(range.x == 37 and range.y == 91 and range.w == 120 and range.h == 44, "touch range follows paint offset")

-- The UI stays independent from any context theme and uses the required gray scale.
local colors = app._test.COLORS
check(colors.black == "#000" and colors.white == "#FFF" and colors.gray333 == "#333" and colors.gray666 == "#666" and colors.grayccc == "#CCC", "strict monochrome palette")
check(#app._test.LOGO_ROWS == 64 and #app._test.LOGO_ROWS[1] == 64, "inline 64x64 logo present")

print("InkBlog tests passed: build isolation, auth retry, local drafts, UTF-8 markdown, pagination, touch offsets, monochrome.")
