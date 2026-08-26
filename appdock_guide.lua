--[[--
AppDock Guide for AppDock.

A local, interactive orientation DApp. It deliberately does not change
AppDock settings: every lesson explains the safe path and lets the reader mark
the topic as understood. This keeps the guide useful in split screen and
avoids surprising configuration changes.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
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
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local function trim(value)
    return type(value) == "string" and (value:match("^%s*(.-)%s*$") or "") or ""
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function empty(width, height)
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, HorizontalSpan:new{ width = 0 } }
end

local TOPICS = {
    {
        id = "start", icon = "1", keywords = "start homescreen launcher öffnen open plugin",
        de = { title = "Schnellstart", steps = {
            "AppDock läuft innerhalb von KOReader. Öffne den Homescreen über das Plugin-Menü oder aktiviere unter Einstellungen → Weiteres den Start-Homescreen.",
            "Tippe eine angeheftete Kachel, um eine App oder DApp zu öffnen. Mit Home kehrst du zum AppDock-Homescreen zurück.",
            "Die erste Ansicht enthält Systemzeile, optionale Karten, Widgets und deine angehefteten Apps. Alles wird lokal gespeichert.",
        } },
        en = { title = "Getting started", steps = {
            "AppDock runs inside KOReader. Open its homescreen from the plugin menu, or enable Startup homescreen in Settings → Other.",
            "Tap a pinned tile to launch an app or DApp. Use Home to return to AppDock.",
            "The first page combines the system row, optional cards, widgets and your pinned apps. Settings stay local to this reader.",
        } },
    },
    {
        id = "control", icon = "2", keywords = "kontrollzentrum quick settings wlan helligkeit nacht schlafen energie sparen wallpaper",
        de = { title = "Kontrollzentrum", steps = {
            "Öffne den Abwärtspfeil in der Systemzeile. Das Kontrollzentrum enthält Helligkeit und auswählbare Kacheln.",
            "Unter Einstellungen → Weiteres → Kontrollzentrum wählst du Kacheln wie WLAN, Nachtmodus, Schlafmodus, Energie sparen oder Hintergrundbild.",
            "Energie sparen versucht WLAN und Frontlight abzuschalten und verlängert den lokalen Refresh-Takt. Hardwarefunktionen hängen vom Reader ab.",
        } },
        en = { title = "Control Center", steps = {
            "Open the down arrow in the system row. Control Center contains brightness and selectable tiles.",
            "Use Settings → Other → Control Center to choose tiles such as Wi-Fi, Night mode, Sleep, Save power or Wallpaper.",
            "Save power attempts to disable Wi-Fi and frontlight and lengthens AppDock's local refresh cadence. Hardware support varies by reader.",
        } },
    },
    {
        id = "layout", icon = "3", keywords = "apps widgets anordnen arrange layout suchen search homescreen",
        de = { title = "Apps, Widgets und Layout", steps = {
            "Halte eine Kachel gedrückt oder nutze Apps und Widgets verwalten, um Verknüpfungen und sichtbare Widgets zu ändern.",
            "Unter Einstellungen → Weiteres → Apps & Widgets anordnen legst du die Reihenfolge für Homescreen-Seiten und Store-Widgets fest.",
            "Unter Display → Launcher-Layout wählst du Abstand, Logoform und die optionale App-Suche. Die Suche filtert nur sichtbare App-Kacheln.",
        } },
        en = { title = "Apps, widgets and layout", steps = {
            "Hold a tile or use Manage apps and widgets to change shortcuts and visible widgets.",
            "Settings → Other → Arrange apps & widgets controls the order of homescreen pages and Store widgets.",
            "Display → Launcher layout changes spacing, logo shape and optional app search. Search filters visible app tiles only.",
        } },
    },
    {
        id = "store", icon = "4", keywords = "appstore installieren update deinstallieren https katalog dapps",
        de = { title = "AppStore", steps = {
            "Der AppStore lädt den DApp-Katalog über HTTPS. Suche filtert den bereits geladenen Katalog lokal.",
            "Installieren und Updates benötigen immer eine sichtbare Bestätigung. DApp-Dateien werden vor dem Speichern auf Lua-Syntax geprüft.",
            "Deinstallieren entfernt die DApp-Datei und Store-Registrierung, nicht automatisch persönliche Daten, die eine DApp selbst angelegt hat.",
        } },
        en = { title = "AppStore", steps = {
            "AppStore loads the DApp catalog over HTTPS. Search filters the already loaded catalog locally.",
            "Installing and updating always need visible confirmation. DApp source is syntax-checked before it is stored.",
            "Uninstall removes the DApp file and Store registration, not necessarily personal data created by that DApp.",
        } },
    },
    {
        id = "split", icon = "5", keywords = "dapp multitasking open apps splitscreen split screen schließen",
        de = { title = "DApps und Splitscreen", steps = {
            "Geöffnete DApps bleiben als Sitzung erhalten. Über Open apps kannst du sie wiederherstellen oder schließen.",
            "Für Splitscreen öffnest du zwei DApps, hältst eine Karte in Open apps gedrückt und wählst zuerst Splitscreen und dann die zweite DApp.",
            "Aktuelle wichtige Store-DApps verwenden relative Pane-Größen. Sie bleiben daher auch in kurzen Split-Panes besser lesbar.",
        } },
        en = { title = "DApps and split screen", steps = {
            "Open DApps remain available as sessions. Open apps lets you restore or close them.",
            "For split screen, open two DApps, hold one Open apps card, choose Split screen, then choose the second DApp.",
            "Current key Store DApps use relative pane sizes, so they remain more readable in short split panes.",
        } },
    },
    {
        id = "privacy", icon = "6", keywords = "wallpaper lockscreen pin muster swipe berechtigung background dockupdate datenschutz sicherheit",
        de = { title = "Datenschutz und Sicherheit", steps = {
            "Hintergrundbilder werden nur über lokale Bildpfade verwendet. Die Betaoption kann die Invertierung des Bilds im Nachtmodus verhindern.",
            "Der AppDock-Lockscreen schützt nur den AppDock-Einstieg. Er ist keine Geräteverschlüsselung und ersetzt keinen Systemschutz.",
            "DApp-Hintergrundfunktionen und Autostart müssen in Einstellungen ausdrücklich erlaubt werden. DockUpdate prüft dann nur lokale Release-Metadaten während KOReader läuft und installiert nie automatisch.",
        } },
        en = { title = "Privacy and safety", steps = {
            "Wallpaper uses local image paths only. A beta option can keep the image uninverted in night mode.",
            "The AppDock lockscreen protects only the AppDock entry. It is not device encryption and does not replace system security.",
            "DApp background capability and autostart need explicit approval in Settings. When permitted, DockUpdate checks release metadata only while KOReader runs and never installs automatically.",
        } },
    },
}

local Action = InputContainer:extend{ title = nil, subtitle = nil, icon = nil, callback = nil, width = nil, height = nil, primary = false, px = nil }
function Action:init()
    local px = self.px or function(value) return value end
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local inset = px(8)
    local foreground = self.primary and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local layers = {
        TextWidget:new{ text = self.icon or "", face = Font:getFace("cfont", px(16)), bold = true, fgcolor = foreground, overlap_offset = { inset, math.max(px(5), math.floor(self.height * .24)) } },
        TextWidget:new{ text = self.title or "", face = Font:getFace("smallinfofont", px(11)), bold = true, fgcolor = foreground, max_width = self.width - px(34), overlap_offset = { px(28), math.max(px(4), math.floor(self.height * .20)) } },
    }
    if self.subtitle and self.subtitle ~= "" then
        layers[#layers + 1] = TextWidget:new{ text = self.subtitle, face = Font:getFace("smallinfofont", px(8)), fgcolor = self.primary and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_DARK_GRAY, max_width = self.width - px(34), overlap_offset = { px(28), math.max(px(20), math.floor(self.height * .55)) } }
    end
    self[1] = FrameContainer:new{ width = self.width, height = self.height, padding = 0, bordersize = 0, radius = math.max(px(5), math.floor(self.height * .20)), background = self.primary and Blitbuffer.COLOR_GRAY_8 or Blitbuffer.COLOR_LIGHT_GRAY, OverlapGroup:new{ dimen = self.dimen, allow_mirroring = false, unpack(layers) } }
    self.ges_events = { TapGuideAction = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end
function Action:paintTo(bb, x, y)
    local range = self.ges_events.TapGuideAction[1].range
    range.x, range.y, range.w, range.h = x, y, self.dimen.w, self.dimen.h
    return InputContainer.paintTo(self, bb, x, y)
end
function Action:onTapGuideAction() if self.callback then self.callback() end return true end

local function stateFor(instance)
    instance.appdock_guide = instance.appdock_guide or { view = "topics", language = "de", selected = 1, step = 1, completed = {}, query = "" }
    return instance.appdock_guide
end

local function copyMatches(query)
    local needle = lower(trim(query))
    if needle == "" then return TOPICS end
    local results = {}
    for index, topic in ipairs(TOPICS) do
        local text = lower(topic.keywords .. " " .. topic.de.title .. " " .. topic.en.title)
        if text:find(needle, 1, true) then results[#results + 1] = topic end
    end
    return results
end

local function completionCount(state)
    local count = 0
    for topic_id, completed in pairs(state.completed) do if completed then count = count + 1 end end
    return count
end

local function rebuild(context)
    if context.requestRebuild then context.requestRebuild("ui") end
end

local function topicPane(instance, context)
    local state = stateFor(instance)
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or function(value) return value end
    local margin, gap, row_h = px(10), px(6), px(48)
    local topics = copyMatches(state.query)
    local header = state.language == "de" and "AppDock Guide" or "AppDock Guide"
    local hint = state.language == "de" and "Tippe ein Kapitel. Fortschritt bleibt in dieser DApp-Sitzung." or "Tap a chapter. Progress stays in this DApp session."
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) },
        TextWidget:new{ text = header, face = Font:getFace("cfont", px(20)), bold = true, overlap_offset = { margin, margin } },
        TextWidget:new{ text = completionCount(state) .. "/" .. #TOPICS .. " · " .. hint, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, margin + px(27) } },
    }
    local half = math.floor((width - 2 * margin - gap) / 2)
    elements[#elements + 1] = Action:new{ title = state.language == "de" and "Suche" or "Search", icon = "⌕", width = half, height = px(30), px = px, callback = function()
        local dialog
        dialog = InputDialog:new{ title = state.language == "de" and "Guide durchsuchen" or "Search guide", input = state.query, input_hint = state.language == "de" and "z. B. WLAN, Store, Splitscreen" or "e.g. Wi-Fi, Store, split", buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, { text = state.language == "de" and "Filtern" or "Filter", is_enter_default = true, callback = function() state.query = trim(dialog:getInputText()); UIManager:close(dialog); rebuild(context) end } } } }
        UIManager:show(dialog); dialog:onShowKeyboard()
    end, overlap_offset = { margin, margin + px(43) } }
    elements[#elements + 1] = Action:new{ title = state.language == "de" and "English" or "Deutsch", icon = "A", width = half, height = px(30), px = px, callback = function() state.language = state.language == "de" and "en" or "de"; rebuild(context) end, overlap_offset = { margin + half + gap, margin + px(43) } }
    local y = margin + px(80)
    if #topics == 0 then
        elements[#elements + 1] = TextWidget:new{ text = state.language == "de" and "Keine Kapitel gefunden. Versuche einen kürzeren Begriff." or "No chapters found. Try a shorter term.", face = Font:getFace("smallinfofont", px(11)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = width - 2 * margin, overlap_offset = { margin, y } }
    end
    for index, topic in ipairs(topics) do
        if y + row_h > height - margin then break end
        local copy = topic[state.language]
        local done = state.completed[topic.id] and "✓ " or ""
        elements[#elements + 1] = Action:new{ title = done .. copy.title, subtitle = copy.steps[1], icon = topic.icon, width = width - 2 * margin, height = row_h, px = px, callback = function()
            for topic_index, candidate in ipairs(TOPICS) do if candidate.id == topic.id then state.selected = topic_index; break end end
            state.step, state.view = 1, "lesson"; rebuild(context)
        end, overlap_offset = { margin, y } }
        y = y + row_h + gap
    end
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

local function lessonPane(instance, context)
    local state = stateFor(instance)
    local topic = TOPICS[state.selected] or TOPICS[1]
    local copy = topic[state.language]
    local width, height = context.dimen.w, context.dimen.h
    local px = context.px or function(value) return value end
    local margin, gap, control_h = px(10), px(6), px(31)
    state.step = math.max(1, math.min(#copy.steps, state.step or 1))
    local content_y = margin + px(57)
    local content_h = math.max(px(58), height - content_y - control_h * 2 - gap * 3 - margin)
    local elements = {
        FrameContainer:new{ width = width, height = height, padding = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE, empty(width, height) },
        TextWidget:new{ text = copy.title, face = Font:getFace("cfont", px(19)), bold = true, max_width = width - 2 * margin, overlap_offset = { margin, margin } },
        TextWidget:new{ text = (state.language == "de" and "Schritt " or "Step ") .. state.step .. "/" .. #copy.steps, face = Font:getFace("smallinfofont", px(9)), fgcolor = Blitbuffer.COLOR_DARK_GRAY, overlap_offset = { margin, margin + px(27) } },
        TextWidget:new{ text = copy.steps[state.step], face = Font:getFace("smallinfofont", px(13)), fgcolor = Blitbuffer.COLOR_BLACK, max_width = width - 2 * margin, overlap_offset = { margin, content_y } },
    }
    local half = math.floor((width - 2 * margin - gap) / 2)
    elements[#elements + 1] = Action:new{ title = state.language == "de" and "‹ Kapitel" or "‹ Topics", icon = "‹", width = half, height = control_h, px = px, callback = function() state.view = "topics"; rebuild(context) end, overlap_offset = { margin, height - margin - control_h * 2 - gap } }
    elements[#elements + 1] = Action:new{ title = state.language == "de" and "Erledigt" or "Done", icon = state.completed[topic.id] and "✓" or "○", width = half, height = control_h, px = px, primary = true, callback = function() state.completed[topic.id] = true; rebuild(context) end, overlap_offset = { margin + half + gap, height - margin - control_h * 2 - gap } }
    elements[#elements + 1] = Action:new{ title = state.language == "de" and "‹ Zurück" or "‹ Back", icon = "‹", width = half, height = control_h, px = px, callback = function() state.step = math.max(1, state.step - 1); rebuild(context) end, overlap_offset = { margin, height - margin - control_h } }
    elements[#elements + 1] = Action:new{ title = state.step == #copy.steps and (state.language == "de" and "Kapitel fertig" or "Chapter complete") or (state.language == "de" and "Weiter ›" or "Next ›"), icon = "›", width = half, height = control_h, px = px, primary = true, callback = function()
        if state.step < #copy.steps then state.step = state.step + 1 else state.completed[topic.id] = true; state.view = "topics" end
        rebuild(context)
    end, overlap_offset = { margin + half + gap, height - margin - control_h } }
    return OverlapGroup:new{ dimen = Geom:new{ w = width, h = height }, allow_mirroring = false, unpack(elements) }
end

return {
    id = "appdock_guide",
    version = "1.0.0",
    title = "AppDock Guide",
    subtitle = "Interactive local feature tour",
    symbol = "?",
    logo = "help",
    buildPane = function(instance, context)
        local state = stateFor(instance)
        local pane = WidgetContainer:new{ dimen = Geom:new{ w = context.dimen.w, h = context.dimen.h } }
        pane[1] = state.view == "lesson" and lessonPane(instance, context) or topicPane(instance, context)
        return pane
    end,
    _test = { topics = TOPICS, matches = copyMatches, stateFor = stateFor },
}
