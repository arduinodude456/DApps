# DChat 1.4.3

Behebt den Attach-Absturz `attempt to index field ui a nil value`. DChat verwendet keinen KOReader-FileChooser mehr, der in AppDock einen vollständigen FileManager-UI-Kontext voraussetzt. Stattdessen öffnet **Attach** einen sicheren Pfad-Dialog. Der Benutzer gibt den vollständigen lokalen Bildpfad ein; anschließend werden PNG, JPEG, GIF und WEBP bis 512 KB validiert und gesendet.
