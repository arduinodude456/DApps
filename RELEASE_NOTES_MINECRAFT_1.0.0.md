# Minecraft 3D 1.0.0

## Neu

- Neue lokale AppDock-DApp **Minecraft 3D** (`minecraft.lua`).
- Erkunde eine deterministische 24×24-Voxelwelt mit Blockhöhen, Säulen und einem kleinen Turm.
- Navigation über die vier E-Ink-Tasten **Links**, **Vor**, **Zurück** und **Rechts**; Pfeiltasten, Press und Select werden unterstützt, wenn KOReader sie bereitstellt.
- Direktes Antippen der Szene: oben vorwärts, unten rückwärts, links/rechts drehen.

## E-Ink-Rendering

- Perspektivische Tiefenspalten statt eines vollständigen Meshes pro Block für begrenzte Lua-Arbeit pro Bewegung.
- Explizite Schwarzweiß-Ditherbänder für mittlere und ferne Voxel; nahe Blockflächen bleiben kontrastreich schwarz.
- Jede Navigation zeichnet nur die Spielarena direkt in den aktiven Screenbuffer und ruft anschließend `UIManager:setDirty(nil, "fast", region)` für genau diese regionale Canvas auf.
- Kein Netzwerk, kein Hintergrundtimer und keine Speicherung personenbezogener Daten.

## Installation

Nach dem Katalog-Refresh in AppDock **Minecraft 3D** im AppStore installieren. Die Welt und die Kameraposition bleiben in der geöffneten DApp-Instanz erhalten.
