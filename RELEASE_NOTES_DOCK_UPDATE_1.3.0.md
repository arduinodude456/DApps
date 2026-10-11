# DockUpdate 1.3.0

- AppDock-Updates laden jetzt auch `appdock_suggestions.lua` und `appdock_suggestions.db`.
- Die Vorschlagsdatenbank wird als Datendatei validiert und nicht als Lua-Code ausgeführt.
- Die Datenbank wird gemeinsam mit den Plugin-Dateien gestaged und beim atomaren Austausch mitinstalliert.
- Fehlt eine benötigte Datenbankdatei oder ist sie beschädigt, wird das Update vollständig abgebrochen; die bestehende Installation bleibt erhalten.
