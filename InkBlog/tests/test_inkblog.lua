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

local decoded_responses = {}
local Decode = setmetatable({ simple = {} }, { __call = function(_, raw)
    return table.remove(decoded_responses, 1) or {}
end })
package.preload["json"] = function() return { encode = simpleJson, decode = Decode } end
package.preload["ffi/blitbuffer"] = function() return {
    COLOR_WHITE = "#FFF", COLOR_BLACK = "#000", COLOR_DARK_GRAY = "#333", COLOR_GRAY_8 = "#666", COLOR_LIGHT_GRAY = "#CCC",
    COLOR_DARK_GREEN = "#164A34", COLOR_DARK_BLUE = "#203A68", COLOR_DARK_CYAN = "#166A72", COLOR_DARK_YELLOW = "#9A6810",
} end
package.preload["ui/widget/container/centercontainer"] = function() return Widget end
package.preload["ui/widget/confirmbox"] = function() return Widget end
package.preload["datastorage"] = function() return { getDataDir = function() return temp_root end } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, value) return value end, isColorEnabled = function() return colour_enabled end } } end
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
local html_widget_creations = 0
package.preload["ui/widget/htmlboxwidget"] = function()
    return { new = function()
        html_widget_creations = html_widget_creations + 1
        return { paintTo = function() error("simulated HtmlBoxWidget paint crash") end }
    end }
end
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

local http_required, http_responses = 0, {}
package.preload["ssl.https"] = function()
    http_required = http_required + 1
    return { request = function(request)
        local response = table.remove(http_responses, 1)
        if not response then error("network must not occur in buildPane") end
        if type(request.sink) == "function" and response.body then request.sink(response.body) end
        return 1, response.code or 200, response.headers or {}, "OK"
    end }
end
package.preload["socket"] = function() return { skip = function(count, ...) return select(count + 1, ...) end } end
package.preload["ltn12"] = function() return { source = { string = function(value) return value end } } end
package.preload["socketutil"] = function() return { set_timeout = function() end, reset_timeout = function() end } end

_G.G_reader_settings = {
    readSetting = function(_, _, fallback) return fallback end,
    saveSetting = function() end,
}

local keyboard_requests = {}
package.preload["appdock_keyboard"] = function()
    return {
        open = function(options) keyboard_requests[#keyboard_requests + 1] = options; return {} end,
        attach = function() return true end,
        isEnabled = function() return true end,
    }
end

local test_file = debug.getinfo(1, "S").source:sub(2)
local app = dofile(test_file:gsub("tests/test_inkblog.lua$", "inkblog.lua"))

local function check(condition, message)
    if not condition then error("TEST FAILED: " .. message, 2) end
end

local function context(width, height, palette)
    return {
        dimen = { w = width, h = height },
        px = function(value) return value end,
        palette = palette,
        requestRebuild = function() end,
    }
end

check(app.requires_tbs_account == true, "AppDock requires the existing TBS account before launch")
check(app.version == "1.3.2", "catalog version exposes the DChat-palette old-paper release")
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

local write_instance = {}
local write_state = app._test.stateFor(write_instance)
write_state.view = "write"
write_state.editor = { title = "Ein Titel", body = "Erste Zeile\nZweite Zeile", images = {} }
local write_pane = app.buildPane(write_instance, context(600, 760))
local title_field, body_field
for _, widget in ipairs(write_pane[1]) do
    if widget.inkblog_editor_field == "title" then title_field = widget end
    if widget.inkblog_editor_field == "body" then body_field = widget end
end
check(title_field and body_field, "write view exposes visible editable title and multiline body fields")
local body_preview_widget = body_field[1] and body_field[1][1]
check(body_preview_widget and body_preview_widget.face and body_preview_widget.face.size <= 18,
    "large multiline body field keeps its preview font within the readable 18pt cap")
body_field:onTapInkBlogAction()
check(keyboard_requests[#keyboard_requests] and keyboard_requests[#keyboard_requests].multiline == true,
    "body field opens the AppDock keyboard in multiline mode")
keyboard_requests[#keyboard_requests].on_submit("Erste Zeile\nZweite Zeile\nDritte Zeile")
check(write_state.editor.body == "Erste Zeile\nZweite Zeile\nDritte Zeile", "multiline keyboard preserves newline-separated Markdown")
title_field:onTapInkBlogAction()
check(keyboard_requests[#keyboard_requests] and keyboard_requests[#keyboard_requests].multiline == false,
    "title field opens the AppDock keyboard in single-line mode")
keyboard_requests[#keyboard_requests].on_submit("Neuer Titel")
check(write_state.editor.title == "Neuer Titel", "title keyboard saves its value into the editor")

local compact_write_instance = {}
local compact_write_state = app._test.stateFor(compact_write_instance)
compact_write_state.view = "write"
local compact_write_pane = app.buildPane(compact_write_instance, context(600, 350))
local compact_fields = {}
for _, widget in ipairs(compact_write_pane[1]) do
    if widget.inkblog_editor_field then compact_fields[#compact_fields + 1] = widget end
end
check(#compact_fields == 2, "compact split pane still exposes both write fields")
for _, rect in ipairs(compact_write_pane[1]._inkblog_button_bounds or {}) do
    check(rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= 600 and rect.y + rect.h <= 350,
        "compact write control remains within split-pane bounds")
end

local article_instance = {}
local article_state = app._test.stateFor(article_instance)
local article_record = {
    id = "223e4567-e89b-12d3-a456-426614174000", author_id = "323e4567-e89b-12d3-a456-426614174000",
    title = "Crash-proof article", markdown = "# A quiet page\n\nA paragraph with **emphasis**.",
    created_at = "2026-10-23T12:00:00Z", avatar_path = "323e4567-e89b-12d3-a456-426614174000/423e4567-e89b-12d3-a456-426614174000.png", like_count = 0, comment_count = 0,
}
article_state.posts, article_state.view, article_state.mode = { article_record }, "discover", "discover"
local feed_pane = app.buildPane(article_instance, context(600, 760))
local article_card
for _, widget in ipairs(feed_pane[1]) do
    if widget.body and widget.body:find("Crash-proof article", 1, true) then article_card = widget; break end
end
check(article_card, "feed renders a tappable article card")
local preview_avatar
for _, widget in ipairs(feed_pane[1]) do
    if widget.inkblog_avatar_path == article_record.avatar_path then preview_avatar = widget; break end
end
check(preview_avatar, "post preview includes the author's round avatar stamp")
article_card:onTapInkBlogAction()
check(article_state.view == "article" and article_state.selected_post == article_record, "article card tap opens the selected article")
local rendered_article = app.buildPane(article_instance, context(600, 760))
check(rendered_article.dimen.w == 600 and rendered_article.dimen.h == 760, "opened discovered article renders without a pane exception")
check(html_widget_creations == 0, "article renderer avoids the unstable HtmlBoxWidget paint path")
local article_avatar, profile_button
for _, widget in ipairs(rendered_article[1]) do
    if widget.inkblog_avatar_path == article_record.avatar_path then article_avatar = widget end
    if widget.inkblog_action == "open_author_profile" then profile_button = widget end
end
check(article_avatar, "opened article includes the author's round avatar stamp")
check(article_avatar and article_avatar.width == 64, "normal article displays a larger 64 px author avatar")
check(profile_button, "a foreign article exposes a clear profile action")
profile_button:onTapInkBlogAction()
check(article_state.view == "author", "profile action opens the foreign author's public account")
local author_pane = app.buildPane(article_instance, context(600, 760))
check(author_pane.dimen.h == 760, "foreign author profile renders even when its network load fails")

local own_article_instance = {}
local own_article_state = app._test.stateFor(own_article_instance)
own_article_state.session.user.id = article_record.author_id
own_article_state.posts, own_article_state.view, own_article_state.mode = { article_record }, "mine", "mine"
local own_posts_pane = app.buildPane(own_article_instance, context(600, 350))
local own_article_card
for _, widget in ipairs(own_posts_pane[1]) do
    if widget.body and widget.body:find("Crash-proof article", 1, true) then own_article_card = widget; break end
end
check(own_article_card, "own-post list renders a tappable article card")
own_article_card:onTapInkBlogAction()
check(own_article_state.view == "article", "own-post card tap enters article view")
local own_rendered_article = app.buildPane(own_article_instance, context(600, 350))
check(own_rendered_article.dimen.w == 600 and own_rendered_article.dimen.h == 350,
    "own article renders inside a 600x350 AppDock split pane")
check(html_widget_creations == 0, "neither discovered nor own articles instantiate HtmlBoxWidget")
local compact_article_text
for _, widget in ipairs(own_rendered_article[1]) do
    if type(widget.text) == "string" and widget.text:find("A quiet page", 1, true) then compact_article_text = widget; break end
end
check(compact_article_text, "compact article keeps a visible content block below its controls")
local compact_avatar
for _, widget in ipairs(own_rendered_article[1]) do if widget.inkblog_avatar_owner == article_record.author_id then compact_avatar = widget end end
check(compact_avatar and compact_avatar.width == 42, "compact article displays a larger 42 px author avatar")

local missing_article_instance = {}
local missing_article_state = app._test.stateFor(missing_article_instance)
missing_article_state.view, missing_article_state.selected_post = "article", nil
local missing_article_pane = app.buildPane(missing_article_instance, context(600, 350))
check(missing_article_state.view == "feed" and missing_article_state.selected_post == nil,
    "missing selected post safely returns to the feed")
check(missing_article_pane.dimen.w == 600 and missing_article_state.status:find("unavailable", 1, true),
    "missing-post fallback keeps pane geometry and shows a readable status")

local incomplete_article_instance = {}
local incomplete_article_state = app._test.stateFor(incomplete_article_instance)
incomplete_article_state.view = "article"
incomplete_article_state.selected_post = { id = "423e4567-e89b-12d3-a456-426614174000", display_name = {} }
local incomplete_article_pane = app.buildPane(incomplete_article_instance, context(600, 350))
check(incomplete_article_state.view == "article" and incomplete_article_pane.dimen.h == 350,
    "valid but incomplete article data renders safely in a split pane")

local publish_instance = {}
local publish_state = app._test.stateFor(publish_instance)
publish_state.view = "write"
publish_state.editor = { title = "Offline publish retry", body = "The complete text stays local.", images = {} }
local publish_pane = app.buildPane(publish_instance, context(600, 760))
local publish_button
for _, widget in ipairs(publish_pane[1]) do if widget.title == "Publizieren" then publish_button = widget; break end end
check(publish_button, "write screen exposes a publish button")
publish_button:onTapInkBlogAction()
check(not publish_state.loading and #publish_state.drafts == 1, "failed TBS/network publication does not strand the UI and retains a local draft")
check(publish_state.drafts[1].body == "The complete text stays local.", "publish retry retains every body byte locally")

-- A successful POST supplies only post columns. InkBlog must enrich and sanitize
-- that response before moving to the reader, which is the crash-prone transition.
local successful_publish_instance = {}
local successful_publish_state = app._test.stateFor(successful_publish_instance)
local AVATAR_PATH = "323e4567-e89b-12d3-a456-426614174000/523e4567-e89b-12d3-a456-426614174000.png"
successful_publish_state.session = {
    access_token = "access", refresh_token = "refresh", expires_at = os.time() + 3600, tbs_account_id = "",
    user = { id = TBS_ACCOUNT_ID, email = "reader@example.org" },
}
successful_publish_state.profile = { id = TBS_ACCOUNT_ID, display_name = "Ink Reader", bio = "A quiet shelf.", avatar_path = AVATAR_PATH }
successful_publish_state.view = "write"
successful_publish_state.editor = { title = "A complete post", body = "This must not crash KOReader.", images = {} }
http_responses[#http_responses + 1] = { code = 201, body = "[post]" }
decoded_responses[#decoded_responses + 1] = { {
    id = "623e4567-e89b-12d3-a456-426614174000", author_id = TBS_ACCOUNT_ID,
    title = "A complete post", markdown = "This must not crash KOReader.", status = "published", created_at = "2026-10-23T12:00:00Z",
} }
http_responses[#http_responses + 1] = { code = 200, body = "[profile]" }
decoded_responses[#decoded_responses + 1] = { { id = TBS_ACCOUNT_ID, display_name = "Ink Reader", bio = "A quiet shelf.", avatar_path = AVATAR_PATH } }
http_responses[#http_responses + 1] = { code = 200, body = "\137PNG\r\n\26\nportrait" }
local successful_publish_pane = app.buildPane(successful_publish_instance, context(600, 760))
local successful_publish_button
for _, widget in ipairs(successful_publish_pane[1]) do if widget.title == "Publizieren" then successful_publish_button = widget; break end end
check(successful_publish_button, "write screen exposes a publish button for the successful path")
successful_publish_button:onTapInkBlogAction()
check(not successful_publish_state.loading and successful_publish_state.view == "article", "successful publication reaches the reader without leaving a loading state")
check(successful_publish_state.selected_post and successful_publish_state.selected_post.display_name == "Ink Reader", "POST response is enriched with the public author name")
check(successful_publish_state.selected_post and successful_publish_state.selected_post.avatar_path == AVATAR_PATH, "POST response is enriched with the public author avatar")
check(successful_publish_state.image_cache[AVATAR_PATH], "published article caches its author avatar within the bounded cache")
local successful_article_pane = app.buildPane(successful_publish_instance, context(600, 760))
check(successful_article_pane.dimen.h == 760, "enriched successful publication renders safely in the reader")

-- A direct foreign post must not inherit the signed-in reader's name or avatar
-- while the public profile lookup completes.
local FOREIGN_AUTHOR_ID = "723e4567-e89b-12d3-a456-426614174000"
local FOREIGN_AVATAR_PATH = FOREIGN_AUTHOR_ID .. "/823e4567-e89b-12d3-a456-426614174000.png"
local foreign_state = app._test.stateFor({})
foreign_state.session = successful_publish_state.session
foreign_state.profile = successful_publish_state.profile
http_responses[#http_responses + 1] = { code = 200, body = "[foreign profile]" }
decoded_responses[#decoded_responses + 1] = { { id = FOREIGN_AUTHOR_ID, display_name = "Foreign Ink", bio = "Another shelf.", avatar_path = FOREIGN_AVATAR_PATH } }
local foreign_post = app._test.enrichPostWithProfile(foreign_state, {
    id = "923e4567-e89b-12d3-a456-426614174000", author_id = FOREIGN_AUTHOR_ID,
    title = "Foreign post", markdown = "A separate author.", status = "published", created_at = "2026-10-23T12:00:00Z",
})
check(foreign_post and foreign_post.display_name == "Foreign Ink" and foreign_post.avatar_path == FOREIGN_AVATAR_PATH,
    "direct foreign post resolves the fetched foreign profile before rendering")
local multilingual_title = string.rep("界", 240)
local normalized_multilingual = app._test.normalizedPost({ id = "a23e4567-e89b-12d3-a456-426614174000", author_id = FOREIGN_AUTHOR_ID, title = multilingual_title, markdown = "" })
check(app._test.utf8Length(normalized_multilingual.title) == 240, "normalization preserves a valid 240-character Unicode title")

local compact_author_instance = {}
local compact_author_state = app._test.stateFor(compact_author_instance)
compact_author_state.view, compact_author_state.mode, compact_author_state.selected_author_id = "author", "blog", FOREIGN_AUTHOR_ID
compact_author_state.author_profile = { id = FOREIGN_AUTHOR_ID, display_name = "Foreign Ink", bio = "Another shelf.", avatar_path = FOREIGN_AVATAR_PATH }
compact_author_state.posts = { foreign_post }
local compact_author_pane = app.buildPane(compact_author_instance, context(600, 350))
local compact_author_card
for _, widget in ipairs(compact_author_pane[1]) do
    if widget.body and widget.body:find("Foreign post", 1, true) then compact_author_card = widget; break end
end
check(compact_author_card, "compact foreign profile keeps one loaded post visible")
for _, widget in ipairs(compact_author_pane[1]) do
    if widget.ges_events and widget.dimen and widget.overlap_offset then
        local x, y = widget.overlap_offset[1], widget.overlap_offset[2]
        check(x >= 0 and y >= 0 and x + widget.dimen.w <= 600 and y + widget.dimen.h <= 350,
            "compact foreign profile keeps every interactive element inside the pane")
    end
end

local failure_state = { loading = true, status = "" }
local failure_context = context(600, 760)
failure_context.requestRebuild = function() error("simulated stale AppDock host") end
local failure_button = app._test.ActionButton:new{
    width = 120, height = 44, state = failure_state, context = failure_context,
    callback = function() error("simulated callback failure") end,
}
failure_button:onTapInkBlogAction()
check(not failure_state.loading and failure_state.status:find("local content", 1, true) ~= nil,
    "unexpected tap errors are contained and translated into visible status")

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
local near_limit_pages = app._test.paginateBlocks({ { kind = "paragraph", text = string.rep("x", 96 * 1024) } }, 190, 90, function(value) return value end)
check(#near_limit_pages > 100, "a near-limit unbroken post paginates deterministically without native layout allocation")
check(app._test.base64Encode("Man") == "TWFu" and app._test.base64Encode("Ma") == "TWE=", "chunked base64 preserves standard padding")
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

-- DChat/AppDock resolves colors into context.palette. InkBlog uses that exact
-- palette contract instead of constructing unsupported RGB values itself.
local palette = {
    background = "paper-background", surface = "paper-surface", surface_variant = "paper-edge",
    primary = "theme-primary", on_primary = "theme-primary-text", secondary = "theme-secondary", on_secondary = "theme-secondary-text",
    tertiary = "theme-tertiary", on_tertiary = "theme-tertiary-text", on_surface = "theme-ink", on_variant = "theme-muted",
}
local palette_pane = app.buildPane({}, context(600, 760, palette))
local colors = app._test.getColors()
check(colors.paper == "paper-background" and colors.parchment == "paper-edge" and colors.ink == "theme-ink", "InkBlog uses the AppDock-provided DChat palette for old-paper surfaces and text")
local palette_button = app._test.ActionButton:new{ width = 120, height = 44, primary = true, title = "Theme" }
check(palette_button[1].background == "theme-primary", "primary InkBlog buttons use the AppDock primary color")
check(palette_pane.dimen.w == 600, "palette-backed pane builds with normal geometry")
check(#app._test.LOGO_ROWS == 64 and #app._test.LOGO_ROWS[1] == 64, "inline 64x64 logo present")

print("InkBlog tests passed: stable publishing, author profiles, avatar stamps, AppDock theme palette, auth retry, local drafts, UTF-8 markdown, pagination and touch offsets.")
