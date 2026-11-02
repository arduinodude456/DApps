# DockUpdate 2.1.2

Behebt abgebrochene AppDock-Updates beim Herunterladen des großen `appdock_dapps.lua`-Moduls.

- Das Modul wird über eine frische HTTPS-Anfrage statt über den Keep-alive-Pfad geladen.
- Ein längeres Empfangs-Timeout und ein sicherer GET-Wiederholungsversuch fangen vorübergehende Netzwerkabbrüche ab.
- Fehlgeschlagene HTTPS-Aufrufe geben den konkreten Fehlergrund weiter.
- Der Regressionstest simuliert einen Verbindungsabbruch und prüft den erfolgreichen Retry.
