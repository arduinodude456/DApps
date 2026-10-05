# Minecraft 3D 3.0.5

Entfernt die eigene Prüfung, ob `ColorRGB32` aufrufbar beziehungsweise das Gerät farbfähig ist. Diese Sonderprüfung war unnötig und konnte selbst Fehler verursachen.

Der Farbpfad verwendet jetzt nur KOReaders bereits etablierte `Screen:isColorEnabled()`-Abfrage wie `draw.lua`. Wenn sie wahr ist, werden Farben mit `Blitbuffer.ColorRGB32` erzeugt und über das normale `bb:paintRect()` des DApp-Canvas gezeichnet. Ist Farbrendering in KOReader nicht aktiv oder auf dem Gerät nicht verfügbar, schaltet der vorhandene monochrome Renderer auf Schwarz-Weiß um. Es wird weder `Screen.bb` noch `bb:isRGB()` zur Fähigkeitsprüfung herangezogen.
