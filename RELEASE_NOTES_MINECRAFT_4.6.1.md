# Minecraft 3D 4.6.1

## Inventar-Touch

- Das geöffnete Inventar fängt Bildschirm-Taps jetzt zusätzlich am Weltpane als modales Overlay ab; so landen Berührungen nicht mehr auf der verdeckten Welt-/Joystick-Ebene.
- Itemzellen haben bildschirmabhängige Spaltenzahl und mehr Höhe, damit die vollständigen Gegenstandsnamen unter den Symbolen lesbar sind.
- Nach Auswahl eines Katalog-Items oder Hotbar-Slots zeigt die Suchleiste den vollständigen Materialnamen.

## Tests

- `luac5.1 -p minecraft.lua`
- Lua-Regressionen für echte Taps über das Weltpane, Auswahl, Anzeige des Materialnamens, Schließen per Touch, Katalog-Trefferbereiche sowie die Survival-/Creative- und Weltenlisten-Tests aus 4.6.0.
