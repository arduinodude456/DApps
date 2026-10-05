# Minecraft 3D 3.0.4

Der Farbpfad wurde an die funktionierende Zeichen-DApp `draw.lua` angeglichen. Diese prüft den Gerätemodus mit `Screen:isColorEnabled()`, erstellt bei aktivem KOReader-Farbrendering einen `Blitbuffer.ColorRGB32`-Wert und übergibt ihn an `bb:paintRect()` des normalen Widget-Canvas.

Minecraft leitet die Farbfähigkeit jetzt ebenfalls ausschließlich aus `Screen:isColorEnabled()` ab. Es prüft nicht mehr `Screen.bb` oder den transienten `bb`-Puffer, den KOReader dem DApp-Canvas bei einem Paint-Aufruf übergibt, und verlangt keine separate RGB-Zeichenmethode. Die Palette wird wie in Draw über `ColorRGB32` erzeugt und mit `paintRect` gezeichnet.

Der Test bildet den Draw-Vertrag ab und stellt sicher, dass RGB-Farben über den üblichen `paintRect`-Pfad des DApp-Canvas gerendert werden.
