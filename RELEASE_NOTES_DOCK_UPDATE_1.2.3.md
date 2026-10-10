# DockUpdate 1.2.3

DockUpdate unterstützt jetzt AppDock **7.9.0**. Die feste Allowlist und die Pflichtdateiliste enthalten die neuen Kernmodule `appdock_dialogs.lua` und `appdock_draw.lua`; dadurch kann das Update die AppDock-eigenen Dialoge und die integrierte Draw-DApp vollständig und atomar installieren.

Das getestete AppDock-Paket umfasst nun 51 erlaubte Dateien: 28 Lua-Module und 23 PNG-Assets. Die Sicherheitsgrenzen bleiben unverändert: nur einzeln freigegebene Dateien, begrenzte Dateigrößen, HTTPS, Syntax-/PNG-Prüfung und ausdrückliche Installationsbestätigung.
