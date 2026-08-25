# AppDock DApps

Dieses Repository ist der **vertrauenswürdige AppStore-Katalog** für die AppDock-DApp in KOReader. Der AppStore lädt ausschließlich die Datei [`dapps.txt`](dapps.txt) über HTTPS. Ein Katalogabruf führt keinen DApp-Code aus. Vor jeder Installation wird der vollständige Pfad angezeigt und der Nutzer muss die Installation auf dem Gerät ausdrücklich bestätigen.

> **Sicherheitsmodell:** Eine installierte DApp ist Lua-Code und läuft innerhalb von KOReader. Füge deshalb nur selbst geprüfte DApps in diesen Katalog ein. Der AppStore akzeptiert keine absoluten Pfade und keine Pfade mit `..`.

## Katalog

`dapps.txt` enthält **eine relative `.lua`-Datei pro Zeile**. Leerzeilen und Zeilen, die mit `#` beginnen, werden ignoriert.

```text
# Example catalog
examples/quote_card.lua
examples/reading_timer.lua
```

Die Reihenfolge im Katalog beeinflusst die Installationslogik nicht. Doppelte Einträge werden vom AppStore ignoriert.

## DApp-Modulformat

Jede gelistete Lua-Datei muss eine Tabelle mit mindestens `id`, `title` und `buildPane` zurückgeben.

```lua
return {
    id = "quote_card",
    title = "Quote Card",
    subtitle = "A small offline card",
    symbol = "Q",
    logo = "help",
    buildPane = function(instance, context)
        -- Return a KOReader widget that only uses context.dimen.
    end,
}
```

Die `id` darf nur Buchstaben, Ziffern, `_` und `-` enthalten. Sie muss im gesamten AppDock-Katalog eindeutig sein. DApps müssen ihren gesamten sichtbaren Inhalt innerhalb von `context.dimen` aufbauen, damit sie mit Open Apps und Splitscreen funktionieren.

## Beispiel

[`examples/quote_card.lua`](examples/quote_card.lua) ist eine kleine offline DApp und ein minimaler Ausgangspunkt für neue DApps.
