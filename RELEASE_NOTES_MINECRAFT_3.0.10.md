# Minecraft 3D 3.0.10

- **Deutlich schnellerer DDA-Renderloop:** Der voxelweise Raycast läuft jetzt direkt im Pixel-/Strahlenloop statt über einen Funktionsaufruf mit mehreren Rückgabewerten je Strahl.
- **Schnellerer Materialzugriff:** Der Renderer liest Materialien aus einem linearen, zusammenhängenden Voxelcache. Ein leerer Rand von 25 Blöcken erhält die Weltgrenze, sodass die häufigen X/Z-Grenzprüfungen im inneren Raycast entfallen. Abbauen und Platzieren halten Cache und Welt synchron.
- **Keine Qualitäts-/Auflösungsreduktion:** Seed, Kamera, Treffer, Texturen, Bayer-Dithering, Materialfarben, 2×2-Ausgabepixel im Farbmodus und 5×5 im Monochrommodus bleiben erhalten. Das maximale Strahlenbudget bleibt 600×600.

## Messung

Fünf kontrollierte A/B-Läufe in der Sandbox mit dem vollständigen generierten Seed-12345-Weltmodell und einem 600×600-Canvas (300×300 Strahlen im Farbmodus) ergaben als Median der fünf p50/p95-Messungen: der vorherige öffentliche 3.0.9-Renderloop **54,65 / 57,34 ms**, 3.0.10 **12,03 / 12,75 ms**. Das entspricht in diesem CPU-Mikrobenchmark etwa **4,5×** weniger Renderzeit (78,0 %). Bei maximalem Strahlenbudget (600×600 Strahlen auf einem 1200×1200-Canvas) maß ein zusätzlicher Lauf **41,44 ms p50 / 43,49 ms p95**. Der Vergleich von Farb- und Monochrombildern vor/nach der Optimierung ergab identische Pixel; auch drei Kamerapositionen nahe der Weltgrenze waren pixelidentisch.

Die Benchmark-Canvas verwendete absichtlich No-op-Paintfunktionen. Sie misst Raycasting, Textur-/Farbwahl und Span-Erzeugung, **nicht** die echten BlitBuffer-Schreibkosten, den KOReader-Refresh oder die Bildwiederholzeit eines E-Readers. Daraus lässt sich deshalb keine garantierte FPS-Zahl auf einem bestimmten Reader ableiten. Die Auflösung wurde für den Gewinn nicht reduziert.

Die Regressionstests prüfen weiterhin die Farb-/Monochrompfade, Seed-Welten und Spawns, die exakte Synchronisierung des Renderer-Caches nach Blockänderungen sowie den aktuellen AppStore-Katalogeintrag.
