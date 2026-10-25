# DockUpdate 1.4.11

DockUpdate kann Doom für AppDock separat installieren.

- Das geprüfte `doom-kobo.zip` wird ausschließlich nach `/mnt/onboard/.adds/doom` staged.
- Archivpfade, Dateiliste und Mindestbestand werden vor dem Entpacken geprüft.
- Bestehende Doom-Installationen werden nie überschrieben.
- Die Doom-Lua-Integration wird erst mit AppDock 8.5.3 vorausgesetzt; der native Payload bleibt ein separater DockUpdate-Schritt.
