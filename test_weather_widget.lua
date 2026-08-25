local now = 1000
local requests = 0
local real_os_time = os.time
os.time = function() return now end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = "black", COLOR_DARK_GRAY = "dark" }
end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, value) return value end } }
end
package.preload["ui/font"] = function()
    return { getFace = function(_, name, size) return { name = name, size = size } end }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, args) return args end }
end
package.preload["ui/widget/overlapgroup"] = function()
    local Group = {}
    Group.__index = Group
    function Group:new(args) setmetatable(args or {}, self); return args end
    return Group
end
package.preload["ui/widget/textwidget"] = function()
    local Text = {}
    Text.__index = Text
    function Text:new(args) setmetatable(args or {}, self); return args end
    return Text
end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["socket.url"] = function() return { escape = function(value) return value end } end
package.preload["socket"] = function()
    return { skip = function(_, first, second) return second end }
end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end }
end
package.preload["ltn12"] = function() return {} end
package.preload["ssl.https"] = function()
    return {
        request = function(args)
            requests = requests + 1
            args.sink('{"current":{"temperature_2m":21.5,"relative_humidity_2m":48,"weather_code":1,"wind_speed_10m":12,"is_day":1}}')
            args.sink(nil)
            return 1, 200
        end,
    }
end
package.preload["json"] = function()
    local JSON = { decode = {} }
    JSON.decode.simple = {}
    setmetatable(JSON.decode, { __call = function() return { current = { temperature_2m = 21.5, relative_humidity_2m = 48, weather_code = 1, wind_speed_10m = 12, is_day = 1 } } end })
    return JSON
end

local widget = dofile("weather_widget.lua")
assert(widget.id == "weather_widget" and widget.version == "1.0.1")
local instance = {}
local first = widget.buildWidget(instance, { dimen = { w = 600, h = 110 } })
assert(requests == 1, "The first widget build must fetch weather data")
assert(first.dimen.w == 600 and first.dimen.h == 110, "The widget must stay inside context.dimen")
assert(instance.weather_widget.data.temperature == 21.5, "The decoded current temperature must be cached")
assert(instance.weather_widget.next_fetch == 1180, "The weather cache must expire after 180 seconds")

now = 1179
widget.buildWidget(instance, { dimen = { w = 600, h = 110 } })
assert(requests == 1, "The weather widget must use its cache before expiry")

now = 1180
widget.buildWidget(instance, { dimen = { w = 600, h = 110 } })
assert(requests == 2, "The weather widget must refresh at the three-minute boundary")

os.time = real_os_time
print("Weather widget test: OK")
