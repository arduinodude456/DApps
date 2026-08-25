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

## BookTranslator

[`book_translator.lua`](book_translator.lua) übersetzt **TXT**, **HTML/XHTML** und **FB2** über eine wählbare Providerkarte. Standardmäßig ist **DeepL API Free** aktiv; die DApp verwendet dafür fest `https://api-free.deepl.com/v2/translate` und benötigt einen persönlichen DeepL-API-Free-Schlüssel. Durch Antippen der Providerkarte lässt sich jederzeit zurück zu **LibreTranslate** wechseln, dessen HTTPS-Endpunkt und optionaler Schlüssel konfigurierbar bleiben.

Die Originaldatei wird niemals verändert. Bei Erfolg entsteht daneben eine neue Datei wie `roman.de.translated.fb2`. Der Text wird absatzweise und größenbegrenzt an den gewählten Dienst gesendet. EPUB, PDF und MOBI werden in dieser Version bewusst nicht verändert, weil ihre Container oder ihr Layout für einen zuverlässigen Export eine gesonderte Verarbeitung benötigen.

> **Datenschutz:** Der Buchtext verlässt das Gerät nur nach der sichtbaren Übersetzungsbestätigung und ausschließlich zum in der DApp angezeigten DeepL- oder LibreTranslate-Endpunkt. Für vertrauliche Texte empfiehlt sich ein selbst betriebener LibreTranslate- bzw. Argos-Translate-Dienst.

## NightLua

[`night_lua.lua`](night_lua.lua) ist ein E-Ink-tauglicher Editor für **Lua-Dateien**. Nach der Installation wird eine `.lua`-Datei in der eigenen AppDock-DApp **Files** mit **Open in NightLua** direkt an den Editor übergeben; KOReaders Standard-Dateimanager wird dabei nicht verwendet.

NightLua zeigt im DApp-Pane eine scrollbar Syntaxhervorhebung für Schlüsselwörter, Literale, Zahlen, Zeichenketten und Kommentare. **Edit** öffnet KOReaders nativen Vollbild-Mehrzeileneditor mit Monospace-Schrift, **Check** prüft Lua-Syntax, und **Save** schreibt nach erfolgreicher Syntaxprüfung über eine temporäre Datei zurück. NightLua akzeptiert nur reguläre `.lua`-Dateien bis 512 KiB und ändert keine andere Dateiart.

> **Hinweis:** Die Live-Eingabe verwendet bewusst KOReaders bewährtes natives Texteingabefeld. Die farbige beziehungsweise kontrastverstärkte Syntaxansicht ist die separate, nach dem Speichern oder Aktualisieren angezeigte Vorschau im NightLua-Pane.

## Beispiel

[`examples/quote_card.lua`](examples/quote_card.lua) ist eine kleine offline DApp und ein minimaler Ausgangspunkt für neue DApps.
