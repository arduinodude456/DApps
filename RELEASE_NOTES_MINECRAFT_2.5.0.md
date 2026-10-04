# Minecraft 3D 2.5.0

Dieses Release repariert den Renderer nach dem 800×800-Belastungstest von 2.4.0:

- Der Raycaster verwendet wieder das vorgesehene 100×100-logische Raster und begrenzt es in kleinen Pane-Flächen auf die echte Canvas-Größe. Dadurch zeichnet kein logischer Pixel mehrfach in dieselbe E-Ink-Zelle.
- Die Skalierung nutzt gemeinsame Rasterkanten für benachbarte Spans. Das verhindert fehlende Ein-Pixel-Zeilen und ungleichmäßige Überzeichnungen.
- X-, Z- und Y-Achsen laufen im DDA wieder in der korrekten Reihenfolge. Grundflächen erscheinen dadurch über die untere Bildhälfte statt als fehlerhafter Randstreifen; Ober- und Seitenflächen verwenden die zu ihrer Ebene passenden horizontalen Texturkoordinaten.
- Der Baum-Pass liest die ursprünglichen Terrainhöhen aus einem Snapshot, wodurch Laubkronen keine ungebremsten neuen Baumstämme mehr erzeugen. Weltspalten bleiben auf die vorgesehene Maximalhöhe von 18 Blöcken begrenzt.
- Die niedrige, deterministische Baumwahrscheinlichkeit in Ebenen ist wieder erreichbar; die vorher widersprüchlichen Zufallsgrenzen konnten dort keine Bäume erzeugen.
- Platzieren an einer maximal hohen Spalte wird sauber abgewiesen, statt die vorhandene Spalte auf 14 Blöcke zu verkürzen.
- Die deterministische Startposition blickt in eine freie Landschaft, nicht mehr direkt auf eine Nahwand.

Die Sichtweite von 48 Blöcken, der DDA-Blocktreffer, das kontrastreiche 2×2-Dithering und der regionale E-Ink-Refresh bleiben erhalten. Die Auflösung wird in Version 2.6.0 auf 180×108 erhöht; siehe `RELEASE_NOTES_MINECRAFT_2.6.0.md`.
