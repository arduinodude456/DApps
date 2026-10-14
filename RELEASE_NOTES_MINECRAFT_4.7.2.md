# Minecraft 3D 4.7.2

## Farbdithering während Bewegung

Die 4.7.1-Bewegungsvorschau hat Farbdithering auf Farb-E-Ink-Geräten fälschlich durch striktes Schwarzweiß ersetzt. 4.7.2 stellt den normalen Material- und Farbditheringpfad auch während Kamera-Pan und Schrittanimationen wieder her. Die bestehende schnelle Waveform und derselbe Ray-/Frame-Takt bleiben erhalten; es wird kein zusätzlicher Renderframe und keine niedrigere FPS-Stufe eingeführt.

Auf Monochromgeräten bleibt der vorhandene Graustufenpfad aktiv. Nach der Bewegung gibt es weiterhin keinen zusätzlichen Zwischenframe.
