# DockUpdate 1.2.2

Behebt die Meldung **“The release contains too many source files.”** beim Update auf AppDock 7.8.13. DockUpdates Dateigrenze zählte alle freigegebenen Dateien — nicht nur Lua-Quellen — und war auf 48 gesetzt. Das veröffentlichte AppDock-Paket enthält jedoch **49 Dateien insgesamt: 26 Lua-Module und 23 PNG-Assets**.

Das begrenzte Gesamtlimit liegt jetzt bei **64 Dateien**. Alle bisherigen per-Datei- und Gesamtgrößengrenzen, die explizite Quell- und Asset-Allowlist, die Syntax-/PNG-Prüfungen und der sichere Staging-/Rollback-Ablauf bleiben bestehen.

Der DockUpdate-Test verwendet nun ein vollständiges Fixture mit 49 Dateien aus dem AppDock-7.8.13-Paket und prüft, dass alle 26 Lua-Dateien und 23 PNGs verarbeitet werden. Die Version wurde in der DApps-Katalogdatei auf **1.2.2** angehoben.
