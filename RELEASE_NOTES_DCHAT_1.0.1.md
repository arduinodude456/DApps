# DChat 1.0.1

Dieses Wartungsupdate korrigiert den HTTPS-Transport für KOReader. DChat verwendet nun denselben Reader-kompatiblen LuaSec-Requestvertrag wie der AppDock-AppStore, statt TLS-Optionen zu erzwingen, die auf einigen Geräten ohne passend eingebundenes CA-Bundle den Verbindungsaufbau verhindern können.

Der sichtbare Verbindungsfehler enthält nun – sofern der Reader eine begrenzte technische Meldung liefert – zusätzlich den knappen Transportgrund. Öffentliche Nachrichten, lokale Geräteidentität, manuelles Aktualisieren, Meldungen und alle Datenschutzgrenzen bleiben unverändert.
