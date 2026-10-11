# DockUpdate 1.2.7

DockUpdate akzeptiert jetzt AppDock **7.9.21** mit der neuen Kobo-Stylus-Unterstützung in Draw für Stiftdruck, Radierer und Marker.

Die feste Pflichtdateiliste und Allowlist enthalten zusätzlich `appdock_stylus.lua`. Das geprüfte Paket wächst auf **53 freigegebene Dateien**: 30 Lua-Module und 23 PNG-Assets. Die bestehende Begrenzung auf 64 Dateien, die Größenlimits, HTTPS-Prüfungen, Lua-Syntax- und PNG-Signaturprüfungen, Passwortabfrage, ausdrückliche Installationsbestätigung und atomare Installation mit Rollback bleiben unverändert.

Der DockUpdate-Regressionstest modelliert jetzt ein Update auf das veröffentlichte `v7.9.21`, prüft die Erkennung der neuen Release Notes und stellt sicher, dass `appdock_stylus.lua` gemeinsam mit den übrigen AppDock-Kernmodulen installiert wird.
