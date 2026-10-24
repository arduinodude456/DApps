--[[--
Gallery for AppDock.

An image-only photo gallery DApp, styled after Google Photos: search bar,
"Photos" timeline grouped by day, "Albums" (folders that contain images), a
navigation rail (landscape) or tab bar (portrait), multi-select with delete and
a full-screen swipe viewer.  Single Lua file (AppStore installs one file per
DApp); it never uses the network and the only write operation is a confirmed
"Delete" inside /mnt/onboard.  Image files handed over by the file manager
(openFile) open directly in the viewer.
--]]--
local Blitbuffer = require("ffi/blitbuffer")
local ok_dialogs, AppDockDialogs = pcall(require, "appdock_dialogs")
if not ok_dialogs or type(AppDockDialogs) ~= "table" then AppDockDialogs = {} end
local ButtonDialog = AppDockDialogs.ButtonDialog or require("ui/widget/buttondialog")
local ConfirmBox = AppDockDialogs.ConfirmBox or require("ui/widget/confirmbox")
local InfoMessage = AppDockDialogs.InfoMessage or require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local ok_theme, Theme = pcall(require, "appdock_theme")
local ok_keyboard, AppDockKeyboard = pcall(require, "appdock_keyboard")
if not ok_keyboard then AppDockKeyboard = nil end
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = require("lfs") end

local Screen = Device.screen
local Gallery = {}
Gallery.__index = Gallery

local APP_ID = "gallery"
local SETTINGS_KEY = "appdock_gallery_v1"
local STORAGE_ROOT = "/mnt/onboard"
-- Formats KOReader's image engine can decode reliably.
local IMAGE_EXTENSIONS = { jpg=true, jpeg=true, png=true, gif=true, webp=true, bmp=true, tif=true, tiff=true, svg=true }
local SCAN_NODE_LIMIT = 30000
local SCAN_IMAGE_LIMIT = 6000
local SCAN_DEPTH_LIMIT = 14
local TARGET_TILE = 150 -- density independent size a photo tile aims for

---------------------------------------------------------------------------
-- Look & feel
---------------------------------------------------------------------------
local function scale(value) return Screen:scaleBySize(value) end
local function color(r, g, b, grayscale)
    if Screen:isColorEnabled() then return Blitbuffer.ColorRGB32(r, g, b, 0xFF) end
    return grayscale
end
local PALETTE = {
    background = color(250, 248, 255, Blitbuffer.COLOR_WHITE),
    surface = color(255, 251, 247, Blitbuffer.COLOR_WHITE),
    surface_alt = color(246, 237, 231, Blitbuffer.COLOR_LIGHT_GRAY),
    primary = color(255, 224, 199, Blitbuffer.COLOR_GRAY_8),
    secondary = color(237, 225, 215, Blitbuffer.COLOR_LIGHT_GRAY),
    on_primary = color(91, 54, 32, Blitbuffer.COLOR_DARK_GRAY),
    on_surface = color(42, 35, 31, Blitbuffer.COLOR_BLACK),
    on_variant = color(104, 91, 83, Blitbuffer.COLOR_DARK_GRAY),
    outline = color(218, 204, 194, Blitbuffer.COLOR_LIGHT_GRAY),
}
local function applyTheme(context)
    local palette = context and type(context.palette) == "table" and context.palette or nil
    if not palette and ok_theme and type(Theme) == "table" and type(Theme.getPalette) == "function" then
        local appdock = context and context.manager and context.manager.appdock
        local ok, result = pcall(Theme.getPalette, appdock)
        if ok and type(result) == "table" then palette = result end
    end
    if not palette then return end
    PALETTE.background = palette.background or PALETTE.background
    PALETTE.surface = palette.surface or PALETTE.surface
    PALETTE.primary = palette.primary or PALETTE.primary
    PALETTE.secondary = palette.secondary or PALETTE.secondary
    PALETTE.on_primary = palette.on_primary or PALETTE.on_primary
    PALETTE.on_surface = palette.on_surface or PALETTE.on_surface
    PALETTE.on_variant = palette.on_variant or palette.on_surface or PALETTE.on_variant
    PALETTE.outline = palette.outline or palette.surface_variant or palette.on_variant or PALETTE.outline
    PALETTE.surface_alt = palette.surface_alt or palette.surface_variant or palette.secondary or PALETTE.surface_alt
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
local function basename(path) return path and path:match("([^/]+)$") or path end
local function parentPath(path)
    if not path or path == "/" then return "/" end
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return "/" end
    return parent
end
local function isInside(path, root)
    return type(path) == "string" and (path == root or path:sub(1, #root + 1) == root .. "/")
end
local function validStoragePath(path)
    return type(path) == "string" and isInside(path, STORAGE_ROOT)
        and not path:find("/%.%./") and not path:find("/%.%.$")
end
local function humanSize(size)
    size = tonumber(size) or 0
    if size < 1024 then return string.format("%d B", size) end
    if size < 1024 * 1024 then return string.format("%.1f KB", size / 1024) end
    if size < 1024 * 1024 * 1024 then return string.format("%.1f MB", size / (1024 * 1024)) end
    return string.format("%.1f GB", size / (1024 * 1024 * 1024))
end
local function extension(path)
    return path and path:lower():match("%.([^./]+)$") or ""
end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function lstat(path)
    if lfs.symlinkattributes then return lfs.symlinkattributes(path) end
    return lfs.attributes(path)
end
local function displayPath(path)
    if not path or path == STORAGE_ROOT then return _("Internal storage") end
    if not isInside(path, STORAGE_ROOT) then return path end
    return _("Internal storage") .. " › " .. (path:sub(#STORAGE_ROOT + 2):gsub("/", " › "))
end

-- Dates: noon of the day, so DST shifts never break day differences.
local function dayStart(timestamp)
    local t = os.date("*t", tonumber(timestamp) or 0)
    return os.time{ year = t.year, month = t.month, day = t.day, hour = 12 }
end
local function dayLabel(timestamp)
    timestamp = tonumber(timestamp) or 0
    if timestamp <= 0 then return _("Unknown date") end
    local days = math.floor((dayStart(os.time()) - dayStart(timestamp)) / 86400 + 0.5)
    if days == 0 then return _("Today") end
    if days == 1 then return _("Yesterday") end
    if days > 1 and days < 7 then return os.date("%A", timestamp) end
    local now_year = os.date("%Y")
    if os.date("%Y", timestamp) == now_year then return os.date("%d. %b", timestamp) end
    return os.date("%d. %b %Y", timestamp)
end
local function fullDate(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp <= 0 then return "" end
    local ok, text = pcall(os.date, "%Y-%m-%d %H:%M", timestamp)
    return ok and text or ""
end

---------------------------------------------------------------------------
-- File operations (delete only, confined to STORAGE_ROOT)
---------------------------------------------------------------------------
local function removeImage(path)
    if not validStoragePath(path) or path == STORAGE_ROOT then
        return false, _("This item cannot be deleted.")
    end
    local attributes = lstat(path)
    if not attributes then return false, _("The item no longer exists.") end
    if attributes.mode ~= "file" and attributes.mode ~= "link" then
        return false, _("This item cannot be deleted.")
    end
    if os.remove(path) then return true end
    return false, _("The file could not be deleted.")
end

local function diskUsage(path)
    local ok_util, util = pcall(require, "util")
    if not ok_util or type(util) ~= "table" or type(util.diskUsage) ~= "function" then return nil end
    local ok, usage = pcall(util.diskUsage, path)
    if not ok or type(usage) ~= "table" then return nil end
    local total = tonumber(usage.total or usage.size)
    local available = tonumber(usage.available or usage.free or usage.avail)
    local used = tonumber(usage.used) or (total and available and (total - available))
    if not total or total <= 0 or not used then return nil end
    return { total = total, used = clamp(used, 0, total) }
end

---------------------------------------------------------------------------
-- Widget helpers
---------------------------------------------------------------------------
local function emptySizedWidget(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end
local function hspan(width) return HorizontalSpan:new{ width = width } end
local function vspan(height) return VerticalSpan:new{ width = height } end
local function label(text, size, fg, bold, max_width, font)
    return TextWidget:new{
        text = text or "", face = Font:getFace(font or "smallinfofont", size),
        fgcolor = fg or PALETTE.on_surface, bold = bold == true, max_width = max_width, padding = 0,
    }
end
local function stack(width, height, entries)
    local group = OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false }
    for _i, item in ipairs(entries) do
        item.widget.overlap_offset = { item.x, item.y }
        table.insert(group, item.widget)
    end
    return group
end
local function rowOf(margin, gap, widgets)
    local row = HorizontalGroup:new{ align = "center", hspan(margin) }
    for index, widget in ipairs(widgets) do
        if index > 1 then table.insert(row, hspan(gap)) end
        table.insert(row, widget)
    end
    return row
end
local function centeredText(width, height, text, size, fg, bold)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, label(text, size, fg, bold, width - scale(16)) }
end
local function magnifier(size, fg)
    local ring = math.floor(size * .72)
    local thickness = math.max(scale(2), math.floor(size * .11))
    return OverlapGroup:new{
        dimen = Geom:new{ w = size, h = size }, allow_mirroring = false,
        FrameContainer:new{ width = ring, height = ring, padding = 0, bordersize = thickness, color = fg, radius = math.floor(ring / 2), emptySizedWidget(ring - 2 * thickness, ring - 2 * thickness) },
        FrameContainer:new{ width = thickness * 2, height = thickness * 2, padding = 0, bordersize = 0, radius = thickness, background = fg, emptySizedWidget(thickness * 2, thickness * 2), overlap_offset = { ring - thickness, ring - thickness } },
    }
end
local function checkbox(size, checked)
    local border = scale(2)
    return FrameContainer:new{
        width = size, height = size, padding = 0, bordersize = border,
        color = checked and PALETTE.on_primary or PALETTE.on_variant, radius = math.floor(size * .25),
        background = checked and PALETTE.on_primary or PALETTE.surface,
        emptySizedWidget(size - 2 * border, size - 2 * border),
    }
end

-- A thumbnail that never takes the screen down if a file is broken.
local function thumbnail(entry, size)
    local ok, widget = pcall(function()
        return ImageWidget:new{ file = entry.path, width = size, height = size, scale_factor = 0, file_do_cache = true, alpha = false }
    end)
    if ok and widget then
        local size_ok, dimen = pcall(function() return widget:getSize() end)
        if size_ok and dimen and dimen.w > 0 and dimen.h > 0 then return widget end
    end
    local ext = extension(entry.path)
    return label(ext ~= "" and ext:upper() or "IMG", 14, PALETTE.on_variant, true, size - scale(4))
end

---------------------------------------------------------------------------
-- Touch widgets
---------------------------------------------------------------------------
local Tappable = InputContainer:extend{ callback = nil, hold_callback = nil, width = nil, height = nil, dimen = nil }
function Tappable:setHitArea()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapAppDock = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if self.hold_callback then
        self.ges_events.HoldAppDock = { GestureRange:new{ ges = "hold", range = self.dimen } }
    end
end
function Tappable:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    return InputContainer.paintTo(self, bb, x, y)
end
function Tappable:onTapAppDock() if self.callback then self.callback() end return true end
function Tappable:onHoldAppDock() if self.hold_callback then self.hold_callback() end return true end

local Button = Tappable:extend{ title = "", font_size = 17, background = nil, foreground = nil, flat = false, active = false, square = false }
function Button:init()
    self:setHitArea()
    local fg = self.foreground or PALETTE.on_surface
    local bg = self.background or PALETTE.surface
    if self.active then bg, fg = PALETTE.primary, PALETTE.on_primary end
    local border = self.flat and 0 or scale(1)
    local inner_w, inner_h = self.width - 2 * border, self.height - 2 * border
    local frame_bg = bg
    if self.flat then frame_bg = self.active and bg or self.background end
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = border, color = PALETTE.outline,
        radius = math.min(scale(24), math.floor(self.height / 2)), background = frame_bg,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, label(self.title, self.font_size, fg, true, inner_w - scale(8)) },
    }
end

local SearchBar = Tappable:extend{ text = "", active = false }
function SearchBar:init()
    self:setHitArea()
    local border = scale(1)
    local inner_w, inner_h = self.width - 2 * border, self.height - 2 * border
    local icon_size = scale(20)
    local text = label(self.text, 18, self.active and PALETTE.on_surface or PALETTE.on_variant, self.active, self.width - scale(72))
    local text_h = text:getSize().h
    self[1] = FrameContainer:new{
        width = self.width, height = self.height, padding = 0, bordersize = border, color = PALETTE.outline,
        radius = math.floor(self.height / 2), background = PALETTE.surface,
        stack(inner_w, inner_h, {
            { widget = magnifier(icon_size, PALETTE.on_variant), x = scale(18), y = math.floor((inner_h - icon_size) / 2) },
            { widget = text, x = scale(52), y = math.floor((inner_h - text_h) / 2) },
        }),
    }
end

-- One photo in the grid.
local PhotoTile = Tappable:extend{ entry = nil, selecting = false, selected = false }
function PhotoTile:init()
    self:setHitArea()
    local size = self.width
    local border = self.selected and scale(3) or scale(1)
    local inner = size - 2 * border
    local frame = FrameContainer:new{
        width = size, height = size, padding = 0, bordersize = border,
        color = self.selected and PALETTE.on_primary or PALETTE.outline,
        background = PALETTE.surface_alt,
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = inner }, thumbnail(self.entry, inner) },
    }
    local items = { { widget = frame, x = 0, y = 0 } }
    if self.selecting then
        table.insert(items, { widget = checkbox(scale(22), self.selected), x = scale(6), y = scale(6) })
    end
    self.layout = { gallery_tile = true, name = self.entry and self.entry.name }
    self[1] = stack(size, size, items)
end

-- One album (a folder that contains images).
local AlbumCard = Tappable:extend{ album = nil }
function AlbumCard:init()
    self:setHitArea()
    local width, height = self.width, self.height
    local album = self.album
    local frame = FrameContainer:new{
        width = width, height = width, padding = 0, bordersize = scale(1), color = PALETTE.outline,
        radius = scale(14), background = PALETTE.surface_alt,
        CenterContainer:new{ dimen = Geom:new{ w = width - 2 * scale(1), h = width - 2 * scale(1) }, thumbnail(album.cover, width - 2 * scale(1)) },
    }
    local title = label(album.name, 18, PALETTE.on_surface, true, width - scale(8))
    local subtitle = label(string.format(_("%d photos"), album.count), 14, PALETTE.on_variant, false, width - scale(8))
    local title_h = title:getSize().h
    self.layout = { gallery_album = true, name = album.name }
    self[1] = stack(width, height, {
        { widget = frame, x = 0, y = 0 },
        { widget = title, x = scale(4), y = width + scale(6) },
        { widget = subtitle, x = scale(4), y = width + scale(6) + title_h },
    })
end

local function messageCard(width, height, title, subtitle)
    local border = scale(1)
    local inner_w, inner_h = width - 2 * border, height - 2 * border
    local main = label(title, 18, PALETTE.on_surface, true, inner_w - scale(24))
    local sub = label(subtitle or "", 14, PALETTE.on_variant, false, inner_w - scale(24))
    local main_size, sub_size = main:getSize(), sub:getSize()
    local y = math.max(0, math.floor((inner_h - main_size.h - sub_size.h) / 2))
    return FrameContainer:new{
        width = width, height = height, padding = 0, bordersize = border, color = PALETTE.outline, radius = scale(16), background = PALETTE.surface,
        stack(inner_w, inner_h, {
            { widget = main, x = math.floor((inner_w - main_size.w) / 2), y = y },
            { widget = sub, x = math.floor((inner_w - sub_size.w) / 2), y = y + main_size.h },
        }),
    }
end
local function titleBlock(width, height, title, subtitle)
    local main = label(title, 20, PALETTE.on_surface, true, width, "cfont")
    local sub = label(subtitle, 14, PALETTE.on_variant, false, width)
    local main_h, sub_h = main:getSize().h, sub:getSize().h
    local y = math.max(0, math.floor((height - main_h - sub_h) / 2))
    return stack(width, height, { { widget = main, x = 0, y = y }, { widget = sub, x = 0, y = y + main_h } })
end

---------------------------------------------------------------------------
-- Full-screen viewer
---------------------------------------------------------------------------
local Viewer = InputContainer:extend{ entries = nil, index = 1, show_bar = true, on_close = nil }
function Viewer:init()
    local size = Screen:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.covers_fullscreen = true
    self.ges_events = {
        TapViewer = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeViewer = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = {
            CloseViewer = { { "Back" } },
            NextImage = { { "Right" }, { "RPgFwd" } },
            PrevImage = { { "Left" }, { "RPgBack" } },
        }
    end
    self:_rebuild()
end
function Viewer:_freeImage()
    if self.image_widget and self.image_widget.free then pcall(function() self.image_widget:free() end) end
    self.image_widget = nil
end
function Viewer:_rebuild()
    self:_freeImage()
    local entry = self.entries[self.index]
    local w, h = self.dimen.w, self.dimen.h
    local bar_h = scale(64)
    local items = {}
    local ok, image = pcall(function()
        return ImageWidget:new{ file = entry.path, width = w, height = h, scale_factor = 0, file_do_cache = false, alpha = false }
    end)
    if ok and image then
        self.image_widget = image
        table.insert(items, { widget = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, image }, x = 0, y = 0 })
    else
        table.insert(items, { widget = centeredText(w, h, _("This image cannot be shown."), 20, PALETTE.on_surface, true), x = 0, y = 0 })
    end
    if self.show_bar then
        local counter = label(string.format("%d / %d", self.index, #self.entries), 16, PALETTE.on_variant, false, scale(120))
        local title_w = w - scale(64) - counter:getSize().w - scale(40)
        local title = label(entry.name, 19, PALETTE.on_surface, true, title_w)
        local top = FrameContainer:new{
            width = w, height = bar_h, padding = 0, bordersize = 0, background = PALETTE.surface,
            stack(w, bar_h, {
                { widget = label("‹", 34, PALETTE.on_surface, true), x = scale(22), y = math.floor((bar_h - label("‹", 34, nil, true):getSize().h) / 2) },
                { widget = title, x = scale(64), y = math.floor((bar_h - title:getSize().h) / 2) },
                { widget = counter, x = w - counter:getSize().w - scale(16), y = math.floor((bar_h - counter:getSize().h) / 2) },
            }),
        }
        local caption_text = table.concat({ fullDate(entry.modified), humanSize(entry.size), displayPath(parentPath(entry.path)) }, "  ·  ")
        local caption = label(caption_text, 15, PALETTE.on_variant, false, w - scale(32))
        local bottom_h = scale(44)
        local bottom = FrameContainer:new{
            width = w, height = bottom_h, padding = 0, bordersize = 0, background = PALETTE.surface,
            stack(w, bottom_h, { { widget = caption, x = scale(16), y = math.floor((bottom_h - caption:getSize().h) / 2) } }),
        }
        table.insert(items, { widget = top, x = 0, y = 0 })
        table.insert(items, { widget = bottom, x = 0, y = h - bottom_h })
    end
    self[1] = FrameContainer:new{
        width = w, height = h, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE,
        stack(w, h, items),
    }
end
function Viewer:_refresh()
    self:_rebuild()
    UIManager:setDirty(self, function() return "partial", self.dimen end)
end
function Viewer:_step(delta)
    local target = self.index + delta
    if target < 1 or target > #self.entries then return end
    self.index = target
    self:_refresh()
end
function Viewer:_close()
    UIManager:close(self)
    if self.on_close then self.on_close(self.index) end
end
function Viewer:onCloseWidget() self:_freeImage() end
function Viewer:onCloseViewer() self:_close(); return true end
function Viewer:onNextImage() self:_step(1); return true end
function Viewer:onPrevImage() self:_step(-1); return true end
function Viewer:onTapViewer(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    local w = self.dimen.w
    if pos.y < scale(64) and pos.x < w * 0.25 then self:_close(); return true end
    if pos.x < w * 0.25 then self:_step(-1)
    elseif pos.x > w * 0.75 then self:_step(1)
    else
        self.show_bar = not self.show_bar
        self:_refresh()
    end
    return true
end
function Viewer:onSwipeViewer(_arg, ges)
    local direction = ges and ges.direction
    if direction == "west" then self:_step(1)
    elseif direction == "east" then self:_step(-1)
    elseif direction == "south" then self:_close() end
    return true
end

---------------------------------------------------------------------------
-- State and preferences
---------------------------------------------------------------------------
function Gallery:_preferences(context)
    local preferences = self._preferences_cache
    if not preferences then
        preferences = {}
        if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
            local ok, saved = pcall(G_reader_settings.readSetting, G_reader_settings, SETTINGS_KEY, {})
            if ok and type(saved) == "table" then
                preferences.newest_first = saved.newest_first
                preferences.show_hidden = saved.show_hidden
            end
        end
        self._preferences_cache = preferences
    end
    preferences.newest_first = preferences.newest_first ~= false
    preferences.show_hidden = preferences.show_hidden == true
    return preferences
end
function Gallery:_savePreferences(context)
    local preferences = self:_preferences(context)
    if G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
        pcall(G_reader_settings.saveSetting, G_reader_settings, SETTINGS_KEY, {
            newest_first = preferences.newest_first, show_hidden = preferences.show_hidden,
        })
    end
end
function Gallery:_ensureState(instance)
    instance.gallery = instance.gallery or { tab = "photos" }
    local state = instance.gallery
    state.tab = state.tab or "photos"
    state.query = state.query or ""
    state.page = state.page or 1
    state.selecting = state.selecting == true
    state.selected = type(state.selected) == "table" and state.selected or {}
    return state
end

---------------------------------------------------------------------------
-- Scanning storage for images
---------------------------------------------------------------------------
local function sortImages(images, newest_first)
    table.sort(images, function(a, b)
        if a.modified ~= b.modified then
            if newest_first then return a.modified > b.modified end
            return a.modified < b.modified
        end
        return a.path < b.path
    end)
end

function Gallery:_scan(preferences)
    local images, albums, by_folder = {}, {}, {}
    local nodes, truncated = 0, false
    local show_hidden = preferences.show_hidden == true
    local function visit(path, depth)
        if truncated or depth > SCAN_DEPTH_LIMIT then return end
        local ok, iterator, directory_object = pcall(lfs.dir, path)
        if not ok or not iterator then return end
        for name in iterator, directory_object do
            if truncated then return end
            if name ~= "." and name ~= ".." and (show_hidden or name:sub(1, 1) ~= ".") then
                nodes = nodes + 1
                if nodes > SCAN_NODE_LIMIT or #images >= SCAN_IMAGE_LIMIT then truncated = true; return end
                local fullpath = path .. "/" .. name
                local attributes = lstat(fullpath)
                if attributes and attributes.mode == "directory" then
                    visit(fullpath, depth + 1)
                elseif attributes and attributes.mode == "file" and IMAGE_EXTENSIONS[extension(name)] then
                    local entry = {
                        name = name, path = fullpath, folder = path,
                        size = tonumber(attributes.size) or 0,
                        modified = tonumber(attributes.modification) or 0,
                    }
                    table.insert(images, entry)
                end
            end
        end
    end
    visit(STORAGE_ROOT, 0)
    sortImages(images, preferences.newest_first)
    for _i, entry in ipairs(images) do
        local album = by_folder[entry.folder]
        if not album then
            album = { path = entry.folder, name = entry.folder == STORAGE_ROOT and _("Internal storage") or basename(entry.folder), count = 0, cover = entry, latest = entry.modified }
            by_folder[entry.folder] = album
            table.insert(albums, album)
        end
        album.count = album.count + 1
        -- images are already sorted, so the first one seen is the cover (newest/oldest per preference)
        if entry.modified > album.latest then album.latest = entry.modified end
    end
    table.sort(albums, function(a, b)
        if a.latest ~= b.latest then return a.latest > b.latest end
        return a.name:lower() < b.name:lower()
    end)
    return images, albums, truncated
end

function Gallery:_ensureScan(instance, context, state, preferences)
    if state.images or state.scanning then return end
    state.scanning = true
    UIManager:nextTick(function()
        local ok, images, albums, truncated = pcall(self._scan, self, preferences)
        if ok then
            state.images, state.albums, state.truncated = images, albums, truncated
        else
            state.images, state.albums, state.truncated = {}, {}, false
            state.error = _("The storage could not be read.")
        end
        state.scanning = false
        state.disk = nil
        context.requestRebuild("ui")
    end)
end

function Gallery:_visibleEntries(state)
    local source = state.images or {}
    local needle = trim(state.query):lower()
    if state.album == nil and needle == "" then return source end
    local result = {}
    for _i, entry in ipairs(source) do
        if (state.album == nil or entry.folder == state.album)
            and (needle == "" or (entry.name:lower():find(needle, 1, true) or entry.path:lower():find(needle, 1, true))) then
            table.insert(result, entry)
        end
    end
    return result
end

---------------------------------------------------------------------------
-- Navigation and actions
---------------------------------------------------------------------------
function Gallery:refresh(instance, context)
    local state = self:_ensureState(instance)
    state.images, state.albums, state.scanning, state.error = nil, nil, false, nil
    context.requestRebuild("ui")
end
function Gallery:setTab(instance, context, tab)
    local state = self:_ensureState(instance)
    state.tab, state.album, state.page = tab, nil, 1
    state.query, state.selecting, state.selected = "", false, {}
    context.requestRebuild("ui")
end
function Gallery:openAlbum(instance, context, album)
    local state = self:_ensureState(instance)
    state.tab, state.album, state.album_name = "photos", album.path, album.name
    state.page, state.query, state.selecting, state.selected = 1, "", false, {}
    context.requestRebuild("ui")
end
function Gallery:clearSearch(instance, context)
    local state = self:_ensureState(instance)
    state.query, state.page, state.selecting, state.selected = "", 1, false, {}
    context.requestRebuild("ui")
end
function Gallery:goUp(instance, context)
    local state = self:_ensureState(instance)
    if state.selecting then self:setSelecting(instance, context, false); return true end
    if state.query ~= "" then self:clearSearch(instance, context); return true end
    if state.album then
        state.album, state.page = nil, 1
        state.tab = "albums"
        context.requestRebuild("ui")
        return true
    end
    if state.tab ~= "photos" then self:setTab(instance, context, "photos"); return true end
    return false
end
function Gallery:onBack(instance, context) return self:goUp(instance, context) end

local function showInput(dialog)
    if AppDockKeyboard and type(AppDockKeyboard.attach) == "function" then
        pcall(AppDockKeyboard.attach, dialog)
    end
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
    return dialog
end

function Gallery:showSearch(instance, context)
    local state = self:_ensureState(instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Search photos"),
        input = state.query or "",
        input_hint = _("File or folder name"),
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local value = trim(dialog:getInputText())
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    if value == "" then self:clearSearch(instance, context); return end
                    state.query, state.page, state.selecting, state.selected = value, 1, false, {}
                    if state.tab == "albums" then state.tab = "photos" end
                    context.requestRebuild("ui")
                end)
            end },
        } },
    }
    showInput(dialog)
end

function Gallery:setSelecting(instance, context, on, first_entry)
    local state = self:_ensureState(instance)
    state.selecting, state.selected = on == true, {}
    if on and first_entry then state.selected[first_entry.path] = first_entry end
    context.requestRebuild("ui")
end
function Gallery:toggleSelected(instance, context, entry)
    local state = self:_ensureState(instance)
    if state.selected[entry.path] then state.selected[entry.path] = nil else state.selected[entry.path] = entry end
    context.requestRebuild("ui")
end
function Gallery:selectAll(instance, context)
    local state = self:_ensureState(instance)
    local entries = self:_visibleEntries(state)
    local all = #entries > 0
    for _i, entry in ipairs(entries) do
        if not state.selected[entry.path] then all = false; break end
    end
    state.selected = {}
    if not all then
        for _i, entry in ipairs(entries) do state.selected[entry.path] = entry end
    end
    context.requestRebuild("ui")
end
function Gallery:_selectedList(state)
    local list = {}
    for _path, entry in pairs(state.selected or {}) do table.insert(list, entry) end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

function Gallery:confirmDelete(instance, context, items)
    local text
    if #items == 1 then
        text = _("Delete this photo permanently?") .. "\n\n" .. items[1].path
    else
        text = string.format(_("Delete %d photos permanently?"), #items)
    end
    UIManager:show(ConfirmBox:new{ text = text, ok_text = _("Delete"), ok_callback = function()
        local failed, first_error = 0, nil
        for _i, item in ipairs(items) do
            local ok, err = removeImage(item.path)
            if not ok then failed = failed + 1; first_error = first_error or err end
        end
        local state = self:_ensureState(instance)
        state.selecting, state.selected = false, {}
        if failed == 0 then
            UIManager:show(InfoMessage:new{ text = _("Deleted."), timeout = 2 })
        else
            UIManager:show(InfoMessage:new{ text = string.format(_("%d of %d items failed."), failed, #items) .. "\n" .. tostring(first_error or "") })
        end
        self:refresh(instance, context)
    end })
end

function Gallery:showEntryActions(instance, context, entry, entries, index)
    local dialog
    local function closeThen(callback) return function() UIManager:close(dialog); UIManager:nextTick(callback) end end
    local buttons = {
        { { text = _("Open"), callback = closeThen(function() self:openViewer(instance, context, entries, index) end) } },
        { { text = _("Select"), callback = closeThen(function() self:setSelecting(instance, context, true, entry) end) },
          { text = _("Details"), callback = closeThen(function()
            UIManager:show(InfoMessage:new{ text = table.concat({
                entry.name, "",
                _("Location") .. ": " .. displayPath(entry.folder),
                _("Size") .. ": " .. humanSize(entry.size),
                _("Modified") .. ": " .. fullDate(entry.modified),
            }, "\n") })
        end) } },
        { { text = _("Delete"), callback = closeThen(function() self:confirmDelete(instance, context, { entry }) end) } },
    }
    dialog = ButtonDialog:new{ title = entry.name, buttons = buttons }
    UIManager:show(dialog)
end

function Gallery:openViewer(instance, context, entries, index)
    if not entries or not entries[index] then return end
    local state = self:_ensureState(instance)
    UIManager:show(Viewer:new{
        entries = entries, index = index,
        on_close = function(last_index)
            -- Jump the grid to the page of the last viewed photo.
            state.focus_path = entries[last_index] and entries[last_index].path or nil
            context.requestRebuild("ui")
        end,
    })
end

function Gallery:showMenu(instance, context)
    local state = self:_ensureState(instance)
    local preferences = self:_preferences(context)
    local dialog
    local function closeThen(callback) return function() UIManager:close(dialog); UIManager:nextTick(callback) end end
    local buttons = {
        { { text = _("Select photos"), callback = closeThen(function()
            if state.tab == "albums" and not state.album then self:setTab(instance, context, "photos") end
            self:setSelecting(instance, context, true)
        end) } },
        { { text = preferences.newest_first and _("Show oldest first") or _("Show newest first"), callback = closeThen(function()
            preferences.newest_first = not preferences.newest_first
            self:_savePreferences(context)
            state.page = 1
            self:refresh(instance, context)
        end) } },
        { { text = preferences.show_hidden and _("Hide hidden folders") or _("Show hidden folders"), callback = closeThen(function()
            preferences.show_hidden = not preferences.show_hidden
            self:_savePreferences(context)
            state.page = 1
            self:refresh(instance, context)
        end) } },
        { { text = _("Refresh"), callback = closeThen(function() self:refresh(instance, context) end) } },
    }
    dialog = ButtonDialog:new{ title = _("Gallery"), buttons = buttons }
    UIManager:show(dialog)
end

---------------------------------------------------------------------------
-- Layout: timeline rows and pagination
---------------------------------------------------------------------------
local function buildTimeline(entries, columns, tile_w, gap, header_h, grouped)
    local rows, last_key, current = {}, nil, nil
    for _i, entry in ipairs(entries) do
        local key = dayStart(entry.modified)
        if grouped and key ~= last_key then
            last_key, current = key, nil
            table.insert(rows, { header = dayLabel(entry.modified), h = header_h })
        end
        if not current or #current.tiles >= columns then
            current = { tiles = {}, h = tile_w + gap }
            table.insert(rows, current)
        end
        table.insert(current.tiles, entry)
    end
    return rows
end

local function paginate(rows, available)
    local pages, current, used = {}, {}, 0
    for index, row in ipairs(rows) do
        if used + row.h > available and #current > 0 then
            -- A day header must never be the last thing on a page.
            local carry
            if rows[current[#current]].header then carry = table.remove(current) end
            if #current > 0 then table.insert(pages, current) end
            current, used = {}, 0
            if carry then table.insert(current, carry); used = rows[carry].h end
        end
        table.insert(current, index)
        used = used + row.h
    end
    if #current > 0 then table.insert(pages, current) end
    if #pages == 0 then pages[1] = {} end
    return pages
end

-- Finds the page that contains the photo we just came back from.
local function pageOfEntry(rows, pages, path)
    for page_index, page in ipairs(pages) do
        for _i, row_index in ipairs(page) do
            local row = rows[row_index]
            if row.tiles then
                for _j, entry in ipairs(row.tiles) do
                    if entry.path == path then return page_index end
                end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Building the screen
---------------------------------------------------------------------------
function Gallery:_buildSearchRow(instance, context, state, width, margin, preferences)
    local height = scale(48)
    local searching = state.query ~= ""
    local side_w = height
    local clear_w = searching and (height + scale(8)) or 0
    local widgets = {
        SearchBar:new{
            width = width - 2 * margin - side_w - scale(8) - clear_w, height = height, active = searching,
            text = searching and state.query or _("Search your photos"),
            callback = function() self:showSearch(instance, context) end,
        },
    }
    if searching then
        table.insert(widgets, Button:new{ title = "×", font_size = 26, width = height, height = height, callback = function() self:clearSearch(instance, context) end })
    end
    table.insert(widgets, Button:new{ title = "···", font_size = 24, width = side_w, height = height, callback = function() self:showMenu(instance, context) end })
    return rowOf(margin, scale(8), widgets)
end

function Gallery:_buildToolbar(instance, context, state, width, margin, total)
    local height, gap = scale(48), scale(6)
    local back_w = scale(48)
    if state.selecting then
        local count = 0
        for _path in pairs(state.selected) do count = count + 1 end
        local all_w = scale(64)
        local title_w = width - 2 * margin - back_w - all_w - 2 * gap
        return rowOf(margin, gap, {
            Button:new{ title = "×", font_size = 26, width = back_w, height = height, callback = function() self:setSelecting(instance, context, false) end },
            titleBlock(title_w, height, string.format(_("%d selected"), count), string.format(_("%d photos"), total)),
            Button:new{ title = _("All"), font_size = 16, width = all_w, height = height, callback = function() self:selectAll(instance, context) end },
        })
    end
    local title_w = width - 2 * margin - back_w - gap
    local title, subtitle
    if state.query ~= "" then
        title = _("Search results")
        subtitle = state.query .. "  ·  " .. string.format(_("%d photos"), total)
    else
        title = state.album_name or basename(state.album or "")
        subtitle = displayPath(state.album) .. "  ·  " .. string.format(_("%d photos"), total)
    end
    return rowOf(margin, gap, {
        Button:new{ title = "‹", font_size = 30, width = back_w, height = height, callback = function() self:goUp(instance, context) end },
        titleBlock(title_w, height, title, subtitle),
    })
end

function Gallery:_footer(content, state, pages, total, width, margin, noun, context)
    local footer_h, pager_w = scale(44), scale(56)
    local info
    if pages > 1 then
        info = string.format("%d / %d  ·  %s", state.page, pages, string.format(noun, total))
    else
        info = string.format(noun, total)
    end
    local previous_widget = emptySizedWidget(pager_w, footer_h)
    local next_widget = emptySizedWidget(pager_w, footer_h)
    if state.page > 1 then
        previous_widget = Button:new{ title = "‹", font_size = 28, width = pager_w, height = footer_h, callback = function()
            state.page = state.page - 1; context.requestRebuild("ui")
        end }
    end
    if state.page < pages then
        next_widget = Button:new{ title = "›", font_size = 28, width = pager_w, height = footer_h, callback = function()
            state.page = state.page + 1; context.requestRebuild("ui")
        end }
    end
    table.insert(content, rowOf(margin, 0, { previous_widget, centeredText(width - 2 * margin - 2 * pager_w, footer_h, info, 15, PALETTE.on_variant, false), next_widget }))
end

function Gallery:_fillPhotos(content, instance, context, state, preferences, width, height)
    local margin, gap = scale(16), scale(6)
    local in_album = state.album ~= nil or state.query ~= ""
    local entries = self:_visibleEntries(state)
    local total = #entries
    table.insert(content, vspan(margin))
    table.insert(content, self:_buildSearchRow(instance, context, state, width, margin, preferences))
    table.insert(content, vspan(scale(10)))
    local used = margin + scale(48) + scale(10)
    if in_album or state.selecting then
        table.insert(content, self:_buildToolbar(instance, context, state, width, margin, total))
        table.insert(content, vspan(scale(8)))
        used = used + scale(48) + scale(8)
    end
    local bar_h = state.selecting and scale(52) or 0
    local footer_h = scale(44)
    local reserve = margin + footer_h + (bar_h > 0 and (bar_h + scale(8)) or 0)
    local list_h = math.max(scale(120), height - used - reserve)

    if total == 0 then
        local title = state.query ~= "" and _("No matching photos") or _("No photos yet")
        local subtitle = state.query ~= "" and _("Try a different name") or _("Images on your device will show up here")
        table.insert(content, rowOf(margin, 0, { messageCard(width - 2 * margin, math.min(list_h, scale(110)), title, subtitle) }))
        table.insert(content, vspan(math.max(0, list_h - math.min(list_h, scale(110)))))
        return 1, 0
    end

    local inner_w = width - 2 * margin
    local columns = math.max(3, math.floor((inner_w + gap) / (scale(TARGET_TILE) + gap)))
    local tile_w = math.floor((inner_w - (columns - 1) * gap) / columns)
    local header_h = scale(38)
    local rows = buildTimeline(entries, columns, tile_w, gap, header_h, true)
    local pages = paginate(rows, list_h)
    if state.focus_path then
        state.page = pageOfEntry(rows, pages, state.focus_path) or state.page
        state.focus_path = nil
    end
    state.page = clamp(state.page or 1, 1, #pages)

    -- Flat index of every entry for the viewer.
    local index_of = {}
    for index, entry in ipairs(entries) do index_of[entry.path] = index end

    local used_list = 0
    for _i, row_index in ipairs(pages[state.page]) do
        local row = rows[row_index]
        if row.header then
            local title = label(row.header, 19, PALETTE.on_surface, true, inner_w, "cfont")
            local y = math.floor((header_h - title:getSize().h) / 2)
            table.insert(content, rowOf(margin, 0, { stack(inner_w, header_h, { { widget = title, x = scale(2), y = y } }) }))
        else
            local tiles = {}
            for _j, entry in ipairs(row.tiles) do
                local index = index_of[entry.path]
                table.insert(tiles, PhotoTile:new{
                    entry = entry, width = tile_w, height = tile_w,
                    selecting = state.selecting, selected = state.selected[entry.path] ~= nil,
                    callback = function()
                        if state.selecting then self:toggleSelected(instance, context, entry)
                        else self:openViewer(instance, context, entries, index) end
                    end,
                    hold_callback = function()
                        if state.selecting then self:toggleSelected(instance, context, entry)
                        else self:showEntryActions(instance, context, entry, entries, index) end
                    end,
                })
            end
            table.insert(content, rowOf(margin, gap, tiles))
            table.insert(content, vspan(gap))
        end
        used_list = used_list + row.h
    end
    table.insert(content, vspan(math.max(0, list_h - used_list)))
    self:_footer(content, state, #pages, total, width, margin, _("%d photos"), context)

    if bar_h > 0 then
        table.insert(content, vspan(scale(8)))
        local selected_items = self:_selectedList(state)
        table.insert(content, rowOf(margin, scale(8), {
            Button:new{
                title = string.format(_("Delete (%d)"), #selected_items), width = width - 2 * margin, height = bar_h,
                active = #selected_items > 0,
                callback = function()
                    local items = self:_selectedList(state)
                    if #items == 0 then UIManager:show(InfoMessage:new{ text = _("Select at least one photo first."), timeout = 2 }); return end
                    self:confirmDelete(instance, context, items)
                end,
            },
        }))
    end
    return #pages, total
end

function Gallery:_fillAlbums(content, instance, context, state, preferences, width, height)
    local margin, gap = scale(16), scale(10)
    local albums = state.albums or {}
    local total = #albums
    table.insert(content, vspan(margin))
    table.insert(content, self:_buildSearchRow(instance, context, state, width, margin, preferences))
    table.insert(content, vspan(scale(10)))
    local used = margin + scale(48) + scale(10)
    local title = label(_("Albums"), 20, PALETTE.on_surface, true, width, "cfont")
    table.insert(content, rowOf(margin, 0, { title }))
    table.insert(content, vspan(scale(8)))
    used = used + title:getSize().h + scale(8)
    local footer_h = scale(44)
    local list_h = math.max(scale(120), height - used - margin - footer_h)
    if total == 0 then
        table.insert(content, rowOf(margin, 0, { messageCard(width - 2 * margin, math.min(list_h, scale(110)), _("No albums yet"), _("Folders that contain images will show up here")) }))
        table.insert(content, vspan(math.max(0, list_h - math.min(list_h, scale(110)))))
        return 1, 0
    end
    local inner_w = width - 2 * margin
    local columns = math.max(2, math.floor((inner_w + gap) / (scale(220) + gap)))
    local card_w = math.floor((inner_w - (columns - 1) * gap) / columns)
    local card_h = card_w + scale(56)
    local rows = {}
    local current
    for _i, album in ipairs(albums) do
        if not current or #current.albums >= columns then
            current = { albums = {}, h = card_h + gap }
            table.insert(rows, current)
        end
        table.insert(current.albums, album)
    end
    local pages = paginate(rows, list_h)
    state.page = clamp(state.page or 1, 1, #pages)
    local used_list = 0
    for _i, row_index in ipairs(pages[state.page]) do
        local row = rows[row_index]
        local cards = {}
        for _j, album in ipairs(row.albums) do
            table.insert(cards, AlbumCard:new{
                album = album, width = card_w, height = card_h,
                callback = function() self:openAlbum(instance, context, album) end,
            })
        end
        table.insert(content, rowOf(margin, gap, cards))
        table.insert(content, vspan(gap))
        used_list = used_list + row.h
    end
    table.insert(content, vspan(math.max(0, list_h - used_list)))
    self:_footer(content, state, #pages, total, width, margin, _("%d albums"), context)
    return #pages, total
end

function Gallery:_buildNav(instance, context, state, landscape, width, height)
    local active_tab = state.album and "albums" or state.tab
    local items = {
        { id = "photos", title = _("Photos") },
        { id = "albums", title = _("Albums") },
        { id = "search", title = _("Search") },
    }
    local function tabButton(item, w, h)
        return Button:new{
            title = item.title, font_size = 16, width = w, height = h,
            active = (item.id == active_tab) or (item.id == "search" and state.query ~= ""),
            callback = function()
                if item.id == "search" then self:showSearch(instance, context)
                else self:setTab(instance, context, item.id) end
            end,
        }
    end
    if landscape then
        local rail = VerticalGroup:new{ align = "center" }
        local button_w, button_h = width - scale(16), scale(56)
        table.insert(rail, vspan(scale(16)))
        for _i, item in ipairs(items) do
            table.insert(rail, tabButton(item, button_w, button_h))
            table.insert(rail, vspan(scale(10)))
        end
        return FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = PALETTE.surface, CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, rail } }
    end
    local gap, margin = scale(8), scale(12)
    local button_w = math.floor((width - 2 * margin - (#items - 1) * gap) / #items)
    local buttons = {}
    for _i, item in ipairs(items) do table.insert(buttons, tabButton(item, button_w, height - scale(12))) end
    return FrameContainer:new{
        width = width, height = height, padding = 0, bordersize = 0, background = PALETTE.surface,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, rowOf(margin, gap, buttons) },
    }
end

function Gallery:buildPane(instance, context)
    applyTheme(context)
    local state = self:_ensureState(instance)
    local preferences = self:_preferences(context)
    local width, height = context.dimen.w, context.dimen.h
    local landscape = width > height * 1.15
    local rail_w = landscape and scale(130) or 0
    local bar_h = landscape and 0 or scale(64)
    local main_w, main_h = width - rail_w, height - bar_h

    self:_ensureScan(instance, context, state, preferences)

    local content = VerticalGroup:new{ align = "left" }
    local pages, total = 1, 0
    if not state.images then
        local margin = scale(16)
        table.insert(content, vspan(margin))
        table.insert(content, self:_buildSearchRow(instance, context, state, main_w, margin, preferences))
        table.insert(content, vspan(scale(16)))
        table.insert(content, rowOf(margin, 0, { messageCard(main_w - 2 * margin, scale(120), _("Loading photos…"), _("Looking for images on your device")) }))
    elseif state.error then
        local margin = scale(16)
        table.insert(content, vspan(margin))
        table.insert(content, rowOf(margin, 0, { messageCard(main_w - 2 * margin, scale(120), _("Gallery unavailable"), state.error) }))
        table.insert(content, vspan(scale(12)))
        table.insert(content, rowOf(margin, 0, { Button:new{ title = _("Refresh"), active = true, width = main_w - 2 * margin, height = scale(48), callback = function() self:refresh(instance, context) end } }))
    elseif state.tab == "albums" and not state.album and state.query == "" then
        pages, total = self:_fillAlbums(content, instance, context, state, preferences, main_w, main_h)
    else
        pages, total = self:_fillPhotos(content, instance, context, state, preferences, main_w, main_h)
    end

    local main = FrameContainer:new{ width = main_w, height = main_h, padding = 0, bordersize = 0, background = PALETTE.background, content }
    local nav = self:_buildNav(instance, context, state, landscape, landscape and rail_w or width, landscape and height or bar_h)
    local layout
    if landscape then
        layout = HorizontalGroup:new{ align = "top", nav, main }
    else
        layout = VerticalGroup:new{ align = "left", main, nav }
    end
    local pane = WidgetContainer:new{ dimen = Geom:new{ w = width, h = height } }
    pane[1] = FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = PALETTE.background, layout }
    pane.file_layout = {
        gallery_style = true, images_only = true, tab = state.tab, album = state.album, query = state.query,
        selecting = state.selecting, page = state.page, pages = pages, item_count = total, paged = true,
        newest_first = preferences.newest_first, storage_root = STORAGE_ROOT, non_destructive = true,
    }
    return pane
end

local function acceptFile(instance, path)
    if type(path) ~= "string" or #path > 1024 or not IMAGE_EXTENSIONS[extension(path)] then
        return false, _("Choose a local image file.")
    end
    local attributes = lstat(path)
    if not attributes or attributes.mode ~= "file" then return false, _("The image could not be found.") end
    local entry = {
        name = basename(path), path = path, folder = parentPath(path),
        size = tonumber(attributes.size) or 0, modified = tonumber(attributes.modification) or 0,
    }
    UIManager:show(Viewer:new{ entries = { entry }, index = 1 })
    return true
end

return {
    id = APP_ID,
    version = "1.0.0",
    title = "Gallery",
    subtitle = "Your photos, quietly kept.",
    symbol = "G",
    logo = "gallery",
    buildPane = function(instance, context) return Gallery:buildPane(instance, context) end,
    onBack = function(instance, context) return Gallery:goUp(instance, context) end,
    openFile = acceptFile,
}
