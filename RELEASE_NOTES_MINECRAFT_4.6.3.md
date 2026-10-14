# Minecraft 3D 4.6.3

Der Welt-Canvas und überlagerte Bedienelemente konnten Touch-Gesten noch vor dem Inventar bekommen. Die Canvas-Geste leitet Taps bei offenem Inventar oder Handwerk nun direkt ans jeweilige Panel weiter; Hotbar, Joystick, Sprung- und Weltbuttons geben Touches ebenfalls ans Modal ab. Direkte Weltaktionen, Umsehen, Halten und Wischen sind während des Overlays gesperrt. Beim Öffnen wird eine gehaltene Bewegung beendet.

Die Regression prüft explizit den Fall, dass ein Inventar-Tap zuerst beim Welt-Canvas landet: Ein Item muss ausgewählt werden, ohne dass sich die Spielfigur bewegt oder ein verdeckter Weltbutton auslöst.
