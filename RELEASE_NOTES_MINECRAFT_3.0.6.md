# Minecraft 3D 3.0.6

Der Farbpfad wurde direkt an `square.koplugin` angeglichen, dessen farbige Spielgrafik auf KOReader funktioniert:

- Paletteinträge werden zu Hex-Strings formatiert und mit `Blitbuffer.colorFromString()` in KOReader-Farbwerte umgewandelt.
- Farbfelder werden über `bb:paintRectRGB32(...)` gezeichnet.
- Die zusätzliche RGB-Konstruktor-/Hardwareprüfung entfällt. Für die Wahl zwischen Farb- und Schwarz-Weiß-Renderer wird ausschließlich `Screen:isColorEnabled()` verwendet.

Die Regressionstests verlangen nun ausdrücklich den Square-Pfad und prüfen, dass jeder Farb-Span über `paintRectRGB32` ausgegeben wird.
