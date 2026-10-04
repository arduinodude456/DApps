# Minecraft 3D 1.2.0

Die Darstellung wurde wegen der Rückmeldung auf dem echten eReader grundlegend geändert. Die vorherige Raycast-Fläche erzeugte zusammenhängende Streifen und wurde entfernt.

Minecraft 3D zeichnet jetzt diskrete projizierte Würfelkörper. Jede sichtbare Weltzelle erhält eine eigene Oberseite, Vorderseite und Seitenkante mit harten schwarzen Fugen. Die Grundwelt ist absichtlich flach und enthält einzelne erhöhte Blöcke, Säulen sowie einen gestuften Turm, damit die Würfelform auch auf einem monochromen E-Ink-Display eindeutig lesbar bleibt.

Die Navigation bleibt regional schnell und animiert: Jeder Schritt wird in vier kleinen Zwischenframes über die Canvas mit `UIManager:setDirty(nil, "fast", region)` aktualisiert. Netzwerk, Hintergrunddienste und Vollbild-Refreshes werden weiterhin nicht verwendet.
