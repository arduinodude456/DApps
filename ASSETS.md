# Assets

## Minecraft-Logo

`assets/minecraft_logo_eink.png` ist die kontrastreiche E-Ink-Variante von `assets/minecraft_logo.png`.

`assets/minecraft_logo.png` ist eine gerenderte PNG-Version der Wikimedia-Commons-Datei [Minecraft Logo-en.svg](https://commons.wikimedia.org/wiki/File:Minecraft_Logo-en.svg). Die Commons-Datei nennt Mojang Studios als Quelle und verweist auf `minecraft-core-brand.svg`; die Datei ist dort als gemeinfrei wegen fehlender urheberrechtlicher Schöpfungshöhe markiert. Markenrechte bleiben unberührt.

## AppStore-Installation

Der AppStore-Installer lädt für eine Store-DApp aktuell nur die in `dapps.txt` genannte Lua-Datei. Deshalb enthält `minecraft.lua` seit 4.3.3 zusätzlich eine eingebettete E-Ink-Logo-Payload und schreibt sie beim ersten Splashscreen-Aufruf in den AppDock-Datenordner.

## AppStore-Hintergrundbilder

Für alle 48 auslieferbaren Apps, Spiele, Widgets und Designs enthält das Repository individuell KI-generierte AppStore-Hintergrundbilder als optimierte RGB-PNG-Dateien mit **1600 × 900 Pixeln (exakt 16:9)**. Die Motive orientieren sich an der jeweiligen Funktion beziehungsweise an der Farbpalette des Designs. Sie bleiben weitgehend textfrei und lassen links ruhigen Platz für die Bedienelemente der Store-Karte; beim 2048-Motiv gehören die Spielzahlen zum Bild.

Der AppStore ersetzt die Endung des vollständigen Katalogpfads durch `.png` und versucht anschließend `.jpg` als Fallback. Das Bild liegt deshalb **neben der jeweiligen Lua- oder Designdatei und hat denselben Basisnamen**: `calc.lua` → `calc.png`, `examples/quote_card.lua` → `examples/quote_card.png`, `InkBlog/inkblog.lua` → `InkBlog/inkblog.png` und `designs/forest.appdock-design` → `designs/forest.png`. DApp-ID, Titel und Logo-Spalte bestimmen den Bildpfad nicht. Das ältere `calculator.png` ist somit nicht das Store-Bild von `calc.lua`; dafür ist `calc.png` zuständig.

Die Abdeckung umfasst alle Einträge aus `dapps.txt` und `games.txt` sowie die eigenständige, noch nicht katalogisierte DApp `bwr_video.lua`. Testdateien und interne Laufzeitbibliotheken sind keine Store-Einträge. Die bisherigen JPG-Dateien bleiben als historische Fallbacks erhalten; die neuen PNG-Dateien werden bevorzugt geladen.

Die fünf Vorschaubilder unter `designs/` sind von den eigentlichen Hochformat-Wallpapern unter `designs/wallpapers/` getrennt. Die in den `.appdock-design`-Dateien referenzierten Wallpaper und alle Designparameter bleiben unverändert. Ebenso werden keine App-Funktionen, Katalogeinträge oder Versionsnummern für diesen reinen Asset-Austausch geändert.
