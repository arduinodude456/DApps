# Minecraft 3D 1.6.0

## Größeres Sichtfeld und Landschaft

- Sichtweite von 14 auf 20 Blöcke erhöht.
- Kürzere Projektionsbrennweite für ein breiteres First-Person-Sichtfeld.
- Welt von 24 × 24 auf 32 × 32 Blöcke erweitert.
- Neue Landschaftselemente: niedrige Hügel, Gras, Erde, Stein und ein kleiner See.
- Mehrere blockige Bäume mit Holzstämmen und Blätterkronen.

## Weniger E-Ink-Ghosting

- Graue Flächen im Welt-Renderer durch harte Schwarz-/Weiß-Texturen ersetzt.
- Gras-, Wasser-, Holz- und Blättertexturen werden als klare Pixelmuster gerastert.
- Bewegungen verwenden weiterhin regionale schnelle Aktualisierungen; jeder zweite Frame nutzt zusätzlich einen sauberen `ui`-Waveform, um angesammelte Schatten zu entfernen.
