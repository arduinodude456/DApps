# Minecraft 3D 1.5.0

Die Würfelgeometrie ist jetzt geschlossen. Die bisherige Darstellung zeichnete nur die Oberseite und zwei sichtbare Seitenflächen, wodurch Blöcke von bestimmten Blickwinkeln oben oder unten offen wirkten.

Jeder Voxel besitzt nun Oberseite, Unterseite, Rückseite und vier Seitenflächen. Die Flächen werden in Painter-Reihenfolge texturiert und anschließend mit schwarzen Kanten geschlossen. Dadurch bleiben auch erhöhte Säulen und Blöcke beim Blick von unten oder schräg von hinten visuell geschlossen.

Die prozeduralen E-Ink-Texturen und der regionale `fast`-Refresh bleiben erhalten.
