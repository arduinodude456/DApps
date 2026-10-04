# DChat 1.2.0

DChat erhält private Direktnachrichten zwischen registrierten Geräten, ohne Manus-Login und ohne zusätzliches Benutzerkonto. Die neue Oberfläche kann zwischen dem öffentlichen Raum und privaten Chats wechseln, Empfänger nach Displayname oder Geräte-ID suchen, eine Zwei-Geräte-Konversation anzeigen, manuell aktualisieren und Nachrichten senden.

Das Backend stellt dafür `GET /api/dchat/v1/recipients`, `GET /api/dchat/v1/dms/:deviceId` und `POST /api/dchat/v1/dms` bereit. Die Geräteidentität wird weiterhin ausschließlich über `x-dchat-device-id` und `x-dchat-device-secret` autorisiert. Nur die beiden Teilnehmer einer Konversation können deren Nachrichten lesen; der Sender wird serverseitig aus dem authentifizierten Header abgeleitet.

Direktnachrichten werden zur Zustellung serverseitig gespeichert. Sie sind **nicht Ende-zu-Ende-verschlüsselt**; DChat verspricht keine Ende-zu-Ende-Verschlüsselung. Der Client akzeptiert ausschließlich HTTPS-Adressen und begrenzt Eingaben, Antwortgrößen und lokale Caches. Der öffentliche Raum, Hintergrundprüfung und Reports bleiben erhalten.
