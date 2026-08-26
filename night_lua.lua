--[[--
NightLua for AppDock.

A small Lua editor for files handed over by AppDock's own Files DApp. It uses
KOReader's native fullscreen InputDialog for editing, saves atomically, and
keeps a separate highlighted read-only preview inside its DApp pane.
--]]--

local CenterContainer = require("ui/widget/container/centercontainer")
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
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")

local MAX_FILE_BYTES = 512 * 1024
local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true,
    ["then"] = true, ["until"] = true, ["while"] = true,
}
local LITERALS = { ["true"] = true, ["false"] = true, ["nil"] = true }
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

local function escapeHTML(text)
    return (text or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;")
end

local function isLuaFile(path)
    return type(path) == "string" and path:lower():match("%.lua$") ~= nil
end

local function readLuaFile(path)
    if not isLuaFile(path) then return nil, _("NightLua only opens .lua files.") end
    local file, err = io.open(path, "rb")
    if not file then return nil, err or _("The Lua file cannot be read.") end
    local content = file:read("*a")
    file:close()
    if not content then return nil, _("The Lua file cannot be read.") end
    if #content > MAX_FILE_BYTES then return nil, _("This Lua file exceeds NightLua's 512 KiB editing limit.") end
    return content
end

local function atomicWrite(path, content)
    local probe = io.open(path, "r+b")
    if not probe then return nil, _("This Lua file is read-only or cannot be opened for writing.") end
    probe:close()
    local temporary = path .. ".nightlua.tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err or _("The temporary file cannot be created.") end
    local ok, write_err = file:write(content)
    file:close()
    if not ok then os.remove(temporary); return nil, write_err or _("The file could not be written.") end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then os.remove(temporary); return nil, rename_err or _("The edited file could not replace the original.") end
    return true
end

local function takeQuoted(line, start)
    local quote, position = line:sub(start, start), start + 1
    while position <= #line do
        local char = line:sub(position, position)
        if char == "\\" then position = position + 2
        elseif char == quote then return line:sub(start, position), position + 1
        else position = position + 1 end
    end
    return line:sub(start), #line + 1
end

local function highlightLine(line)
    local output, position = {}, 1
    while position <= #line do
        if line:sub(position, position + 1) == "--" then
            output[#output + 1] = '<span class="comment">' .. escapeHTML(line:sub(position)) .. "</span>"
            break
        end
        local char = line:sub(position, position)
        if char == "\"" or char == "'" then
            local quoted, next_position = takeQuoted(line, position)
            output[#output + 1] = '<span class="string">' .. escapeHTML(quoted) .. "</span>"
            position = next_position
        elseif char:match("[%a_]") then
            local word = line:match("^[%a_][%w_]*", position)
            if KEYWORDS[word] then
                output[#output + 1] = '<span class="keyword">' .. word .. "</span>"
            elseif LITERALS[word] then
                output[#output + 1] = '<span class="literal">' .. word .. "</span>"
            else
                output[#output + 1] = escapeHTML(word)
            end
            position = position + #word
        elseif char:match("%d") then
            local number = line:match("^%d+%.?%d*[eE]?[%+%-]?%d*", position) or char
            output[#output + 1] = '<span class="number">' .. escapeHTML(number) .. "</span>"
            position = position + #number
        else
            output[#output + 1] = escapeHTML(char)
            position = position + 1
        end
    end
    return table.concat(output)
end

local function highlightLua(source)
    local lines = {}
    source = source or ""
    for line in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = highlightLine(line) end
    if #lines == 0 then lines[1] = "" end
    return table.concat(lines, "\n")
end

local function syntaxStatus(content)
    local err = util.checkLuaSyntax(content or "")
    return not err, err
end

local function basename(path)
    return (path or ""):match("([^/]+)$") or path or _("No Lua file")
end

local function ensureState(instance)
    instance.night_lua = instance.night_lua or { path = nil, content = "", status = _("Open a Lua file from Files."), syntax_ok = nil }
    return instance.night_lua
end

local function setFile(instance, path)
    local state = ensureState(instance)
    local content, err = readLuaFile(path)
    if not content then
        state.status = _("Open failed: ") .. tostring(err)
        return false, err
    end
    state.path = path
    state.content = content
    state.syntax_ok = nil
    state.status = _("Loaded: ") .. path
    return true
end

local EditorButton = InputContainer:extend{
    title = nil,
    callback = nil,
    width = nil,
    height = nil,
    dimen = nil,
    px = nil,
}

function EditorButton:init()
    local px = self.px or scale
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = 0,
        radius = math.floor(self.height * 0.34),
        background = require("ffi/blitbuffer").COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = self.dimen,
            TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", px(11)), bold = true, max_width = self.width - px(8) },
        },
    }
    self.ges_events = { TapNightLuaButton = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function EditorButton:paintTo(bb, x, y)
    local range = self.ges_events.TapNightLuaButton[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end

function EditorButton:onTapNightLuaButton()
    if self.callback then self.callback() end
    return true
end

local function openEditor(instance, context)
    local state = ensureState(instance)
    if not state.path then
        UIManager:show(InfoMessage:new{ text = _("Select a .lua file in AppDock Files first.") })
        return
    end
    local original = state.content
    local dialog
    dialog = InputDialog:new{
        title = basename(state.path),
        input = original,
        input_face = Font:getFace("infont", scale(16)),
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        cursor_at_end = false,
        add_nav_bar = true,
        scroll_by_pan = true,
        buttons = {
            {
                {
                    text = _("Lua check"),
                    callback = function()
                        local valid, err = syntaxStatus(dialog:getInputText())
                        UIManager:show(InfoMessage:new{ text = valid and _("Lua syntax OK.") or (_("Lua syntax error:\n") .. tostring(err)) })
                    end,
                },
            },
        },
        reset_callback = function()
            local refreshed, err = readLuaFile(state.path)
            if not refreshed then return nil, tostring(err) end
            original = refreshed
            return refreshed, _("Text reset to last saved content")
        end,
        save_callback = function(content)
            local valid, syntax_err = syntaxStatus(content)
            if not valid then return false, _("Lua syntax error:\n") .. tostring(syntax_err) end
            local ok, write_err = atomicWrite(state.path, content)
            if not ok then return false, tostring(write_err) end
            original = content
            state.content = content
            state.syntax_ok = true
            state.status = _("Saved safely: ") .. state.path
            context.requestRebuild("ui")
            return true, _("Lua file saved")
        end,
        close_callback = function()
            context.requestRebuild("ui")
        end,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function reloadFile(instance, context)
    local state = ensureState(instance)
    if not state.path then return end
    setFile(instance, state.path)
    context.requestRebuild("ui")
end

return {
    id = "night_lua",
    version = "1.0.1",
    title = "NightLua",
    subtitle = "Lua editor with E-Ink syntax preview",
    symbol = "L",
    logo = "code",
    openFile = function(instance, path)
        return setFile(instance, path)
    end,
    buildPane = function(instance, context)
        local state = ensureState(instance)
        local width, height = context.dimen.w, context.dimen.h
        local px = context.px or scale
        local margin, gap, action_height = px(14), px(8), px(38)
        local action_y = px(58)
        local button_width = math.max(px(44), math.floor((width - 2 * margin - 2 * gap) / 3))
        local preview_y = action_y + action_height + px(10)
        local preview_height = math.max(px(56), height - preview_y - margin)
        local html = '<pre>' .. highlightLua(state.content) .. '</pre>'
        local css = [[
            body { background: #ffffff; color: #171717; font-family: monospace; font-size: 0.88em; line-height: 1.22; }
            pre { white-space: pre-wrap; margin: 0; }
            .keyword { color: #202020; font-weight: bold; background: #e2e2e2; }
            .literal { color: #383838; font-weight: bold; }
            .number { color: #545454; }
            .string { color: #303030; background: #eeeeee; }
            .comment { color: #6a6a6a; font-style: italic; }
        ]]
        local preview = ScrollHtmlWidget:new{
            html_body = html, css = css,
            width = width - 2 * margin, height = preview_height,
            default_font_size = px(13), dialog = context.host,
        }
        preview.overlap_offset = { margin, preview_y }
        local valid, syntax_err = syntaxStatus(state.content)
        if state.path then
            state.syntax_ok = valid
            if not valid and not state.status:match("Open failed") then state.status = _("Syntax warning: ") .. tostring(syntax_err) end
        end
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = require("ffi/blitbuffer").COLOR_WHITE, emptySizedWidget(width, height) },
            TextWidget:new{ text = _("NightLua"), face = Font:getFace("cfont", px(20)), bold = true, overlap_offset = { margin, px(10) } },
            TextWidget:new{ text = state.path or _("Open .lua from Files"), face = Font:getFace("smallinfofont", px(10)), max_width = width - 2 * margin, overlap_offset = { margin, px(38) } },
            EditorButton:new{ title = _("Edit"), width = button_width, height = action_height, px = px, callback = function() openEditor(instance, context) end, overlap_offset = { margin, action_y } },
            EditorButton:new{ title = _("Check"), width = button_width, height = action_height, px = px, callback = function()
                local ok, err = syntaxStatus(state.content)
                state.syntax_ok = ok
                state.status = ok and _("Lua syntax OK.") or (_("Lua syntax error: ") .. tostring(err))
                context.requestRebuild("ui")
            end, overlap_offset = { margin + button_width + gap, action_y } },
            EditorButton:new{ title = _("Reload"), width = button_width, height = action_height, px = px, callback = function() reloadFile(instance, context) end, overlap_offset = { margin + (button_width + gap) * 2, action_y } },
            preview,
            TextWidget:new{ text = state.status or "", face = Font:getFace("smallinfofont", px(10)), max_width = width - 2 * margin, overlap_offset = { margin, height - px(18) } },
        }
        return pane
    end,
    test = {
        highlightLua = highlightLua,
        isLuaFile = isLuaFile,
        syntaxStatus = syntaxStatus,
        readLuaFile = readLuaFile,
    },
}
