# Geometry Rush 1.0.1

Der VNC-Client pollt jetzt mit 60 Hz und fordert nach jeder vollständigen Antwort — auch nach einem leeren Update — den nächsten Frame an. Die Bildausgabe ist für E-Ink auf maximal 480 Pixel Breite und eine 40-ms-Framekadenz abgestimmt; der schnelle `fast`/A2-Refresh bleibt Standard. Wer Graustufen/Farben höher gewichtet, kann `GD_REFRESH=ui` setzen.

Sprung-Taps auf dem Bild und der JUMP-Taste bleiben mindestens 160 ms aktiv. Kurze Kobo-Touch-Eingaben gehen damit nicht mehr zwischen zwei Spiel-Frames verloren; ausbleibende Release-Gesten werden abgefangen.
