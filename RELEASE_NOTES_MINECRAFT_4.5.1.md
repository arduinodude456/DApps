# Minecraft 3D 4.5.1

## Mob-Bewegung und Renderleistung

Mobs erhalten jetzt während der geöffneten Weltansicht einen eigenen, aufgeräumten Ambient-Timer. Sie bewegen sich daher auch, wenn der Spieler stillsteht; beim Verlassen des Weltbildschirms wird der Timer beendet. Die Bewegungsgeschwindigkeit wurde leicht angehoben, damit Richtungswechsel und Laufanimation im Spiel besser erkennbar sind.

Mob-Körper, Köpfe, Beine, Schatten und Konturen werden nun auf das grobe Sample-Raster der Blockwelt quantisiert, statt jedes Display-Pixel einzeln zu bemalen. Die sichtbare Auflösung und der Rasterstil passen damit zusammen, und das Mob-Rendering benötigt wesentlich weniger Zeichenoperationen.

## Stabilität

- Behoben: Gedrückthalten von **Vorwärts** übergibt jetzt den numerischen Bewegungswert `1` an die Bewegungsroutine statt des Strings `"forward"`. Dadurch entfällt der Lua-Fehler bei der Rechenoperation und KOReader stürzt nicht mehr ab.
- Wiederholte Bewegungen, Release und die bestehenden lokalen E-Ink-Refreshes bleiben unverändert abgesichert.

## Welt: Zeit, Licht und Mobs

- Schrittbasierter **Tag-/Nacht-Zyklus** mit Morgen, Tag, Sonnenuntergang und Nacht; der aktuelle Status erscheint im Kopfbereich.
- Dynamischer Himmel, dunklere Nachtlandschaft, stabile Sterne und harte voxelbasierte **Sonnenschatten** auf Blockoberflächen.
- Platzierbare **Fackeln** mit eigener Textur, Lichtquellen-Registry und lokalem Lichtkegel. Dorfplätze erhalten Fackeln; vier Fackeln lassen sich aus Holz und Kohle herstellen.
- Mehrteilige, perspektivisch projizierte 3D-Mobs: **Schafe, Kühe, Schweine** sowie nachts aktive **Zombies**. Körper, Köpfe, Beine beziehungsweise Arme werden aus 3D-Quadern aufgebaut, animiert und von Weltblöcken korrekt verdeckt.
- Mobs besitzen dynamische Bodenausrichtung, schrittweise Bewegung und geworfene Bodenschatten.

## Oberfläche

- Neuer pixeliger Splashscreen mit Himmel, Blocklandschaft und reliefartigen Minecraft-Schaltflächen.
- Überarbeitete Hotbar mit Material-Miniaturen, Zählerständen, Slot-Auswahl und 3D-Rahmen.
- Überarbeitetes Inventar mit kontrastreichem Panel, klarer Kopfzeile, nummerierten Bedrock-artigen Slots und Material-Icons.
