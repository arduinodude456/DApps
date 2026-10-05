# Minecraft 3D 3.2.1

Der Farb-Renderer verwendet jetzt ein 3x3-Ray-Sampling pro Ausgabebereich statt 2x2. Blocksilhouetten, Texturen und Dithering bleiben auf dem kleinen E-Ink-Canvas lesbar, während der teure DDA-Raycast im Farbmodus ungefähr halb so viele Strahlen verarbeitet. Der monochrome Pfad bleibt unverändert.
