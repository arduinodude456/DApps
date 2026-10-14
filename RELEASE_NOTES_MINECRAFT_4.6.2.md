# Minecraft 3D 4.6.2

Das Inventar-Touchproblem lag an der Eingabereihenfolge: KOReader registriert Gesten des `InputContainer` beim Initialisieren. Die modale Inventargeste wurde zuvor erst nach dem Erzeugen des Welt-Panes hinzugefügt und konnte dadurch unregistriert bleiben. Sie wird jetzt direkt im Konstruktor übergeben, bevor die Initialisierung läuft; Berührungen werden dann zum offenen Inventar geleitet.

Die Regression prüft zusätzlich, dass die Pane-Geste bereits während der Initialisierung vorhanden ist, und testet Auswahl eines Gegenstands sowie Schließen per Touch über den echten Pane-Handler.
