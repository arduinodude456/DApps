# Minecraft 3D 2.1.0

Diese Version übernimmt weitere Teile der Standalone-C-Struktur in die AppDock-DApp:

- Seed-basierte Weltgenerierung mit geglättetem Hash-Rauschen
- Biome: Ebene, Wald, Wüste, Taiga, Sumpf, Tundra und Berge
- Seen, Schnee, unterschiedliche Geländeprofile und deterministische Bäume
- Sitzungs-Seed und „Neue Welt“-Grundlage
- Hotbar mit neun Slots
- Inventaroverlay
- Inventarbestände pro Blockmaterial
- Platzieren per mittlerem unteren Szenentap
- Abbauen per Halten der Szene
- Auswahl des aktiven Baumaterials über die Hotbar

Die C-spezifischen Arduino-, SD-, SPIFFS- und TFT-Abhängigkeiten wurden nicht übernommen. Speicherung und UI-Lifecycle bleiben AppDock-/KOReader-kompatibel.
