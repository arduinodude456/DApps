# DChat 1.0.0

DChat eröffnet die **AppDock Lounge** als einen öffentlichen, textbasierten Gemeinschaftsraum für AppDock-Nutzer.

| Bereich | Umfang in 1.0.0 |
|---|---|
| Identität | Anzeigename und zufälliger lokaler Geräteschlüssel auf dem Reader; der Dienst speichert nur einen Hash. |
| Nachrichten | Öffentlicher Text, 1–500 Zeichen, serverseitig höchstens drei Beiträge pro zehn Minuten und Geräteidentität. |
| Aktualisierung | Ausschließlich über sichtbares manuelles Aktualisieren; keine WebSockets, keine automatische Abfrage und keine Hintergrundschleife. |
| Sicherheit | HTTPS, begrenzte Antworten und lokaler begrenzter Cache. Keine privaten Nachrichten, keine Ende-zu-Ende-Verschlüsselung und keine Wiederherstellung oder Geräteübertragung. |
| Moderation | Nutzer können Beiträge melden; Moderatoren können Beiträge ausblenden und Geräte sperren. |

Die DApp verwendet standardmäßig `https://appdock-bd7bcrzm.manus.space` und bietet die Serviceadresse in den Einstellungen sichtbar an. Ein Reset der lokalen Identität ist absichtlich endgültig: Bereits veröffentlichte Beiträge bleiben öffentlich, aber die alte lokale Identität kann nicht wiederhergestellt werden.
