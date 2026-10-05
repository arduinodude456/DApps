# Minecraft 3D 3.0.8

Die vorhandenen 8×8-Materialtexturen und ihre hitflächenabhängigen Koordinaten werden jetzt auch im Farbmodus ausgewertet. Jede Materialtextur moduliert ihre eigene reichere Ziel-RGB-Farbe (zum Beispiel Braun für Erde/Holz und neutralere Töne für Stein). Ein 4×4-Bayer-Raster approximiert die jeweilige Zielfarbe mit dem nächstliegenden Paar aus den sieben schnellen Palettenfarben. Dadurch entstehen zusätzliche wahrgenommene Farbtöne und Texturdetails, statt alle Flächen auf sieben einfarbige Werte zu reduzieren.

Pro Ausgabepixel wird weiterhin nur eine der schnellen Palettenfarben verwendet. Der Farbmodus nutzt auf einem 210×126-Pane ein feineres 105×63-Strahlengitter, damit das Dithermuster sichtbar bleibt. Schwarz-Weiß-Renderer und seine Texturen bleiben unverändert.
