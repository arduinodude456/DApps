# Minecraft 3D 3.0.9

- **Sichtbare Bäume ab Spielstart:** Der bisherige feste Spawn lag bei Seed `12345` mitten in dichtem Blattwerk. Der Spawn wird jetzt pro Welt seed-basiert auf einer freien Grasfläche gesucht und zu einem nahen Baum mit freier Sichtlinie ausgerichtet.
- **Eigene Welten und Seeds:** Die neue Schaltfläche **Welt** öffnet eine Seed-Eingabe. Dieselbe Ganzzahl erzeugt reproduzierbar dieselbe Welt; ein leeres Feld wählt einen neuen Seed. Der aktuelle Seed wird im Kopfbereich angezeigt.
- **Schnellere Neuzeichnungen bei gleicher Abtastauflösung:** Voxel-Ebenen und Material-/Ditherfarben werden vorberechnet; normalisierte Kamerastrahlen werden bei unverändertem Blickwinkel zwischen Bewegungs-Frames wiederverwendet. Die 2×2-Farbabtastung, die 5×5-Monochromabtastung und das bestehende Strahlenbudget bleiben unverändert.
- **Günstigere Farbsortierung:** Im inneren Renderpfad werden Palette-Namen statt RGB-cdata pro Strahl verglichen; RGB32-Farben werden erst beim Zeichnen eines zusammenhängenden Spans aufgelöst.

Der lokale LuaJIT-Mikrobenchmark für ein 600×350-Pane lag mit wiederholten Farbframes vor diesen Änderungen bei rund **21,9 ms/Frame** und danach bei rund **15,3 ms/Frame** (ca. **30 % schneller** in diesem Sandbox-Test). Die Messung ist kein Leistungsversprechen für ein bestimmtes E-Reader-Modell; die Renderauflösung wurde nicht reduziert.

Die Regressionstests decken Baum-Spawn und Blickrichtung über mehrere Seeds, feste und zufällige Seed-Eingaben, Cache-Aktualisierung nach Abbauen/Platzieren sowie Farb- und Monochromrendering ab.
