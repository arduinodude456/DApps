# DockUpdate 1.2.1

DockUpdate akzeptiert jetzt **AppDock 7.8.13**. Die verpflichtende Dateiliste und Allowlist enthalten die YouTube-Kernmodule `appdock_audio.lua`, `appdock_bwr.lua`, `appdock_player.lua` und `appdock_youtube.lua`. Damit kann DockUpdate ein Update von älteren AppDock-Versionen auf 7.8.13 vollständig stagen und installieren, statt die neuen Module als unbekannte Dateien abzulehnen oder sie beim Update auszulassen.

Die bestehende Sicherheitsgrenze bleibt unverändert: stabile Releases aus dem fest konfigurierten AppDock-Repository, begrenzte Dateigrößen, explizite Datei-Allowlist, Syntaxprüfung, Staging, Update-Passwort, ausdrückliche Installationsbestätigung und Rollback-Kopie. Es werden keine zusätzlichen Assets oder ausführbaren Binärdateien akzeptiert.

Die Regressionstests prüfen nun, dass alle vier YouTube-Module explizit erlaubt und verpflichtend sind und dass DockUpdate ausschließlich die erwarteten 21 Lua-Quelldateien und fünf PNG-Dateien abruft.
