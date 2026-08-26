--[[--
RSS Reader for AppDock.
A local-first, text-only RSS 2.0 and Atom feed reader. It accepts explicitly
added HTTPS feeds, imposes strict response limits, and never executes remote
markup or opens article URLs automatically.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end
local ok_util, Util = pcall(require, "util")

local STORE_DIR = DataStorage:getDataDir() .. "/appdock_rss_reader"
local STORE_FILE = STORE_DIR .. "/feeds.lua"
local MAX_FEEDS = 18
local MAX_RESPONSE_BYTES = 768 * 1024
local MAX_ARTICLES = 60
local MAX_TITLE_BYTES = 160
local MAX_SUMMARY_BYTES = 1200
local MAX_URL_BYTES = 512
local CONNECT_TIMEOUT = 12
local REQUEST_MAX_TIME = 30

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function trim(value) return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or "" end
local function empty(width, height) return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } } end
local function smallFace(width) return Font:getFace("smallinfofont", math.max(8, math.floor(width / 55))) end
local function normalFace(width) return Font:getFace("smallinfofont", math.max(10, math.floor(width / 40))) end
local function titleFace(width) return Font:getFace("cfont", math.max(17, math.floor(width / 26))) end

-- Local store -----------------------------------------------------------------
local Store = {}

local function serialize(value, indent)
    indent = indent or ""
    local kind = type(value)
    if kind == "number" then return tostring(value) end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "string" then return string.format("%q", value) end
    if kind ~= "table" then return "nil" end
    local out, deeper = { "{" }, indent .. "  "
    for index, item in ipairs(value) do out[#out + 1] = "\n" .. deeper .. serialize(item, deeper) .. "," end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then keys[#keys + 1] = key end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local encoded = type(key) == "string" and (key:match("^[%a_][%w_]*$") and key or "[" .. string.format("%q", key) .. "]") or "[" .. tostring(key) .. "]"
        out[#out + 1] = "\n" .. deeper .. encoded .. " = " .. serialize(value[key], deeper) .. ","
    end
    if #out > 1 then out[#out + 1] = "\n" .. indent end
    out[#out + 1] = "}"
    return table.concat(out)
end

local function defaultStore() return { version = 1, feeds = {}, next_id = 1 } end
function Store.ensure()
    local attr = lfs.attributes(STORE_DIR)
    if attr and attr.mode == "directory" then return true end
    return lfs.mkdir(STORE_DIR)
end

local function validArticle(article)
    if type(article) ~= "table" then return nil end
    local title = trim(article.title):sub(1, MAX_TITLE_BYTES)
    if title == "" then return nil end
    return {
        title = title,
        summary = trim(article.summary):sub(1, MAX_SUMMARY_BYTES),
        link = type(article.link) == "string" and article.link:sub(1, MAX_URL_BYTES) or "",
        date = trim(article.date):sub(1, 120),
    }
end

local function validFeed(feed)
    if type(feed) ~= "table" or type(feed.url) ~= "string" or not feed.url:match("^https://") then return nil end
    local clean = { id = math.max(1, math.floor(tonumber(feed.id) or 1)), url = feed.url:sub(1, MAX_URL_BYTES), title = trim(feed.title):sub(1, MAX_TITLE_BYTES), updated = math.max(0, math.floor(tonumber(feed.updated) or 0)), articles = {} }
    if clean.title == "" then clean.title = clean.url end
    if type(feed.articles) == "table" then
        for _, article in ipairs(feed.articles) do
            local parsed = validArticle(article)
            if parsed and #clean.articles < MAX_ARTICLES then clean.articles[#clean.articles + 1] = parsed end
        end
    end
    return clean
end

function Store.load()
    local data = defaultStore()
    local chunk = loadfile(STORE_FILE)
    if not chunk then return data end
    setfenv(chunk, {})
    local ok, loaded = pcall(chunk)
    if not ok or type(loaded) ~= "table" or loaded.version ~= 1 then return data end
    data.next_id = math.max(1, math.floor(tonumber(loaded.next_id) or 1))
    if type(loaded.feeds) == "table" then
        for _, feed in ipairs(loaded.feeds) do
            local clean = validFeed(feed)
            if clean and #data.feeds < MAX_FEEDS then data.feeds[#data.feeds + 1] = clean; data.next_id = math.max(data.next_id, clean.id + 1) end
        end
    end
    return data
end

function Store.save(data)
    if not Store.ensure() then return nil, _("RSS Reader could not create its storage folder.") end
    local temporary = STORE_FILE .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err or _("RSS Reader could not save feeds.") end
    local ok, write_err = file:write("return " .. serialize(data) .. "\n")
    file:close()
    if not ok then os.remove(temporary); return nil, write_err end
    local renamed, rename_err = os.rename(temporary, STORE_FILE)
    if not renamed then os.remove(temporary); return nil, rename_err end
    return true
end

-- Text and XML ----------------------------------------------------------------
local Text = {}
function Text.entities(value)
    value = value or ""
    if ok_util and Util.htmlEntitiesToUtf8 then value = Util.htmlEntitiesToUtf8(value) end
    return value:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\""):gsub("&#39;", "'")
end
function Text.plain(value)
    value = value or ""
    value = value:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    value = value:gsub("<!%-%-.-%-%->", "")
    value = value:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]%s*>", "")
    value = value:gsub("<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</[Ss][Tt][Yy][Ll][Ee]%s*>", "")
    value = value:gsub("<[Bb][Rr]%s*/?>", "\n")
    value = value:gsub("</?[Pp][^>]*>", "\n\n")
    value = value:gsub("<[^>]->", "")
    value = Text.entities(value)
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("[ \t]+", " "):gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
    return trim(value)
end

local function tagContent(xml, tag)
    local letters = {}
    for char in tag:gmatch(".") do letters[#letters + 1] = "[" .. char:lower() .. char:upper() .. "]" end
    local pattern = table.concat(letters)
    return xml:match("<" .. pattern .. "[^>]*>%s*(.-)%s*</" .. pattern .. "%s*>")
end

local function attr(fragment, name)
    local needle = name:lower()
    for key, quote, value in fragment:gmatch("([%w:_%-]+)%s*=%s*([\"'])(.-)%2") do if key:lower() == needle then return value end end
end

local Parser = {}
local function article(title, summary, link, date)
    title = Text.plain(title):sub(1, MAX_TITLE_BYTES)
    if title == "" then return nil end
    return { title = title, summary = Text.plain(summary):sub(1, MAX_SUMMARY_BYTES), link = trim(link):sub(1, MAX_URL_BYTES), date = Text.plain(date):sub(1, 120) }
end

function Parser.rss(xml)
    local channel = xml:match("<[Cc][Hh][Aa][Nn][Nn][Ee][Ll][^>]*>(.-)</[Cc][Hh][Aa][Nn][Nn][Ee][Ll]%s*>")
    if not channel then return nil end
    local feed = { title = Text.plain(tagContent(channel, "title") or ""), articles = {} }
    for item in channel:gmatch("<[Ii][Tt][Ee][Mm][^>]*>(.-)</[Ii][Tt][Ee][Mm]%s*>") do
        local parsed = article(tagContent(item, "title") or "", tagContent(item, "description") or tagContent(item, "content") or "", tagContent(item, "link") or tagContent(item, "guid") or "", tagContent(item, "pubDate") or tagContent(item, "date") or "")
        if parsed then feed.articles[#feed.articles + 1] = parsed end
        if #feed.articles >= MAX_ARTICLES then break end
    end
    return #feed.articles > 0 and feed or nil
end

function Parser.atom(xml)
    if not xml:match("<[Ff][Ee][Ee][Dd][^>]*>") then return nil end
    local feed = { title = Text.plain(tagContent(xml, "title") or ""), articles = {} }
    for entry in xml:gmatch("<[Ee][Nn][Tt][Rr][Yy][^>]*>(.-)</[Ee][Nn][Tt][Rr][Yy]%s*>") do
        local link = ""
        for raw in entry:gmatch("<[Ll][Ii][Nn][Kk][^>]-/?>") do
            local href, rel = attr(raw, "href"), attr(raw, "rel")
            if href and (not rel or rel == "alternate") then link = href; break end
        end
        local parsed = article(tagContent(entry, "title") or "", tagContent(entry, "summary") or tagContent(entry, "content") or "", link, tagContent(entry, "published") or tagContent(entry, "updated") or "")
        if parsed then feed.articles[#feed.articles + 1] = parsed end
        if #feed.articles >= MAX_ARTICLES then break end
    end
    return #feed.articles > 0 and feed or nil
end

function Parser.feed(xml)
    if type(xml) ~= "string" or #xml == 0 then return nil, _("Feed response is empty.") end
    local parsed = Parser.rss(xml) or Parser.atom(xml)
    return parsed or nil, parsed and nil or _("This source is not a readable RSS 2.0 or Atom feed.")
end

-- HTTPS network ---------------------------------------------------------------
local Network = {}
function Network.safeUrl(value)
    if type(value) ~= "string" or #value == 0 or #value > MAX_URL_BYTES then return nil, _("Enter a valid HTTPS feed address.") end
    local socket_url = require("socket.url")
    local parsed = socket_url.parse(trim(value))
    if not parsed or parsed.scheme ~= "https" or not parsed.host or parsed.host == "" then return nil, _("Only HTTPS feed addresses are allowed.") end
    return trim(value)
end

function Network.fetch(url)
    local safe, url_err = Network.safeUrl(url)
    if not safe then return nil, url_err end
    local socket = require("socket")
    local socketutil = require("socketutil")
    local https = require("ssl.https")
    local chunks, received, started = {}, 0, os.time()
    local function sink(chunk)
        if os.time() - started > REQUEST_MAX_TIME then return nil, "response timed out" end
        if chunk then
            received = received + #chunk
            if received > MAX_RESPONSE_BYTES then return nil, "response too large" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    socketutil:set_timeout(CONNECT_TIMEOUT, REQUEST_MAX_TIME)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, https.request{ url = safe, method = "GET", sink = sink, headers = { ["user-agent"] = socketutil.USER_AGENT, ["accept"] = "application/rss+xml,application/atom+xml,application/xml,text/xml;q=0.9,*/*;q=0.1" } })
    end)
    socketutil:reset_timeout()
    if not ok or not headers then return nil, status or _("Network request failed.") end
    if not code or code < 200 or code > 299 then return nil, status or _("Feed server is unavailable.") end
    return table.concat(chunks)
end

-- UI and state ----------------------------------------------------------------
local function stateFor(instance)
    if instance.rss_reader then return instance.rss_reader end
    instance.rss_reader = { store = Store.load(), view = "feeds", selected_feed = nil, selected_article = nil, article_page = 1, article_pages = nil, notice = nil, feed_page = 1, article_list_page = 1 }
    return instance.rss_reader
end

local function getFeed(state, id)
    for _, feed in ipairs(state.store.feeds) do if feed.id == id then return feed end end
end

local function save(state)
    local ok, err = Store.save(state.store)
    state.notice = ok and nil or (err or _("RSS Reader could not save feeds."))
    return ok
end

local function refreshFeed(state, feed)
    local body, err = Network.fetch(feed.url)
    if not body then return nil, err end
    local parsed, parse_err = Parser.feed(body)
    if not parsed then return nil, parse_err end
    -- Cache replacement happens only after a complete successful fetch and parse.
    feed.title = parsed.title ~= "" and parsed.title or feed.title
    feed.articles = parsed.articles
    feed.updated = os.time()
    save(state)
    return true
end

local function refreshAll(state)
    local failures = 0
    for _, feed in ipairs(state.store.feeds) do if not refreshFeed(state, feed) then failures = failures + 1 end end
    return failures
end

local function paginate(text, width, height)
    local chars = math.max(20, math.floor(width / math.max(7, width / 52)))
    local lines_per_page = math.max(5, math.floor(height / math.max(12, width / 31)))
    local lines, pages, line = {}, {}, ""
    for paragraph in (text .. "\n\n"):gmatch("(.-)\n\n") do
        paragraph = trim(paragraph)
        if paragraph == "" then lines[#lines + 1] = "" else
            for word in paragraph:gmatch("%S+") do
                local candidate = line == "" and word or line .. " " .. word
                if #candidate > chars and line ~= "" then lines[#lines + 1], line = line, word else line = candidate end
            end
            if line ~= "" then lines[#lines + 1], line = line, "" end
            lines[#lines + 1] = ""
        end
    end
    if #lines == 0 then lines[1] = "" end
    for index = 1, #lines, lines_per_page do pages[#pages + 1] = table.concat(lines, "\n", index, math.min(#lines, index + lines_per_page - 1)) end
    return pages
end

local Action = InputContainer:extend{ title = nil, subtitle = nil, callback = nil, width = nil, height = nil, background = nil, foreground = nil, dimen = nil }
function Action:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local children = { TextWidget:new{ text = self.title or "", face = smallFace(self.width), fgcolor = self.foreground or Blitbuffer.COLOR_BLACK, bold = true, max_width = self.width - 8 } }
    if self.subtitle and self.subtitle ~= "" then children[#children + 1] = TextWidget:new{ text = self.subtitle, face = smallFace(self.width), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = self.width - 8 } end
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.max(4, math.floor(self.height * .22)), background = self.background or Blitbuffer.COLOR_LIGHT_GRAY, CenterContainer:new{ dimen = self.dimen, VerticalGroup:new{ unpack(children) } } }
    self.ges_events = { TapRSSAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:paintTo(bb, x, y) local range = self.ges_events.TapRSSAction[1].range; range.x, range.y, range.w, range.h = x, y, self.width, self.height; return InputContainer.paintTo(self, bb, x, y) end
function Action:onTapRSSAction() if self.callback then self.callback() end; return true end

local function background(width, height) return FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) } end
local function refresh(context) context.requestRebuild("ui") end

local function addFeed(instance, context)
    local state, dialog = stateFor(instance), nil
    dialog = InputDialog:new{ title = _("Add HTTPS feed"), input = "", input_hint = _("https://example.org/feed.xml"), buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = _("Add"), is_enter_default = true, callback = function()
        local url, url_err = Network.safeUrl(dialog:getInputText())
        if not url then UIManager:show(InfoMessage:new{ text = url_err }); return end
        for _, feed in ipairs(state.store.feeds) do if feed.url == url then UIManager:show(InfoMessage:new{ text = _("This feed is already in your list.") }); return end end
        if #state.store.feeds >= MAX_FEEDS then UIManager:show(InfoMessage:new{ text = _("RSS Reader has reached its feed limit.") }); return end
        UIManager:close(dialog)
        local feed = { id = state.store.next_id, url = url, title = url, updated = 0, articles = {} }
        state.store.next_id = state.store.next_id + 1
        local ok, err = refreshFeed(state, feed)
        if not ok then state.notice = err; refresh(context); return end
        state.store.feeds[#state.store.feeds + 1] = feed
        save(state); refresh(context)
    end } } } }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function deleteFeed(state, context, feed)
    UIManager:show(ConfirmBox:new{ text = _("Remove this RSS feed and its local article cache?\n\n") .. feed.title, ok_text = _("Remove"), ok_callback = function()
        for index, item in ipairs(state.store.feeds) do if item.id == feed.id then table.remove(state.store.feeds, index); break end end
        state.selected_feed, state.selected_article, state.view = nil, nil, "feeds"
        save(state); refresh(context)
    end })
end

local function feedPane(instance, context)
    local state, width, height = stateFor(instance), context.dimen.w, context.dimen.h
    local px = context.px or function(value) return value end
    local margin, gap, row_h = math.max(px(7), math.floor(width / 65)), math.max(px(4), math.floor(width / 140)), math.max(px(39), math.floor(height / 12))
    local elements = { background(width, height), TextWidget:new{ text = _("RSS Reader"), face = titleFace(width), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, margin } }, TextWidget:new{ text = _("Local feeds · HTTPS only"), face = smallFace(width), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, margin + math.max(px(22), math.floor(height / 20)) } } }
    local half = math.floor((width - 2 * margin - gap) / 2)
    local toolbar_y = margin + math.max(px(36), math.floor(height / 13))
    elements[#elements + 1] = Action:new{ title = _("+ Feed"), width = half, height = row_h, background = Blitbuffer.COLOR_GRAY_8, callback = function() addFeed(instance, context) end, overlap_offset = { margin, toolbar_y } }
    elements[#elements + 1] = Action:new{ title = _("Refresh all"), width = half, height = row_h, callback = function() local failures = refreshAll(state); state.notice = failures > 0 and (failures .. " " .. _("feed refreshes failed.")) or _("Feeds updated."); refresh(context) end, overlap_offset = { margin + half + gap, toolbar_y } }
    local y = toolbar_y + row_h + gap
    if #state.store.feeds == 0 then elements[#elements + 1] = TextWidget:new{ text = state.notice or _("No feeds yet. Add a trusted HTTPS RSS or Atom address."), face = normalFace(width), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, y + gap } } end
    for index, feed in ipairs(state.store.feeds) do
        if index > 8 or y + row_h > height - margin then break end
        local subtitle = #feed.articles .. " " .. _("articles") .. (feed.updated > 0 and " · " .. os.date("%Y-%m-%d", feed.updated) or "")
        elements[#elements + 1] = Action:new{ title = feed.title, subtitle = subtitle, width = width - 2 * margin, height = row_h, callback = function() state.selected_feed, state.view, state.article_list_page = feed.id, "articles", 1; refresh(context) end, overlap_offset = { margin, y } }
        y = y + row_h + gap
    end
    if state.notice then elements[#elements + 1] = TextWidget:new{ text = state.notice, face = smallFace(width), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, height - margin - math.max(px(14), math.floor(width / 45)) } } end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function articleListPane(instance, context)
    local state, feed, width, height = stateFor(instance), nil, context.dimen.w, context.dimen.h
    feed = getFeed(state, state.selected_feed)
    if not feed then state.view = "feeds"; return feedPane(instance, context) end
    local px = context.px or function(value) return value end
    local margin, gap, row_h = math.max(px(7), math.floor(width / 65)), math.max(px(4), math.floor(width / 140)), math.max(px(42), math.floor(height / 11))
    local elements = { background(width, height), TextWidget:new{ text = feed.title, face = titleFace(width), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, margin } } }
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    local toolbar_y = margin + math.max(px(33), math.floor(height / 13))
    elements[#elements + 1] = Action:new{ title = _("‹ Feeds"), width = third, height = row_h, callback = function() state.view = "feeds"; refresh(context) end, overlap_offset = { margin, toolbar_y } }
    elements[#elements + 1] = Action:new{ title = _("Refresh"), width = third, height = row_h, background = Blitbuffer.COLOR_GRAY_8, callback = function() local ok, err = refreshFeed(state, feed); state.notice = ok and _("Feed updated.") or err; refresh(context) end, overlap_offset = { margin + third + gap, toolbar_y } }
    elements[#elements + 1] = Action:new{ title = _("Remove"), width = third, height = row_h, callback = function() deleteFeed(state, context, feed) end, overlap_offset = { margin + 2 * (third + gap), toolbar_y } }
    local per_page, start = 6, (state.article_list_page - 1) * 6 + 1
    local y = toolbar_y + row_h + gap
    if #feed.articles == 0 then elements[#elements + 1] = TextWidget:new{ text = _("No cached articles. Tap Refresh to try this feed again."), face = normalFace(width), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, y + gap } } end
    for index = start, math.min(#feed.articles, start + per_page - 1) do
        local entry = feed.articles[index]
        local subtitle = entry.date ~= "" and entry.date or entry.summary:sub(1, 96)
        elements[#elements + 1] = Action:new{ title = entry.title, subtitle = subtitle, width = width - 2 * margin, height = row_h, callback = function() state.selected_article, state.article_page, state.article_pages, state.view = index, 1, nil, "reader"; refresh(context) end, overlap_offset = { margin, y } }
        y = y + row_h + gap
    end
    if #feed.articles > per_page then
        local nav_w = math.floor((width - 2 * margin - gap) / 2)
        elements[#elements + 1] = Action:new{ title = _("Earlier"), width = nav_w, height = row_h, callback = function() state.article_list_page = clamp(state.article_list_page - 1, 1, math.ceil(#feed.articles / per_page)); refresh(context) end, overlap_offset = { margin, height - margin - row_h } }
        elements[#elements + 1] = Action:new{ title = _("Later"), width = nav_w, height = row_h, callback = function() state.article_list_page = clamp(state.article_list_page + 1, 1, math.ceil(#feed.articles / per_page)); refresh(context) end, overlap_offset = { margin + nav_w + gap, height - margin - row_h } }
    end
    if state.notice then elements[#elements + 1] = TextWidget:new{ text = state.notice, face = smallFace(width), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, math.max(toolbar_y, height - 2 * row_h) } } end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function readerPane(instance, context)
    local state, feed, width, height = stateFor(instance), nil, context.dimen.w, context.dimen.h
    feed = getFeed(state, state.selected_feed)
    local entry = feed and feed.articles[state.selected_article]
    if not entry then state.view = "articles"; return articleListPane(instance, context) end
    local px = context.px or function(value) return value end
    local margin, gap, toolbar_h = math.max(px(7), math.floor(width / 65)), math.max(px(4), math.floor(width / 140)), math.max(px(29), math.floor(height / 17))
    local metadata_h = math.max(px(19), math.floor(height / 28))
    local content_y, content_h = margin + toolbar_h + gap + metadata_h, height - (margin + toolbar_h + gap + metadata_h) - toolbar_h - 2 * gap
    local text = entry.title .. "\n\n" .. (entry.date ~= "" and entry.date .. "\n\n" or "") .. (entry.summary ~= "" and entry.summary or _("This feed item has no readable summary."))
    local key = table.concat({ width, height, state.selected_feed or 0, state.selected_article or 0 }, ":")
    if state.article_layout_key ~= key then state.article_pages, state.article_page, state.article_layout_key = paginate(text, width - 2 * margin, content_h), 1, key end
    local pages = state.article_pages or { "" }
    state.article_page = clamp(state.article_page, 1, #pages)
    local elements = { background(width, height), TextBoxWidget:new{ text = pages[state.article_page], face = normalFace(width), width = width - 2 * margin, height = content_h, line_height = 0.32, alignment = "left", fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, content_y } } }
    local third = math.floor((width - 2 * margin - 2 * gap) / 3)
    elements[#elements + 1] = Action:new{ title = _("‹ Articles"), width = third, height = toolbar_h, callback = function() state.view = "articles"; refresh(context) end, overlap_offset = { margin, margin } }
    elements[#elements + 1] = Action:new{ title = entry.title:sub(1, 16), width = third, height = toolbar_h, background = Blitbuffer.COLOR_GRAY_8, callback = function() end, overlap_offset = { margin + third + gap, margin } }
    elements[#elements + 1] = Action:new{ title = state.article_page .. "/" .. #pages, width = third, height = toolbar_h, callback = function() end, overlap_offset = { margin + 2 * (third + gap), margin } }
    local nav_w = math.floor((width - 2 * margin - gap) / 2)
    elements[#elements + 1] = Action:new{ title = _("‹ Previous"), width = nav_w, height = toolbar_h, callback = function() state.article_page = clamp(state.article_page - 1, 1, #pages); refresh(context) end, overlap_offset = { margin, height - margin - toolbar_h } }
    elements[#elements + 1] = Action:new{ title = _("Next ›"), width = nav_w, height = toolbar_h, background = Blitbuffer.COLOR_GRAY_8, callback = function() state.article_page = clamp(state.article_page + 1, 1, #pages); refresh(context) end, overlap_offset = { margin + nav_w + gap, height - margin - toolbar_h } }
    if entry.link ~= "" then elements[#elements + 1] = TextWidget:new{ text = _("Original: ") .. entry.link, face = smallFace(width), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, content_y - math.max(px(16), math.floor(height / 28)) } } end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function persistentPane(pane, state)
    function pane:onDeactivate() save(state) end
    return pane
end

return {
    id = "rss_reader",
    version = "1.0.2",
    title = "RSS Reader",
    subtitle = "Local RSS and Atom feeds",
    symbol = "R",
    logo = "rss",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        if state.view == "articles" then return persistentPane(articleListPane(instance, context), state) end
        if state.view == "reader" then return persistentPane(readerPane(instance, context), state) end
        return persistentPane(feedPane(instance, context), state)
    end,
}
