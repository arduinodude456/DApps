local rebuilds = 0

local function extend(base)
    local cls = {}; cls.__index = cls
    setmetatable(cls, { __index = base })
    function cls:new(args)
        args = args or {}; setmetatable(args, self)
        if args.init then args:init() end
        return args
    end
    return cls
end

local Widget = {}; Widget.__index = Widget
function Widget:new(args) args = args or {}; setmetatable(args, self); if args.init then args:init() end; return args end
Widget.extend = extend
local InputContainer = extend(Widget)
local function generic() return extend(Widget) end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_LIGHT_GRAY = "light", COLOR_GRAY_8 = "gray", COLOR_DARK_GRAY = "dark", COLOR_BLACK = "black" }
end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, v) return v end }, input = { group = { Left = "left", Right = "right", Up = "up", Down = "down" } } }
end
package.preload["ui/font"] = function() return { getFace = function(_, name, size) return { name = name, size = size } end } end
package.preload["ui/widget/container/framecontainer"] = function() return generic() end
package.preload["ui/widget/container/centercontainer"] = function() return generic() end
package.preload["ui/geometry"] = function() return { new = function(_, a) return a end } end
package.preload["ui/gesturerange"] = function() return { new = function(_, a) return a end } end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/overlapgroup"] = function() return generic() end
package.preload["ui/widget/textwidget"] = function() return generic() end
package.preload["ui/widget/container/widgetcontainer"] = function() return generic() end
package.preload["gettext"] = function() return function(v) return v end end
package.preload["appdock_theme"] = function()
    return { getPalette = function()
        return { background="bg", surface="surface", surface_variant="variant", primary="primary", secondary="secondary", tertiary="tertiary", on_surface="ink", on_variant="muted", on_primary="onprimary", on_secondary="onsecondary", on_tertiary="ontertiary" }
    end }
end

local app = dofile("2048.lua")
assert(app.id == "game_2048" and app.version == "1.0.3" and app.logo == "other")
local instance = {}
local rebuilds = 0
local context = { dimen = { w = 600, h = 900 }, manager = { appdock = {} }, requestRebuild = function(kind) assert(kind == "ui"); rebuilds = rebuilds + 1 end }
local pane = app.buildPane(instance, context)
assert(instance.game_2048.board[1] == 2 and instance.game_2048.board[6] == 2, "new games need two tiles")
pane.on_move("left")
assert(rebuilds == 1, "a changed move must rebuild")
assert(instance.game_2048.score == 0, "a non-merge move must not score")
instance.game_2048.board = { 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
pane.on_move("left")
assert(instance.game_2048.board[1] == 4 and instance.game_2048.score == 4, "equal tiles must merge and score")
assert(rebuilds == 2, "a merge must rebuild")
local found_theme_color = false
local function scan(widget)
    if type(widget) ~= "table" then return end
    if widget.background == "primary" or widget.background == "surface" or widget.background == "secondary" or widget.background == "tertiary" then found_theme_color = true end
    for _, child in ipairs(widget) do scan(child) end
end
scan(pane)
assert(found_theme_color, "tile colors must come from the active theme palette")
local board = pane[1][4]
assert(#board == 16, "the board must contain all sixteen tile widgets")
assert(board[1].overlap_offset[1] == 0 and board[1].overlap_offset[2] == 0, "the first tile must start at the board origin")
assert(board[2].overlap_offset[1] > 0 and board[5].overlap_offset[2] > 0, "each board tile must own its grid offset")
local before_swipe = rebuilds
pane:onSwipe2048(nil, { direction = "west" })
assert(rebuilds == before_swipe + 1, "a west swipe must move the board through the standard move path")
assert(pane:onSwipe2048(nil, { direction = "unknown" }) == false, "unknown swipes must not consume a move")
instance.game_2048.over = true
local before = rebuilds
local pane_over = app.buildPane(instance, context)
assert(pane_over and rebuilds == before, "game-over rendering must not rebuild by itself")
print("2048 DApp test: OK")
