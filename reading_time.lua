-- Lesezeit · erstellt mit DApp Forge
-- AppDock / KOReader · Lua 5.1 / LuaJIT
-- Zustand ist instanzgebunden; Oberfläche verwendet ausschließlich context.dimen.
local FORGE_ID = "reading_time"
local FORGE_ASSETS = {

}
-- AppDock Forge Runtime
--
-- Diese Datei wird vom Exporter vor den generierten Blockly-Code gesetzt.
-- Sie definiert absichtlich nur ForgeNew: Der erzeugte Code hält f und state
-- lokal, so dass mehrere AppDock-Instanzen keinen globalen Zustand teilen.

local forge_bridge = rawget(_G, "__forge_call")

local function ForgeNew(instance, context)
    instance = instance or {}
    context = context or {}
    instance.__forge = instance.__forge or { vars = {}, initialized = false }
    local state = instance.__forge
    state.vars = type(state.vars) == "table" and state.vars or {}
    state.event = type(state.event) == "table" and state.event or {}
    for _, key in ipairs({"x", "y", "start_x", "start_y", "dx", "dy"}) do
        state.event[key] = tonumber(state.event[key]) or 0
    end
    for _, key in ipairs({"type", "direction", "key", "text", "id"}) do
        state.event[key] = tostring(state.event[key] or "")
    end

    local width = math.max(1, math.floor(tonumber(context.dimen and context.dimen.w) or 1))
    local height = math.max(1, math.floor(tonumber(context.dimen and context.dimen.h) or 1))
    local browser = type(forge_bridge) == "function"
    local MAX_COMMANDS, MAX_PIXELS, MAX_TEXT_BYTES = 4096, 4096, 4096

    local f = {
        state = state,
        handlers = {},
        _commands = {},
        _buttons = {},
        _painted = false,
        _drawing = false,
        _painting = false,
        _origin_x = 0,
        _origin_y = 0,
    }

    -- Layout-Container sind nur Runtime-Hilfen. Koordinaten werden beim
    -- Eintragen abgeflacht, damit native und Browser-Vorschau identisch sind.
    local function rectangle(x, y, w, h)
        x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
        w, h = math.max(0, math.floor(tonumber(w) or 0)), math.max(0, math.floor(tonumber(h) or 0))
        return { x = x, y = y, w = w, h = h }
    end

    local function intersection(a, b)
        local left, top = math.max(a.x, b.x), math.max(a.y, b.y)
        local right, bottom = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
        return { x = left, y = top, w = math.max(0, right - left), h = math.max(0, bottom - top) }
    end

    local function resetLayout()
        f._layout = { { x = 0, y = 0, w = width, h = height, clip = rectangle(0, 0, width, height) } }
    end

    local function currentLayout()
        return f._layout[#f._layout]
    end

    local function number(value, fallback)
        value = tonumber(value)
        if value == nil or value ~= value or value == math.huge or value == -math.huge then return fallback or 0 end
        return value
    end

    local function saneSize(value, fallback)
        return math.max(0, math.min(MAX_PIXELS, math.floor(number(value, fallback))))
    end

    -- Positionen dürfen negativ sein (ein Element kann in einen Container
    -- hineinragen); nur ihre Größen bleiben zwangsläufig nichtnegativ.
    local function coordinate(value, fallback)
        return math.max(-MAX_PIXELS, math.min(MAX_PIXELS, math.floor(number(value, fallback))))
    end

    local function clippedCommand(command)
        local clip = command.clip or rectangle(0, 0, width, height)
        return {
            x = math.floor(f._origin_x + clip.x),
            y = math.floor(f._origin_y + clip.y),
            w = math.max(0, math.floor(clip.w)),
            h = math.max(0, math.floor(clip.h)),
        }
    end

    local function append(command)
        if #f._commands >= MAX_COMMANDS then
            f._overflow = true
            return false
        end
        f._commands[#f._commands + 1] = command
        return true
    end

    local function bridge(command, ...)
        -- Der Browser-Worker stellt genau diese synchrone Brücke bereit.
        return forge_bridge(command, ...)
    end

    resetLayout()

    function f:width()
        return currentLayout().w
    end

    function f:height()
        return currentLayout().h
    end

    function f:px(value)
        value = number(value, 0)
        if type(context.px) == "function" then
            local ok, pixels = pcall(context.px, value)
            if ok and tonumber(pixels) then return math.max(1, math.floor(tonumber(pixels) + 0.5)) end
        end
        local scale = number(context.ui_scale or context.scale, 1)
        return math.max(1, math.floor(value * scale + 0.5))
    end

    function f:push(x, y, w, h)
        local parent = currentLayout()
        x, y = coordinate(x, 0), coordinate(y, 0)
        local local_w = w == nil and math.max(0, parent.w - x) or saneSize(w, 0)
        local local_h = h == nil and math.max(0, parent.h - y) or saneSize(h, 0)
        local frame = rectangle(parent.x + x, parent.y + y, local_w, local_h)
        frame.clip = intersection(parent.clip, frame)
        f._layout[#f._layout + 1] = frame
        return frame.w, frame.h
    end

    function f:pop()
        if #f._layout > 1 then table.remove(f._layout) end
        local frame = currentLayout()
        return frame.w, frame.h
    end

    local function drawCommand(command, name, ...)
        if append(command) and browser then
            local clip = command.clip
            bridge("clip", clip.x, clip.y, clip.w, clip.h)
            bridge(name, ...)
        end
    end

    function f:clear(color)
        local layout = currentLayout()
        drawCommand({ op = "clear", color = color, clip = layout.clip }, "clear", color)
    end

    function f:rect(x, y, w, h, color, fill, radius)
        local layout = currentLayout()
        x, y, w, h = coordinate(x, 0), coordinate(y, 0), saneSize(w, 0), saneSize(h, 0)
        local command = {
            op = "rect", x = layout.x + x, y = layout.y + y, w = w, h = h,
            color = color, fill = fill ~= false, radius = saneSize(radius, 0), clip = layout.clip,
        }
        drawCommand(command, "rect", command.x, command.y, command.w, command.h, color, command.fill, command.radius)
    end

    function f:circle(x, y, radius, color, fill, thickness)
        local layout = currentLayout()
        local command = {
            op = "circle", x = layout.x + coordinate(x, 0), y = layout.y + coordinate(y, 0),
            r = saneSize(radius, 0), color = color, fill = fill ~= false,
            thickness = math.max(1, saneSize(thickness, 1)), clip = layout.clip,
        }
        drawCommand(command, "circle", command.x, command.y, command.r, color, command.fill, command.thickness)
    end

    function f:line(x1, y1, x2, y2, color, thickness)
        local layout = currentLayout()
        local command = {
            op = "line", x1 = layout.x + coordinate(x1, 0), y1 = layout.y + coordinate(y1, 0),
            x2 = layout.x + coordinate(x2, 0), y2 = layout.y + coordinate(y2, 0),
            color = color, thickness = math.max(1, saneSize(thickness, 1)), clip = layout.clip,
        }
        drawCommand(command, "line", command.x1, command.y1, command.x2, command.y2, color, command.thickness)
    end

    function f:text(text, x, y, size, color, maxwidth, bold, align)
        local layout = currentLayout()
        text = tostring(text or ""):sub(1, MAX_TEXT_BYTES)
        local local_x, local_y = coordinate(x, 0), coordinate(y, 0)
        local available = math.max(1, layout.clip.x + layout.clip.w - (layout.x + local_x))
        local command = {
            op = "text", text = text, x = layout.x + local_x, y = layout.y + local_y,
            size = math.max(1, saneSize(size, 12)), color = color,
            maxwidth = math.max(1, math.min(available, maxwidth == nil and available or saneSize(maxwidth, available))),
            bold = bold == true, align = align == "center" and "center" or align == "right" and "right" or "left",
            clip = layout.clip,
        }
        drawCommand(command, "text", command.text, command.x, command.y, command.size, color, command.maxwidth, command.bold, command.align)
    end

    function f:image(path, x, y, w, h)
        local layout = currentLayout()
        path = tostring(path or ""):sub(1, 512)
        local command = {
            op = "image", path = path, x = layout.x + coordinate(x, 0), y = layout.y + coordinate(y, 0),
            w = saneSize(w, 0), h = saneSize(h, 0), clip = layout.clip,
        }
        drawCommand(command, "image", command.path, command.x, command.y, command.w, command.h)
    end

    function f:button(id, label, x, y, w, h, bg, fg, radius)
        local layout = currentLayout()
        local command = {
            op = "button", id = tostring(id or ""), label = tostring(label or ""):sub(1, 256),
            x = layout.x + coordinate(x, 0), y = layout.y + coordinate(y, 0),
            w = saneSize(w, 0), h = saneSize(h, 0), bg = bg, fg = fg,
            radius = saneSize(radius, 0), clip = layout.clip,
        }
        if append(command) then
            f._buttons[#f._buttons + 1] = command
            if browser then
                bridge("clip", command.clip.x, command.clip.y, command.clip.w, command.clip.h)
                bridge("button", command.id, command.label, command.x, command.y, command.w, command.h, bg, fg, command.radius)
            end
        end
    end

    local function callHandler(handler, ...)
        if type(handler) == "function" then return handler(...) end
    end

    -- Das erneute Zeichnen ersetzt nur die Display-List. Erst paintTo schreibt
    -- Pixel; deshalb bleibt ein draw-Handler frei von Rendering-Nebenwirkungen.
    function f:redraw()
        if f._drawing then return false end
        f._drawing = true
        f._commands, f._buttons, f._overflow = {}, {}, false
        resetLayout()
        local draw = f.handlers and f.handlers.draw
        local ok, err = true, nil
        if type(draw) == "function" then ok, err = pcall(draw) end
        f._drawing = false
        if not ok then error(err) end

        if browser then return true end
        if f._painted and f._pane and not f._pane._forge_closed then
            local native = f._native
            if native and native.UIManager and native.UIManager.widgetRepaint and not f._painting then
                native.UIManager:widgetRepaint(f._pane, f._origin_x, f._origin_y)
            end
            -- Der Repaint oben muss vor dem regionalen E-Ink-Refresh erfolgen.
            local request = f._pending_refresh
            f._pending_refresh = nil
            if request then f:refresh(request.kind, request.x, request.y, request.w, request.h)
            else f:refresh("ui", 0, 0, width, height) end
        end
        return true
    end

    function f:refresh(kind, x, y, w, h)
        kind = tostring(kind or "ui")
        if browser then return bridge("refresh", kind, x, y, w, h) end
        if type(context.requestRefresh) ~= "function" then return false end
        if f._handling then
            f._pending_refresh = {kind = kind, x = x, y = y, w = w, h = h}
            return true
        end

        local region = nil
        if x ~= nil and y ~= nil and w ~= nil and h ~= nil then
            local local_region = intersection(rectangle(coordinate(x, 0), coordinate(y, 0), saneSize(w, 0), saneSize(h, 0)), rectangle(0, 0, width, height))
            if local_region.w < 1 or local_region.h < 1 then return false end
            local native = f._native
            region = native.Geom:new{
                -- AppDock verlangt hier Bildschirm-, nicht Pane-Koordinaten.
                x = math.floor(f._origin_x + local_region.x),
                y = math.floor(f._origin_y + local_region.y),
                w = local_region.w,
                h = local_region.h,
            }
        end

        -- Bei einem Fast-Refresh wird der bestehende Pane-Renderer zuerst noch
        -- einmal in den aktiven Buffer gemalt. Keine globale Screen-API nötig.
        local native = f._native
        if kind == "fast" and f._painted and f._pane and native and native.UIManager
            and native.UIManager.widgetRepaint and not f._painting then
            native.UIManager:widgetRepaint(f._pane, f._origin_x, f._origin_y)
        end
        return context.requestRefresh(kind, region)
    end

    function f:rebuild(kind)
        kind = tostring(kind or "ui")
        if browser then return bridge("rebuild", kind) end
        if state._forge_rebuilding or type(context.requestRebuild) ~= "function" then return false end
        state._forge_rebuilding = true
        local ok, result = pcall(context.requestRebuild, kind)
        state._forge_rebuilding = false
        if not ok then f:log(result); return false end
        return result ~= false
    end

    function f:notify(title, message, priority)
        title = tostring(title or ""):sub(1, 72)
        message = tostring(message or ""):sub(1, 240)
        priority = priority == "high" and "high" or "normal"
        if browser then return bridge("notify", title, message, priority) end
        if type(context.notify) == "function" then return context.notify({ title = title, message = message, priority = priority }) end
        return false
    end

    function f:message(text)
        text = tostring(text or ""):sub(1, 512)
        if browser then return bridge("message", text) end
        local native = f._native
        if native and native.InfoMessage and native.UIManager then
            local dialog = native.InfoMessage:new{ text = text }
            native.UIManager:show(dialog)
            return true
        end
        return false
    end

    function f:input(key, prompt, default)
        key = tostring(key or ""):sub(1, 128)
        prompt = tostring(prompt or ""):sub(1, 256)
        default = default == nil and state.vars[key] or default
        default = tostring(default or ""):sub(1, 1024)
        if browser then return bridge("input", key, prompt, default) end
        local native = f._native
        if not native or not native.InputDialog or not native.UIManager then return nil end
        local dialog
        dialog = native.InputDialog:new{
            title = prompt, input = default, input_hint = prompt,
            buttons = { {
                { text = "Cancel", callback = function() native.UIManager:close(dialog) end },
                { text = "OK", is_enter_default = true, callback = function()
                    local value = dialog:getInputText() or ""
                    native.UIManager:close(dialog)
                    f:event("input", 0, 0, "", key, value)
                end },
            } },
        }
        native.UIManager:show(dialog)
        if dialog.onShowKeyboard then dialog:onShowKeyboard() end
        return state.vars[key]
    end

    function f:save(key, value)
        key = tostring(key or ""):sub(1, 128)
        state.vars[key] = value
        if browser then return bridge("save", key, value) end
        if f._settings then
            local function safeCopy(item, depth, seen)
                local kind = type(item)
                if kind == "string" then return item:sub(1, 65536) end
                if kind == "number" then return number(item, 0) end
                if kind == "boolean" or kind == "nil" then return item end
                if kind ~= "table" or depth > 8 or seen[item] then return nil end
                seen[item] = true
                local copy, count = {}, 0
                for item_key, child in pairs(item) do
                    count = count + 1
                    if count > 1024 then break end
                    if type(item_key) == "string" or type(item_key) == "number" then
                        copy[item_key] = safeCopy(child, depth + 1, seen)
                    end
                end
                seen[item] = nil
                return copy
            end
            f._settings:saveSetting(key, safeCopy(value, 0, {}))
            local ok, err = pcall(f._settings.flush, f._settings)
            if not ok then f:log(err); return false end
        end
        return value
    end

    function f:load(key, default)
        key = tostring(key or ""):sub(1, 128)
        if browser then
            local value = bridge("load", key, default)
            if value ~= nil then state.vars[key] = value; return value end
        end
        if not browser and f._settings then
            local value = f._settings:readSetting(key, default)
            state.vars[key] = value
            return value
        end
        local value = state.vars[key]
        if value == nil then return default end
        return value
    end

    function f:remove(key)
        key = tostring(key or ""):sub(1, 128)
        state.vars[key] = nil
        if browser then return bridge("remove", key) end
        if f._settings then
            f._settings:delSetting(key)
            local ok, err = pcall(f._settings.flush, f._settings)
            if not ok then f:log(err); return false end
        end
        return true
    end

    function f:system(key)
        key = tostring(key or "")
        if browser then return bridge("system", key) end
        local native = f._native
        if key == "time" then return os.date("%H:%M") end
        if key == "date" then return os.date("%Y-%m-%d") end
        if key == "ui_scale" then return number(context.ui_scale or context.scale, 1) end
        if key == "color" then
            if native and native.Device and native.Device.screen and native.Device.screen.isColorEnabled then
                local ok, value = pcall(native.Device.screen.isColorEnabled, native.Device.screen)
                if ok then return value and true or false end
            end
            return false
        end
        if key == "battery" or key == "charging" then
            if native and native.Device and native.Device.getPowerDevice then
                local ok, power = pcall(native.Device.getPowerDevice, native.Device)
                if ok and power then
                    if key == "battery" and power.getCapacity then
                        local got, capacity = pcall(power.getCapacity, power)
                        if got then return capacity end
                    elseif key == "charging" and power.isCharging then
                        local got, charging = pcall(power.isCharging, power)
                        if got then return charging and true or false end
                    end
                end
            end
            return key == "battery" and 0 or false
        end
        return nil
    end

    function f:log(value)
        if browser then return bridge("log", tostring(value)) end
        print("[AppDock Forge] " .. tostring(value))
    end

    local function pointInButton(button, x, y)
        local visible = intersection(rectangle(button.x, button.y, button.w, button.h), button.clip)
        return visible.w > 0 and visible.h > 0 and x >= visible.x and y >= visible.y
            and x < visible.x + visible.w and y < visible.y + visible.h
    end

    function f:event(event_type, x, y, direction, key, text, start_x, start_y)
        event_type = tostring(event_type or "")
        if event_type == "pan_release" or event_type == "hold_release" then event_type = "release" end
        x, y = saneSize(x, 0), saneSize(y, 0)
        direction, key = tostring(direction or ""), tostring(key or "")
        if text ~= nil then text = tostring(text):sub(1, 1024) else text = "" end
        state.event.type, state.event.x, state.event.y = event_type, x, y
        state.event.direction, state.event.key, state.event.text = direction, key, text
        if start_x ~= nil and start_y ~= nil then
            f._gesture_start = {x = saneSize(start_x, x), y = saneSize(start_y, y)}
        elseif event_type == "tap" or event_type == "hold" or (event_type == "pan" and not f._gesture_start) then
            f._gesture_start = {x = x, y = y}
        end
        local start = f._gesture_start or {x = x, y = y}
        state.event.start_x, state.event.start_y = start.x, start.y
        state.event.dx, state.event.dy = x - start.x, y - start.y
        state.event.id = ""
        if event_type == "tap" then
            for index = #f._buttons, 1, -1 do
                if pointInButton(f._buttons[index], x, y) then state.event.id = f._buttons[index].id; break end
            end
        end

        if event_type == "input" and key ~= "" then state.vars[key] = text end
        f._handling = true
        callHandler(f.handlers and f.handlers[event_type], x, y, direction, key, text)
        if event_type == "tap" then
            for index = #f._buttons, 1, -1 do
                local button = f._buttons[index]
                if pointInButton(button, x, y) then
                    local buttons = f.handlers and f.handlers.buttons
                    if type(buttons) == "table" then callHandler(buttons[button.id], x, y, direction, key, text) end
                    break
                end
            end
        end
        f._handling = false
        f:redraw()
        if event_type == "tap" or event_type == "release" or event_type == "swipe" then f._gesture_start = nil end
        return true
    end

    if browser then
        -- Die Vorschau behält dieselbe Event-API, besitzt aber kein KOReader-Pane.
        function f:finish(handlers, interval)
            f.handlers = type(handlers) == "table" and handlers or {}
            f.interval = math.max(0, number(interval, 0))
            f:redraw() -- draw wird beim Aufbau genau einmal aufgerufen.
            return f
        end
        return f
    end

    -- Native Abhängigkeiten werden erst hier geladen: Der Browser braucht keine
    -- KOReader-Module und kann die Runtime damit direkt im Worker ausführen.
    local Blitbuffer = require("ffi/blitbuffer")
    local Device = require("device")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local ImageWidget = require("ui/widget/imagewidget")
    local InfoMessage = require("ui/widget/infomessage")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local InputDialog = require("ui/widget/inputdialog")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    f._native = {
        Blitbuffer = Blitbuffer, Device = Device, Font = Font, Geom = Geom,
        ImageWidget = ImageWidget, InfoMessage = InfoMessage, InputDialog = InputDialog,
        TextWidget = TextWidget, UIManager = UIManager,
    }

    -- FORGE_ASSETS und FORGE_ID werden vom Single-Lua-Exporter vor dieser
    -- Runtime lokal definiert. Ohne Einbettung bleibt image(path, ...) ein
    -- normaler, lokaler KOReader-Dateipfad.
    local forge_assets = type(FORGE_ASSETS) == "table" and FORGE_ASSETS or {}
    local forge_id = tostring(FORGE_ID or "appdock_forge"):gsub("[^%w_-]", "_"):sub(1, 64)
    if forge_id == "" then forge_id = "appdock_forge" end
    local MAX_ASSET_BYTES = 5 * 1024 * 1024
    local MAX_ASSET_BASE64 = math.floor((MAX_ASSET_BYTES + 2) / 3) * 4
    state.asset_paths = type(state.asset_paths) == "table" and state.asset_paths or {}

    local ok_storage, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    local ok_mime, mime = pcall(require, "mime")

    local function base64Value(byte)
        if byte >= 65 and byte <= 90 then return byte - 65 end
        if byte >= 97 and byte <= 122 then return byte - 71 end
        if byte >= 48 and byte <= 57 then return byte + 4 end
        if byte == 43 then return 62 end
        if byte == 47 then return 63 end
        return nil
    end

    local function base64Length(encoded)
        local count, last, previous = 0, nil, nil
        for index = 1, #encoded do
            local byte = encoded:byte(index)
            if byte ~= 9 and byte ~= 10 and byte ~= 13 and byte ~= 32 then
                if byte == 61 then byte = -1 elseif not base64Value(byte) then return nil end
                count, previous, last = count + 1, last, byte
                if count > MAX_ASSET_BASE64 then return nil end
            end
        end
        if count < 4 or count % 4 ~= 0 then return nil end
        local padding = last == -1 and (previous == -1 and 2 or 1) or 0
        local decoded = count / 4 * 3 - padding
        if decoded < 1 or decoded > MAX_ASSET_BYTES then return nil end
        return decoded
    end

    -- Reine Lua-5.1-Variante für Geräte ohne LuaSocket mime.unb64.
    local function decodeBase64Pure(encoded, expected)
        local parts, quartet, count, seen_padding = {}, {}, 0, false
        for index = 1, #encoded do
            local byte = encoded:byte(index)
            if byte ~= 9 and byte ~= 10 and byte ~= 13 and byte ~= 32 then
                local value = byte == 61 and -1 or base64Value(byte)
                if value == nil or seen_padding then return nil end
                quartet[#quartet + 1] = value
                if #quartet == 4 then
                    local a, b, c, d = quartet[1], quartet[2], quartet[3], quartet[4]
                    if a < 0 or b < 0 or (c < 0 and d >= 0) then return nil end
                    parts[#parts + 1] = string.char(a * 4 + math.floor(b / 16))
                    count = count + 1
                    if c >= 0 then
                        parts[#parts + 1] = string.char((b % 16) * 16 + math.floor(c / 4))
                        count = count + 1
                        if d >= 0 then
                            parts[#parts + 1] = string.char((c % 4) * 64 + d)
                            count = count + 1
                        end
                    end
                    if c < 0 or d < 0 then seen_padding = true end
                    quartet = {}
                    if count > MAX_ASSET_BYTES then return nil end
                end
            end
        end
        if #quartet ~= 0 or count ~= expected then return nil end
        return table.concat(parts)
    end

    local function decodeBase64(encoded)
        if type(encoded) ~= "string" then return nil end
        local expected = base64Length(encoded)
        if not expected then return nil end
        if ok_mime and mime and mime.unb64 then
            local ok, decoded = pcall(mime.unb64, encoded)
            if ok and type(decoded) == "string" and #decoded == expected then return decoded end
        end
        return decodeBase64Pure(encoded, expected)
    end

    local function imageExtension(bytes)
        if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
        if bytes:sub(1, 3) == "\255\216\255" then return "jpg" end
        if bytes:sub(1, 6) == "GIF87a" or bytes:sub(1, 6) == "GIF89a" then return "gif" end
        if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return "webp" end
        return nil
    end

    local function assetHash(value)
        local hash = 5381
        for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 2147483647 end
        return string.format("%08x", hash)
    end

    local function ensureDirectory(path)
        if not ok_lfs or not lfs then return false end
        local info = lfs.attributes(path)
        if info and info.mode == "directory" then return true end
        return lfs.mkdir(path) and true or false
    end

    -- KOReaders eigener lokaler Settings-Store schreibt vertrauenswürdige,
    -- bereinigte Werte atomar. Keine Downloads oder Benutzercodes laden.
    if ok_storage and DataStorage and DataStorage.getDataDir then
        local root = DataStorage:getDataDir() .. "/appdock_forge"
        local directory = root .. "/" .. forge_id
        if ensureDirectory(root) and ensureDirectory(directory) then
            local ok_settings, LuaSettings = pcall(require, "luasettings")
            if ok_settings and LuaSettings and LuaSettings.open then
                local ok, settings = pcall(LuaSettings.open, LuaSettings, directory .. "/settings.lua")
                if ok then f._settings = settings end
            end
        end
    end

    local function materializeAsset(path)
        local encoded = forge_assets[path]
        if type(encoded) ~= "string" then
            -- Freie Gerätepfade gehören nicht in ungeprüfte Benutzereingaben.
            -- Standardmäßig sind nur eingebettete Asset-Schlüssel zulässig.
            return nil
        end
        local cache_key = path .. "\0" .. assetHash(encoded)
        local cached = state.asset_paths[cache_key]
        if cached and ok_lfs and lfs and lfs.attributes(cached) then return cached end
        if not ok_storage or not DataStorage or not DataStorage.getDataDir then return nil end

        -- Vor dem Dekodieren werden Base64- und danach Binärgröße begrenzt.
        local bytes = decodeBase64(encoded)
        if not bytes or #bytes > MAX_ASSET_BYTES then return nil end
        local extension = imageExtension(bytes)
        if not extension then return nil end

        local root = DataStorage:getDataDir() .. "/appdock_forge"
        local directory = root .. "/" .. forge_id
        if not ensureDirectory(root) or not ensureDirectory(directory) then return nil end
        local target = directory .. "/asset_" .. assetHash(encoded) .. "." .. extension
        local existing = lfs.attributes(target)
        if not existing or existing.size ~= #bytes then
            local temporary = target .. ".tmp"
            local file = io.open(temporary, "wb")
            if not file then return nil end
            local written = file:write(bytes)
            file:close()
            if not written or not os.rename(temporary, target) then os.remove(temporary); return nil end
        end
        state.asset_paths[cache_key] = target
        return target
    end

    local color_cache = {}
    local function ink(value)
        if type(value) ~= "string" then return value or Blitbuffer.COLOR_BLACK end
        local key = value:lower()
        if color_cache[key] then return color_cache[key] end
        local named = {
            black = Blitbuffer.COLOR_BLACK, white = Blitbuffer.COLOR_WHITE,
            gray = Blitbuffer.COLOR_GRAY, lightgray = Blitbuffer.COLOR_LIGHT_GRAY,
            light_gray = Blitbuffer.COLOR_LIGHT_GRAY, darkgray = Blitbuffer.COLOR_DARK_GRAY,
            dark_gray = Blitbuffer.COLOR_DARK_GRAY,
        }
        local result = named[key]
        local hex = key:match("^#(%x%x%x%x%x%x)$")
        if not hex then
            local short = key:match("^#(%x%x%x)$")
            if short then hex = short:sub(1, 1):rep(2) .. short:sub(2, 2):rep(2) .. short:sub(3, 3):rep(2) end
        end
        if hex then
            local red, green, blue = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
            local coloured = Device.screen and Device.screen.isColorEnabled and Device.screen:isColorEnabled()
            if coloured and Blitbuffer.ColorRGB32 then result = Blitbuffer.ColorRGB32(red, green, blue, 0xFF)
            else
                local brightness = red * 0.299 + green * 0.587 + blue * 0.114
                result = Blitbuffer.Color8 and Blitbuffer.Color8(math.floor(brightness + 0.5)) or (brightness > 190 and Blitbuffer.COLOR_WHITE or brightness > 105 and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK)
            end
        end
        result = result or Blitbuffer.COLOR_BLACK
        color_cache[key] = result
        return result
    end

    -- Sichere, pixelgenaue Begrenzung ohne nicht-portable Screen-Clip-APIs.
    local function paintRect(bb, x, y, w, h, color, clip)
        if not bb or not bb.paintRect then return end
        x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
        local left, top = math.max(x, clip.x), math.max(y, clip.y)
        local right, bottom = math.min(x + w, clip.x + clip.w), math.min(y + h, clip.y + clip.h)
        if right > left and bottom > top then
            if Device.screen and Device.screen.isColorEnabled and Device.screen:isColorEnabled() and bb.paintRectRGB32 then
                bb:paintRectRGB32(left, top, right - left, bottom - top, color)
            else
                bb:paintRect(left, top, right - left, bottom - top, color)
            end
        end
    end

    local function paintLine(bb, x1, y1, x2, y2, thickness, color, clip)
        local dx, dy = x2 - x1, y2 - y1
        local count = math.max(1, math.floor(math.max(math.abs(dx), math.abs(dy))))
        local increment = math.max(1, math.ceil(count / 2048))
        local half = math.floor(thickness / 2)
        for step = 0, count, increment do
            local ratio = step / count
            paintRect(bb, math.floor(x1 + dx * ratio) - half, math.floor(y1 + dy * ratio) - half, thickness, thickness, color, clip)
        end
        if count % increment ~= 0 then paintRect(bb, math.floor(x2) - half, math.floor(y2) - half, thickness, thickness, color, clip) end
    end

    local function paintRoundedRect(bb, x, y, w, h, radius, color, fill, clip)
        if w < 1 or h < 1 then return end
        radius = math.min(math.floor(radius), math.floor(math.min(w, h) / 2))
        if radius < 1 then
            if fill then paintRect(bb, x, y, w, h, color, clip)
            else
                paintRect(bb, x, y, w, 1, color, clip); paintRect(bb, x, y + h - 1, w, 1, color, clip)
                paintRect(bb, x, y, 1, h, color, clip); paintRect(bb, x + w - 1, y, 1, h, color, clip)
            end
            return
        end
        local rows, increment = h, math.max(1, math.ceil(h / 2048))
        for row = 0, rows - 1, increment do
            local yy = row < radius and radius - row or row >= h - radius and row - (h - radius - 1) or 0
            local inset = yy > 0 and math.floor(radius - math.sqrt(math.max(0, radius * radius - yy * yy))) or 0
            local row_h = math.min(increment, h - row)
            if fill then paintRect(bb, x + inset, y + row, w - 2 * inset, row_h, color, clip)
            else
                if row < 1 or row + row_h >= h then paintRect(bb, x + inset, y + row, w - 2 * inset, row_h, color, clip)
                else
                    paintRect(bb, x + inset, y + row, 1, row_h, color, clip)
                    paintRect(bb, x + w - inset - 1, y + row, 1, row_h, color, clip)
                end
            end
        end
    end

    local function paintCircle(bb, x, y, radius, color, fill, thickness, clip)
        if radius < 1 then paintRect(bb, x, y, 1, 1, color, clip); return end
        local rows = radius * 2 + 1
        local increment = math.max(1, math.ceil(rows / 2048))
        local inner = math.max(0, radius - math.max(1, thickness))
        for row = -radius, radius, increment do
            local outer_half = math.floor(math.sqrt(math.max(0, radius * radius - row * row)))
            local row_h = math.min(increment, radius - row + 1)
            if fill then paintRect(bb, x - outer_half, y + row, outer_half * 2 + 1, row_h, color, clip)
            else
                local inner_half = row * row < inner * inner and math.floor(math.sqrt(math.max(0, inner * inner - row * row))) or 0
                if inner_half > 0 then
                    paintRect(bb, x - outer_half, y + row, outer_half - inner_half + 1, row_h, color, clip)
                    paintRect(bb, x + inner_half, y + row, outer_half - inner_half + 1, row_h, color, clip)
                else
                    paintRect(bb, x - outer_half, y + row, outer_half * 2 + 1, row_h, color, clip)
                end
            end
        end
    end

    local function paintWidgetInClip(widget, bb, x, y, clip)
        if bb.viewport and clip.w > 0 and clip.h > 0 then
            local viewport = bb:viewport(clip.x, clip.y, clip.w, clip.h)
            local ok, err = pcall(widget.paintTo, widget, viewport, x - clip.x, y - clip.y)
            if viewport.free then viewport:free() end
            if widget.free then widget:free() end
            if not ok then f:log(err) end
        else
            -- Alte Testdoubles ohne Viewport: nur vollständig sichtbare Widgets.
            local size = widget.getSize and widget:getSize() or {w = 0, h = 0}
            if x >= clip.x and y >= clip.y and x + size.w <= clip.x + clip.w and y + size.h <= clip.y + clip.h then
                widget:paintTo(bb, x, y)
            end
            if widget.free then widget:free() end
        end
    end

    function f:paint(bb, x, y)
        f._painted, f._painting = true, true
        f._origin_x, f._origin_y = math.floor(number(x, 0)), math.floor(number(y, 0))
        for _, command in ipairs(f._commands) do
            local clip = clippedCommand(command)
            if clip.w > 0 and clip.h > 0 then
                if command.op == "clear" then
                    paintRect(bb, f._origin_x, f._origin_y, width, height, ink(command.color), clip)
                elseif command.op == "rect" then
                    paintRoundedRect(bb, f._origin_x + command.x, f._origin_y + command.y, command.w, command.h, command.radius, ink(command.color), command.fill, clip)
                elseif command.op == "circle" then
                    paintCircle(bb, f._origin_x + command.x, f._origin_y + command.y, command.r, ink(command.color), command.fill, command.thickness, clip)
                elseif command.op == "line" then
                    paintLine(bb, f._origin_x + command.x1, f._origin_y + command.y1, f._origin_x + command.x2, f._origin_y + command.y2, command.thickness, ink(command.color), clip)
                elseif command.op == "text" then
                    local tx, ty = f._origin_x + command.x, f._origin_y + command.y
                    if tx < clip.x then tx = clip.x end
                    local max_width = math.max(1, math.min(command.maxwidth, clip.x + clip.w - tx))
                    if max_width > 0 and ty < clip.y + clip.h and ty >= clip.y then
                        local widget = TextWidget:new{
                            text = command.text, face = Font:getFace("cfont", command.size), fgcolor = ink(command.color),
                            bold = command.bold, max_width = max_width,
                        }
                        if command.align ~= "left" and widget.getSize then
                            local ok, text_w = pcall(function() local size = widget:getSize(); return size and size.w or 0 end)
                            if ok and text_w then
                                if command.align == "center" then tx = tx + math.floor((max_width - text_w) / 2)
                                elseif command.align == "right" then tx = tx + max_width - text_w end
                            end
                        end
                        if tx < clip.x then tx = clip.x end
                        if tx + max_width > clip.x + clip.w then max_width = math.max(1, clip.x + clip.w - tx) end
                        widget.max_width = max_width
                        paintWidgetInClip(widget, bb, tx, ty, clip)
                    end
                elseif command.op == "image" and command.path ~= "" then
                    local visible = intersection(rectangle(f._origin_x + command.x, f._origin_y + command.y, command.w, command.h), clip)
                    if visible.w > 0 and visible.h > 0 then
                        local file = materializeAsset(command.path)
                        if file then
                            local ok, image = pcall(ImageWidget.new, ImageWidget, {
                                file = file, width = command.w, height = command.h, alpha = true,
                            })
                            if ok and image then paintWidgetInClip(image, bb, f._origin_x + command.x, f._origin_y + command.y, clip) end
                        end
                    end
                elseif command.op == "button" then
                    paintRoundedRect(bb, f._origin_x + command.x, f._origin_y + command.y, command.w, command.h, command.radius, ink(command.bg), true, clip)
                    local tx, ty = f._origin_x + command.x, f._origin_y + command.y + math.max(0, math.floor((command.h - math.min(command.h, f:px(15))) / 2))
                    if tx < clip.x then tx = clip.x end
                    local max_width = math.max(1, math.min(command.w - 2, clip.x + clip.w - tx - 1))
                    if max_width > 0 and ty >= clip.y and ty < clip.y + clip.h then
                        local widget = TextWidget:new{
                            text = command.label, face = Font:getFace("cfont", math.max(1, math.min(f:px(14), math.floor(command.h * .62)))),
                            fgcolor = ink(command.fg), bold = true, max_width = max_width,
                        }
                        local text_w = 0
                        if widget.getSize then
                            local ok, measured = pcall(function() local size = widget:getSize(); return size and size.w or 0 end)
                            if ok then text_w = measured or 0 end
                        end
                        local label_x = math.max(tx, tx + math.max(0, math.floor((command.w - text_w) / 2)))
                        widget.max_width = math.max(1, math.min(max_width, clip.x + clip.w - label_x))
                        paintWidgetInClip(widget, bb, label_x, ty, clip)
                    end
                end
            end
        end
        f._painting = false
    end

    local function localPoint(pane, gesture)
        local point = gesture and (gesture.pos or gesture) or {}
        local x = number(point.x, pane._forge_x or 0) - (pane._forge_x or 0)
        local y = number(point.y, pane._forge_y or 0) - (pane._forge_y or 0)
        return math.max(0, math.min(width, math.floor(x))), math.max(0, math.min(height, math.floor(y)))
    end

    function f:finish(handlers, interval)
        f.handlers = type(handlers) == "table" and handlers or {}
        f.interval = math.max(0, number(interval, 0))
        f:redraw() -- Einziger initialer draw-Aufruf; Generatoren rufen draw nicht selbst.

        -- Ein erneut gebautes Pane darf keinen alten Worker-Timer behalten.
        local old = state.pane
        if old and old._forge_timer and UIManager.unschedule then UIManager:unschedule(old._forge_timer) end
        if old then old._forge_closed = true end

        local pane = InputContainer:extend{ dimen = Geom:new{ w = width, h = height } }:new{}
        pane._forge_x, pane._forge_y, pane._forge_closed = 0, 0, false
        pane.ges_events = {
            ForgeTap = { GestureRange:new{ ges = "tap", range = pane.dimen } },
            ForgeHold = { GestureRange:new{ ges = "hold", range = pane.dimen } },
            ForgeHoldRelease = { GestureRange:new{ ges = "hold_release", range = pane.dimen } },
            ForgePan = { GestureRange:new{ ges = "pan", range = pane.dimen, rate = 8 } },
            ForgePanRelease = { GestureRange:new{ ges = "pan_release", range = pane.dimen } },
            ForgeSwipe = { GestureRange:new{ ges = "swipe", range = pane.dimen } },
        }

        function pane:paintTo(bb, x, y)
            self._forge_x, self._forge_y = math.floor(number(x, 0)), math.floor(number(y, 0))
            for _, events in pairs(self.ges_events) do
                local range = events[1] and events[1].range
                if range then range.x, range.y, range.w, range.h = self._forge_x, self._forge_y, width, height end
            end
            f:paint(bb, self._forge_x, self._forge_y)
        end
        function pane:onForgeTap(_, gesture)
            gesture = gesture or _
            local x, y = localPoint(self, gesture); return f:event("tap", x, y)
        end
        function pane:onForgeHold(_, gesture)
            gesture = gesture or _
            local x, y = localPoint(self, gesture); return f:event("hold", x, y)
        end
        function pane:onForgeHoldRelease(_, gesture)
            gesture = gesture or _
            local x, y = localPoint(self, gesture); return f:event("release", x, y, gesture and gesture.direction)
        end
        function pane:onForgePan(_, gesture)
            gesture = gesture or _
            local x, y = localPoint(self, gesture); return f:event("pan", x, y, gesture and gesture.direction)
        end
        function pane:onForgePanRelease(_, gesture)
            gesture = gesture or _
            local x, y = localPoint(self, gesture); return f:event("release", x, y, gesture and gesture.direction)
        end
        function pane:onForgeSwipe(_, gesture)
            gesture = gesture or _
            local x, y = localPoint(self, gesture); return f:event("swipe", x, y, gesture and gesture.direction)
        end

        -- Hardwaretasten sind optional: Fehlt eine Gruppe, wird keine Bindung
        -- registriert. Jede vorhandene Gruppe landet bei demselben key-Handler.
        pane.key_events = {}
        local groups = Device.input and Device.input.group or {}
        local key_groups = { Left = "left", Right = "right", Up = "up", Down = "down", Press = "press", Select = "select", Back = "back", PgBack = "pageback", PgFwd = "pageforward" }
        for group_name, key_name in pairs(key_groups) do
            if groups[group_name] then
                local event_name = "ForgeKey" .. group_name
                pane.key_events[event_name] = { { groups[group_name] }, event = event_name }
                pane["on" .. event_name] = function() return f:event("key", 0, 0, "", key_name, "") end
            end
        end

        local function stopTimer()
            if pane._forge_timer and UIManager.unschedule then UIManager:unschedule(pane._forge_timer) end
            pane._forge_timer = nil
        end
        local function startTimer()
            if pane._forge_closed or state.pane ~= pane or pane._forge_timer or f.interval < 0.2 or not UIManager.scheduleIn then return end
            pane._forge_timer = function()
                if pane._forge_closed or pane._forge_inactive or state.pane ~= pane then stopTimer(); return end
                f:event("timer", 0, 0, "", "", "")
                if not pane._forge_closed and not pane._forge_inactive and state.pane == pane then
                    UIManager:scheduleIn(f.interval, pane._forge_timer)
                end
            end
            UIManager:scheduleIn(f.interval, pane._forge_timer)
        end
        function pane:onDeactivate()
            self._forge_inactive = true
            stopTimer()
        end
        function pane:onActivate()
            self._forge_inactive = false
            startTimer()
        end
        function pane:onCloseWidget()
            self._forge_closed = true
            stopTimer()
            if InputContainer.onCloseWidget then return InputContainer.onCloseWidget(self) end
        end

        state.pane, f._pane = pane, pane
        startTimer()
        return pane
    end

    return f
end


return {
  id = "reading_time",
  title = "Lesezeit",
  version = "1.0.0",
  subtitle = "Ein kleiner Begleiter für deine Lesezeit.",
  symbol = "L",
  logo = "timer",
  buildPane = function(instance, context)
    local f = ForgeNew(instance, context)
    local state = f.state

    if not state.initialized then
        state.vars["Minuten"] = 0
      state.initialized = true
    end
    return f:finish({
      draw = function()
          f:clear("#fcfcf6")
          f:text('DEIN TÄGLICHER LESEMOMENT', 0, 25, 13, "#7b8d70", f:width(), false, "center")
          f:text('Lesezeit', 0, 55, 32, "#273a2e", f:width(), true, "center")
          f:text(state.vars["Minuten"], 0, 110, 64, "#273a2e", f:width(), true, "center")
          f:text('Minuten gelesen', 0, 176, 16, "#7b8d70", f:width(), false, "center")
          f:button("minus", "−10", 50, 215, 220, 58, "#dddddd", "#111111", 8)
          f:button("plus", "+10 Minuten", 330, 215, 220, 58, "#2d6552", "#ffffff", 8)
          f:text('Ein gutes Buch. Ein kleiner Anfang.', 0, 296, 14, "#7b8d70", f:width(), false, "center")
      end,
      buttons = {
        ["plus"] = function()
            state.vars["Minuten"] = (tonumber(state.vars["Minuten"]) or 0) + 10
            f:rebuild("ui")
        end,
        ["minus"] = function()
            state.vars["Minuten"] = (tonumber(state.vars["Minuten"]) or 0) + -10
            state.vars["Minuten"] = math.min(math.max(state.vars["Minuten"], 0), 10000)
            f:rebuild("ui")
        end,
      },
    }, 0)
  end,
}
