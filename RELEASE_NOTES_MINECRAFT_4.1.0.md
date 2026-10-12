# Minecraft 3D 4.1.0

## Bedrock-Steuerung und Live-Kamera

- Neues grafisches Steuerkreuz mit vier getrennten Richtungstasten wie in der Bedrock-Mobile-Steuerung.
- Neue grafische Sprungtaste mit Pfeil-Symbol.
- Fingerziehen auf der Welt nutzt jetzt eine echte `pan`-Gesture: Jede Positionsänderung wird sofort auf Yaw und Pitch angewendet.
- Die alte diskrete Wischsteuerung bleibt als Fallback für Geräte ohne Pan-Geste erhalten.

## E-Ink-Farbe

- Die Farb-Ditherung verwendet jetzt die 8×8-Bayer-Matrix aus der AppDock-YouTube-Pipeline.
- Bayer-Schwellen werden auf die vorbereiteten Material-Farbmischungen abgebildet, sodass die interaktive Render-Schleife ohne zusätzliche RGB-Berechnungen pro Pixel auskommt.
