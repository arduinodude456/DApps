--[[--
Open-Meteo weather widget for AppDock.
The location is configured in the source and can be changed by developers/users
before installation. It fetches current conditions over HTTPS and keeps the
last successful result in the widget instance.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local _ = require("gettext")

local MAX_RESPONSE_BYTES = 96 * 1024
local CACHE_SECONDS = 180
local CONNECT_TIMEOUT = 10
local REQUEST_TIMEOUT = 20

-- Change these three values to the desired location before installing.
local LOCATION = {
    name = "Berlin",
    latitude = 52.52,
    longitude = 13.405,
}

local WEATHER_CODES = {
    [0] = "Clear sky", [1] = "Mainly clear", [2] = "Partly cloudy", [3] = "Overcast",
    [45] = "Fog", [48] = "Rime fog", [51] = "Light drizzle", [53] = "Drizzle",
    [55] = "Heavy drizzle", [56] = "Freezing drizzle", [57] = "Heavy freezing drizzle",
    [61] = "Light rain", [63] = "Rain", [65] = "Heavy rain", [66] = "Freezing rain",
    [67] = "Heavy freezing rain", [71] = "Light snow", [73] = "Snow", [75] = "Heavy snow",
    [77] = "Snow grains", [80] = "Light showers", [81] = "Showers", [82] = "Heavy showers",
    [85] = "Light snow showers", [86] = "Heavy snow showers", [95] = "Thunderstorm",
    [96] = "Thunderstorm with hail", [99] = "Heavy thunderstorm with hail",
}

local function scale(value)
    return Device.screen:scaleBySize(value)
end

local function clampNumber(value, low, high)
    value = tonumber(value)
    if not value then return nil end
    return math.max(low, math.min(high, value))
end

local function formatNumber(value, decimals)
    value = tonumber(value)
    if not value then return "—" end
    return string.format("%." .. tostring(decimals or 0) .. "f", value)
end

local function validLocation()
    return type(LOCATION.name) == "string" and LOCATION.name ~= ""
        and clampNumber(LOCATION.latitude, -90, 90)
        and clampNumber(LOCATION.longitude, -180, 180)
end

local function fetchWeather()
    if not validLocation() then return nil, "Invalid weather location." end
    local ok_url, url = pcall(require, "socket.url")
    if not ok_url or not url then return nil, "URL support is unavailable." end
    local latitude = formatNumber(LOCATION.latitude, 4)
    local longitude = formatNumber(LOCATION.longitude, 4)
    local endpoint = "https://api.open-meteo.com/v1/forecast?latitude=" .. url.escape(latitude)
        .. "&longitude=" .. url.escape(longitude)
        .. "&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
        .. "&temperature_unit=celsius&wind_speed_unit=kmh&timezone=auto&forecast_days=1"

    local ok_https, https = pcall(require, "ssl.https")
    local ok_socket, socket = pcall(require, "socket")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_util, socketutil = pcall(require, "socketutil")
    if not ok_https or not ok_socket or not ok_ltn12 or not ok_util then
        return nil, "HTTPS support is unavailable."
    end

    local chunks, total = {}, 0
    local function limitedSink(chunk, sink_error)
        if sink_error then return nil, sink_error end
        if chunk then
            total = total + #chunk
            if total > MAX_RESPONSE_BYTES then return nil, "Response is too large." end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end

    socketutil:set_timeout(CONNECT_TIMEOUT, REQUEST_TIMEOUT)
    local ok_request, code = pcall(function()
        return socket.skip(1, https.request{
            url = endpoint,
            method = "GET",
            sink = limitedSink,
            headers = {
                ["accept"] = "application/json",
                ["user-agent"] = "AppDock-WeatherWidget/1.0",
            },
        })
    end)
    socketutil:reset_timeout()
    if not ok_request or code ~= 200 then return nil, "Open-Meteo request failed." end

    local ok_json, JSON = pcall(require, "json")
    if not ok_json or not JSON then return nil, "JSON support is unavailable." end
    local ok_decode, decoded = pcall(JSON.decode, table.concat(chunks), JSON.decode.simple)
    if not ok_decode or type(decoded) ~= "table" or type(decoded.current) ~= "table" then
        return nil, "Open-Meteo returned an invalid response."
    end
    local current = decoded.current
    local temperature = tonumber(current.temperature_2m)
    local humidity = tonumber(current.relative_humidity_2m)
    local code_number = tonumber(current.weather_code)
    local wind = tonumber(current.wind_speed_10m)
    if not temperature or not humidity or not code_number or not wind then
        return nil, "Open-Meteo returned incomplete weather data."
    end
    return {
        temperature = temperature,
        humidity = humidity,
        weather_code = code_number,
        weather = WEATHER_CODES[code_number] or "Weather update",
        wind = wind,
        is_day = current.is_day == 1,
        fetched_at = os.time(),
    }
end

local function stateFor(instance)
    instance.weather_widget = instance.weather_widget or {
        location = LOCATION.name,
        status = "Not fetched yet",
    }
    return instance.weather_widget
end

local function loadIfNeeded(state)
    local now = os.time()
    if state.data and state.fetched_at and now - state.fetched_at < CACHE_SECONDS then return end
    local data, err = fetchWeather()
    if data then
        state.data = data
        state.fetched_at = now
        state.status = "Updated " .. os.date("%H:%M", now)
    elseif not state.data then
        state.status = err or "Weather unavailable."
    else
        state.status = "Using last update"
    end
    state.next_fetch = now + CACHE_SECONDS
end

return {
    id = "weather_widget",
    version = "1.0.0",
    title = "Weather Widget",
    subtitle = "Current conditions from Open-Meteo",
    symbol = "W",
    logo = "weather",

    buildWidget = function(instance, context)
        local state = stateFor(instance)
        loadIfNeeded(state)
        local width, height = context.dimen.w, context.dimen.h
        local margin = scale(16)
        local data = state.data
        local headline = data and (formatNumber(data.temperature, 1) .. " °C") or "Weather unavailable"
        local details = data and (data.weather .. "  ·  " .. formatNumber(data.wind, 0) .. " km/h") or state.status
        local footer = data and ("Humidity " .. formatNumber(data.humidity, 0) .. "%  ·  " .. LOCATION.name) or LOCATION.name
        return OverlapGroup:new{
            dimen = Geom:new{ w = width, h = height },
            allow_mirroring = false,
            TextWidget:new{
                text = "Open-Meteo  ·  " .. (data and (data.is_day and "Day" or "Night") or "Offline"),
                face = Font:getFace("smallinfofont", scale(11)),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                bold = true,
                max_width = width - 2 * margin,
                overlap_offset = { margin, scale(10) },
            },
            TextWidget:new{
                text = headline,
                face = Font:getFace("cfont", scale(20)),
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold = true,
                max_width = width - 2 * margin,
                overlap_offset = { margin, scale(28) },
            },
            TextWidget:new{
                text = details,
                face = Font:getFace("smallinfofont", scale(11)),
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = width - 2 * margin,
                overlap_offset = { margin, math.max(scale(58), height - scale(38)) },
            },
            TextWidget:new{
                text = footer,
                face = Font:getFace("smallinfofont", scale(10)),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = width - 2 * margin,
                overlap_offset = { margin, math.max(scale(76), height - scale(18)) },
            },
        }
    end,
}
