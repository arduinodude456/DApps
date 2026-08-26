# DPdf 1.0.0

DPdf ist ein lokaler PDF-Betrachter für AppDock. Er öffnet ausschließlich vorhandene absolute `.pdf`-Dateipfade und verwendet dafür KOReaders vorhandene `DocumentRegistry` und PDF-Renderer. DPdf lädt keine Dokumente aus dem Netz, sendet keine PDF-Daten und ändert die geöffnete Datei nicht.

Die DApp zeigt eine Seite mit Vor-/Zurück-Steuerung an und berechnet den Seitenzoom aus der aktuell zugewiesenen DApp-Pane. Dadurch bleibt die Ansicht im normalen DApp-Fenster und in kurzen Splitscreen-Panes nutzbar. Beim Verlassen der DApp wird das Dokument geschlossen, damit KOReader den Renderer- und Seitencache wiederverwenden kann.

PDF-Darstellung, Speicherbedarf und Geschwindigkeit hängen von Datei, Seitengröße, Bildern, KOReader-Version und Reader-Hardware ab. DPdf ersetzt keine vollständige KOReader-Leseansicht und bietet in Version 1.0.0 bewusst keine Annotationen, Formulare oder Netzwerkquellen.
