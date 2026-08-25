# Calendar: Architekturentscheidung

Calendar ist eine einzelne, installierbare AppStore-DApp mit logisch getrennten Bereichen für Kalenderarithmetik, lokalen Speicher, Terminvalidierung und Pane-Aufbau. Sie verwendet weder Netzwerk noch Synchronisation noch Systemkalenderzugriff.

| Bereich | Entscheidung |
|---|---|
| Datenspeicher | Atomare Datei unter dem KOReader-Datenverzeichnis; sie enthält nur `version`, optionale Einstellungen und den lokalen Terminbestand. |
| Terminmodell | Jeder Termin hat eine interne ID, ein lokales Datum `YYYY-MM-DD`, einen begrenzten Titel und optional eine kurze Notiz. |
| Monatsansicht | Gregorianische Monatsberechnung mit Montag als Wochenbeginn, sechs stabilen Zeilen und klarer Hervorhebung von Heute, ausgewähltem Tag und Tagen mit Terminen. |
| Tagesansicht | Antippen eines Tages öffnet seine Details mit den gespeicherten Terminen und einer Aktion zum Hinzufügen. Einzelne Termine können nur nach ausdrücklicher Bestätigung gelöscht werden. |
| E-Ink | Keine Animationen und keine fortlaufenden Aktualisierungen. Monatswechsel, Tageswahl und Änderungen bauen lediglich das betroffene DApp-Pane mit dem regulären UI-Refresh neu auf. |
| Grenzen | Keine Erinnerungen, keine Systemkalender-/ICS-Synchronisierung und keine Hintergrundjobs. Termine bleiben ausschließlich in Calendar lokal. |

Calendar verwendet ausschließlich die vom AppDock-Host übergebene Pane-Geometrie `context.dimen`. Damit bleibt die Monatsansicht in Open Apps und im Splitscreen skalierbar.
