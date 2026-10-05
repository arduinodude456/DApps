# DockUpdate 1.1.6

DockUpdate verwendet jetzt eine explizite Allowlist für den aktuellen AppDock-Paketinhalt. Dadurch werden Repository-Dokumentation, Tests, Root-Spiegelungen und andere fremde Source-Dateien nicht mehr als Update-Bestandteile behandelt.

Die Allowlist enthält die aktuellen AppDock-Kernmodule sowie die tatsächlich verwendeten Logos, LockScreen-Bilder und Raster-Oberflächen. Das Paketlimit wurde so angepasst, dass die vollständige aktuelle Plugin-Struktur sicher angenommen wird, ohne beliebige Dateien zu akzeptieren.
