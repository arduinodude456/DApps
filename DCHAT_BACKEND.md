# DChat-Backend und Direktnachrichten

Die DChat-DApp verwendet den von Manus veröffentlichten DChat-Server. Der Server bewahrt die bestehende öffentliche API und ergänzt `GET /api/dchat/v1/recipients`, `GET /api/dchat/v1/dms/:deviceId`, `POST /api/dchat/v1/dms` sowie den unauthentifizierten Statuspfad `GET /api/health`.

Es gibt keinen Manus-Login und kein zusätzliches Benutzerkonto. Geräte werden nur mit `x-dchat-device-id` und `x-dchat-device-secret` authentifiziert. Die Konversation wird aus genau diesen beiden Geräte-IDs gebildet; fremde Geräte erhalten keine Nachrichten der Konversation. Eingehende Nachrichten werden serverseitig gespeichert und sind ausdrücklich **nicht Ende-zu-Ende-verschlüsselt**.

Der aktuelle Server wird im Manus-Projekt `DChat DM Backend` verwaltet. Die Client-App akzeptiert ausschließlich HTTPS-Endpunkte, begrenzt Namen, IDs, Nachrichten und Antworten und zeigt Serverfehler absichtlich nur datensparsam an. Die öffentliche DChat-Funktion bleibt auch bei einem nicht verfügbaren DM-Backend erhalten.
