# DChat 1.4.11

Behebt einen nativen KOReader/Android-Absturz beim Aktualisieren eines privaten Chats. Der ↻-Refresh startet den HTTPS-Abruf jetzt erst im nächsten UI-Zyklus und nicht direkt innerhalb des Touch-Callbacks.
