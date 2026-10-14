# Minecraft 3D 4.7.0

## Grafik und Helligkeit

- Die geometrische Auflösung bleibt unverändert: Sampling 6 für Welt, Bewegung und Blick-Pan.
- Vorberechnete native Materialfarben und neutrale Graustufen ersetzen das grobe Dithering pro Renderzelle. Display-/Ink-Konvertierung wird KOReader bzw. dem Gerät überlassen; es wird kein neuer Treiber vorausgesetzt.
- Einmalige, sanfte Richtungsbeleuchtung statt mehrfacher Texturebenen-Absenkung verhindert schwarze Blockseiten. Auch nachts bleibt eine lesbare Grundhelligkeit; der Himmel zeigt weiterhin die Tageszeit.
- Entfernte 8×8-Texturen werden in Richtung ihrer Durchschnittshelligkeit gefiltert, um Aliasing und Musterrauschen zu reduzieren.
- Grasblöcke haben grüne Oberseiten und einen grünen Rand auf den Erdseiten. Dünne Auswahlkontur und kontrastreiches Fadenkreuz ersetzen schwere Konturen.
- Fackeln besitzen ein erkennbares Hotbar-Symbol. Mob-Farben und deren Graustufen behalten Körper-, Kopf- und Flächenkontrast.
- Fackellicht wird pro Halbblockposition innerhalb eines Frames gecacht; entfernte Quellen werden vor der Distanzberechnung verworfen.

## Mob-Performance

- Mobs außerhalb des 18-Block-Aktivrings schlafen ohne Bewegungs- und Kollisionsarbeit.
- Sichtprüfungen sind am Weltpopulationslimit von 18 Mobs begrenzt; maximal drei sichtbare Mobs werden fern nach nah gemalt. Verdeckte Vordergrundtiere verhindern nicht die Anzeige weiter entfernter sichtbarer Tiere.
- Korrekte relative Rasterung mit anschließendem absolutem Pane-Origin verhindert versetzte Mob-Flächen.
- Leerlauf-Bewegungen verwenden einen Terrainspan-Cache und aktualisieren nur den vereinigten alten/neuen Mob-Bereich. Alle Schreiboperationen werden auf diesen Bereich geclippt, einschließlich Auswahlkontur und Fadenkreuz.
- Unsichtbare bzw. außerhalb des Bildes liegende Mobs erzeugen keine Repaints.
- Ambient-Repaints unterbrechen keine Bewegung, Blick-Pans, Sprünge oder modalen Inventar-/Craftingansichten.
- Begrenzte Beleuchtungsupdates bleiben unabhängig von sichtbaren Mobs aktiv. Kamera-, Welt-, Licht-, Farbmodus- und Zeitänderungen verhindern veraltete Cache-Nutzung.
- Zombies erscheinen nicht in Creative oder Peaceful; nächtliche Survival-Angriffe bleiben erhalten.

### Lokale Messung

Ein isolierter LuaJIT-Test mit KOReader-Testdoubles, Seed 12345, Pane 600×748, drei sichtbaren Schafen und 20 Ambient-Ticks ergab:

| Kennzahl | 4.6.3 | 4.7.0 |
|---|---:|---:|
| Vollständige Terrain-Raycasts bei 20 Ambient-Ticks | 20 | 2 |
| Zeichenaufrufe bei 20 Ambient-Ticks | 78.334 | 19.533 |
| CPU-Zeit dieser Ambient-Ticks im Sandbox-Test | 0,0492 s | 0,0200 s |

Das entspricht 90 % weniger vollständigen Raycasts und rund 75 % weniger Zeichenaufrufen im gemessenen Leerlauf-Szenario. **Dies ist kein FPS-Versprechen für reale E-Ink-Hardware.** Die neue Weltfläche ist größer; ein vollständiger Frame führt mehr Strahlen aus und verwaltet zusätzlich den Hintergrundcache. Im selben Test kosteten 20 volle Frames 0,0874 s statt 0,0496 s. Die Hauptbeschleunigung ist deshalb bewusst die Vermeidung unnötiger voller Mob-Frames, nicht eine behauptete Beschleunigung jeder einzelnen Welt-Neuzeichnung.

## Touch-HUD

- Größere, zentrierte Hotbar mit klarer Slot-Auswahl und innen liegenden Rahmen.
- Kompaktes, opakes HUD-Band statt einer großen leeren Bedienfläche plus zweiter Bewegungsleiste.
- Steuerkreuz mit skalierten Pfeilen, beschriftetes Springen sowie Inventar und Tippmodus.
- Keine redundanten Left/Forward/Back/Right-Toolbarbuttons; Tastatur-/D-Pad-Steuerung bleibt erhalten.
- Ein lesbarer Ereignisfooter statt überlappender Kleinstschrift.
- Weiterhin modale Inventarweiterleitung, damit verdeckte Controls keine Weltaktionen auslösen.
- Adaptives Layout geprüft bei 600×748, 600×350, 320×480 und 200×250. Sehr schmale Panes bieten naturgemäß kleinere horizontale Touch-Ziele.

## Validierung

Erfolgreich:

```sh
luac5.1 -p minecraft.lua test_minecraft.lua test_minecraft_performance.lua
lua5.1 test_minecraft.lua
luajit test_minecraft.lua
lua5.1 test_minecraft_performance.lua
luajit test_minecraft_performance.lua
git diff --check
```

Die aktualisierte Hauptsuite deckt Weltgenerierung, Ray-Cache, Materialtöne, Monochrompfad, Nacht, Fackelsymbol, Inventar, Drops, Crafting, Survival/Creative, modale Touchweiterleitung, Bewegung und Pane-Geometrie ab. Die neue Performance-Suite prüft Schlafradius, Sicht-/Draw-Budgets, Painter-Reihenfolge, Origin, gesperrte Ambient-Zustände, Teilregionen, Clipping, unsichtbare Mobs, Beleuchtungswechsel und Peaceful/Creative-Zombies.

Von 18 lokalen Store-Testskripten liefen 10 erfolgreich. Acht andere Skripte scheitern auch auf dem unveränderten Hauptbranch: sechs wegen fest eingebauter, in dieser Umgebung fehlender lokaler Repositorypfade, `test_dchat_layout.lua` wegen einer veralteten Versionsassertion und `test_gmail_notifications.lua` an seiner bestehenden Assertion. Sie wurden nicht außerhalb dieses Minecraft-Scopes geändert.

**Noch auf dem Zielgerät zu prüfen:** tatsächliche Farbdarstellung, native Graustufen in schnellen Waveforms, Ghosting, Touchgefühl und Bildrate. Die visuellen Vergleichsbilder stammen aus den realen Zeichenaufrufen mit Testdoubles; Schriftrasterung ist dort angenähert, nicht ein Screenshot eines angeschlossenen Readers.

## Installation nach Übernahme

DApp-Metadaten und `dapps.txt` verwenden beide 4.7.0. Nach dem Merge in AppDock AppStore den Katalog aktualisieren und das Minecraft-Update installieren. Bestehende Weltmetadaten bleiben kompatibel. Weltfortschritt und Inventar werden wie bisher nicht dauerhaft gespeichert; diese Version ändert den Speichervertrag nicht.
