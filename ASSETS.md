# Assets

## Minecraft-Logo

`assets/minecraft_logo_eink.png` ist die kontrastreiche E-Ink-Variante von `assets/minecraft_logo.png`.

`assets/minecraft_logo.png` ist eine gerenderte PNG-Version der Wikimedia-Commons-Datei [Minecraft Logo-en.svg](https://commons.wikimedia.org/wiki/File:Minecraft_Logo-en.svg). Die Commons-Datei nennt Mojang Studios als Quelle und verweist auf `minecraft-core-brand.svg`; die Datei ist dort als gemeinfrei wegen fehlender urheberrechtlicher Schöpfungshöhe markiert. Markenrechte bleiben unberührt.

## AppStore-Installation

Der AppStore-Installer lädt für eine Store-DApp aktuell nur die in `dapps.txt` genannte Lua-Datei. Deshalb enthält `minecraft.lua` seit 4.3.3 zusätzlich eine eingebettete E-Ink-Logo-Payload und schreibt sie beim ersten Splashscreen-Aufruf in den AppDock-Datenordner.
