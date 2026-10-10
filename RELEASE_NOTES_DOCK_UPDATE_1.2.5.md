# DockUpdate 1.2.5

DockUpdate akzeptiert jetzt AppDock **7.9.14**. Die feste Pflichtdateiliste und Quellcode-Allowlist enthalten das neue Modul `appdock_ytmusic.lua`, das AppDock beim Start für die YouTube-Music-DApp benötigt.

- Die geprüfte Plugin-Dateiliste wächst auf **52 Einträge**: 29 Lua-Module und 23 PNG-Assets. Das Gesamtlimit von 64 Dateien und die übrigen Größenlimits bleiben aktiv.
- `appdock_dapps.lua` aus AppDock 7.9.14 ist 205.636 Byte groß und bleibt unter der bestehenden, begrenzten Obergrenze von 256 KiB pro Quellmodul.
- Der DockUpdate-Regressionstest modelliert jetzt ein Update von AppDock 7.9.13 auf das veröffentlichte `v7.9.14`, prüft, dass `appdock_ytmusic.lua` erlaubt, als Pflichtdatei übernommen und installiert wird, und kontrolliert die vollständige Downloadanzahl.

Die HTTPS-Prüfung, stabile-Release-Filterung, Lua-Syntaxprüfung, explizite Bestätigung, Passwortabfrage und atomare Installation mit Rollback-Backup bleiben unverändert.
