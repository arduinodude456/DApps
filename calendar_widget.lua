-- Calendar Widget: displays upcoming events from the local Calendar DApp store only.

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")

local STORE_FILE = DataStorage:getDataDir() .. "/appdock_calendar/events.lua"
local MAX_EVENTS = 3
local MAX_TITLE_BYTES = 96

local function scale(value) return Device.screen:scaleBySize(value) end
local function trim(value) return type(value) == "string" and (value:match("^%s*(.-)%s*$") or "") or "" end
local function validDate(key) return type(key) == "string" and key:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil end
local function todayKey() return os.date("%Y-%m-%d") end
local function displayDate(key)
    local year, month, day = key:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    return year and string.format("%s.%s.", day, month) or key
end
local function localEvents()
    local chunk = loadfile(STORE_FILE)
    if not chunk then return {} end
    setfenv(chunk, {})
    local ok, store = pcall(chunk)
    if not ok or type(store) ~= "table" or store.version ~= 1 or type(store.events) ~= "table" then return {} end
    local today, events = todayKey(), {}
    for _, event in ipairs(store.events) do
        local title = type(event) == "table" and trim(event.title):sub(1, MAX_TITLE_BYTES) or ""
        if type(event) == "table" and validDate(event.date) and event.date >= today and title ~= "" then
            events[#events + 1] = { date = event.date, title = title, id = tonumber(event.id) or 0 }
        end
    end
    table.sort(events, function(a, b) if a.date == b.date then return a.id < b.id end return a.date < b.date end)
    while #events > MAX_EVENTS do table.remove(events) end
    return events
end

return {
    id = "calendar_widget",
    version = "1.0.0",
    title = "Calendar",
    subtitle = "Upcoming local appointments",
    symbol = "K",
    logo = "calendar",
    buildWidget = function(instance, context)
        local width, height, margin = context.dimen.w, context.dimen.h, scale(16)
        local events = localEvents()
        local parts = {
            TextWidget:new{ text = _("Calendar"), face = Font:getFace("smallinfofont", scale(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, bold = true, overlap_offset = { margin, scale(10) } },
        }
        if #events == 0 then
            parts[#parts + 1] = TextWidget:new{ text = _("No upcoming local appointments."), face = Font:getFace("smallinfofont", scale(14)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, scale(37) } }
        else
            local row_h = math.max(scale(20), math.floor((height - scale(30)) / #events))
            for index, event in ipairs(events) do
                parts[#parts + 1] = TextWidget:new{ text = displayDate(event.date) .. "  " .. event.title, face = Font:getFace("smallinfofont", scale(13)), fgcolor = Blitbuffer.COLOR_BLACK, bold = index == 1, max_width = width - 2 * margin, overlap_offset = { margin, scale(29) + (index - 1) * row_h } }
            end
        end
        return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(parts) }
    end,
    _test = { localEvents = localEvents, displayDate = displayDate, validDate = validDate },
}
