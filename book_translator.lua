--[[--
BookTranslator for AppDock.

Supported input and output formats: TXT, HTML, XHTML and FB2.
The original file is never changed. A new <name>.<target>.translated.<ext>
file is written next to it after a successful translation.

Book text is sent only after a visible confirmation to the LibreTranslate-
compatible endpoint chosen by the reader owner. Use only books you own or
are allowed to process.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SETTINGS_KEY = "appdock_booktranslator"
local MAX_FILE_BYTES = 3 * 1024 * 1024
local CHUNK_BYTES = 2600
local SUPPORTED = { txt = true, html = true, htm = true, xhtml = true, fb2 = true }

local DEFAULT_CONFIG = {
    endpoint = "https://libretranslate.com/translate",
    api_key = "",
    source = "auto",
    target = "de",
}

local Screen = Device.screen

local function scale(value)
    return Screen:scaleBySize(value)
end

local function emptySizedWidget(width, height)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalSpan:new{ width = 0 },
    }
end

local function trim(value)
    return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or ""
end

local function cloneConfig(config)
    return {
        endpoint = config.endpoint or DEFAULT_CONFIG.endpoint,
        api_key = config.api_key or "",
        source = config.source or DEFAULT_CONFIG.source,
        target = config.target or DEFAULT_CONFIG.target,
    }
end

local function loadConfig()
    local stored = G_reader_settings:readSetting(SETTINGS_KEY, {})
    return cloneConfig(stored)
end

local function saveConfig(config)
    G_reader_settings:saveSetting(SETTINGS_KEY, cloneConfig(config))
end

local function fileExtension(path)
    local suffix = (path or ""):match("%.([%w]+)$")
    return suffix and suffix:lower() or ""
end

local function outputPath(path, target)
    local stem, ext = path:match("^(.*)(%.[^%.]+)$")
    if not stem then return path .. "." .. target .. ".translated.txt" end
    local safe_target = (target or "translated"):gsub("[^%w%-]", "_")
    return stem .. "." .. safe_target .. ".translated" .. ext
end

local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    if not content then return nil, "could not read source" end
    if #content > MAX_FILE_BYTES then
        return nil, _("This book is larger than the BookTranslator safety limit of 3 MiB.")
    end
    return content
end

local function writeFile(path, content)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(content)
    file:close()
    return ok and true or nil, write_err
end

local function splitText(text)
    local chunks, position = {}, 1
    while position <= #text do
        local stop = math.min(position + CHUNK_BYTES - 1, #text)
        if stop < #text then
            local candidate = text:sub(position, stop)
            local break_at = candidate:match("^.*()[%s%.,;:!%?]")
            if break_at and break_at > math.floor(CHUNK_BYTES * 0.35) then
                stop = position + break_at - 1
            else
                while stop > position and text:byte(stop + 1) and text:byte(stop + 1) >= 0x80 and text:byte(stop + 1) <= 0xBF do
                    stop = stop - 1
                end
            end
        end
        chunks[#chunks + 1] = text:sub(position, stop)
        position = stop + 1
    end
    return chunks
end

local function translateRequest(config, text)
    if trim(text) == "" then return text end
    local parsed = require("socket.url").parse(config.endpoint)
    if not parsed or parsed.scheme ~= "https" then
        return nil, _("The LibreTranslate endpoint must use HTTPS.")
    end
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    local url = require("socket.url")
    local http = require("ssl.https")
    local JSON = require("json")
    local body = "q=" .. url.escape(text)
        .. "&source=" .. url.escape(config.source)
        .. "&target=" .. url.escape(config.target)
        .. "&format=text"
    if trim(config.api_key) ~= "" then body = body .. "&api_key=" .. url.escape(config.api_key) end
    local sink = {}
    socketutil:set_timeout(20, 40)
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = config.endpoint,
            method = "POST",
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
            headers = {
                ["content-type"] = "application/x-www-form-urlencoded",
                ["content-length"] = tostring(#body),
                ["accept"] = "application/json",
            },
        })
    end)
    socketutil:reset_timeout()
    if not ok or not headers then return nil, status or _("The translation service could not be reached.") end
    if code ~= 200 then return nil, status or (_("Translation service returned HTTP ") .. tostring(code)) end
    local response = table.concat(sink)
    local decoded_ok, decoded = pcall(JSON.decode, response, JSON.decode.simple)
    if not decoded_ok or type(decoded) ~= "table" or type(decoded.translatedText) ~= "string" then
        return nil, _("The translation service returned an invalid response.")
    end
    return decoded.translatedText
end

local function translatePlainText(content, config)
    local output = {}
    for _, chunk in ipairs(splitText(content)) do
        local translated, err = translateRequest(config, chunk)
        if not translated then return nil, err end
        output[#output + 1] = translated
    end
    return table.concat(output)
end

local function translateMarkup(content, config)
    local output, position, protected = {}, 1, nil
    while position <= #content do
        local tag_start = content:find("<", position, true)
        if not tag_start then
            local translated, err = translatePlainText(content:sub(position), config)
            if not translated then return nil, err end
            output[#output + 1] = translated
            break
        end
        local text = content:sub(position, tag_start - 1)
        if text ~= "" then
            if protected then
                output[#output + 1] = text
            else
                local translated, err = translatePlainText(text, config)
                if not translated then return nil, err end
                output[#output + 1] = translated
            end
        end
        local tag_end = content:find(">", tag_start, true)
        if not tag_end then return nil, _("This markup file has an incomplete tag.") end
        local tag = content:sub(tag_start, tag_end)
        local tag_name = tag:match("^%s*</%s*([%w:_-]+)") or tag:match("^%s*<%s*([%w:_-]+)")
        local lower_name = tag_name and tag_name:lower() or nil
        if tag:match("^%s*<%s*/") and protected == lower_name then
            protected = nil
        elseif lower_name and (lower_name == "style" or lower_name == "script" or lower_name == "code" or lower_name == "pre") and not tag:match("/%s*>") then
            protected = lower_name
        end
        output[#output + 1] = tag
        position = tag_end + 1
    end
    return table.concat(output)
end

local function translateBook(path, config)
    local extension = fileExtension(path)
    if not SUPPORTED[extension] then
        return nil, _("Supported formats are TXT, HTML, XHTML and FB2."), nil
    end
    local source, read_err = readFile(path)
    if not source then return nil, read_err, nil end
    local translated, translate_err
    if extension == "txt" then
        translated, translate_err = translatePlainText(source, config)
    else
        translated, translate_err = translateMarkup(source, config)
    end
    if not translated then return nil, translate_err, nil end
    local destination = outputPath(path, config.target)
    local ok, write_err = writeFile(destination, translated)
    if not ok then return nil, write_err or _("Could not save the translated book."), nil end
    return destination, nil, #splitText(source)
end

local ActionCard = InputContainer:extend{
    title = nil,
    subtitle = nil,
    callback = nil,
    width = nil,
    height = nil,
}

function ActionCard:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = scale(1),
        radius = scale(13),
        background = require("ffi/blitbuffer").COLOR_LIGHT_GRAY,
        color = require("ffi/blitbuffer").COLOR_DARK_GRAY,
        CenterContainer:new{
            dimen = self.dimen,
            VerticalGroup:new{
                TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", scale(14)), bold = true, max_width = self.width - scale(22) },
                VerticalSpan:new{ width = scale(3) },
                TextWidget:new{ text = self.subtitle or "", face = Font:getFace("smallinfofont", scale(10)), max_width = self.width - scale(22) },
            },
        },
    }
    self.ges_events = { TapBookTranslatorCard = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function ActionCard:paintTo(bb, x, y)
    local range = self.ges_events.TapBookTranslatorCard[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function ActionCard:onTapBookTranslatorCard()
    if self.callback then self.callback() end
    return true
end

local function currentBookPath(context)
    local ui = context.manager and context.manager.appdock and context.manager.appdock.ui
    local document = ui and ui.document
    return document and document.file or nil
end

local function showInput(title, hint, value, callback)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input_hint = hint,
        input = value or "",
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                { text = _("Save"), is_enter_default = true, callback = function()
                    local input = dialog:getInputText()
                    UIManager:close(dialog)
                    callback(input)
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function editConfig(instance, context, key, title, hint)
    local state = instance.book_translator
    showInput(title, hint, state.config[key], function(value)
        state.config[key] = trim(value)
        saveConfig(state.config)
        context.requestRebuild("ui")
    end)
end

local function startTranslation(instance, context)
    local state = instance.book_translator
    local path = currentBookPath(context)
    if not path then
        UIManager:show(InfoMessage:new{ text = _("Open a supported book in KOReader before starting BookTranslator.") })
        return
    end
    local extension = fileExtension(path)
    if not SUPPORTED[extension] then
        UIManager:show(InfoMessage:new{ text = _("BookTranslator currently supports TXT, HTML, XHTML and FB2. EPUB, PDF and MOBI are left unchanged to protect their containers and layout.") })
        return
    end
    if trim(state.config.target) == "" then
        UIManager:show(InfoMessage:new{ text = _("Set a target language code before translating, for example de, en, es or fr.") })
        return
    end
    local confirm = ConfirmBox:new{
        text = _("Translate this book with your configured LibreTranslate service?\n\n")
            .. path .. "\n\n"
            .. _("Target: ") .. state.config.target .. "\n"
            .. _("Endpoint: ") .. state.config.endpoint .. "\n\n"
            .. _("The selected book text will be sent to that service. The original file is never changed."),
        ok_text = _("Translate"),
        ok_callback = function()
            UIManager:nextTick(function()
                local destination, err = translateBook(path, state.config)
                if destination then
                    state.status = _("Saved translated copy: ") .. destination
                else
                    state.status = _("Translation stopped: ") .. tostring(err)
                end
                context.requestRebuild("ui")
            end)
        end,
    }
    UIManager:show(confirm)
end

return {
    id = "book_translator",
    title = "BookTranslator",
    subtitle = "Translate supported books with LibreTranslate",
    symbol = "T",
    logo = "translate",
    buildPane = function(instance, context)
        instance.book_translator = instance.book_translator or { config = loadConfig(), status = nil }
        local state = instance.book_translator
        local width, height = context.dimen.w, context.dimen.h
        local margin, gap = scale(14), scale(8)
        local card_h = math.max(scale(38), math.min(scale(54), math.floor((height - 2 * margin - scale(48) - 5 * gap) / 6)))
        local book = currentBookPath(context)
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        local content = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = require("ffi/blitbuffer").COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = _("BookTranslator"), face = Font:getFace("cfont", scale(20)), bold = true, overlap_offset = { margin, scale(12) } },
            TextWidget:new{ text = _("TXT · HTML/XHTML · FB2 · original file stays unchanged"), face = Font:getFace("smallinfofont", scale(10)), max_width = width - 2 * margin, overlap_offset = { margin, scale(40) } },
        }
        local cards = {
            { title = _("Current book"), subtitle = book or _("No reader document open"), callback = function() end },
            { title = _("Target language"), subtitle = state.config.target, callback = function() editConfig(instance, context, "target", _("Target language"), _("Language code, e.g. de")) end },
            { title = _("Source language"), subtitle = state.config.source, callback = function() editConfig(instance, context, "source", _("Source language"), _("Language code or auto")) end },
            { title = _("LibreTranslate endpoint"), subtitle = state.config.endpoint, callback = function() editConfig(instance, context, "endpoint", _("LibreTranslate endpoint"), _("https://example.org/translate")) end },
            { title = _("API key"), subtitle = trim(state.config.api_key) == "" and _("Not set") or _("Stored locally"), callback = function() editConfig(instance, context, "api_key", _("LibreTranslate API key"), _("Optional for self-hosted services")) end },
            { title = _("Translate current book"), subtitle = _("Confirm before text leaves this device"), callback = function() startTranslation(instance, context) end },
        }
        local first_y = scale(60)
        for index, card in ipairs(cards) do
            if first_y + (index - 1) * (card_h + gap) + card_h > height - margin then break end
            content[#content + 1] = ActionCard:new{
                title = card.title, subtitle = card.subtitle,
                callback = card.callback,
                width = width - 2 * margin, height = card_h,
                overlap_offset = { margin, first_y + (index - 1) * (card_h + gap) },
            }
        end
        if state.status then
            content[#content + 1] = TextWidget:new{ text = state.status, face = Font:getFace("smallinfofont", scale(10)), max_width = width - 2 * margin, overlap_offset = { margin, height - scale(24) } }
        end
        pane[1] = content
        return pane
    end,
    test = {
        supported = SUPPORTED,
        outputPath = outputPath,
        splitText = splitText,
    },
}
