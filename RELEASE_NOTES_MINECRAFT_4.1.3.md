# Minecraft 3D 4.1.3

## Performance auf E-Ink

- Während des Finger-Pans wird ein deutlich gröberes Live-Preview-Raster verwendet, damit Kameraänderungen nicht mehr jedes Mal den vollen Raycast-Aufwand auslösen.
- Preview-Frames verwenden ausschließlich den schnellen E-Ink-Waveform-Pfad und blockieren nicht zusätzlich auf `yieldToEPDC`.
- Beim Loslassen wird genau ein voller Qualitätsframe gerendert.
- Die normale Detailqualität und Konturen bleiben im stehenden Bild erhalten.
