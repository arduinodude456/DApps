# Minecraft 3D 4.5.4

## Schatten und Startmenü

Sämtliche Spielschatten (Mob- und voxelbasierte Sonnenschatten) sind entfernt. Die Startmenü-Schaltflächen sind breiter und höher, mit Abständen und Position dynamisch an die Displayhöhe angepasst.

## Bewegungsstabilität

Die Bewegungsrichtung wird jetzt am Einstieg in die Bewegungsarithmetik strikt normalisiert. Die Legacy-Aktionsnamen `forward` und `back` werden sicher auf `1` beziehungsweise `-1` abgebildet; unbekannte oder nichtnumerische Werte werden ohne Rechenoperation verworfen.

## Mob-Performance

Die Welt rendert höchstens drei nahe Mobs auf einmal. Sichtlinien werden erst nach Distanzsortierung geprüft und die Suche stoppt, sobald das Mob-Budget gefüllt ist. Überflüssige pixelweise Konturen an jedem Körperteil entfallen; das reduziert die Zeichenoperationen stark. Die autonome Aktualisierung läuft im 1,25-Sekunden-Takt statt mehr als einmal pro Sekunde.

## Mob-Bewegung und Renderleistung

Mobs erhalten jetzt während der geöffneten Weltansicht einen eigenen, aufgeräumten Ambient-Timer. Sie bewegen sich daher auch, wenn der Spieler stillsteht; beim Verlassen des Weltbildschirms wird der Timer beendet. Die Bewegungsgeschwindigkeit wurde leicht angehoben, damit Richtungswechsel und Laufanimation im Spiel besser erkennbar sind.

Mob-Körper, Köpfe, Beine und Konturen werden nun auf das grobe Sample-Raster der Blockwelt quantisiert, statt jedes Display-Pixel einzeln zu bemalen. Die sichtbare Auflösung und der Rasterstil passen damit zusammen, und das Mob-Rendering benötigt wesentlich weniger Zeichenoperationen.

## Stabilität

- Behoben: Gedrückthalten von **Vorwärts** übergibt jetzt den numerischen Bewegungswert `1` an die Bewegungsroutine statt des Strings `"forward"`. Dadurch entfällt der Lua-Fehler bei der Rechenoperation und KOReader stürzt nicht mehr ab.
- Wiederholte Bewegungen, Release und die bestehenden lokalen E-Ink-Refreshes bleiben unverändert abgesichert.

## Welt: Zeit, Licht und Mobs

- Schrittbasierter **Tag-/Nacht-Zyklus** mit Morgen, Tag, Sonnenuntergang und Nacht; der aktuelle Status erscheint im Kopfbereich.
- Dynamischer Himmel, dunklere Nachtlandschaft und stabile Sterne; Spielschatten sind in 4.5.4 entfernt.
- Platzierbare **Fackeln** mit eigener Textur, Lichtquellen-Registry und lokalem Lichtkegel. Dorfplätze erhalten Fackeln; vier Fackeln lassen sich aus Holz und Kohle herstellen.
- Mehrteilige, perspektivisch projizierte 3D-Mobs: **Schafe, Kühe, Schweine** sowie nachts aktive **Zombies**. Körper, Köpfe, Beine beziehungsweise Arme werden aus 3D-Quadern aufgebaut, animiert und von Weltblöcken korrekt verdeckt.
- Mobs besitzen dynamische Bodenausrichtung und schrittweise Bewegung.

## Oberfläche

- Neuer pixeliger Splashscreen mit Himmel, Blocklandschaft und reliefartigen Minecraft-Schaltflächen.
- Überarbeitete Hotbar mit Material-Miniaturen, Zählerständen, Slot-Auswahl und 3D-Rahmen.
- Überarbeitetes Inventar mit kontrastreichem Panel, klarer Kopfzeile, nummerierten Bedrock-artigen Slots und Material-Icons.
