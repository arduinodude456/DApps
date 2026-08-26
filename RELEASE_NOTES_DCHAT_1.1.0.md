# DChat 1.1.0

DChat kann jetzt **optional** auf neue öffentliche Beiträge hinweisen. Die Funktion ist nach Installation **ausgeschaltet**. Aktiviere sie erst unter **AppDock Settings → DApp permissions → DChat → Run in background for notifications**.

Bei aktivierter Berechtigung prüft DChat nur solange KOReader läuft, nur bei eingeschaltetem WLAN und höchstens einmal in 15 Minuten. Der Hintergrundabruf aktualisiert den Bildschirm nicht. Er erzeugt höchstens eine zusammengefasste AppDock-Benachrichtigung für seit dem letzten gesehenen Stand neue Beiträge und meldet dieselbe Nachricht nicht erneut.

Der erste erfolgreiche Hintergrundabruf legt lediglich einen lokalen Ausgangsstand an und erzeugt keine Benachrichtigung. Ein manueller DChat-Refresh markiert die sichtbaren Beiträge ebenfalls als gesehen. DChat bleibt ein öffentlicher Textraum: Es gibt keine privaten Nachrichten, keine Ende-zu-Ende-Verschlüsselung und keine Echtzeit- oder Push-Garantie.
