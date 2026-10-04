# Minecraft 3D 1.8.0

Der bisherige Polygonrenderer wurde durch einen Lua-Port des Renderingkerns aus `PocketOS_Minecraft_Standalone.h` ersetzt. Die Portierung übernimmt das zentrale Prinzip des Standalone-Codes: DDA-Raycasting durch die Voxelwelt, ein großes 130°-Sichtfeld, vertikales Look-Pitch und materialabhängige 8×8-Pixeltexturen.

Für AppDock wird die Szene auf einem kleinen logischen Raster berechnet und anschließend mit nearest-neighbour auf die lokale Canvas vergrößert. Das reduziert die Anzahl der E-Ink-Pixeloperationen und vermeidet die bisherigen stehenden Karten beziehungsweise offenen Polygonflächen.

Die AppDock-Steuerung bleibt erhalten: Joystick, Sprungtaste, Hardwaretasten sowie horizontale und vertikale Wischgesten. Der Port benötigt weder Arduino-, TFT-, SPIFFS- noch SD-Abhängigkeiten; Weltzustand und Rendering bleiben vollständig lokal in Lua.
