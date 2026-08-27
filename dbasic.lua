--[[
DBASIC for AppDock.
It is a deliberately small, local BASIC interpreter. Programs are parsed by
this module; user input is never passed to Lua's load/loadfile functions.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Screen = Device.screen
local GRAPH_W, GRAPH_H = 160, 100
local MAX_LINES, MAX_STEPS, MAX_OUTPUT, MAX_VARIABLES = 500, 10000, 1600, 80

local function scale(value) return Screen:scaleBySize(value) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function empty(width, height) return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } } end
local function trim(value) return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function stripComment(line)
    local in_string = false
    for index = 1, #line do
        local char = line:sub(index, index)
        if char == "\"" then in_string = not in_string end
        if char == "'" and not in_string then return line:sub(1, index - 1) end
    end
    return line
end

local function tokenize(source)
    local tokens, position = {}, 1
    source = source or ""
    while position <= #source do
        local rest = source:sub(position)
        local whitespace = rest:match("^%s+")
        if whitespace then
            position = position + #whitespace
        else
            local char = source:sub(position, position)
            if char == "\"" then
                local close = position + 1
                while close <= #source and source:sub(close, close) ~= "\"" do close = close + 1 end
                if close > #source then return nil, _("Unclosed string.") end
                tokens[#tokens + 1] = { kind = "string", value = source:sub(position + 1, close - 1) }
                position = close + 1
            else
                local number = rest:match("^%d+%.?%d*")
                local name = rest:match("^[%a_][%w_]*")
                local pair = rest:sub(1, 2)
                local operator = (pair == "<=" or pair == ">=" or pair == "<>") and pair or rest:match("^[+%-%*/%^=<>(),;]")
                if number then
                    tokens[#tokens + 1] = { kind = "number", value = tonumber(number) }
                    position = position + #number
                elseif name then
                    tokens[#tokens + 1] = { kind = "name", value = name:upper() }
                    position = position + #name
                elseif operator then
                    tokens[#tokens + 1] = { kind = "operator", value = operator }
                    position = position + #operator
                else
                    return nil, _("Unsupported character in expression.")
                end
            end
        end
    end
    return tokens
end

local function parseExpression(source, variables)
    local tokens, token_error = tokenize(source)
    if not tokens then return nil, token_error end
    local index = 1
    local function peek() return tokens[index] end
    local function take(value)
        local token = peek()
        if token and token.value == value then index = index + 1; return true end
        return false
    end
    local parse_compare, parse_sum, parse_term, parse_power, parse_primary
    local function number(value)
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil, _("Invalid number.") end
        return clamp(value, -1000000, 1000000)
    end
    parse_primary = function()
        local token = peek()
        if not token then return nil, _("Expression is incomplete.") end
        if token.kind == "number" or token.kind == "string" then index = index + 1; return token.value end
        if token.kind == "name" then
            index = index + 1
            local name = token.value
            if take("(") then
                local args = {}
                if not take(")") then
                    while true do
                        local value, err = parse_compare()
                        if err then return nil, err end
                        args[#args + 1] = value
                        if take(")") then break end
                        if not take(",") then return nil, _("Expected comma or closing parenthesis.") end
                    end
                end
                local a, b = tonumber(args[1]), tonumber(args[2])
                if name == "RND" then return number(math.random() * (a or 1)) end
                if name == "ABS" and a then return number(math.abs(a)) end
                if name == "INT" and a then return number(math.floor(a)) end
                if name == "MIN" and a and b then return number(math.min(a, b)) end
                if name == "MAX" and a and b then return number(math.max(a, b)) end
                return nil, _("Unknown BASIC function.")
            end
            return variables[name] == nil and 0 or variables[name]
        end
        if take("(") then
            local value, err = parse_compare()
            if err then return nil, err end
            if not take(")") then return nil, _("Expected closing parenthesis.") end
            return value
        end
        return nil, _("Expected a number, string, variable, or parenthesis.")
    end
    parse_power = function()
        local sign = 1
        while true do
            if take("+") then elseif take("-") then sign = -sign else break end
        end
        local value, err = parse_primary()
        if err then return nil, err end
        if type(value) ~= "number" and sign ~= 1 then return nil, _("Unary signs require a number.") end
        value = type(value) == "number" and value * sign or value
        if take("^") then
            local right, right_err = parse_power()
            if right_err or type(value) ~= "number" or type(right) ~= "number" then return nil, right_err or _("Power requires numbers.") end
            return number(value ^ clamp(right, -12, 12))
        end
        return value
    end
    parse_term = function()
        local value, err = parse_power()
        if err then return nil, err end
        while true do
            local operation = peek() and peek().value
            if operation ~= "*" and operation ~= "/" then break end
            index = index + 1
            local right, right_err = parse_power()
            if right_err or type(value) ~= "number" or type(right) ~= "number" then return nil, right_err or _("Arithmetic requires numbers.") end
            if operation == "/" and right == 0 then return nil, _("Division by zero.") end
            value, err = number(operation == "*" and value * right or value / right)
            if err then return nil, err end
        end
        return value
    end
    parse_sum = function()
        local value, err = parse_term()
        if err then return nil, err end
        while true do
            local operation = peek() and peek().value
            if operation ~= "+" and operation ~= "-" then break end
            index = index + 1
            local right, right_err = parse_term()
            if right_err then return nil, right_err end
            if operation == "+" and (type(value) == "string" or type(right) == "string") then
                value = tostring(value) .. tostring(right)
            elseif type(value) == "number" and type(right) == "number" then
                value, err = number(operation == "+" and value + right or value - right)
                if err then return nil, err end
            else
                return nil, _("Arithmetic requires numbers.")
            end
        end
        return value
    end
    parse_compare = function()
        local value, err = parse_sum()
        if err then return nil, err end
        local operation = peek() and peek().value
        if operation == "=" or operation == "<>" or operation == "<" or operation == ">" or operation == "<=" or operation == ">=" then
            index = index + 1
            local right, right_err = parse_sum()
            if right_err then return nil, right_err end
            local result = operation == "=" and value == right or operation == "<>" and value ~= right or operation == "<" and value < right or operation == ">" and value > right or operation == "<=" and value <= right or value >= right
            value = result and 1 or 0
        end
        return value
    end
    local value, err = parse_compare()
    if err then return nil, err end
    if peek() then return nil, _("Unexpected expression content.") end
    return value
end

local function parseProgram(source)
    local lines, by_number = {}, {}
    local count = 0
    source = (source or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for raw in (source .. "\n"):gmatch("(.-)\n") do
        raw = stripComment(raw)
        if trim(raw) ~= "" then
            local number, code = raw:match("^%s*(%d+)%s*(.-)%s*$")
            number = tonumber(number)
            if not number or number < 1 or number > 99999 or trim(code) == "" then return nil, _("Each BASIC line needs a number and command.") end
            if by_number[number] then return nil, _("BASIC line numbers must be unique.") end
            count = count + 1
            if count > MAX_LINES then return nil, _("Program has too many lines.") end
            local line = { number = number, code = trim(code) }
            lines[#lines + 1], by_number[number] = line, line
        end
    end
    if #lines == 0 then return nil, _("Program is empty.") end
    table.sort(lines, function(left, right) return left.number < right.number end)
    for index, line in ipairs(lines) do by_number[line.number] = index end
    return lines, by_number
end

local function formatValue(value)
    if type(value) == "number" and math.floor(value) == value then return tostring(math.floor(value)) end
    return tostring(value)
end

local function splitPrint(source, variables)
    local tokens, err = tokenize(source)
    if not tokens then return nil, err end
    local values, start, depth = {}, 1, 0
    for index, token in ipairs(tokens) do
        if token.value == "(" then depth = depth + 1 elseif token.value == ")" then depth = depth - 1 end
        if token.value == ";" and depth == 0 then
            local parts = {}
            for item = start, index - 1 do parts[#parts + 1] = tokens[item].kind == "string" and "\"" .. tokens[item].value .. "\"" or tostring(tokens[item].value) end
            local value, value_err = parseExpression(table.concat(parts, " "), variables)
            if value_err then return nil, value_err end
            values[#values + 1], start = formatValue(value), index + 1
        end
    end
    local parts = {}
    for item = start, #tokens do parts[#parts + 1] = tokens[item].kind == "string" and "\"" .. tokens[item].value .. "\"" or tostring(tokens[item].value) end
    local value, value_err = parseExpression(table.concat(parts, " "), variables)
    if value_err then return nil, value_err end
    values[#values + 1] = formatValue(value)
    return table.concat(values, " ")
end

local function splitArgs(source, variables)
    local tokens, err = tokenize(source)
    if not tokens then return nil, err end
    local values, start, depth = {}, 1, 0
    for index, token in ipairs(tokens) do
        if token.value == "(" then depth = depth + 1 elseif token.value == ")" then depth = depth - 1 end
        if token.value == "," and depth == 0 then
            local parts = {}; for item = start, index - 1 do parts[#parts + 1] = tokens[item].kind == "string" and "\"" .. tokens[item].value .. "\"" or tostring(tokens[item].value) end
            local value, value_err = parseExpression(table.concat(parts, " "), variables)
            if value_err then return nil, value_err end
            values[#values + 1], start = value, index + 1
        end
    end
    local parts = {}; for item = start, #tokens do parts[#parts + 1] = tokens[item].kind == "string" and "\"" .. tokens[item].value .. "\"" or tostring(tokens[item].value) end
    local value, value_err = parseExpression(table.concat(parts, " "), variables)
    if value_err then return nil, value_err end
    values[#values + 1] = value
    return values
end

local function runProgram(source, state, touch, start_line)
    local lines, targets = parseProgram(source)
    if not lines then return false, targets end
    local variables = { TOUCHX = touch and touch.x or 0, TOUCHY = touch and touch.y or 0, TOUCH = touch and 1 or 0 }
    local output, graphics, loops, touch_target = {}, {}, {}, nil
    local ip = start_line and targets[start_line] or 1
    if not ip then return false, _("Touch target line does not exist.") end
    local function report(message)
        output[#output + 1] = message
        while #table.concat(output, "\n") > MAX_OUTPUT do table.remove(output, 1) end
    end
    local function jump(value)
        value = math.floor(tonumber(value) or 0)
        return targets[value] or nil
    end
    for steps = 1, MAX_STEPS do
        local line = lines[ip]
        if not line then
            state.output, state.graphics, state.variables, state.touch_target = table.concat(output, "\n"), graphics, variables, touch_target
            return true
        end
        local command, rest = line.code:match("^([%a_][%w_]*)%s*(.*)$")
        command, rest = command and command:upper() or "", rest or ""
        local next_ip = ip + 1
        if command == "REM" then
        elseif command == "END" or command == "STOP" then break
        elseif command == "PRINT" then
            local value, err = splitPrint(rest, variables)
            if err then return false, _("Line ") .. line.number .. ": " .. err end
            report(value)
        elseif command == "LET" or command:match("^[%a_][%w_]*$") and rest:match("^%s*=") then
            local assignment = command == "LET" and rest or line.code
            local name, expression = assignment:match("^%s*([%a_][%w_]*)%s*=%s*(.+)$")
            if not name then return false, _("Line ") .. line.number .. ": " .. _("Expected variable assignment.") end
            name = name:upper()
            if variables[name] == nil then
                local count = 0; for key in pairs(variables) do if key ~= "TOUCHX" and key ~= "TOUCHY" and key ~= "TOUCH" then count = count + 1 end end
                if count >= MAX_VARIABLES then return false, _("Too many variables.") end
            end
            local value, err = parseExpression(expression, variables)
            if err then return false, _("Line ") .. line.number .. ": " .. err end
            variables[name] = value
        elseif command == "GOTO" then
            local target, err = parseExpression(rest, variables)
            next_ip = target and jump(target) or nil
            if err or not next_ip then return false, _("Line ") .. line.number .. ": " .. (err or _("Unknown line number.")) end
        elseif command == "IF" then
            local expression, destination = rest:match("^(.-)%s+[Tt][Hh][Ee][Nn]%s+(%d+)%s*$")
            if not expression then return false, _("Line ") .. line.number .. ": " .. _("Use IF expression THEN line.") end
            local result, err = parseExpression(expression, variables)
            if err then return false, _("Line ") .. line.number .. ": " .. err end
            if tonumber(result) and tonumber(result) ~= 0 then
                next_ip = jump(destination)
                if not next_ip then return false, _("Line ") .. line.number .. ": " .. _("Unknown line number.") end
            end
        elseif command == "FOR" then
            local name, first, last, step = rest:match("^%s*([%a_][%w_]*)%s*=%s*(.-)%s+[Tt][Oo]%s+(.-)%s+[Ss][Tt][Ee][Pp]%s+(.+)%s*$")
            if not name then name, first, last = rest:match("^%s*([%a_][%w_]*)%s*=%s*(.-)%s+[Tt][Oo]%s+(.+)%s*$") end
            if not name then return false, _("Line ") .. line.number .. ": " .. _("Use FOR variable = first TO last [STEP value].") end
            local from, from_err = parseExpression(first, variables); local to, to_err = parseExpression(last, variables); local delta, delta_err = parseExpression(step or "1", variables)
            if from_err or to_err or delta_err or type(from) ~= "number" or type(to) ~= "number" or type(delta) ~= "number" or delta == 0 then return false, _("Line ") .. line.number .. ": " .. _("FOR needs numeric bounds and a nonzero step.") end
            if #loops >= 24 then return false, _("Too many nested loops.") end
            name = name:upper(); variables[name] = from; loops[#loops + 1] = { name = name, last = to, step = delta, line = ip + 1 }
        elseif command == "NEXT" then
            local loop = loops[#loops]
            local requested = trim(rest):upper()
            if not loop or (requested ~= "" and requested ~= loop.name) then return false, _("Line ") .. line.number .. ": " .. _("NEXT has no matching FOR.") end
            variables[loop.name] = (tonumber(variables[loop.name]) or 0) + loop.step
            if loop.step > 0 and variables[loop.name] <= loop.last or loop.step < 0 and variables[loop.name] >= loop.last then next_ip = loop.line else table.remove(loops) end
        elseif command == "CLS" then
            graphics = {}
        elseif command == "COLOR" then
            local value, err = parseExpression(rest, variables)
            if err or type(value) ~= "number" then return false, _("Line ") .. line.number .. ": " .. (err or _("COLOR needs a number.")) end
            variables.COLOR = clamp(math.floor(value), 0, 2)
        elseif command == "PSET" or command == "LINE" or command == "RECT" then
            local values, err = splitArgs(rest, variables)
            local need = command == "PSET" and 2 or 4
            if err or #values < need then return false, _("Line ") .. line.number .. ": " .. (err or _("Not enough graphic coordinates.")) end
            local drawing = { kind = command:lower(), color = clamp(math.floor(tonumber(values[need + 1]) or variables.COLOR or 0), 0, 2) }
            if command == "PSET" then drawing.x, drawing.y = values[1], values[2] else drawing.x, drawing.y, drawing.x2, drawing.y2 = values[1], values[2], values[3], values[4] end
            for key, value in pairs(drawing) do if key ~= "kind" and key ~= "color" and type(value) == "number" then drawing[key] = clamp(math.floor(value + .5), -GRAPH_W, GRAPH_W * 2) end end
            graphics[#graphics + 1] = drawing
            if #graphics > 600 then return false, _("Too many graphic operations.") end
        elseif command == "ON" then
            local target = rest:match("^[Tt][Oo][Uu][Cc][Hh]%s+[Gg][Oo][Tt][Oo]%s+(%d+)%s*$")
            if not target or not jump(target) then return false, _("Line ") .. line.number .. ": " .. _("Use ON TOUCH GOTO line.") end
            touch_target = tonumber(target)
        else
            return false, _("Line ") .. line.number .. ": " .. _("Unknown BASIC command.")
        end
        ip = next_ip
    end
    state.output, state.graphics, state.variables, state.touch_target = table.concat(output, "\n"), graphics, variables, touch_target
    return true
end

local BasicAction = InputContainer:extend{ title = nil, callback = nil, width = nil, height = nil, dimen = nil }
function BasicAction:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.floor(self.height * .28), background = Blitbuffer.COLOR_GRAY_8, CenterContainer:new{ dimen = self.dimen, TextWidget:new{ text = self.title, face = Font:getFace("smallinfofont", scale(10)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, max_width = self.width - scale(8) } } }
    self.ges_events = { TapDBasicAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function BasicAction:paintTo(bb, x, y) local range = self.ges_events.TapDBasicAction[1].range; range.x, range.y, range.w, range.h = x, y, self.width, self.height; return InputContainer.paintTo(self, bb, x, y) end
function BasicAction:onTapDBasicAction() if self.callback then self.callback() end; return true end

local GraphCanvas = InputContainer:extend{ state = nil, context = nil, width = nil, height = nil, dimen = nil }
function GraphCanvas:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 1, color = Blitbuffer.COLOR_DARK_GRAY, background = Blitbuffer.COLOR_WHITE, empty(self.width, self.height) }
    self.ges_events = { TapDBasicCanvas = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function GraphCanvas:_coordinate(x, y, drawing)
    local actual_x = x + clamp(drawing.x or 0, 0, GRAPH_W) * self.width / GRAPH_W
    local actual_y = y + clamp(drawing.y or 0, 0, GRAPH_H) * self.height / GRAPH_H
    return math.floor(actual_x), math.floor(actual_y)
end
function GraphCanvas:paintTo(bb, x, y)
    local range = self.ges_events.TapDBasicCanvas[1].range; range.x, range.y, range.w, range.h = x, y, self.width, self.height
    self._paint_x, self._paint_y = x, y
    InputContainer.paintTo(self, bb, x, y)
    local inks = { Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_GRAY }
    for index, drawing in ipairs(self.state.graphics or {}) do
        local ink = inks[(drawing.color or 0) + 1] or Blitbuffer.COLOR_BLACK
        local x1, y1 = self:_coordinate(x, y, drawing)
        if drawing.kind == "pset" then bb:paintRect(x1, y1, math.max(1, scale(2)), math.max(1, scale(2)), ink)
        elseif drawing.kind == "line" then
            local x2, y2 = self:_coordinate(x, y, { x = drawing.x2, y = drawing.y2 })
            local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1), 1)
            for step = 0, steps do bb:paintRect(math.floor(x1 + (x2 - x1) * step / steps), math.floor(y1 + (y2 - y1) * step / steps), 1, 1, ink) end
        elseif drawing.kind == "rect" then
            local x2, y2 = self:_coordinate(x, y, { x = drawing.x2, y = drawing.y2 })
            local left, top, right, bottom = math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2)
            bb:paintRect(left, top, math.max(1, right - left), 1, ink); bb:paintRect(left, bottom, math.max(1, right - left), 1, ink)
            bb:paintRect(left, top, 1, math.max(1, bottom - top), ink); bb:paintRect(right, top, 1, math.max(1, bottom - top), ink)
        end
    end
end
function GraphCanvas:onTapDBasicCanvas(arg, gesture)
    if not self.state.touch_target then return true end
    local pos = gesture and gesture.pos or {}
    local touch = { x = clamp(math.floor(((pos.x or 0) - (self._paint_x or 0)) * GRAPH_W / math.max(1, self.width)), 0, GRAPH_W), y = clamp(math.floor(((pos.y or 0) - (self._paint_y or 0)) * GRAPH_H / math.max(1, self.height)), 0, GRAPH_H) }
    local ok, err = runProgram(self.state.program, self.state, touch, self.state.touch_target)
    if not ok then self.state.error = err end
    if self.context and self.context.requestRebuild then self.context.requestRebuild("fast") end
    return true
end

local EXAMPLES = {
    hello = "10 CLS\n20 PRINT \"Hello from DBASIC!\"\n30 FOR I = 5 TO 155 STEP 10\n40 LINE I,10,I,90,2\n50 NEXT I\n60 RECT 5,5,155,95,0\n70 END",
    touch = "10 CLS\n20 RECT 2,2,158,98,2\n30 PRINT \"Tap the canvas to draw.\"\n40 ON TOUCH GOTO 100\n50 END\n100 PSET TOUCHX,TOUCHY,0\n110 ON TOUCH GOTO 100\n120 END",
}

local function stateFor(instance)
    instance.dbasic = instance.dbasic or { program = EXAMPLES.hello, output = "", graphics = {}, variables = {}, touch_target = nil, error = nil }
    return instance.dbasic
end

local function execute(instance, context)
    local state = stateFor(instance)
    state.error = nil
    local ok, err = runProgram(state.program, state)
    if not ok then state.error = err end
    if context and context.requestRebuild then context.requestRebuild(ok and "ui" or "fast") end
    return ok, err
end

local function showEditor(instance, context)
    local state = stateFor(instance)
    local dialog
    dialog = InputDialog:new{
        title = _("DBASIC editor"),
        description = _("Use numbered lines. Commands: PRINT, LET, IF…THEN, GOTO, FOR…NEXT, CLS, COLOR, PSET, LINE, RECT, ON TOUCH GOTO, END."),
        input_hint = _("10 PRINT \"Hello\""), input = state.program or "",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function() state.program = (dialog:getInputText() or ""):sub(1, 20000); state.error = nil; UIManager:close(dialog); context.requestRebuild("ui") end },
        } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function buildPane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local margin, gap, action_h = scale(10), scale(6), scale(32)
    local action_w = math.floor((width - 2 * margin - 2 * gap) / 3)
    local canvas_h = math.max(scale(110), math.floor(height * .42))
    local output_h = math.max(scale(52), height - canvas_h - action_h - scale(58))
    local title = state.error and (_("Error: ") .. state.error) or _("Local BASIC interpreter · 160×100 graphics canvas")
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) },
        TextWidget:new{ text = "DBASIC", face = Font:getFace("cfont", scale(19)), bold = true, fgcolor = Blitbuffer.COLOR_BLACK, overlap_offset = { margin, scale(8) } },
        TextWidget:new{ text = title, face = Font:getFace("smallinfofont", scale(9)), fgcolor = state.error and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, scale(31) } },
        BasicAction:new{ title = _("Edit"), width = action_w, height = action_h, callback = function() showEditor(instance, context) end, overlap_offset = { margin, scale(47) } },
        BasicAction:new{ title = _("Run"), width = action_w, height = action_h, callback = function() execute(instance, context) end, overlap_offset = { margin + action_w + gap, scale(47) } },
        BasicAction:new{ title = _("Touch demo"), width = action_w, height = action_h, callback = function() state.program = EXAMPLES.touch; state.error = nil; execute(instance, context) end, overlap_offset = { margin + 2 * (action_w + gap), scale(47) } },
        GraphCanvas:new{ state = state, context = context, width = width - 2 * margin, height = canvas_h, overlap_offset = { margin, scale(47) + action_h + gap } },
        FrameContainer:new{ width = width - 2 * margin, height = output_h, padding = scale(6), bordersize = 1, color = Blitbuffer.COLOR_GRAY, background = Blitbuffer.COLOR_LIGHT_GRAY, TextWidget:new{ text = state.output ~= "" and state.output or _("Output appears here."), face = Font:getFace("smallinfofont", scale(10)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin - scale(12) }, overlap_offset = { margin, scale(47) + action_h + gap + canvas_h + gap } },
    }
    return WidgetContainer:new{ dimen = Geom:new{ w = width, h = height }, OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) } }
end

return {
    id = "dbasic", version = "1.0.0", title = "DBASIC", subtitle = "Local BASIC with graphics and touch", symbol = "B", logo = "code",
    buildPane = buildPane,
    _test = { tokenize = tokenize, parseExpression = parseExpression, parseProgram = parseProgram, runProgram = runProgram, examples = EXAMPLES },
}
