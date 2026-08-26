# DChat 1.1.1

Dieses Patchupdate korrigiert die Hintergrundbenachrichtigung nach einem anfänglich leeren öffentlichen Raum. Ein erfolgreicher erster Abruf speichert jetzt auch dann einen lokalen Ausgangsstand, wenn noch keine Nachricht existiert. Der erste später eingehende Beitrag löst daher bei aktivierter DChat-Hintergrundberechtigung zuverlässig genau eine zusammengefasste AppDock-Benachrichtigung aus.

Die festen Grenzen bleiben unverändert: Die Funktion ist standardmäßig aus, läuft nur bei laufendem KOReader und WLAN, frühestens alle 15 Minuten, ohne Bildschirmrefresh und ohne doppelte Meldung bereits gesehener Beiträge.
