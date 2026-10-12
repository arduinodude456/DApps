# Minecraft 3D 4.3.4

- Das Bedrock-Steuerkreuz ist deutlich größer und wird nach jedem Canvas-Refresh explizit über der Welt neu gezeichnet.
- Der Sprungbutton ist ebenfalls vergrößert und bleibt über dem Weltbild sichtbar; Control-Taps werden nicht als Blockaktionen behandelt.
- Während des Laufens wird wie beim Live-Pan mit `LIVE_RENDER_SAMPLE = 6` gerendert. Nach dem Schritt folgt ein sauberer Vollqualitäts-Frame.
- Schafe werden als blockige 3D-Mobs mit Körper-, Kopf-, Seiten-, Oberflächen- und Beinflächen gezeichnet.
- Schafe bewegen sich deterministisch über geeignete Grasflächen, bleiben innerhalb der Welt und passen ihre Höhe an das Gelände an.
