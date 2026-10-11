# DockUpdate 1.2.8

DockUpdate prüft AppDock-Releases jetzt ohne die anonyme GitHub-REST-API. Die Versions- und Release-Notes kommen aus dem öffentlichen GitHub-Atom-Feed; die freigegebenen AppDock-Module und PNG-Assets werden direkt über `raw.githubusercontent.com` geladen.

Damit verbraucht eine Updateprüfung kein gemeinsames GitHub-API-Kontingent mehr. Die feste Allowlist, Lua-Syntaxprüfung, PNG-Signaturprüfung, Staging-Logik, atomare Installation, Rückfallkopie sowie Passwort- und Bestätigungsabfrage bleiben erhalten.
