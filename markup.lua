--[[--
MarkUP for AppDock.

A local Markdown editor with its own AppDock touch keyboard. Markdown files
are opened through AppDock Files and written atomically on the local device.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local MAX_FILE_BYTES = 512 * 1024
local MAX_RENDER_BYTES = 256 * 1024
local Screen = Device.screen

local function scale(value)
    return Screen:scaleBySize(value)
end

local function color(r, g, b, grayscale)
    if Screen:isColorEnabled() then return Blitbuffer.ColorRGB32(r, g, b, 0xFF) end
    return grayscale
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function escapeHtml(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;")
end

local function isMarkdownFile(path)
    if type(path) ~= "string" then return false end
    local extension = path:lower():match("%.([%a%d]+)$")
    return extension == "md" or extension == "markdown" or extension == "mdown" or extension == "mkdn"
end

local function validSavePath(path)
    path = trim(path)
    if path == "" then return nil, _("Enter a file path.") end
    if not path:match("^/") then return nil, _("Use an absolute path, for example /mnt/onboard/notes.md.") end
    if path:find("/../", 1, true) or path:sub(-3) == "/.." then return nil, _("Parent-directory paths are not allowed.") end
    if path:find("[%z\r\n]") then return nil, _("The file path contains unsupported characters.") end
    if not isMarkdownFile(path) then return nil, _("MarkUP saves .md, .markdown, .mdown or .mkdn files only.") end
    return path
end

local function readMarkdownFile(path)
    if not isMarkdownFile(path) then return nil, _("MarkUP only opens Markdown files.") end
    local file, err = io.open(path, "rb")
    if not file then return nil, err or _("The Markdown file cannot be read.") end
    local content = file:read("*a")
    file:close()
    if not content then return nil, _("The Markdown file cannot be read.") end
    if #content > MAX_FILE_BYTES then return nil, _("This file exceeds MarkUP's 512 KiB editing limit.") end
    return content
end

local function atomicWrite(path, content)
    local checked_path, path_err = validSavePath(path)
    if not checked_path then return nil, path_err end
    content = tostring(content or "")
    if #content > MAX_FILE_BYTES then return nil, _("This document exceeds MarkUP's 512 KiB editing limit.") end
    local temporary = checked_path .. ".markup.tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err or _("The temporary file cannot be created.") end
    local ok, write_err = file:write(content)
    file:close()
    if not ok then
        os.remove(temporary)
        return nil, write_err or _("The document could not be written.")
    end
    local renamed, rename_err = os.rename(temporary, checked_path)
    if not renamed then
        os.remove(temporary)
        return nil, rename_err or _("The temporary document could not replace the target.")
    end
    return true
end

local function basename(path)
    return (path or ""):match("([^/]+)$") or path or _("Untitled.md")
end

local function insertAt(state, text)
    text = tostring(text or "")
    local cursor = math.max(0, math.min(#state.content, state.cursor or #state.content))
    state.content = state.content:sub(1, cursor) .. text .. state.content:sub(cursor + 1)
    state.cursor = cursor + #text
    state.dirty = true
end

local function backspace(state)
    local cursor = math.max(0, math.min(#state.content, state.cursor or #state.content))
    if cursor <= 0 then return end
    state.content = state.content:sub(1, cursor - 1) .. state.content:sub(cursor + 1)
    state.cursor = cursor - 1
    state.dirty = true
end

local function lineStart(source, cursor)
    local before = source:sub(1, cursor)
    local last = before:match(".*()\n")
    return last and last or 0
end

local function lineEnd(source, cursor)
    local next_newline = source:find("\n", cursor + 1, true)
    return next_newline and next_newline - 1 or #source
end

local function moveCursor(state, delta)
    state.cursor = math.max(0, math.min(#state.content, (state.cursor or #state.content) + delta))
end

local function moveLine(state, direction)
    local cursor = state.cursor or #state.content
    local start = lineStart(state.content, cursor)
    local column = cursor - start
    if direction < 0 then
        if start == 0 then return end
        local previous_end = start - 1
        local previous_start = lineStart(state.content, previous_end)
        state.cursor = math.min(previous_start + column, previous_end)
    else
        local ending = lineEnd(state.content, cursor)
        if ending >= #state.content then return end
        local next_start = ending + 1
        local next_end = lineEnd(state.content, next_start)
        state.cursor = math.min(next_start + column, next_end)
    end
end

local function cursorFromTap(state, gesture, origin_x, origin_y, line_height, character_width)
    if not gesture or not gesture.pos then return end
    local buffer = state.target == "path" and "save_path" or "content"
    local source = state[buffer] or ""
    local wanted_line = math.max(1, math.floor((gesture.pos.y - origin_y) / line_height) + 1)
    local wanted_column = math.max(0, math.floor((gesture.pos.x - origin_x) / character_width))
    local start, current_line = 0, 1
    while current_line < wanted_line do
        local newline = source:find("\n", start + 1, true)
        if not newline then break end
        start, current_line = newline, current_line + 1
    end
    local ending = lineEnd(source, start)
    state.cursor = math.max(start, math.min(start + wanted_column, ending))
end

local function escapeInline(value)
    local output = escapeHtml(value)
    output = output:gsub("!%[([^%]]*)%]%(([^%)]+)%)", function(alt)
        return "<em>[" .. escapeHtml(_("Image")) .. ": " .. alt .. "]</em>"
    end)
    output = output:gsub("%[([^%]]+)%]%((https?://[^%s%)]+)%)", function(label, url)
        return "<a href=\"" .. url .. "\">" .. label .. "</a>"
    end)
    output = output:gsub("`([^`]+)`", "<code>%1</code>")
    output = output:gsub("%*%*([^*]+)%*%*", "<strong>%1</strong>")
    output = output:gsub("__([^_]+)__", "<strong>%1</strong>")
    output = output:gsub("~~([^~]+)~~", "<del>%1</del>")
    output = output:gsub("%*([^*]+)%*", "<em>%1</em>")
    output = output:gsub("_([^_]+)_", "<em>%1</em>")
    return output
end

local function splitLines(source)
    local lines = {}
    source = tostring(source or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    return lines
end

local function tableCells(line)
    line = trim(line):gsub("^|", ""):gsub("|$", "")
    local cells = {}
    for cell in (line .. "|"):gmatch("(.-)|") do cells[#cells + 1] = trim(cell) end
    return cells
end

local function isTableDivider(line)
    local cells = tableCells(line)
    if #cells == 0 then return false end
    for index, cell in ipairs(cells) do
        if not cell:match("^:?-+:?$") then return false end
    end
    return true
end

local function renderTable(header, rows)
    local output = { "<table><thead><tr>" }
    for index, cell in ipairs(header) do output[#output + 1] = "<th>" .. escapeInline(cell) .. "</th>" end
    output[#output + 1] = "</tr></thead><tbody>"
    for row_index, row in ipairs(rows) do
        output[#output + 1] = "<tr>"
        for cell_index, cell in ipairs(row) do output[#output + 1] = "<td>" .. escapeInline(cell) .. "</td>" end
        output[#output + 1] = "</tr>"
    end
    output[#output + 1] = "</tbody></table>"
    return table.concat(output)
end

local function markdownToHtml(source)
    source = tostring(source or "")
    if #source > MAX_RENDER_BYTES then source = source:sub(1, MAX_RENDER_BYTES) .. "\n\n[Preview truncated]" end
    local lines, output = splitLines(source), {}
    local in_code, list_kind, paragraph = false, nil, {}
    local function closeParagraph()
        if #paragraph > 0 then
            output[#output + 1] = "<p>" .. escapeInline(table.concat(paragraph, " ")) .. "</p>"
            paragraph = {}
        end
    end
    local function closeList()
        if list_kind then output[#output + 1] = "</" .. list_kind .. ">"; list_kind = nil end
    end
    local index = 1
    while index <= #lines do
        local line = lines[index]
        if line:match("^%s*```") then
            closeParagraph(); closeList()
            if in_code then output[#output + 1] = "</code></pre>" else output[#output + 1] = "<pre><code>" end
            in_code = not in_code
        elseif in_code then
            output[#output + 1] = escapeHtml(line) .. "\n"
        elseif line:match("^%s*$") then
            closeParagraph(); closeList()
        else
            local heading_marks, heading = line:match("^%s*(#+)%s+(.+)%s*$")
            local unordered = line:match("^%s*[%-%*%+]%s+(.+)%s*$")
            local ordered = line:match("^%s*%d+[%.%)]%s+(.+)%s*$")
            local quote = line:match("^%s*>%s?(.*)$")
            if line:match("^%s*[-*_][-%s*_][-%s*_]+%s*$") then
                closeParagraph(); closeList(); output[#output + 1] = "<hr/>"
            elseif heading_marks then
                closeParagraph(); closeList()
                local level = math.min(6, #heading_marks)
                output[#output + 1] = "<h" .. level .. ">" .. escapeInline(heading) .. "</h" .. level .. ">"
            elseif line:find("|", 1, true) and lines[index + 1] and isTableDivider(lines[index + 1]) then
                closeParagraph(); closeList()
                local header, rows = tableCells(line), {}
                index = index + 2
                while index <= #lines and lines[index]:find("|", 1, true) and not lines[index]:match("^%s*$") do
                    rows[#rows + 1] = tableCells(lines[index])
                    index = index + 1
                end
                output[#output + 1] = renderTable(header, rows)
                index = index - 1
            elseif quote ~= nil then
                closeParagraph(); closeList(); output[#output + 1] = "<blockquote><p>" .. escapeInline(quote) .. "</p></blockquote>"
            elseif unordered then
                closeParagraph()
                if list_kind ~= "ul" then closeList(); output[#output + 1] = "<ul>"; list_kind = "ul" end
                output[#output + 1] = "<li>" .. escapeInline(unordered) .. "</li>"
            elseif ordered then
                closeParagraph()
                if list_kind ~= "ol" then closeList(); output[#output + 1] = "<ol>"; list_kind = "ol" end
                output[#output + 1] = "<li>" .. escapeInline(ordered) .. "</li>"
            else
                closeList(); paragraph[#paragraph + 1] = trim(line)
            end
        end
        index = index + 1
    end
    closeParagraph(); closeList()
    if in_code then output[#output + 1] = "</code></pre>" end
    return "<article class=\"markup-preview\">" .. table.concat(output, "\n") .. "</article>"
end

local function editorHtml(state)
    local cursor = math.max(0, math.min(#state.content, state.cursor or #state.content))
    local before = escapeHtml(state.content:sub(1, cursor))
    local after = escapeHtml(state.content:sub(cursor + 1))
    return "<pre class=\"markup-editor\">" .. before .. "<span class=\"markup-cursor\">|</span>" .. after .. "</pre>"
end

local EditorButton = InputContainer:extend{ title = nil, callback = nil, width = nil, height = nil, background = nil, foreground = nil, dimen = nil, px = nil }

function EditorButton:init()
    local px = self.px or scale
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = 0,
        radius = math.floor(self.height * 0.30), background = self.background or Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", px(10)), fgcolor = self.foreground or Blitbuffer.COLOR_BLACK, bold = true, max_width = self.width - px(6) } },
    }
    self.ges_events = { TapMarkUPButton = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function EditorButton:paintTo(bb, x, y)
    local range = self.ges_events.TapMarkUPButton[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function EditorButton:onTapMarkUPButton()
    if self.callback then self.callback() end
    return true
end

local KeyButton = EditorButton:extend{ key = nil, callback = nil }

function KeyButton:init()
    self.title = self.key
    EditorButton.init(self)
end

local CursorSurface = InputContainer:extend{ width = nil, height = nil, dimen = nil, callback = nil }

function CursorSurface:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = CenterContainer:new{ dimen = self.dimen, HorizontalSpan:new{ width = 0 } }
    self.ges_events = { TapMarkUPCursor = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function CursorSurface:paintTo(bb, x, y)
    local range = self.ges_events.TapMarkUPCursor[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function CursorSurface:onTapMarkUPCursor(arg, gesture)
    if self.callback then self.callback(gesture) end
    return true
end

local function ensureState(instance)
    instance.markup = instance.markup or {
        path = nil,
        content = "# MarkUP\n\nWrite Markdown with the AppDock keyboard.\n",
        cursor = 0,
        dirty = false,
        mode = "edit",
        target = "content",
        save_path = "/mnt/onboard/markup.md",
        uppercase = false,
        status = _("New document · choose Save as to select a path."),
    }
    local state = instance.markup
    if not state.cursor then state.cursor = #state.content end
    return state
end

local function rebuild(context)
    context.requestRebuild("ui")
end

local function setFile(instance, path)
    local state = ensureState(instance)
    if state.dirty then return false, _("Save or discard the current changes before opening another file.") end
    local content, err = readMarkdownFile(path)
    if not content then return false, err end
    state.path, state.content, state.cursor = path, content, #content
    state.dirty, state.mode, state.target = false, "edit", "content"
    state.status = _("Loaded: ") .. path
    return true
end

local function saveDocument(instance, context, save_as)
    local state = ensureState(instance)
    if save_as or not state.path then
        state.mode, state.target = "path", "path"
        state.save_path = state.path or state.save_path or "/mnt/onboard/markup.md"
        state.cursor = #state.save_path
        state.status = _("Enter an absolute Markdown path, then tap Save.")
        rebuild(context)
        return
    end
    local ok, err = atomicWrite(state.path, state.content)
    if ok then
        state.dirty, state.status = false, _("Saved: ") .. state.path
    else
        state.status = _("Save failed: ") .. tostring(err)
    end
    rebuild(context)
end

local function commitSaveAs(instance, context)
    local state = ensureState(instance)
    local path, path_err = validSavePath(state.save_path)
    if not path then state.status = path_err; rebuild(context); return end
    local ok, err = atomicWrite(path, state.content)
    if not ok then state.status = _("Save failed: ") .. tostring(err); rebuild(context); return end
    state.path, state.dirty, state.mode, state.target = path, false, "edit", "content"
    state.cursor = #state.content
    state.status = _("Saved: ") .. path
    rebuild(context)
end

local function discardDocument(instance, context)
    local state = ensureState(instance)
    if state.path then
        local content, err = readMarkdownFile(state.path)
        if content then state.content, state.cursor, state.dirty = content, #content, false; state.status = _("Changes discarded.") else state.status = tostring(err) end
    else
        state.content, state.cursor, state.dirty = "# MarkUP\n\n", 10, false
        state.status = _("New document cleared.")
    end
    state.mode, state.target = "edit", "content"
    rebuild(context)
end

local function newDocument(instance, context)
    local state = ensureState(instance)
    if state.dirty then state.status = _("Save or discard changes before creating a new document."); rebuild(context); return end
    state.path, state.content, state.cursor = nil, "# Untitled\n\n", 12
    state.dirty, state.mode, state.target = false, "edit", "content"
    state.status = _("New Markdown document.")
    rebuild(context)
end

local function insertFormatting(instance, context, kind)
    local state = ensureState(instance)
    if state.mode ~= "edit" then return end
    if kind == "heading" then
        local start = lineStart(state.content, state.cursor)
        state.content = state.content:sub(1, start) .. "# " .. state.content:sub(start + 1)
        state.cursor = state.cursor + 2
        state.dirty = true
    elseif kind == "bold" then insertAt(state, "**bold**"); state.cursor = state.cursor - 6
    elseif kind == "list" then
        local start = lineStart(state.content, state.cursor)
        state.content = state.content:sub(1, start) .. "- " .. state.content:sub(start + 1)
        state.cursor = state.cursor + 2; state.dirty = true
    elseif kind == "quote" then
        local start = lineStart(state.content, state.cursor)
        state.content = state.content:sub(1, start) .. "> " .. state.content:sub(start + 1)
        state.cursor = state.cursor + 2; state.dirty = true
    elseif kind == "code" then insertAt(state, "`code`"); state.cursor = state.cursor - 5
    elseif kind == "link" then insertAt(state, "[link](https://)"); state.cursor = state.cursor - 15 end
    rebuild(context)
end

local function editKey(instance, context, key)
    local state = ensureState(instance)
    local target = state.target or "content"
    local buffer = target == "path" and "save_path" or "content"
    local cursor = math.max(0, math.min(#state[buffer], state.cursor or #state[buffer]))
    local function insert(text)
        state[buffer] = state[buffer]:sub(1, cursor) .. text .. state[buffer]:sub(cursor + 1)
        state.cursor = cursor + #text
        if buffer == "content" then state.dirty = true end
    end
    if key == "⌫" then
        if cursor > 0 then
            state[buffer] = state[buffer]:sub(1, cursor - 1) .. state[buffer]:sub(cursor + 1)
            state.cursor = cursor - 1
            if buffer == "content" then state.dirty = true end
        end
    elseif key == "←" then state.cursor = math.max(0, cursor - 1)
    elseif key == "→" then state.cursor = math.min(#state[buffer], cursor + 1)
    elseif key == "↑" and buffer == "content" then moveLine(state, -1)
    elseif key == "↓" and buffer == "content" then moveLine(state, 1)
    elseif key == "⇧" then state.uppercase = not state.uppercase
    elseif key == "Space" then insert(" ")
    elseif key == "↵" and buffer == "content" then insert("\n")
    elseif #key > 0 then insert(state.uppercase and key:upper() or key) end
    rebuild(context)
end

local function addButton(layer, title, x, y, width, height, px, callback, primary)
    local button = EditorButton:new{ title = title, width = width, height = height, px = px, callback = callback, background = primary and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY, foreground = Blitbuffer.COLOR_BLACK }
    button.overlap_offset = { x, y }
    table.insert(layer, button)
end

local function addKeyboard(layer, instance, context, state, x, y, width, px)
    local rows = {
        { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" },
        { "a", "s", "d", "f", "g", "h", "j", "k", "l" },
        { "⇧", "z", "x", "c", "v", "b", "n", "m", "⌫" },
        { "#", "*", "_", "`", "[", "]", "(", ")", "/", "." },
        { "↑", "←", "Space", "↵", "→", "↓" },
    }
    local key_height, row_gap = px(27), px(3)
    for row_index, keys in ipairs(rows) do
        local count, row_gap_total = #keys, (#keys - 1) * row_gap
        local key_width = math.max(px(22), math.floor((width - row_gap_total) / count))
        local used = key_width * count + row_gap_total
        local row_x = x + math.floor((width - used) / 2)
        for key_index, key in ipairs(keys) do
            local actual_width = key == "Space" and math.max(key_width, px(52)) or key_width
            local offset = 0
            if key == "Space" then offset = math.floor((actual_width - key_width) / 2) end
            local button = KeyButton:new{ key = key, width = actual_width, height = key_height, px = px, callback = function() editKey(instance, context, key) end, background = (key == "⌫" or key == "↵") and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY }
            button.overlap_offset = { row_x - offset, y + (row_index - 1) * (key_height + row_gap) }
            table.insert(layer, button)
            row_x = row_x + key_width + row_gap
        end
    end
end

return {
    id = "markup",
    version = "1.0.0",
    title = "MarkUP",
    subtitle = "Markdown editor with AppDock keyboard",
    symbol = "M",
    logo = "code",
    openFile = function(instance, path)
        return setFile(instance, path)
    end,
    canClose = function(instance)
        local state = ensureState(instance)
        if state.dirty then return false, _("MarkUP has unsaved changes. Save or discard them before closing.") end
        return true
    end,
    buildPane = function(instance, context)
        local state = ensureState(instance)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or scale
        local margin, gap = px(12), px(6)
        local title_y, toolbar_y, format_y = px(9), px(47), px(81)
        local button_height = px(28)
        local keyboard_height = px(5 * 30)
        local keyboard_y = height - margin - keyboard_height
        local content_y = format_y + button_height + px(8)
        local content_height = math.max(px(52), keyboard_y - content_y - px(18))
        local column_width = math.max(px(40), math.floor((width - 2 * margin - 3 * gap) / 4))
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        local layer = OverlapGroup:new{ dimen = pane.dimen, allow_mirroring = false }
        table.insert(layer, FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = color(255, 253, 248, Blitbuffer.COLOR_WHITE), CenterContainer:new{ dimen = pane.dimen, HorizontalSpan:new{ width = 0 } } })
        table.insert(layer, TextWidget:new{ text = state.mode == "preview" and _("MarkUP · Preview") or (state.mode == "path" and _("MarkUP · Save as") or _("MarkUP")), face = Font:getFace("cfont", px(19)), bold = true, overlap_offset = { margin, title_y } })
        table.insert(layer, TextWidget:new{ text = state.mode == "path" and _("Custom path editor") or (state.path and basename(state.path) or _("Untitled Markdown document")), face = Font:getFace("smallinfofont", px(9)), max_width = width - 2 * margin, overlap_offset = { margin, px(31) } })

        if state.mode == "preview" then
            addButton(layer, _("Edit"), margin, toolbar_y, column_width, button_height, px, function() state.mode = "edit"; rebuild(context) end, true)
            addButton(layer, _("Save"), margin + column_width + gap, toolbar_y, column_width, button_height, px, function() saveDocument(instance, context, false) end)
            addButton(layer, _("Save as"), margin + (column_width + gap) * 2, toolbar_y, column_width, button_height, px, function() saveDocument(instance, context, true) end)
            addButton(layer, _("Discard"), margin + (column_width + gap) * 3, toolbar_y, column_width, button_height, px, function() discardDocument(instance, context) end)
            local preview = ScrollHtmlWidget:new{ html_body = markdownToHtml(state.content), css = [[body { background: #fffdf8; color: #1d1b18; font-family: sans-serif; line-height: 1.35; } h1 { border-bottom: 1px solid #777; padding-bottom: .2em; } h2 { margin-top: 1em; } blockquote { border-left: .35em solid #806000; margin-left: 0; padding-left: .7em; color: #514733; } pre { background: #f0ebe0; padding: .5em; white-space: pre-wrap; } code { background: #eee7da; } table { border-collapse: collapse; width: 100%; margin: .6em 0; } th, td { border: 1px solid #777; padding: .28em; vertical-align: top; } th { background: #ebe2d0; } a { color: #243e62; } ]], width = width - 2 * margin, height = height - toolbar_y - button_height - 2 * margin, default_font_size = px(13), dialog = context.host }
            preview.overlap_offset = { margin, toolbar_y + button_height + px(7) }
            table.insert(layer, preview)
        else
            if state.mode == "path" then
                addButton(layer, _("Save"), margin, toolbar_y, column_width, button_height, px, function() commitSaveAs(instance, context) end, true)
                addButton(layer, _("Edit text"), margin + column_width + gap, toolbar_y, column_width, button_height, px, function() state.mode, state.target, state.cursor = "edit", "content", #state.content; rebuild(context) end)
                addButton(layer, _("Clear path"), margin + (column_width + gap) * 2, toolbar_y, column_width, button_height, px, function() state.save_path, state.cursor = "", 0; rebuild(context) end)
                addButton(layer, _("Cancel"), margin + (column_width + gap) * 3, toolbar_y, column_width, button_height, px, function() state.mode, state.target, state.cursor = "edit", "content", #state.content; rebuild(context) end)
            else
                addButton(layer, _("New"), margin, toolbar_y, column_width, button_height, px, function() newDocument(instance, context) end)
                addButton(layer, _("Save"), margin + column_width + gap, toolbar_y, column_width, button_height, px, function() saveDocument(instance, context, false) end, true)
                addButton(layer, _("Save as"), margin + (column_width + gap) * 2, toolbar_y, column_width, button_height, px, function() saveDocument(instance, context, true) end)
                addButton(layer, _("Preview"), margin + (column_width + gap) * 3, toolbar_y, column_width, button_height, px, function() state.mode = "preview"; rebuild(context) end)
            end
            local formats = { { _("H1"), "heading" }, { _("Bold"), "bold" }, { _("List"), "list" }, { _("Quote"), "quote" }, { _("Code"), "code" }, { _("Link"), "link" }, { _("Discard"), "discard" } }
            local format_width = math.max(px(32), math.floor((width - 2 * margin - (#formats - 1) * gap) / #formats))
            for format_index, format in ipairs(formats) do
                addButton(layer, format[1], margin + (format_index - 1) * (format_width + gap), format_y, format_width, button_height, px, function()
                    if format[2] == "discard" then discardDocument(instance, context) else insertFormatting(instance, context, format[2]) end
                end)
            end
            local display = state.mode == "path" and { content = state.save_path, cursor = state.cursor } or state
            local editor = ScrollHtmlWidget:new{ html_body = editorHtml(display), css = [[body { background: #fffdf8; color: #1d1b18; font-family: monospace; } pre.markup-editor { white-space: pre-wrap; margin: 0; line-height: 1.28; } .markup-cursor { background: #443400; color: #fffdf8; font-weight: bold; } ]], width = width - 2 * margin, height = content_height, default_font_size = px(12), dialog = context.host }
            editor.overlap_offset = { margin, content_y }
            table.insert(layer, editor)
            local cursor_surface = CursorSurface:new{ width = width - 2 * margin, height = content_height, callback = function(gesture)
                cursorFromTap(state, gesture, margin, content_y, math.max(px(13), px(12) * 1.28), math.max(px(6), math.floor(px(12) * 0.58)))
                rebuild(context)
            end }
            cursor_surface.overlap_offset = { margin, content_y }
            table.insert(layer, cursor_surface)
            addKeyboard(layer, instance, context, state, margin, keyboard_y, width - 2 * margin, px)
        end
        table.insert(layer, TextWidget:new{ text = (state.dirty and _("● Unsaved · ") or "") .. (state.status or ""), face = Font:getFace("smallinfofont", px(9)), max_width = width - 2 * margin, overlap_offset = { margin, height - px(14) } })
        pane[1] = layer
        return pane
    end,
    test = {
        atomicWrite = atomicWrite,
        isMarkdownFile = isMarkdownFile,
        markdownToHtml = markdownToHtml,
        readMarkdownFile = readMarkdownFile,
        validSavePath = validSavePath,
    },
}
