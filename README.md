# AppDock DApps

Dieses Repository ist der **vertrauenswürdige AppStore-Katalog** für die AppDock-DApp in KOReader. Der AppStore lädt ausschließlich die Datei [`dapps.txt`](dapps.txt) über HTTPS. Ein Katalogabruf führt keinen DApp-Code aus. Vor jeder Installation wird der vollständige Pfad angezeigt und der Nutzer muss die Installation auf dem Gerät ausdrücklich bestätigen.

> **Sicherheitsmodell:** Eine installierte DApp ist Lua-Code und läuft innerhalb von KOReader. Füge deshalb nur selbst geprüfte DApps in diesen Katalog ein. Der AppStore akzeptiert keine absoluten Pfade und keine Pfade mit `..`.

## Katalog

`dapps.txt` enthält **eine sichere relative `.lua`-Datei pro Zeile**. Nach dem Pfad können eine numerische Version und ein AppDock-Logo stehen. Leerzeilen und Zeilen, die mit `#` beginnen, werden ignoriert.

```text
# Example catalog
examples/quote_card.lua | 1.0.0 | help
examples/reading_timer.lua | 1.2.0 | timer
```

Der AppStore vergleicht numerische Versionen komponentenweise. Ist die Repository-Version höher als die installierte Version, wird **Update** statt einer Installationssperre angeboten. Die Logo-Spalte akzeptiert ausschließlich Namen aus AppDocks Logo-Bibliothek, etwa `calculator`, `code`, `help`, `notes`, `timer` oder `translate`; ungültige Logoangaben werden ignoriert. Doppelte Pfade werden weiterhin ignoriert; die Reihenfolge im Katalog beeinflusst die Installationslogik nicht.

## DApp-Modulformat

Jede gelistete Lua-Datei muss eine Tabelle mit mindestens `id`, `title` und `buildPane` zurückgeben. Für aktualisierbare Store-DApps gehört außerdem eine numerische `version` wie `1.0.0` in die Tabelle.

```lua
return {
    id = "quote_card",
    version = "1.0.0",
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

## Calc

[`calc.lua`](calc.lua) verbindet einen wissenschaftlichen Taschenrechner mit einem Funktionsplotter. Calc wertet Ausdrücke über einen eigenen begrenzten Parser aus und führt **nie** frei eingegebenen Lua-Code aus. Unterstützt werden `+`, `-`, `*`, `/`, `^`, Klammern, die Konstanten `pi` und `e` sowie `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `sqrt`, `abs`, `exp`, `ln`, `log`, `floor` und `ceil`. Die Trigonometrie arbeitet im **Bogenmaß**.

Für den Plotter wird die Variable `x` verwendet, zum Beispiel `sin(x)` oder `x^2-4`. **Range** legt den sichtbaren x-Bereich fest; der y-Bereich ist bewusst auf `-10` bis `10` fixiert, um auf E-Ink-Displays eine stabile und schnell erkennbare Achsenskalierung zu behalten. Der lokale Verlauf speichert die letzten zwölf Berechnungen, solange die DApp geöffnet ist.

> **Sicherheitsgrenze:** Ausdruckslänge, Tokenanzahl, Namen, Funktionen und Wertebereich sind begrenzt. Unbekannte Namen, Lua-Syntax, Dateizugriffe, Anweisungen und Division durch null werden abgewiesen.

## Draw

[`draw.lua`](draw.lua) ist ein mehrseitiges E-Ink-Skizzenbuch für AppDock. Es speichert Striche als bearbeitbare Vektorpunkte in einem eigenen lokalen `.draw.lua`-Format und kann gespeicherte Zeichnungen wieder laden. Jede Zeichnung besitzt mehrere Seiten mit den Hintergrundtypen **blank**, **lined**, **grid** oder einem optionalen Bildhintergrund über einen vom Nutzer eingegebenen PNG-, JPG-, GIF- oder WEBP-Pfad.

Die Werkzeugleiste bietet sieben Schnellfarben, eine Eingabe für eine sechsstellige eigene Farbe, einen Stiftdicken-Slider, Radierer, Seitenwechsel, neue Seiten sowie Speichern und Laden. Auf Geräten, auf denen KOReader Stylus-Slots bereitstellt, übernimmt Draw deren Stifteingaben exklusiv innerhalb der Canvas. Kobo-artige Radierer- und Markiertasten werden als Radierer beziehungsweise breiterer Marker übernommen; falls ein Druckwert mitgeliefert wird, beeinflusst er die Strichstärke. Ohne solche Hardware bleibt die Zeichenfläche vollständig per Touch-Pan und Tippen verwendbar.

> **E-Ink-Hinweis:** Draw zeichnet während einer Bewegung nur die Canvas mit einem schnellen regionalen Update neu. Der finale Strich erhält danach einen regulären UI-Refresh. Stiftdruck und Seitentasten sind geräte- und KOReader-abhängig; sie werden daher auf dem Zielgerät getestet, nicht vorausgesetzt.

## NightLua

[`night_lua.lua`](night_lua.lua) ist ein E-Ink-tauglicher Editor für **Lua-Dateien**. Nach der Installation wird eine `.lua`-Datei in der eigenen AppDock-DApp **Files** mit **Open in NightLua** direkt an den Editor übergeben; KOReaders Standard-Dateimanager wird dabei nicht verwendet.

NightLua zeigt im DApp-Pane eine scrollbar Syntaxhervorhebung für Schlüsselwörter, Literale, Zahlen, Zeichenketten und Kommentare. **Edit** öffnet KOReaders nativen Vollbild-Mehrzeileneditor mit Monospace-Schrift, **Check** prüft Lua-Syntax, und **Save** schreibt nach erfolgreicher Syntaxprüfung über eine temporäre Datei zurück. NightLua akzeptiert nur reguläre `.lua`-Dateien bis 512 KiB und ändert keine andere Dateiart.

> **Hinweis:** Die Live-Eingabe verwendet bewusst KOReaders bewährtes natives Texteingabefeld. Die farbige beziehungsweise kontrastverstärkte Syntaxansicht ist die separate, nach dem Speichern oder Aktualisieren angezeigte Vorschau im NightLua-Pane.

## Beispiel

[`examples/quote_card.lua`](examples/quote_card.lua) ist eine kleine offline DApp und ein minimaler Ausgangspunkt für neue DApps.
