# WidgetGenerator 1.0.0

WidgetGenerator ist eine lokale No-Code-DApp für **AppDock 3.1.0 oder neuer**. Sie erstellt eigene Homescreen-Widgets ohne Lua-Programmierung.

Ein Widget kann einen Titel, begrenzten Freitext sowie die optionalen lokalen Systeminfos Uhrzeit, Datum und – soweit die Reader-Hardware sie über KOReader bereitstellt – Akkustand anzeigen. WidgetGenerator bietet eine DApp-Vorschau, Bearbeitung, einen Homescreen-Sichtbarkeitsschalter und Löschen. Eigene Widgets erscheinen außerdem in AppDocks regulärer Widgetverwaltung und können dort wie Store-Widgets angeordnet werden.

Die DApp speichert höchstens 20 deklarative Widgetkonfigurationen lokal. Sie erzeugt oder führt keinen Nutzer-Lua-Code aus, nutzt kein Netzwerk und überträgt keine Daten. Beim Löschen entfernt AppDock die Konfiguration, den Sichtbarkeitsstatus und den gespeicherten Reihenfolgeneintrag.
