--[[--
A small AppDock homescreen widget example.
The host rebuilds visible store widgets every three minutes.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")

local seeded = false

local QUOTES = {
    { text = "A quiet page can hold a very loud idea.", author = "AppDock" },
    { text = "Small steps still move the story forward.", author = "AppDock" },
    { text = "Read slowly. Think deeply. Build kindly.", author = "AppDock" },
}

local function scale(value)
    return Device.screen:scaleBySize(value)
end

local function chooseQuote(state)
    if not seeded then
        math.randomseed(os.time())
        math.random()
        seeded = true
    end
    local now = os.time()
    if not state.quote_index or not state.next_change or now >= state.next_change then
        local previous = state.quote_index
        local index = math.random(1, #QUOTES)
        if previous and #QUOTES > 1 and index == previous then
            index = index % #QUOTES + 1
        end
        state.quote_index = index
        state.next_change = now + 180
    end
    return QUOTES[state.quote_index]
end

return {
    id = "quote_widget",
    version = "1.0.0",
    title = "Quote Widget",
    subtitle = "A new thought every three minutes",
    symbol = "Q",
    logo = "help",

    buildWidget = function(instance, context)
        instance.quote_widget = instance.quote_widget or {}
        local state = instance.quote_widget
        local quote = chooseQuote(state)
        local width, height = context.dimen.w, context.dimen.h
        local margin = scale(16)
        local quote_height = math.max(scale(42), height - scale(42))
        return OverlapGroup:new{
            dimen = Geom:new{ w = width, h = height },
            allow_mirroring = false,
            TextWidget:new{
                text = "Quote of the moment",
                face = Font:getFace("smallinfofont", scale(11)),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                bold = true,
                overlap_offset = { margin, scale(10) },
            },
            TextWidget:new{
                text = "“" .. quote.text .. "”",
                face = Font:getFace("cfont", scale(18)),
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold = true,
                max_width = width - 2 * margin,
                overlap_offset = { margin, scale(28) },
            },
            TextWidget:new{
                text = "— " .. quote.author,
                face = Font:getFace("smallinfofont", scale(11)),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = width - 2 * margin,
                overlap_offset = { margin, math.max(scale(60), quote_height - scale(4)) },
            },
        }
    end,
}
