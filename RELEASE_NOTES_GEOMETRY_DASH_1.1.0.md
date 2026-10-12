# Geometry Dash 1.1.0

Die DApp enthält jetzt einen **Leveleditor**. Er setzt pro Tipp genau ein Objekt auf die gerasterte Bahn: **Spike**, **Block** und **Trampolin** platzieren, **Löschen** entfernt das Objekt unter dem Finger. **◀ zurück** und **vor ▶** verschieben die Ansicht, **Länge −** und **Länge +** ändern die Levelbreite, **Name** benennt die eigene Ebene und **Neu** setzt den Entwurf zurück.

Eigene Ebenen werden ausschließlich lokal im KOReader-Datenverzeichnis (Ordner `appdock_geometry_dash`) gespeichert und bleiben nach dem Schließen der DApp erhalten. **Spielen** startet den Entwurf sofort im normalen Spielablauf. Die Editorfläche zeichnet nur ihre eigene Region mit `fast` neu.