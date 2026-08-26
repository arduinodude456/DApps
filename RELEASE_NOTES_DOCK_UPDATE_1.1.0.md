# DockUpdate 1.1.0

DockUpdate 1.1.0 kann an AppDock 3.0.0 angebunden als ausdrücklich erlaubte Hintergrund-DApp arbeiten.

| Bereich | Verhalten |
|---|---|
| Berechtigung | Hintergrundlauf und Autostart benötigen je eine sichtbare Nutzerfreigabe in AppDock. Ohne Freigabe wird kein Hook ausgeführt. |
| Prüfung | Während einer aktiven KOReader-/AppDock-Sitzung kann der Hook alle zwei Minuten ausschließlich die stabile GitHub-Release-Metadaten über HTTPS abrufen. Im Energiesparmodus wird er übersprungen. |
| Meldung | Ein höherer, neu beobachteter Release-Tag erzeugt höchstens eine lokale Benachrichtigung. |
| Grenze | Der Hintergrundhook lädt weder Quellbaum noch Archiv und installiert oder staged niemals Dateien. Installation bleibt eine sichtbare, bestätigte Aktion in DockUpdate. |

Die Release-Tree-Prüfung verlangt zusätzlich die AppDock-3.0-Module `appdock_wallpaper.lua` und `appdock_lockscreen.lua`, damit eine bestätigte Core-Aktualisierung nicht mit einem unvollständigen Pluginordner endet.
