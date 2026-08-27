# AppDock DApps

Dieses Repository ist der **vertrauenswürdige AppStore-Katalog** für die AppDock-DApp in KOReader. Der AppStore lädt ausschließlich die Datei [`dapps.txt`](dapps.txt) über HTTPS. Ein Katalogabruf führt keinen DApp-Code aus. Vor jeder Installation wird der vollständige Pfad angezeigt und der Nutzer muss die Installation auf dem Gerät ausdrücklich bestätigen.

> **Sicherheitsmodell:** Eine installierte DApp ist Lua-Code und läuft innerhalb von KOReader. Füge deshalb nur selbst geprüfte DApps in diesen Katalog ein. Designs sind dagegen bewusst **deklarative Daten**: Sie werden nicht als Lua geladen oder ausgeführt. Der AppStore akzeptiert keine absoluten Pfade und keine Pfade mit `..`.

## Katalog

`dapps.txt` enthält eine sichere relative Datei pro Zeile. **DApps und Widgets** verwenden die Endung `.lua`; **Designs** nutzen ausschließlich `.appdock-design`. Nach dem Pfad stehen eine numerische Version, ein AppDock-Logo und optional der Typ `widget` oder `design`. Ohne Typ ist der Eintrag eine DApp. Leerzeilen und Zeilen, die mit `#` beginnen, werden ignoriert.

```text
# Example catalog
examples/quote_card.lua | 1.0.0 | help
examples/reading_timer.lua | 1.2.0 | timer
quote_widget.lua | 1.0.0 | help | widget
designs/forest.appdock-design | 1.0.0 | palette | design
```

Der AppStore vergleicht numerische Versionen komponentenweise. Ist die Repository-Version höher als die installierte Version, wird **Update** statt einer Installationssperre angeboten. Die Logo-Spalte akzeptiert ausschließlich Namen aus AppDocks Logo-Bibliothek, etwa `calculator`, `code`, `help`, `notes`, `timer` oder `translate`; ungültige Logoangaben werden ignoriert. Doppelte Pfade werden weiterhin ignoriert; die Reihenfolge im Katalog beeinflusst die Installationslogik nicht.

## Designs

Ein Design ist eine kleine UTF-8-Textdatei mit festen `key=value`-Zeilen. Der AppStore akzeptiert nur die Felder `id`, `title`, `version`, `highlight`, `background`, `button`, `text`, `dropdown`, `button_style`, `logo_shape` und `wallpaper`. Alle fünf Farbwerte müssen als sechsstellige Hexfarbe vorliegen. Der Buttonstil ist `rounded` oder `3d`, die App-Logoform `rounded` oder `circle`. Ein optionales Hintergrundbild muss als sicherer relativer PNG-, JPG-, JPEG- oder WEBP-Pfad im selben Repository liegen.

Nach dem Bestätigen lädt AppDock die Textdatei und gegebenenfalls das Hintergrundbild ausschließlich lokal herunter. Anschließend werden Highlight-, Hintergrund-, Button-, Text- und Dropdownfarbe, der gewählte Buttonstil und die App-Logoform gemeinsam aktiviert. Ein erneutes Antippen eines installierten Designs aktiviert es wieder; **Uninstall** entfernt die lokalen Designdateien und stellt die vorhandene persönliche Theme-, Button- und Hintergrundkonfiguration wieder her.

| Design | Charakter | Stil |
|---|---|---|
| [`Galaxy`](designs/galaxy.appdock-design) | Dunkles Indigo mit violettem Sternennebel | 3D-Schaltflächen, runde App-Logos |
| [`Forest`](designs/forest.appdock-design) | Ruhiges Moosgrün mit nebligen Waldschichten | Abgerundete Schaltflächen und App-Logoflächen |
| [`Coffee`](designs/coffee.appdock-design) | Warmes Espresso, Kakao und Creme | 3D-Schaltflächen, runde App-Logos |
| [`Old Paper`](designs/old-paper.appdock-design) | Helles Pergament mit dezenten Alterungsspuren | Abgerundete Schaltflächen und App-Logoflächen |
| [`Ozean`](designs/ozean.appdock-design) | Tiefes Blaugrün mit sanften Wellen | 3D-Schaltflächen, runde App-Logos |

## DApp-Modulformat

Jede gelistete DApp-Lua-Datei muss eine Tabelle mit mindestens `id`, `title` und `buildPane` zurückgeben. Ein Store-Widget verwendet stattdessen `buildWidget(instance, context)`. Für aktualisierbare Store-Einträge gehört außerdem eine numerische `version` wie `1.0.0` in die Tabelle.

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

## Store-Widgets

Store-Widgets sind kleine, passive Homescreen-Karten. Sie werden mit dem vierten Manifestfeld `widget` gekennzeichnet und nach der Installation automatisch auf dem Homescreen aktiviert. Unter **Manage apps and widgets → Store widgets** können sie ausgeblendet werden. Der Widget-Vertrag erhält eine lokale `context.dimen`-Geometrie und muss ein KOReader-Widget zurückgeben; Netzwerkzugriffe, Hintergrundprozesse und aktive Inhalte gehören nicht in ein Widget. AppDock baut sichtbare Widgets bei Bedarf neu auf und aktualisiert sie E-Ink-gerecht im Drei-Minuten-Takt.

Das Beispiel [`quote_widget.lua`](quote_widget.lua) enthält drei lokale Zitate und zeigt jeweils eines auf einer kontrastreichen Karte. Es verwendet keinen Netzwerkdienst und speichert keine persönlichen Daten.

## Random Book Covers Widget

[`random_book_covers_widget.lua`](random_book_covers_widget.lua) zeigt bis zu drei zufällig ausgewählte Bücher aus der **lokalen KOReader-Lesehistorie**. Wenn KOReaders BookInfo-Schnittstelle ein echtes lokales Cover bereitstellt, wird dieses Cover auf einer E-Ink-tauglichen Dreierkarte gerendert. Fehlt ein Cover, bleibt der echte lokale Buchtitel sichtbar und der Slot zeigt **No local cover**; bei leerer Historie zeigt das Widget keinen erfundenen Buchtitel oder ein Platzhaltercover.

Das Widget verwendet weder Netzwerk noch Hintergrundaufgaben, externe Metadaten oder generierte Bilder. Es betrachtet höchstens 24 lokale Verlaufseinträge und stellt höchstens drei Coveranfragen. Die von KOReader bereitgestellten Cover-Blitbuffer werden an den regulären `ImageWidget`-Lebenszyklus übergeben und beim Schließen freigegeben.

## Weather Widget

[`weather_widget.lua`](weather_widget.lua) zeigt aktuelle Wetterbedingungen von der öffentlichen [Open-Meteo Forecast API](https://open-meteo.com/en/docs). Die Beispielkonfiguration verwendet Berlin; Entwickler oder Nutzer können Name, Breitengrad und Längengrad in der Datei vor der Installation anpassen. Das Widget fragt nur aktuelle Temperatur, Luftfeuchtigkeit, Wettercode, Windgeschwindigkeit und Tag/Nacht-Status ab und zeigt die Daten in einer kontrastreichen Homescreen-Karte.

Der Abruf erfolgt ausschließlich über HTTPS, ist auf 96 KiB Antwortgröße sowie kurze Netzwerkzeiten begrenzt und validiert die JSON-Struktur vor der Anzeige. Der letzte erfolgreiche Stand bleibt im Widget-Zustand erhalten; vor Ablauf von 180 Sekunden wird kein neuer Abruf ausgelöst. Bei einem Fehler bleibt der letzte Wert sichtbar oder es erscheint eine verständliche Offline-Meldung. Das Widget führt keine Standortberechtigung, automatische Ortung, Hintergrundschleife oder aktive Webinhalte aus.

> **Open-Meteo-Hinweis:** Die kostenlose Open-Meteo-API ist laut [Nutzungsbedingungen](https://open-meteo.com/en/terms) für nicht-kommerzielle Nutzung vorgesehen und unterliegt dort genannten Aufrufgrenzen. Das Widget enthält deshalb eine sichtbare Open-Meteo-Kennung und ist für persönliche AppDock-Nutzung ausgelegt.

## DockUpdate

[`dock_update.lua`](dock_update.lua) ist die **manuelle Kernaktualisierung** für AppDock. In Version **1.0.3** ignoriert DockUpdate Markdown-Dokumentation wie `README.md` und erkennt vollständige Releases mit einem `appdock.koplugin/`-Paketspiegel. Wenn dieser Spiegel vollständig ist, verwendet DockUpdate daraus die aktuellen Kernmodule und entfernt den Paketpräfix beim Staging; veraltete Root-Dateien können dadurch nicht mehr das Update überschreiben. Mit **Check updates** fragt sie ausschließlich den neuesten stabilen Release von [`arduinodude456/appdock.koplugin`](https://github.com/arduinodude456/appdock.koplugin) über HTTPS ab. Die Karte zeigt installierte und veröffentlichte Version, eine Zusammenfassung der Release Notes sowie den Updatestatus; **Release Notes** öffnet den vollständigen, lesbaren Release-Text.

Eine Aktualisierung startet niemals automatisch. Erst nach einer ausdrücklichen Bestätigung prüft DockUpdate die freigegebene AppDock-Dateiliste, begrenzt deren Größe, lädt die etablierten Lua-Kernmodule einzeln über HTTPS, prüft ihre Lua-Syntax und schreibt sie in ein Staging-Verzeichnis. Danach ersetzt ein atomarer Ordnerwechsel die aktive Pluginversion. Der vorherige AppDock-Ordner bleibt als Rückrollkopie neben dem Plugin erhalten.

> **Wichtig:** Nach einer erfolgreichen Aktualisierung muss KOReader neu gestartet werden, damit die neuen Pluginmodule geladen werden. DockUpdate akzeptiert ausschließlich stabile Releases des fest eingebauten AppDock-Repositorys, nur erwartete root-level Lua-Kernmodule und keine absoluten Pfade, `..`-Pfade, Archive, Binärdateien oder Hintergrundaktualisierungen.

## BookTranslator

[`book_translator.lua`](book_translator.lua) übersetzt **TXT**, **HTML/XHTML** und **FB2** über eine wählbare Providerkarte. Standardmäßig ist **DeepL API Free** aktiv; die DApp verwendet dafür fest `https://api-free.deepl.com/v2/translate` und benötigt einen persönlichen DeepL-API-Free-Schlüssel. Durch Antippen der Providerkarte lässt sich jederzeit zurück zu **LibreTranslate** wechseln, dessen HTTPS-Endpunkt und optionaler Schlüssel konfigurierbar bleiben.

Die Originaldatei wird niemals verändert. Bei Erfolg entsteht daneben eine neue Datei wie `roman.de.translated.fb2`. Der Text wird absatzweise und größenbegrenzt an den gewählten Dienst gesendet. EPUB, PDF und MOBI werden in dieser Version bewusst nicht verändert, weil ihre Container oder ihr Layout für einen zuverlässigen Export eine gesonderte Verarbeitung benötigen.

> **Datenschutz:** Der Buchtext verlässt das Gerät nur nach der sichtbaren Übersetzungsbestätigung und ausschließlich zum in der DApp angezeigten DeepL- oder LibreTranslate-Endpunkt. Für vertrauliche Texte empfiehlt sich ein selbst betriebener LibreTranslate- bzw. Argos-Translate-Dienst.

## Calc

[`calc.lua`](calc.lua) verbindet einen wissenschaftlichen Taschenrechner mit einem Funktionsplotter. Calc wertet Ausdrücke über einen eigenen begrenzten Parser aus und führt **nie** frei eingegebenen Lua-Code aus. Unterstützt werden `+`, `-`, `*`, `/`, `^`, Klammern, die Konstanten `pi` und `e` sowie `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `sqrt`, `abs`, `exp`, `ln`, `log`, `floor` und `ceil`. Die Trigonometrie arbeitet im **Bogenmaß**.

Für den Plotter wird die Variable `x` verwendet, zum Beispiel `sin(x)` oder `x^2-4`. **Range** legt den sichtbaren x-Bereich fest; der y-Bereich ist bewusst auf `-10` bis `10` fixiert, um auf E-Ink-Displays eine stabile und schnell erkennbare Achsenskalierung zu behalten. Der lokale Verlauf speichert die letzten zwölf Berechnungen, solange die DApp geöffnet ist.

> **Sicherheitsgrenze:** Ausdruckslänge, Tokenanzahl, Namen, Funktionen und Wertebereich sind begrenzt. Unbekannte Namen, Lua-Syntax, Dateizugriffe, Anweisungen und Division durch null werden abgewiesen.

## RSS Reader

[`rss_reader.lua`](rss_reader.lua) ist ein **lokaler, textorientierter Feedreader** für explizit hinzugefügte RSS-2.0- und Atom-Feeds. Die DApp zeigt eine Feedliste, eine begrenzte Artikelübersicht und einen paginierten E-Ink-Lesemodus. Feedbeschreibungen werden als Plain Text gelesen; entfernte HTML-, Skript- und Style-Anteile können nicht ausgeführt werden.

Über **+ Feed** wird eine Feedadresse hinzugefügt. RSS Reader akzeptiert ausschließlich `https://`-URLs, begrenzt Antwortgröße, Verbindungszeit, Gesamtzeit und die Zahl gelesener Artikel. **Refresh all** sowie die feedbezogene Aktualisierung holen Daten nur auf ausdrückliche Nutzeraktion. Ein fehlerhafter Abruf oder ungültiger Feed ersetzt den zuletzt gültigen lokalen Artikelcache nicht.

> **Datenschutz und Grenzen:** RSS Reader führt weder JavaScript noch HTML aus, öffnet Artikel-Originaladressen nicht automatisch und unterstützt keine Feed-Logins, HTTP-Adressen, OPML, Podcasts, Bilder oder Hintergrundaktualisierungen. Feedliste, begrenzter Artikelcache und Lesestatus bleiben lokal im KOReader-Datenverzeichnis.

## Calendar

[`calendar.lua`](calendar.lua) ist ein **lokaler Monatsplaner** für AppDock. Die DApp zeigt eine E-Ink-geeignete Sechszeilen-Monatsansicht mit Montag als Wochenbeginn, hebt Heute sowie den ausgewählten Tag hervor und markiert Tage mit Terminen. Pfeiltasten wechseln den Monat; **Today** kehrt zum aktuellen Monat zurück.

Ein Antippen eines Tages aktualisiert die Detailkarte. Über **+ Event** wird ein kurzer Termin für den ausgewählten Tag angelegt. Die Tagesdetails zeigen vorhandene Termine; das Antippen eines Termins verlangt eine ausdrückliche Bestätigung vor dem Entfernen. Termine, ausgewählter Monat und Datenbestand werden lokal und atomar im KOReader-Datenverzeichnis gespeichert.

> **Datenschutz und Grenzen:** Calendar synchronisiert nicht mit Systemkalendern, Konten oder ICS-Dateien und erstellt keine Hintergrund-Erinnerungen. Die DApp nutzt weder Netzwerk noch Hintergrundprozesse; alle Termine bleiben ausschließlich lokal in Calendar.

## DReader

[`dreader.lua`](dreader.lua) ist seit Version **2.0.0** ein ruhiger, **stateful** AppDock-Reader für lokale EPUB-, HTML-, HTM- und XHTML-Dokumente. Er enthält eine eigene Bibliothek der zuletzt geöffneten Bücher, einen Seitenbrowser ohne Vorschauen, seitenorientiertes Blättern, ein-/ausblendbare Bedienelemente, Schriftstufen, anpassbare Ränder, persistenten Lesefortschritt sowie Lesezeichen mit optionalen Anmerkungen.

Bei EPUB nutzt DReader KOReaders Archivschnittstelle, um `META-INF/container.xml`, OPF, Manifest, Spine und – sofern vorhanden – EPUB-3-Navigation oder NCX auszulesen. Ein Buch wird nicht pauschal entpackt: Nur benötigte, begrenzte reguläre Archiveinträge werden in den Speicher gelesen. HTML/XHTML wird als Lesetext normalisiert; lokale Rasterbilder werden in einem begrenzten Bildbereich gerendert. Eingebettete CSS-Metadaten für Schriftfamilie, Grundgröße und Textfarbe werden berücksichtigt; unbekannte Schriften fallen sicher auf KOReaders Standardschrift zurück. Skripte, interaktive Elemente und browserartige Ausführung bleiben ausgeschlossen.

> **Installation und Öffnen:** DReader benötigt **AppDock 1.7.0**. Nach der Installation zeigt die eigene **Files**-DApp bei `.epub`, `.html`, `.htm` und `.xhtml` den Eintrag **Open in DReader**. Alternativ kann ein absoluter lokaler Pfad in DReaders Bibliothek eingegeben werden.

DReader ist bewusst kein vollständiger Webbrowser und kein Ersatz für KOReaders professionelle Satzengine: komplexes CSS, JavaScript, DRM-EPUBs, SVG-/Vektor-only-Bilder, interaktive Inhalte und entfernte Ressourcen werden nicht vollständig unterstützt. Die 2.0.0 konzentriert sich auf robustes lokales Lesen, begrenztes Bild-Rendering, direkte Seitenauswahl und nachvollziehbare Lesezeichen. Lesezeichen werden als `[buchname].lz` neben der Quelldatei gespeichert.

## BWR Video

[`bwr_video.lua`](bwr_video.lua) ist die **neu aufgebaute, empfohlene** BWR1-Video-DApp. Sie wurde bewusst als frischer Store-Eintrag mit eigener DApp-ID erstellt und enthält weder eine `Player`-Klasse noch Testexporte oder die frühere Player-Laufzeitstruktur. Dadurch lädt AppDock sie unabhängig von jeder zuvor installierten VideoPlayer-Version.

Die DApp spielt ausschließlich lokale, vorab geditherte `.bwr`-Dateien ab, bietet **Open video**, **−5 s**, **Play/Pause**, **+5 s** und **Stop** und aktualisiert die Canvas nur regional mit `fast`. Eine gleichnamige `.wav`-Datei wird als optionaler Begleitton erkannt und über den bestehenden Systemaudio-Ausgang – also auch über ein bereits verbundenes Bluetooth-Headset – ausgegeben. Bluetooth-Paarung bleibt beim System.

> Nach der Installation von BWR Video sollte die fehlerhafte DApp **VideoPlayer** über deren AppStore-Karte mit **Uninstall** entfernt werden. BWR Video ist kein Update dieser alten DApp, sondern ein bewusst unabhängiger Neuaufbau.

## VideoPlayer

[`video_player.lua`](video_player.lua) spielt lokale, für E-Ink vorbereitete **BWR1**-Dateien (`.bwr`) ab. BWR1 ist ein vorab gedithertes, 1-Bit-schwarzweißes Rohvideoformat: Die DApp decodiert bewusst **keine** komprimierten Container wie MP4, WebM oder MKV. Dadurch bleiben Framedaten, Speicherbedarf und regionale E-Ink-Updates vorhersehbar.

Über **Open video** wird ein lokaler absoluter `.bwr`-Pfad gewählt. Eine gleichnamige `.wav`-Datei wird automatisch als Begleitton erkannt; über **Audio WAV** lässt sich ein anderer lokaler WAV-Pfad wählen oder die Wiedergabe stummschalten. Die Wiedergabeoberfläche bietet Play/Pause, ±5 Sekunden und Stop, behält die Dateiauswahl als DApp-Zustand und beendet aktive Prozesse beim Verlassen der DApp. Jedes neue Bild wird ausschließlich regional mit `fast` aktualisiert.

> **Bluetooth-Audio:** VideoPlayer verwaltet keine Bluetooth-Paarung. Wenn ein Headset bereits im Betriebssystem verbunden ist und der gerätespezifische Audio-Backend-Pfad verfügbar ist, sendet die DApp den WAV-Ton an genau diese Systemaudio-Ausgabe. Auf Kobo kann dies abhängig von Firmware und Modell GStreamer mit MediaTek-Audioausgabe oder ALSA/aplay sein; andere Geräte benötigen ein verfügbares `aplay` oder `tinyplay`. Bluetooth-Verhalten wurde nicht auf konkreter Hardware getestet.

## Draw

[`draw.lua`](draw.lua) ist ein mehrseitiges E-Ink-Skizzenbuch für AppDock. Es speichert Striche als bearbeitbare Vektorpunkte in einem eigenen lokalen `.draw.lua`-Format und kann gespeicherte Zeichnungen wieder laden. Jede Zeichnung besitzt mehrere Seiten mit den Hintergrundtypen **blank**, **lined**, **grid** oder einem optionalen Bildhintergrund über einen vom Nutzer eingegebenen PNG-, JPG-, GIF- oder WEBP-Pfad.

Die Werkzeugleiste bietet sieben Schnellfarben, eine Eingabe für eine sechsstellige eigene Farbe, einen Stiftdicken-Slider, Radierer, Seitenwechsel, neue Seiten sowie Speichern und Laden. Auf Geräten, auf denen KOReader Stylus-Slots bereitstellt, übernimmt Draw deren Stifteingaben exklusiv innerhalb der Canvas. Kobo-artige Radierer- und Markiertasten werden als Radierer beziehungsweise breiterer Marker übernommen; falls ein Druckwert mitgeliefert wird, beeinflusst er die Strichstärke. Ohne solche Hardware bleibt die Zeichenfläche vollständig per Touch-Pan und Tippen verwendbar.

Ab **Version 1.2.1** zeichnet Draw jeden erfassten Strichabschnitt direkt in den aktiven Screenbuffer und fordert anschließend ausschließlich für dessen kleine absolute Region einen KOReader-Refresh mit `fast` an. Dadurch werden Stift und Radierer vor dem Refresh gleich behandelt und sofort sichtbar. Auf Farb-E-Ink-Geräten verwendet Draw während des schnellen Zeichnens eine kontraststarke schwarze Vorschau; beim regulären Canvas-Neuzeichnen bleibt die ausgewählte Farbe erhalten. Vor dem nächsten Punkt gibt Draw dem E-Ink-Controller kurz Zeit, die regionale Übertragung zu starten. Dieser Pfad nutzt bewusst keinen Vollrefresh.

> **E-Ink-Hinweis:** Draw zeichnet während einer Bewegung und beim Abschluss eines Strichs nur die Canvas mit einem schnellen regionalen Update neu. Stiftdruck und Seitentasten sind geräte- und KOReader-abhängig; sie werden daher auf dem Zielgerät getestet, nicht vorausgesetzt.

## NightLua

[`night_lua.lua`](night_lua.lua) ist ein E-Ink-tauglicher Editor für **Lua-Dateien**. Nach der Installation wird eine `.lua`-Datei in der eigenen AppDock-DApp **Files** mit **Open in NightLua** direkt an den Editor übergeben; KOReaders Standard-Dateimanager wird dabei nicht verwendet.

NightLua zeigt im DApp-Pane eine scrollbar Syntaxhervorhebung für Schlüsselwörter, Literale, Zahlen, Zeichenketten und Kommentare. **Edit** öffnet KOReaders nativen Vollbild-Mehrzeileneditor mit Monospace-Schrift, **Check** prüft Lua-Syntax, und **Save** schreibt nach erfolgreicher Syntaxprüfung über eine temporäre Datei zurück. NightLua akzeptiert nur reguläre `.lua`-Dateien bis 512 KiB und ändert keine andere Dateiart.

> **Hinweis:** Die Live-Eingabe verwendet bewusst KOReaders bewährtes natives Texteingabefeld. Die farbige beziehungsweise kontrastverstärkte Syntaxansicht ist die separate, nach dem Speichern oder Aktualisieren angezeigte Vorschau im NightLua-Pane.

## DBASIC

[`dbasic.lua`](dbasic.lua) ist ein kleiner, vollständig lokaler BASIC-Editor und -Interpreter für AppDock. Programme bestehen aus nummerierten Zeilen. DBASIC unterstützt `PRINT`, Zuweisungen mit und ohne `LET`, `IF … THEN`, `GOTO`, `FOR … TO … STEP … NEXT`, `CLS`, `COLOR`, `PSET`, `LINE`, `RECT`, `ON TOUCH GOTO` sowie `END` und `STOP`. Numerische Ausdrücke bieten Klammern, `+`, `-`, `*`, `/`, `^`, Vergleiche und die Funktionen `RND`, `ABS`, `INT`, `MIN` und `MAX`.

Die Grafikfläche arbeitet mit einem festen virtuellen Koordinatensystem von **160 × 100**. `PSET`, `LINE` und `RECT` werden darauf skaliert; `COLOR` akzeptiert drei kontrastreiche E-Ink-Stufen. Mit `ON TOUCH GOTO 100` kann ein Programm den nächsten Tipp auf die Grafikfläche abfangen. Die bereitgestellte Touch-Demo zeigt diesen Ablauf direkt.

> **Sicherheitsgrenze:** DBASIC wertet niemals Lua aus und akzeptiert keine Dateizugriffe, Shellbefehle, Netzwerkzugriffe, dynamischen Code, `POST`-Anfragen oder unbegrenzte Schleifen. Programmgröße, Variablen, Schleifentiefe, Grafikanweisungen, Ausgabetext und maximale Ausführungsschritte sind fest begrenzt. Fehler nennen stets die betreffende BASIC-Zeilennummer.

## Beispiel

[`examples/quote_card.lua`](examples/quote_card.lua) ist eine kleine offline DApp und ein minimaler Ausgangspunkt für neue DApps.
