# Minecraft 3D 2.1.2

Der letzte Performance-Fix hatte die Strahlnormalisierung entfernt, um Rechenzeit zu sparen. Bei dem großen 130°-Sichtfeld führte das auf dem eInk-Gerät zu einer stark verzerrten Darstellung. Die vorberechnete Spalten-/Zeilenstruktur bleibt erhalten, aber jeder Strahl wird vor dem DDA wieder normalisiert.

Das ursprüngliche 1-Pixel-Bayer-Dithering wirkte auf dem Panel außerdem wie graues Rauschen. Die Ditherentscheidung arbeitet nun mit 2×2-Pixel-E-Ink-Zellen. Die 480×320-Ray-Auflösung, 48 Blöcke Sichtweite und die Texturdetails bleiben erhalten.
