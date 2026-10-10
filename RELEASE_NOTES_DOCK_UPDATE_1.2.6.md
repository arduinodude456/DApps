# DockUpdate 1.2.6

DockUpdate erkennt und installiert jetzt AppDock **7.9.15** mit der reparierten YouTube-Music-Suche und dem neu gestalteten Now-Playing-Player.

Die vorhandene feste Pflichtdateiliste und Quellcode-Allowlist enthalten bereits alle von AppDock 7.9.15 benötigten Module. Die Paketgrenze bleibt bei 52 freigegebenen Dateien: 29 Lua-Module und 23 PNG-Assets. Der Höchstwert pro Quelldatei bleibt 256 KiB; das unveränderte `appdock_dapps.lua` mit 205.636 Byte liegt darunter. Die Begrenzung auf 64 Dateien insgesamt sowie die übrigen HTTPS-, Syntax-, Passwort-, Bestätigungs- und Rollback-Prüfungen bleiben aktiv.

Der DockUpdate-Regressionstest simuliert jetzt die Aktualisierung von AppDock 7.9.14 auf `v7.9.15` und prüft Release-Erkennung, Notes, Dateiliste, Rollback-Kopie und Installation der gebündelten Module.
