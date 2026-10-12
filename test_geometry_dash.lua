--[[--
Regression test for Geometry Dash level selection, approachable defaults, and
the 1.1.0 level editor: snapped placement, atomic storage round-trip, custom
level playback, and the editor pane contract.

Run with: lua5.1 test_geometry_dash.lua
]]--
local function class()
    local C = {}
    function C:new(value)
        value = value or {}
        setmetatable(value, { __index = C })
        if value.init then value:init() end
        return value
    end
    function C:extend(proto)
        local E = class()
        setmetatable(E, { __index = C })
        for key, value in pairs(proto or {}) do E[key] = value end
        return E
    end
    return C
end
local function install(name, value) package.preload[name] = function() return value end end
local Widget, Input = class(), class()
install("ffi/blitbuffer", { COLOR_WHITE = 1, COLOR_BLACK = 2, COLOR_DARK_GRAY = 3, COLOR_LIGHT_GRAY = 4 })
install("device", { screen = { scaleBySize = function(_, value) return value end }, input = { group = {} } })
install("ui/font", { getFace = function() return {} end })
install("ui/widget/container/centercontainer", Widget)
install("ui/widget/container/framecontainer", Widget)
install("ui/geometry", { new = function(_, value) return value end })
install("ui/gesturerange", { new = function(_, value) return value end })
install("ui/widget/horizontalspan", Widget)
install("ui/widget/container/inputcontainer", Input)
install("ui/widget/overlapgroup", Widget)
install("ui/widget/textwidget", Widget)
install("ui/widget/container/widgetcontainer", Widget)
install("gettext", function(value) return value end)
local dirty_calls, repaint_calls = {}, 0
local shown_widget
local InputDialog = Widget:extend({})
function InputDialog:getInputText() return self.input or "" end
function InputDialog:onShowKeyboard() self.keyboard_shown = true end
install("ui/widget/inputdialog", InputDialog)
install("ui/uimanager", {
    scheduleIn = function() end,
    unschedule = function() end,
    widgetRepaint = function() repaint_calls = repaint_calls + 1 end,
    setDirty = function(_, _, waveform, region) dirty_calls[#dirty_calls + 1] = { waveform = waveform, region = region } end,
    forceRePaint = function() end,
    yieldToEPDC = function() end,
    show = function(_, widget) shown_widget = widget end,
    close = function(_, widget) if shown_widget == widget then shown_widget = nil end end,
})

-- Local storage: a temporary KOReader-style data directory plus an lfs double.
local store_root = "/tmp/gd-store-test"
os.execute("rm -rf '" .. store_root .. "' && mkdir -p '" .. store_root .. "'")
install("datastorage", { getDataDir = function() return store_root end })
install("libs/libkoreader-lfs", {
    attributes = function(path) return os.rename(path, path) and {} or nil end,
    mkdir = function(path) os.execute("mkdir -p '" .. path .. "'"); return true end,
})
_G.unpack = table.unpack or unpack

local app = assert(loadfile("geometry_dash.lua"))()
assert(app.id == "geometry_dash" and app.version == "1.1.0", "Geometry Dash must publish the level editor release")
local test = app._test
local builtin = test.builtinLevelCount
local Editor, E = test.Editor, test.Editor
assert(builtin >= 4, "Geometry Dash must offer four built-in levels")
assert(test.runSpeed < 225, "The runner must be slower than the original difficulty")
assert(test.levels[1].id == "warmup" and test.levels[1].length == test.defaultLevelLength, "The first level must be a short warm-up")
for index = 1, builtin do
    local level = test.levels[index]
    assert(type(level.objects) == "table" and #level.objects > 0 and level.length > 0, "Every built-in level needs obstacles and a positive finish length")
    if index > 1 then assert(level.length > test.levels[index - 1].length, "Built-in levels must progress in length") end
end
local events = {}
local session = test.GameSession.new(function(kind, message) events[#events + 1] = { kind = kind, message = message } end)
assert(session.level_index == 1 and session.level.id == "warmup", "A new game must start on the approachable warm-up level")
session:nextLevel()
assert(session.level_index == 2 and session.level.id == "meadow" and session.paused, "Next level must reset safely before play")
session:setLevel(999)
assert(session.level_index == 1, "Invalid level selection must fall back to warm-up")
assert(#test.buildLevel(4) == #test.levels[4].objects, "The level builder must return the selected level data")

--[[--
Level editor core: snapped placement, block stacking, erase, and length control.
]]--
local draft = E.newDraft("Test-Ebene")
assert(draft.length == test.defaultLevelLength, "A new draft must start with the default length")
assert(E.snapLane(38) == test.editorSnap and E.snapLane(51) == test.editorSnap * 2, "Spikes and pads snap to the 26-unit lane grid")
assert(E.snapBlock(70) == test.editorBlockGrid and E.snapBlock(41) == 0, "Blocks snap to the 42-unit block module")
assert(E.clampLength(10) == test.editorMinLength and E.clampLength(999999) == test.editorMaxLength, "The level length must stay inside the editor bounds")
assert(#draft.objects == 0, "A new draft must be empty")

assert(Editor.apply(draft, "spike", 130) == "placed" and #draft.objects == 1, "The spike tool must place an object")
assert(draft.objects[1].kind == "spike" and draft.objects[1].x == 130, "A placed spike must sit on the snapped lane")
assert(Editor.apply(draft, "spike", 132) == "removed" and #draft.objects == 0, "Tapping the same lane again must remove the spike")
assert(Editor.apply(draft, "pad", 208) == "placed" and draft.objects[1].kind == "pad" and draft.objects[1].x == 208, "The pad tool must place a trampoline on the lane grid")
assert(Editor.apply(draft, "block", 90) == "placed", "The block tool must place a block")
local function findObject(target, kind)
    for _, object in ipairs(target.objects) do if object.kind == kind then return object end end
    return nil
end
local block = findObject(draft, "block")
assert(#draft.objects == 2 and block and block.x == 84, "Blocks must snap to the 42-unit module")
assert(draft.objects[1].x <= draft.objects[2].x, "Draft objects must stay sorted by column for stable playback")
local first_height = block.h
assert(Editor.apply(draft, "block", 95) == "raised" and block.h == first_height + test.editorBlockStep, "Tapping an existing block must raise it by one step")
for _ = 1, 20 do Editor.apply(draft, "block", 95) end
assert(block.h == test.editorBlockMax, "Blocks must stop at the editor height limit")
assert(Editor.apply(draft, "block", 95) == "limit", "A maximum-height block must report the limit")
assert(Editor.apply(draft, "erase", 95) == "removed" and #draft.objects == 1, "The erase tool must remove the block under the finger")
assert(Editor.apply(draft, "erase", 1000) == "none", "Erasing an empty spot must report no object")
assert(Editor.messageFor("placed", { tool = "spike" }) == "Spike gesetzt.", "Editor feedback must name the active tool")
assert(E.clampScroll({ length = test.editorMinLength }, -50) == 0, "The editor must not scroll before the level start")
assert(E.clampScroll({ length = test.editorMaxLength }, 99999) == E.scrollLimit({ length = test.editorMaxLength }), "Scrolling must stop at the level end")
for index = 1, test.editorMaxObjects + 5 do Editor.apply(draft, "spike", index * test.editorSnap) end
assert(#draft.objects == test.editorMaxObjects, "The editor must cap the object count per level")
assert(Editor.apply(draft, "spike", 30000) == "full", "A full level must refuse new objects")

--[[--
Storage: custom levels survive an atomic save/load round-trip and stay validated.
]]--
local small = E.newDraft("Gespeicherte Ebene")
Editor.apply(small, "spike", 104)
Editor.apply(small, "block", 168)
small.length = 1560
local saved, save_err = test.Store.save({ small })
assert(saved, "Saving a custom level must succeed: " .. tostring(save_err))
local file_check = io.open(store_root .. "/appdock_geometry_dash/levels.lua", "rb")
assert(file_check, "The editor store must live in its own data directory")
local stored_source = file_check:read("*a")
file_check:close()
assert(stored_source:find("version", 1, true) and stored_source:find("spike", 1, true), "The stored level file must be a readable versioned table")
assert(not io.open(store_root .. "/appdock_geometry_dash/levels.lua.tmp", "rb"), "An atomic save must not leave its temporary file behind")
local loaded = test.Store.load()
assert(#loaded == 1 and loaded[1].title == "Gespeicherte Ebene" and #loaded[1].objects == 2, "Custom levels must be loaded back with their objects")
assert(loaded[1].length == 1560 and loaded[1].custom == true and loaded[1].id == "custom-1", "Loaded levels must keep length, flag, and id")
assert(loaded[1].objects[1].kind == "spike" and loaded[1].objects[2].kind == "block", "Loaded objects must keep their kinds and order")

local corrupted = test.validLevel({ title = "Kaputt", objects = { { kind = "evil", x = 10 }, { kind = "spike", x = "abc" } } }, "custom-9")
assert(corrupted == nil, "A level without a single valid object must be rejected")
local mixed = test.validLevel({ title = "Gemischt", length = 99999, objects = { { kind = "spike", x = 12 }, { kind = "bogus", x = 1 } } }, "custom-3")
assert(mixed and #mixed.objects == 1 and mixed.length == test.editorMaxLength, "Invalid objects must be dropped and the length clamped")
local written = io.open(store_root .. "/appdock_geometry_dash/levels.lua", "wb")
written:write("return { version = 2, levels = { { id = 'x', objects = { { kind = 'spike', x = 1 } } } } }\n")
written:close()
assert(#test.Store.load() == 0, "An unknown store version must be ignored instead of trusted")
assert(test.Store.save({ small }), "The editor must be able to rewrite a valid store after a damaged file")

--[[--
Custom levels join the level switcher and can be played straight from the editor.
]]--
test.registerCustomLevels({ loaded[1] })
assert(#test.levels == builtin + 1, "Registering a custom level must extend the level switcher")
local custom_index = test.levelIndexById(loaded[1].id)
assert(custom_index == builtin + 1, "The custom level must be appended after the built-in levels")
local context = { dimen = { w = 600, h = 420 }, px = function(value) return value end, requestRebuild = function() end }
local instance = {}
local state = test.stateFor(instance, context)
assert(state.session, "AppDock state must create a playable session")
assert(#state.custom_levels == 1, "AppDock state must load the stored custom levels")
local editor = test.openEditor(state, context, nil)
assert(editor.open == true and editor.draft and #editor.draft.objects == 0, "Opening the editor must expose an empty draft")
Editor.apply(editor.draft, "spike", 260)
Editor.apply(editor.draft, "pad", 520)
editor.draft.title = "Aus dem Editor"
local played = test.playDraft(state, context, editor.draft)
assert(played and state.session.level.id == "custom-" .. tostring(#state.custom_levels), "Playing the draft must select the stored custom level")
assert(editor.open == false and #state.session.level.objects == 2, "Playing the draft must leave the editor and load its objects")
assert(state.session.paused, "A freshly selected custom level must start paused")
local reopened = test.currentCustomDraft(state)
assert(reopened and reopened.id == state.session.level.id and #reopened.objects == 2, "Reopening the editor must load the running custom level as draft")
assert(#test.Store.load() == 2, "Saving from the editor must append the new custom level to disk")
assert(test.playDraft(state, context, editor.draft), "Playing an existing custom level again must reuse its slot")
assert(#test.Store.load() == 2, "Replaying an existing level must not duplicate it in the catalog")
local clear_target = test.clearDraft(state, context)
assert(#clear_target.objects == 0 and clear_target.title == "Aus dem Editor", "Clearing must keep the level name but empty the objects")

-- Relative fast refresh of the editor canvas keeps the E-Ink cost local.
local editor_canvas = test.EditorCanvas:new{ width = 210, height = 126, editor = editor }
editor_canvas._origin_x, editor_canvas._origin_y = 17, 29
local canvas_layout = editor_canvas:layoutAt(17, 29)
assert(canvas_layout.scale > 0 and canvas_layout.view == test.editorViewWidth, "The editor canvas must lay out a wide level viewport")
dirty_calls, repaint_calls = {}, 0
assert(editor_canvas:onTapGeometryDashEditor({ pos = { x = 57, y = 129 } }), "A tap in the editor canvas must be handled")
assert(repaint_calls == 1 and #dirty_calls == 1 and dirty_calls[1].waveform == "fast", "Editor edits must repaint only the canvas with the fast waveform")
assert(dirty_calls[1].region.w == 210 and dirty_calls[1].region.h == 126, "The editor refresh region must match the canvas")
local world_x = editor_canvas:worldXAt(57)
assert(type(world_x) == "number" and world_x >= 0, "A canvas tap must resolve to a world column")

local arena_layout = test.levelLayout(210, 126, 17, 29)
assert(arena_layout.scale > 0, "The play arena must keep its own layout helper")
local painter = { calls = 0, paintRect = function(self) self.calls = self.calls + 1 end }
test.paintObject(painter, arena_layout, { kind = "spike", x = 10, y = 276, w = 25, h = 30 }, 0)
assert(painter.calls > 0, "Spike painting must draw visible columns")

--[[--
Pane contract: the game view exposes an editor entry, and the editor view offers
the tool palette plus its actions inside the assigned pane geometry.
]]--
local pane_instance = {}
local pane = app.buildPane(pane_instance, { dimen = { w = 600, h = 748 }, px = function(value) return value end, requestRebuild = function() end })
local function findButton(root, title)
    for _, widget in ipairs(root) do
        if widget.title == title then return widget end
    end
    return nil
end
local editor_button = findButton(pane[1], "Editor")
assert(editor_button and editor_button.width > 0, "The game pane must expose an editor button")
editor_button.callback()
assert(pane_instance.geometry_dash.editor.open, "The editor button must open the editor state")
local editor_pane = app.buildPane(pane_instance, { dimen = { w = 600, h = 748 }, px = function(value) return value end, requestRebuild = function() end })
for _, tool in ipairs(test.toolOrder) do
    assert(findButton(editor_pane[1], test.toolTitles[tool]), "The editor pane must expose the " .. tool .. " tool")
end
for _, title in ipairs({ "Speichern", "Spielen", "Zurück", "Neu", "Länge +", "Länge −", "vor ▶", "◀ zurück" }) do
    assert(findButton(editor_pane[1], title), "The editor pane must expose the " .. title .. " action")
end
local tool_button = findButton(editor_pane[1], test.toolTitles.pad)
tool_button.callback()
assert(pane_instance.geometry_dash.editor.tool == "pad", "Selecting a tool must update the editor state")
local length_button = findButton(editor_pane[1], "Länge +")
length_button.callback()
assert(pane_instance.geometry_dash.editor.draft.length == test.defaultLevelLength + test.editorLengthStep, "The length buttons must change the draft length")
local back_button = findButton(editor_pane[1], "Zurück")
back_button.callback()
assert(pane_instance.geometry_dash.editor.open == false, "The back action must return to the game view")
local compact_pane = app.buildPane(pane_instance, { dimen = { w = 600, h = 350 }, px = function(value) return value end, requestRebuild = function() end })
assert(compact_pane and compact_pane.dimen.h == 350, "Geometry Dash must also fit a compact split pane")

os.execute("rm -rf '" .. store_root .. "'")
print("geometry-dash-levels-ok")
