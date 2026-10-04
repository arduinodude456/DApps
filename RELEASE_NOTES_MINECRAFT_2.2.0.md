# Minecraft 3D 2.2.0

Der Renderer wurde vom Höhenkartenmodell auf voxelweise Blocktreffer umgestellt. Jeder DDA-Schritt prüft nun einen einzelnen Block auf einer Y-Ebene. Dadurch werden die Materialschichten des PocketOS-Programms sichtbar: Oberflächenblöcke, Erde, Stein und deterministische Erzadern. Baumstämme und Laub werden ebenfalls als getrennte Blockmaterialien gerendert.

Das 130°-FOV, die 480×320-Ray-Auflösung, die 48-Blöcke-Sichtweite und das eInk-Dithering bleiben erhalten. Die Darstellung ist damit strukturell näher am C-Programm als die vorherige reine Säulen-/Höhenkartenprojektion.
