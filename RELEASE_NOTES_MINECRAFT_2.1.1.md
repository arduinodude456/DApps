# Minecraft 3D 2.1.1

Der Raycaster wurde ohne Reduzierung der Bildqualität optimiert. Die Zielauflösung bleibt 480×320, die Sichtweite bleibt 48 Blöcke und das 4×4-Bayer-Dithering bleibt unverändert.

Die Kamera-Strahlen werden nun wie im PocketOS-C-Programm aus vorberechneten Spalten- und Zeilenanteilen zusammengesetzt. Dadurch entfallen pro Pixel mehrere trigonometrische Berechnungen und die teure Vektornormalisierung. Außerdem greift der DDA direkt auf vorbereitete Höhen- und Materialzeilen der Welt zu, statt für jeden Zellschritt mehrere Lua-Funktionsaufrufe zu machen. Die horizontale Span-Kompression der Ausgabe bleibt aktiv.
