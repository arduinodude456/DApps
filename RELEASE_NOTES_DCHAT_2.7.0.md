# DChat 2.7.0 — Schnellere Sticker und unabhängige InkBlog-Avatare

Stickeranimationen verwenden jetzt eine e-Ink-freundliche Fünffarbenpalette aus Schwarz, Weiß, Rot, Grün und Blau mit Floyd-Steinberg-Dithering. Die animierten Stickerframes werden über den nativen GIF-Decoder geladen, mit einem Lua-Fallback abgesichert und über regionale Fast-Refresh-Aktualisierungen auf das Display gebracht.

Das Frame-Intervall wurde auf 0,16 Sekunden reduziert, sofern das jeweilige Display und sein EPDC diese Geschwindigkeit unterstützen. Nach jedem Frame wird die regionale Aktualisierung unmittelbar an den Display-Eventloop übergeben.

InkBlog-Profilbilder werden anhand des DChat-Anzeigenamens verwendet, auch wenn DChat- und TBS-Konto nicht identisch sind. Ein lokal gesetztes DChat-Profilbild hat weiterhin Vorrang.
