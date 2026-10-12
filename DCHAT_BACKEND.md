# DChat-Backend und Direktnachrichten

Die DChat-DApp verwendet den von Manus veröffentlichten DChat-Server. Der Server bewahrt die bestehende öffentliche API und ergänzt `GET /api/dchat/v1/recipients`, `GET /api/dchat/v1/dms/:deviceId`, `POST /api/dchat/v1/dms`, `DELETE /api/dchat/v1/devices` sowie den unauthentifizierten Statuspfad `GET /api/health`.

Es gibt keinen Manus-Login und kein zusätzliches Benutzerkonto. Geräte werden nur mit `x-dchat-device-id` und `x-dchat-device-secret` authentifiziert. Die Konversation wird aus genau diesen beiden Geräte-IDs gebildet; fremde Geräte erhalten keine Nachrichten der Konversation. Eingehende Nachrichten werden serverseitig gespeichert und sind ausdrücklich **nicht Ende-zu-Ende-verschlüsselt**.

`DELETE /api/dchat/v1/devices` löscht ausschließlich die durch die beiden Authentifizierungs-Header identifizierte eigene Geräteidentität und die dazugehörigen serverseitigen Gerätedaten. Fremde Konten können damit nicht adressiert werden. Die Client-App ruft diese Route für den öffentlichen und den privaten Dienst auf; bereits veröffentlichte öffentliche Nachrichten bleiben bestehen.

Der aktuelle Server wird im Manus-Projekt `DChat DM Backend` verwaltet und ist öffentlich unter `https://dchatdm-4z5dnjbr.manus.space` erreichbar. `GET /api/health` liefert den Betriebsstatus. Die Client-App akzeptiert ausschließlich HTTPS-Endpunkte, begrenzt Namen, IDs, Nachrichten und Antworten und zeigt Serverfehler absichtlich nur datensparsam an. Die öffentliche DChat-Funktion bleibt auch bei einem nicht verfügbaren DM-Backend erhalten.

## API-Vertrag

Die Basis-URL wird mit folgenden Pfaden verwendet:

- `POST /api/dchat/v1/devices` registriert oder aktualisiert `{ deviceId, deviceSecret, displayName }`.
- `GET /api/dchat/v1/recipients?limit=30&q=...` liefert Empfänger mit `deviceId`, `displayName` und `unreadCount`.
- `GET /api/dchat/v1/dms/:deviceId?limit=60` liefert `conversation.messages`.
- `POST /api/dchat/v1/dms` speichert `{ recipientDeviceId, text, attachment }`; Anhänge sind PNG, JPEG, GIF oder WEBP bis 512 KiB Rohdaten.
- `DELETE /api/dchat/v1/dms/:deviceId` löscht die Konversation in beide Richtungen.

Nachrichten enthalten numerische `id`, `authorName`, `body`, `createdAt`, `senderDeviceId`, `readAt`, `attachmentMime` und `attachmentData`. Die verwaltete MySQL-Datenbank des Manus-Projekts speichert Geräte, Nachrichten, Lesestatus und Anhänge dauerhaft; das Container-Dateisystem wird nicht als Speicher verwendet. Migrationen werden vor dem Produktionsprozess ausgeführt. Der Dienst ist in Git-Checkpoint `cd47d0ec6cbd6d8deb5ec85373520a2529c98c79` veröffentlicht.
