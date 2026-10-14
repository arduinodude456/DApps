# Minecraft 3D 4.7.1

## E-Ink-Kamera-Bewegung

Während Kamera-Pan und Schrittanimationen schreibt der Renderer auf schnellen E-Ink-Waveforms ausschließlich echtes Schwarz und Weiß. Die Ray-Anzahl und das Low-Res-Sampling bleiben exakt gleich; deshalb sinken die FPS nicht durch einen zusätzlichen Renderpfad. Farbe und feine Graustufen werden nur während der Bewegung ausgeblendet, weil gerade diese Zwischenwerte auf schnellen Waveforms am stärksten verschmieren.

Die Kamera-Vorschau verwendet weiterhin `fast`. Nach dem Loslassen folgt automatisch der normale Frame mit Materialfarben bzw. Graustufen. Dadurch bleiben die bisherigen Bildrate und die direkte Reaktion erhalten, während die bewegte Welt deutlich kontrastreicher und weniger verwaschen erscheint.

Die Performance-Regressionstests prüfen, dass Bewegungsframes keine RGB-Pixel ausgeben und ausschließlich Schwarz/Weiß schreiben. Die Tests bestehen unter Lua 5.1 und LuaJIT.

**Hinweis:** E-Ink-Panel, Firmware und Waveform-Implementierung beeinflussen Ghosting unterschiedlich. Die finale Abstimmung sollte auf dem konkreten Reader geprüft werden.
