# Minecraft 3D 1.4.0

Die Polygongeometrie bleibt erhalten, aber die Flächen werden nun vollflächig texturiert. Die vorherige Version zeichnete zu wenige Ditherzeilen und wirkte dadurch wie ein Wireframe-Gitter.

Oberseiten erhalten ein dichtes prozedurales Pixelmuster, während die beiden Seitenflächen mit einer dunklen Stein-/Erdfüllung, horizontalen Schichten und versetzten vertikalen Fugen gerendert werden. Alle Texturen werden lokal als Scanline-Spans aus `paintRect` erzeugt; es werden keine externen Bilddateien benötigt.

Der regionale `fast`-Refresh und die vier kleinen Bewegungsschritte bleiben unverändert.
