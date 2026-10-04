# Minecraft 3D 2.0.0

## Volle Renderauflösung

Der Raycaster berechnet jetzt bis zu **480×320 logische Pixel** statt eines stark reduzierten Rasters. Die Ausgabe wird nur dann geometrisch an eine kleinere oder größere AppDock-Pane angepasst.

## Größere Sichtweite

Die maximale Sichtweite wurde auf **48 Blöcke** erhöht. Die Welt ist auf 80×80 Blöcke gewachsen, damit die zusätzliche Distanz sinnvoll genutzt werden kann. Der DDA-Raycaster verwendet bis zu 96 Zellschritte pro Strahl.

## E-Ink-Optimierung

Gleichfarbige horizontale Pixel werden vor dem Zeichnen zu Spans zusammengefasst. Das reduziert die Zahl einzelner `paintRect`-Aufrufe, ohne die 480×320-Auflösung oder das 4×4-Bayer-Dithering aufzugeben.
