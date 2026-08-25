# AppDock DApp DeveloperManual

**Version:** 1.0  
**Zielplattform:** AppDock innerhalb von KOReader  
**Referenzkern:** AppDock 1.7.0  
**Sprache:** Lua 5.1 beziehungsweise LuaJIT-kompatibles Lua

Dieses Manual beschreibt, wie eigenständige **DApps** für AppDock entwickelt, lokal getestet und über den öffentlichen AppStore-Katalog veröffentlicht werden. Eine DApp ist kein Android-Paket und kein eigenständiges KOReader-Plugin. Sie ist eine einzelne vertrauenswürdige Lua-Datei, die innerhalb des AppDock-Hosts läuft und eine begrenzte, lokale Pane-Fläche erhält.

> **Grundprinzip:** Eine gute DApp kennt nur ihre übergebene `context.dimen`, verwaltet ihren Zustand über `instance`, aktualisiert E-Ink sparsam und führt niemals ungeprüften Lua-Code aus Benutzereingaben aus.

## 1. Schnellstart

Erstelle zunächst eine Datei wie `examples/my_app.lua` und lege sie in das DApps-Repository. Die Datei muss eine Tabelle zurückgeben. Der kleinstmögliche gültige Vertrag sieht so aus:

```lua
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local function scale(value)
    return Device.screen:scaleBySize(value)
end

return {
    id = "my_app",
    version = "1.0.0",
    title = "My App",
    subtitle = "A small AppDock DApp",
    symbol = "M",
    logo = "help",

    buildPane = function(instance, context)
        local width, height = context.dimen.w, context.dimen.h
        local margin = scale(14)
        local pane = WidgetContainer:new{
            dimen = Geom:new{ w = width, h = height },
        }
        pane[1] = OverlapGroup:new{
            dimen = pane.dimen,
            allow_mirroring = false,
            FrameContainer:new{
                width = width,
                height = height,
                padding = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                CenterContainer:new{
                    dimen = Geom:new{ w = width, h = height },
                    TextWidget:new{
                        text = "Hello AppDock",
                        face = Font:getFace("cfont", scale(18)),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        bold = true,
                        max_width = width - 2 * margin,
                    },
                },
            },
        }
        return pane
    end,
}
```

Die Datei kann lokal mit `luac5.1 -p my_app.lua` auf Syntaxfehler geprüft werden. Danach wird sie über einen Katalogeintrag in `dapps.txt` installierbar. Ein vollständiges Referenzbeispiel befindet sich in [`examples/quote_card.lua`](examples/quote_card.lua) [1].

## 2. DApp-Vertrag

Der AppStore lädt einzelne `.lua`-Dateien. AppDock führt die Datei aus und akzeptiert nur eine Tabelle mit mindestens `id`, `title` und `buildPane`. Für Updates sollte immer auch eine numerische Versionszeichenkette vorhanden sein.

| Feld | Typ | Pflicht | Bedeutung |
|---|---|---:|---|
| `id` | String | Ja | Eindeutige technische ID; nur Buchstaben, Ziffern, `_` und `-`. |
| `version` | String | Empfohlen | Punktgetrennte numerische Version, zum Beispiel `1.2.0`. Der AppStore vergleicht sie komponentenweise. |
| `title` | String | Ja | Anzeigename der DApp. |
| `subtitle` | String | Nein | Kurze Erklärung für Homescreen und AppStore. |
| `symbol` | String | Nein | Fallback-Zeichen, wenn kein Logo verwendet wird. |
| `logo` | String | Nein | Name aus AppDocks vorhandener Logo-Bibliothek. |
| `buildPane` | Funktion | Ja | Baut das sichtbare Pane für eine konkrete DApp-Instanz. |
| `openFile` | Funktion | Nein | Nimmt lokale Dateien aus AppDock Files entgegen. |

Eine DApp-ID muss im Katalog eindeutig sein. Die Versionsnummer in der Datei und die Versionsnummer in `dapps.txt` müssen übereinstimmen. Die technische Prüfung des Hosts ist in der DApp-Verwaltung des AppDock-Kerns dokumentiert [2].

### 2.1 `buildPane(instance, context)`

AppDock ruft `buildPane` auf, wenn das Pane neu aufgebaut wird. Das Ergebnis muss ein KOReader-Widget sein. Das Pane muss vollständig innerhalb der übergebenen Rechteckgeometrie liegen:

```lua
local width, height = context.dimen.w, context.dimen.h
local pane = WidgetContainer:new{
    dimen = Geom:new{ w = width, h = height },
}
```

Verwende **niemals** globale Bildschirmbreiten oder eine fest codierte Fullscreen-Geometrie. Dasselbe DApp-Pane kann im Homescreen, in „Open apps“ oder in einer geteilten Ansicht mit einer wesentlich kleineren Höhe erscheinen.

### 2.2 `instance` ist der langlebige Zustand

`instance` gehört zur DApp-Instanz und bleibt erhalten, wenn der Nutzer zu einer anderen App wechselt und später zurückkehrt. Lege DApp-Zustand unter einem eigenen Feld ab:

```lua
local function stateFor(instance)
    instance.my_app = instance.my_app or {
        counter = 0,
        status = "Ready",
    }
    return instance.my_app
end
```

`buildPane` darf deshalb den Zustand auslesen und die sichtbare Oberfläche daraus erzeugen. Nach einer Aktion aktualisiert die DApp ihren Zustand und fordert einen UI-Neuaufbau an. Vermeide globale veränderliche Variablen; sie würden mehrere Instanzen vermischen und erschweren Tests.

## 3. Der `context`-Vertrag

AppDock erzeugt für jedes aktive Pane einen eigenen Kontext. Die aktuell verlässlich nutzbaren Felder sind:

| Feld/Funktion | Zweck | Typischer Einsatz |
|---|---|---|
| `context.dimen` | Zugewiesene lokale Pane-Geometrie | `context.dimen.w`, `context.dimen.h` lesen |
| `context.manager` | AppDock-DApp-Manager | `context.manager:openDAppFile(...)` |
| `context.host` | Aktiver DApp-Host | Nur für fortgeschrittene Hostprüfungen |
| `context.requestRebuild(kind)` | Pane neu aufbauen und danach aktualisieren | `context.requestRebuild("ui")` |
| `context.requestRefresh(kind, region)` | Bestehende Darstellung regional aktualisieren | `context.requestRefresh("fast", region)` |

Die Funktionen sind bereits an den aktiven Host gebunden. Rufe deshalb in einer DApp **nicht** direkt auf interne Host-Stacks zu und verwende nicht die globale Fensterverwaltung als Ersatz für den Kontext. Die konkrete Kontextbildung sowie die Weiterleitung an KOReaders `UIManager` liegen im AppDock-Kern [2].

### 3.1 UI-Neuaufbau

Für normale Aktionen wie Seitenwechsel, Dialogabschluss, geänderte Einstellungen oder neue Daten verwende:

```lua
context.requestRebuild("ui")
```

Ein Neuaufbau darf den Status einer DApp nicht verlieren. `buildPane` muss jederzeit aus `instance` denselben logischen Zustand wieder darstellen können.

### 3.2 Regionaler Fast-Refresh

Für bereits direkt gezeichnete Pixel, zum Beispiel eine Zeichenlinie oder einen Slider-Knopf, verwende eine absolute Region:

```lua
context.requestRefresh("fast", Geom:new{
    x = absolute_x,
    y = absolute_y,
    w = region_width,
    h = region_height,
})
```

`fast` ist für kleine, kurzfristige Änderungen gedacht. Es ersetzt keinen UI-Neuaufbau. Wenn sich Widgets, Text, Layout oder ein Dialog ändern, ist `requestRebuild("ui")` die richtige Wahl. Fordere keinen Fullscreen-Refresh bei jeder Eingabe an.

## 4. E-Ink- und UI-Regeln

AppDock ist ein E-Ink-Homescreen. Eine Oberfläche, die auf einem schnellen LCD gut aussieht, kann auf E-Ink flackern, überlagert wirken oder erst verspätet erscheinen. Baue daher ruhig, kontrastreich und geometrisch deterministisch.

### 4.1 Robuster Widgetaufbau

Für eine Karte oder Schaltfläche ist eine explizite Struktur aus `FrameContainer`, `CenterContainer`, `OverlapGroup` und `TextWidget` gut geeignet. Text sollte als tatsächliches Kind in der Widgettabelle stehen:

```lua
FrameContainer:new{
    width = button_width,
    height = button_height,
    padding = 0,
    bordersize = 0,
    background = Blitbuffer.COLOR_LIGHT_GRAY,
    CenterContainer:new{
        dimen = Geom:new{ w = button_width, h = button_height },
        TextWidget:new{
            text = "Save",
            face = Font:getFace("smallinfofont", scale(12)),
            fgcolor = Blitbuffer.COLOR_BLACK,
            bold = true,
            max_width = button_width - scale(8),
        },
    },
}
```

Bei Titel und Untertitel sind feste `overlap_offset`-Positionen innerhalb einer gemeinsamen `OverlapGroup` robuster als eine dynamische Gruppe, deren Größe erst aus ihren Kindern entsteht:

```lua
OverlapGroup:new{
    dimen = Geom:new{ w = button_width, h = button_height },
    allow_mirroring = false,
    TextWidget:new{
        text = "Open document",
        face = Font:getFace("smallinfofont", scale(11)),
        fgcolor = Blitbuffer.COLOR_BLACK,
        bold = true,
        max_width = button_width - scale(10),
        overlap_offset = { scale(5), scale(7) },
    },
    TextWidget:new{
        text = "EPUB / HTML",
        face = Font:getFace("smallinfofont", scale(8)),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = button_width - scale(10),
        overlap_offset = { scale(5), scale(22) },
    },
}
```

Ein häufiger Fehler ist ein variadischer Aufruf wie `VerticalGroup:new(child_a, child_b)`. KOReader erwartet die Kinder als Konstruktor-Tabelle: `VerticalGroup:new{ child_a, child_b }`. Noch wichtiger ist, dass das resultierende Kind tatsächlich in der Widgetstruktur des Parents landet. Die Struktur sollte mit lokalen Testdoubles oder einem Referenzwidget überprüft werden.

### 4.2 Kontrast und Größe

Setze bei wichtigen Texten explizit `fgcolor`, begrenze die Breite mit `max_width` und lasse genügend Innenabstand. Kurze Beschriftungen sind auf geteilten Pane-Flächen zuverlässiger als lange Sätze. Verwende `Device.screen:scaleBySize(...)` für Größen, statt Pixelwerte blind von einem Gerät zu übernehmen.

```lua
local margin = scale(12)
local button_height = scale(36)
local text_width = math.max(scale(20), width - 2 * margin)
```

Überlappende Widgets sollten bewusst mit `overlap_offset` angeordnet werden. Für fünf nebeneinanderliegende Schaltflächen muss die Breite aus der Pane-Breite berechnet werden:

```lua
local gap = scale(6)
local button_width = math.floor((width - 2 * margin - 4 * gap) / 5)
```

### 4.3 Touch und Stylus

Interaktive Widgets sollten `InputContainer` erweitern und ihre `GestureRange` an die lokale Widget-Geometrie binden. Aktualisiere die absoluten Ereignisbereiche in `paintTo`, weil das Widget erst dort seine tatsächliche Position kennt. Ein optionaler Stylus darf nie die Touchbedienung zerstören.

Für Canvas- oder Zeichen-DApps gilt ein anderer Ablauf als für statische Buttons: Das neue Segment wird direkt in den aktiven Screenbuffer geschrieben und danach mit einer kleinen Region per `fast` aktualisiert. Eine vollständige Referenz ist [`draw.lua`](draw.lua), insbesondere `Canvas:_paintLiveSegment` und `Canvas:_refreshDisplay` [3].

## 5. Dialoge, Eingaben und Feedback

Verwende KOReaders vorhandene Widgets für Dialoge und Texteingabe, zum Beispiel `InputDialog`, `ButtonDialog`, `ConfirmBox` und `InfoMessage`. Nach dem Dialogabschluss müssen Dialoge geschlossen und der DApp-Zustand aktualisiert werden.

Eine destruktive Aktion benötigt eine sichtbare Bestätigung:

```lua
local dialog
 dialog = ConfirmBox:new{
    text = "Remove this item?",
    ok_text = "Remove",
    ok_callback = function()
        UIManager:close(dialog)
        state.status = "Removed"
        context.requestRebuild("ui")
    end,
}
UIManager:show(dialog)
```

Bei Netzwerkzugriffen, Übersetzungen, Kernupdates oder dem Löschen lokaler Inhalte muss vor der Aktion klar erkennbar sein, was geschieht und welche Daten das Gerät verlassen. Statusmeldungen gehören in die DApp-Oberfläche oder eine kurze `InfoMessage`, nicht in versteckte Logs.

## 6. Lokale Daten und Dateisicherheit

Lokale Daten gehören in ein eigenes Unterverzeichnis unter `DataStorage:getDataDir()`. Verwende für speicherbare Dokumente eine atomare temporäre Datei und anschließend `os.rename`:

```lua
local DataStorage = require("datastorage")
local DataStorageDir = DataStorage:getDataDir() .. "/my_app"
local path = DataStorageDir .. "/state.lua"
local temporary = path .. ".tmp"

-- Verzeichnis anlegen, Datei vollständig schreiben und schließen.
-- Erst danach temporary atomar nach path umbenennen.
```

Benutzereingaben dürfen nicht ungeprüft als Dateinamen oder Lua-Code verwendet werden. Bereinige Dateinamen, begrenze Dateigrößen und validiere die geladene Struktur nach dem Einlesen. `loadstring` für eigene, zuvor von der DApp erzeugte lokale Daten ist nur mit einer isolierten Umgebung und einer strengen Größen-/Strukturprüfung vertretbar; Benutzereingaben oder Downloads dürfen niemals als Lua-Programm ausgeführt werden.

Wenn eine DApp lokale Dateien aus AppDock Files übernimmt, muss sie Erweiterung, reguläre Datei, Lesbarkeit und Größenlimit prüfen. Sie darf nicht eigenmächtig den KOReader-Standard-Dateimanager öffnen.

## 7. Dateihandover aus AppDock Files

Eine DApp kann passende Dateien über `openFile(instance, path)` akzeptieren. Die Funktion muss `true` beziehungsweise `false, reason` zurückgeben und darf die Datei nur nach eigener Validierung übernehmen:

```lua
openFile = function(instance, path)
    if type(path) ~= "string" or not path:lower():match("%.lua$") then
        return false, "Only Lua files are supported."
    end
    local file = io.open(path, "rb")
    if not file then return false, "The file cannot be read." end
    local source = file:read("*a")
    file:close()
    if not source or #source > 512 * 1024 then
        return false, "The file is too large."
    end
    stateFor(instance).path = path
    stateFor(instance).source = source
    return true
end
```

AppDock Files ruft den Handler über `context.manager:openDAppFile(id, path)` auf. Der Manager aktiviert die DApp erst nach erfolgreicher Annahme [2]. In der aktuellen Kernversion nutzt Files diesen Mechanismus beispielsweise für Lua-Dateien an NightLua sowie EPUB/HTML-Dateien an DReader [4].

## 8. Netzwerk und externe Daten

Netzwerk ist für eine DApp optional. Wenn es benötigt wird, soll die DApp ausschließlich explizit vom Nutzer gestartete Aktionen ausführen. Verwende HTTPS, begrenze Antwortgröße sowie Verbindungs- und Gesamtzeit und ersetze einen gültigen lokalen Cache nicht durch eine fehlerhafte Antwort.

Keine DApp darf JavaScript, HTML, Lua-Code oder beliebige aktive Inhalte aus einer Antwort ausführen. HTML aus Feeds oder Webseiten muss als Text behandelt und vor der Darstellung bereinigt werden. Ein API-Schlüssel gehört nicht in das Repository. Die Architektur von [`rss_reader.lua`](rss_reader.lua) zeigt die vorgesehenen HTTPS-, Größen- und Cache-Grenzen [5].

## 9. AppStore-Katalog

Der öffentliche Katalog [`dapps.txt`](dapps.txt) verwendet eine Zeile pro DApp:

```text
my_app.lua | 1.0.0 | help
examples/quote_card.lua | 1.0.0 | help
```

Der Pfad muss relativ sein, auf `.lua` enden und darf weder mit `/` beginnen noch `..` enthalten. Das Logo muss ein Name aus der AppDock-Logo-Bibliothek sein, zum Beispiel `help`, `notes`, `calculator`, `code`, `calendar`, `document` oder `download`. Unbekannte Logos werden nicht als gültige Metadaten behandelt.

Die Datei muss im selben Repository liegen wie der Katalogeintrag. Nach einer funktionalen Änderung wird die Version erhöht. Ein Bugfix ohne neue Funktionen ist typischerweise ein Patch-Update, beispielsweise `1.0.0` zu `1.0.1`; eine neue kompatible Funktion erhöht die Minor-Version.

## 10. Tests

Eine DApp sollte mindestens drei Ebenen von Tests besitzen:

| Testebene | Prüfung | Kommando/Technik |
|---|---|---|
| Syntax | Lua-5.1-Kompatibilität | `luac5.1 -p my_app.lua` |
| Vertrag | Metadaten, Pane, State, Callback und Fehlerfälle | Isolierter Test mit KOReader-Testdoubles |
| Geometrie | Normale sowie kleine Split-Pane-Größe | Zum Beispiel `600x760` und `600x350` |
| Gerätepfad | E-Ink-Refresh, Stylus, echte Dateipfade | Auf realer Zielhardware zusätzlich prüfen |
| Regression | Andere Katalog-DApps bleiben funktionsfähig | Gesamte lokale Store-Suite ausführen |

Testdoubles sollen nicht nur zählen, dass eine Funktion aufgerufen wurde. Für UI-Bugs muss der Test die tatsächliche Widgetstruktur, Textwerte, Offsets, Farben und Refreshregionen inspizieren. Für eine Zeichen-DApp sollte der Test beispielsweise nachweisen, dass ein Stiftsegment im Screenbuffer landet, bevor `fast` angefordert wird.

Ein Test darf keine lokalen Tests oder Notizen in den öffentlichen Katalog committen. Testdateien können lokal neben den DApps liegen und über `.gitignore` oder bewusstes selektives Staging ausgeschlossen werden.

## 11. Typische Fehler

| Problem | Ursache | Bessere Lösung |
|---|---|---|
| Text ist unsichtbar | Falsche Widgettabelle, fehlender Kontrast oder dynamisch falsch zentrierte Gruppe | Explizite Kinder, `fgcolor`, `max_width` und feste Offsets verwenden |
| Layout bricht im Splitscreen | Globale Bildschirmmaße oder feste Vollbildkoordinaten | Ausschließlich `context.dimen` nutzen |
| Änderung erscheint erst später | Nur Zustand geändert, aber kein Rebuild oder Refresh angefordert | `requestRebuild("ui")` beziehungsweise regionale `requestRefresh("fast", region)` verwenden |
| E-Ink flackert | Fullrefresh oder UI-Neuaufbau bei jeder Eingabe | Kleine Regionen und `fast` nur für direkte Pixeländerungen verwenden |
| Datei überschreibt sich beim Speichern | Direkt in die Zieldatei geschrieben | Temporär schreiben, schließen, atomar umbenennen |
| App stürzt bei schlechter Datei ab | Ungeprüfte Größe, Struktur oder Erweiterung | Vor jedem Lesen Größen-, Pfad- und Inhaltsvalidierung durchführen |
| Übersetzungsfunktion verschwindet | `_` als Schleifenvariable verwendet | `_` ausschließlich für `gettext` reservieren; Indizes `index`, `position` oder `item_index` nennen |
| Update wird nicht angeboten | Katalog- und DApp-Version unterscheiden sich | Beide Versionen gemeinsam erhöhen und vor dem Push prüfen |

## 12. Veröffentlichung

Vor dem Push sollte der Entwickler die Produktivdatei, den Katalog und mindestens die Dokumentation prüfen. Ein typischer Ablauf lautet:

```sh
cd /path/to/DApps
luac5.1 -p my_app.lua
lua5.1 test_my_app.lua
git diff --check
git add my_app.lua dapps.txt README.md DeveloperManual.md
git commit -m "Add My App DApp"
git push origin main
```

Staged werden nur die vorgesehenen Produktivdateien. Danach muss die Datei aus der tatsächlich veröffentlichten GitHub-Revision erneut über die Raw-URL geladen und mit `luac5.1 -p` geprüft werden. Kontrolliere außerdem, dass der Katalogeintrag exakt auf den neuen Dateinamen, die neue Version und ein gültiges Logo zeigt.

Nach dem Push öffnet der Nutzer in AppDock **AppStore**, wählt **Refresh catalog** und installiert die neue DApp. Bei Updates muss die vorhandene DApp-Version kleiner als die Katalogversion sein. Eine DApp darf ihre eigene Installation nicht als automatisch akzeptierte Vertrauensentscheidung behandeln; der AppStore zeigt Pfad und Aktion an und verlangt eine ausdrückliche Bestätigung.

## 13. Qualitätscheckliste

Vor der Veröffentlichung sollte jede Frage mit „Ja“ beantwortet werden:

- Gibt die Datei eine Tabelle mit eindeutiger `id`, Version, Titel und `buildPane` zurück?
- Baut `buildPane` ein gültiges Widget ausschließlich innerhalb von `context.dimen`?
- Bleibt der Zustand in `instance` erhalten und ist der Neuaufbau deterministisch?
- Sind alle wichtigen Textwidgets sichtbar, kontrastreich und in kleinen Panes lesbar?
- Werden normale UI-Aktionen mit `requestRebuild("ui")` und Pixeländerungen mit regionalem `fast` behandelt?
- Werden keine globalen Bildschirmmaße, Hintergrundjobs, unnötigen Animationen oder Fullrefresh-Schleifen verwendet?
- Sind Dateipfade, Dateigrößen, Inhalte und lokale Speicherdateien validiert und atomar behandelt?
- Sind Netzwerkzugriffe HTTPS-only, größenbegrenzt, zeitbegrenzt und nutzerinitiiert?
- Gibt es Tests für normale Größe, Splitscreen, Fehlerfälle und die reale Widgetstruktur?
- Stimmen DApp-Version, Katalogversion und Release-Dokumentation überein?

## 14. Weiterführende Referenzen

Die vorhandene Beispiel-DApp ist der beste Einstieg für eine einfache Offline-App. Für komplexere Anforderungen sollten zusätzlich eine etablierte DApp mit Dialogen, eine Dateihandover-DApp und eine direkt zeichnende DApp gelesen werden. Die folgenden Dateien sind bewusst Teil des öffentlichen Repositorys und dienen als verifizierbare Referenzimplementierungen.

## References

[1]: examples/quote_card.lua "Minimales AppDock-DApp-Beispiel"
[2]: https://github.com/arduinodude456/appdock.koplugin/blob/1.7.0/appdock_dapps.lua "AppDock 1.7.0: DApp-Verwaltung und Kontextvertrag"
[3]: draw.lua "Draw: direkter Canvas- und E-Ink-Fast-Refresh"
[4]: https://github.com/arduinodude456/appdock.koplugin/blob/1.7.0/appdock_filemanager.lua "AppDock 1.7.0: Files und DApp-Dateihandover"
[5]: rss_reader.lua "RSS Reader: HTTPS-, Cache- und Textsicherheitsgrenzen"
