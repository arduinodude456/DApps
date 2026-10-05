# DChat 1.4.16

Beim Öffnen einer DM-Konversation werden Bildanhänge nicht mehr automatisch inline dekodiert. Auf Tolino bleiben PNG, JPEG/JPG, GIF und WebP verfügbar und lassen sich durch Antippen einzeln öffnen.

DChat-Bilder werden aus KOReaders gemeinsamem `ImageWidget`-Cache herausgehalten. Ihre temporären Dateien liegen nun in einem DChat-eigenen Verzeichnis; veraltete Cache-Dateien werden beim Start entfernt und der aktive Anhang-Cache bei Seiten- und Ansichtswechseln geleert. Schreibfehler bei fehlendem Speicherplatz führen zu einem Hinweis in der Detailansicht statt zu einer unkontrollierten Cache-Belegung. Empfangene Anhänge oberhalb des 512-KiB-Limits werden nicht in den lokalen Nachrichtencache übernommen.

Auf Android bleibt die Bilddarstellung deaktiviert; Bildanhänge können weiterhin gesendet und empfangen werden.
