# Minecraft 3D 2.3.0

Der Renderpfad entspricht nun dem Layout des bereitgestellten PocketOS-C-Programms: 100×100 logische Raycaster-Pixel werden zeilenweise berechnet und anschließend auf den 480×320-artigen Viewport skaliert. Das ist die tatsächliche Strategie der Vorlage und deutlich schneller sowie vollständiger als 480×320 einzelne Lua-Raycasts.

Die Perspektive verwendet das Seitenverhältnis des realen Canvas-Viewports. Dadurch werden die vertikalen Strahlen nicht mehr mit einem quadratischen 480×320-Raster verzerrt. Die vorberechneten Strahlen bleiben erhalten, werden aber normalisiert; die Sichtweite bleibt bei 48 Blöcken. Der voxelweise Block-Raycaster und das E-Ink-Dithering bleiben unverändert.
