# DockUpdate 1.1.2

DockUpdate erhöht das feste Limit für einzelne AppDock-Lua-Module von 160 KiB auf 192 KiB. Das ist nötig, damit der aktuelle AppDock-Release mit seinem gewachsenen DApp-Host aktualisiert werden kann.

Die Sicherheitsgrenzen bleiben aktiv: Die Dateiliste kommt weiterhin ausschließlich aus dem festgelegten GitHub-Repository, nur die erwarteten Lua-Module werden akzeptiert, die Gesamtgröße bleibt auf 768 KiB begrenzt, jede Datei wird über HTTPS geladen und vor dem atomaren Austausch auf Lua-Syntax geprüft.

Die Änderung ist rückwärtskompatibel für kleinere AppDock-Releases und enthält einen Regressionstest für das neue Limit.
