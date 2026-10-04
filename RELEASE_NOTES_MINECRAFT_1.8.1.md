# Minecraft 3D 1.8.1

Das im Standalone-Renderer vorhandene mehrstufige Texturprinzip ist jetzt auch im Lua-Port sichtbar. Die vier Helligkeitsstufen der 8×8-Blockmuster werden über eine geordnete 4×4-Bayer-Matrix in Schwarzweiß-Pixel umgesetzt.

Damit erscheinen Gras, Erde, Stein, Holz, Blätter und Wasser wieder mit strukturiertem Dithering statt als reine Schwarz-/Weißflächen. Die Texturen bleiben deterministisch und werden weiterhin auf dem kleinen logischen Raster erzeugt, damit der Renderer für E-Ink schnell genug bleibt.
