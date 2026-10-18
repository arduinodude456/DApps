# Transparente Textdarstellung

| DApp | Neue Version |
| --- | --- |
| DChat | 2.1.3 |
| AI Chat Agent | 1.5.4 |
| DReader | 2.2.1 |
| RSS Reader | 1.0.3 |
| Dex Document | 1.0.1 |
| DockUpdate | 1.4.5 |

Diese Apps nutzen den lokalen transparenten TextBox-Renderer aus AppDock 8.2.13 oder neuer, wenn er verfügbar ist. Nicht editierbare mehrzeilige Texte zeichnen damit nur die Glyphen; ihre Zwischenräume erhalten den darunterliegenden Hintergrund. Die Apps bleiben einzelne installierbare Lua-Dateien und laden keine zusätzlichen Dateien aus dem Netz.

Auf älteren AppDock-Versionen wird weiterhin KOReaders nativer TextBox-Renderer verwendet. Jeder TextBox-Aufruf setzt deshalb eine explizite, zur tatsächlichen Fläche passende Hintergrundfarbe. In DChat gilt das nun neben Sprechblasen auch für mehrzeilige Aktionsflächen, leere Kontakt-/Nachrichtenlisten, Einstellungen sowie öffentliche und private Nachrichtendetails. DChat 2.1.3 misst Blasen nun anhand KOReaders tatsächlichem Zeilenumbruch statt sie bei 180 Pixeln abzuschneiden; Lesestatus-Häkchen sind ein eigenes sichtbares Element. Antwortnachrichten bewahren ihre Zitatgrenze auch nach der Textbereinigung und stellen das Zitat in einer abgesetzten Karte dar. Die Blasenhöhe wird aus KOReaders tatsächlichem Textlayout gemessen statt auf 180 Pixel begrenzt; Versand-/Lesemarken sind eigene sichtbare Widgets. Antworten behalten mit einem unsichtbaren Textseparator ihre Zitatgrenze und rendern das Zitat in einer abgesetzten Karte.

Dex Document konfiguriert das interne `text_widget` seiner ScrollTextWidget-Ansicht. Ein bloßes `bgcolor` am äußeren ScrollTextWidget wird von KOReader nicht an den Textpuffer weitergegeben.

DockUpdate installiert `appdock_text.lua` für AppDock-Releases ab 8.2.13 aus seiner festen Dateiliste. Ältere Releases werden ohne das dort noch nicht vorhandene Modul installiert. Downloadgrenzen, Bestätigung und atomarer Ordnerwechsel bleiben unverändert.

Die übrigen DApps verwenden für ihre normalen Beschriftungen bereits KOReaders transparentes `TextWidget` und benötigen dafür kein Update. Absichtliche Dokument-, Bild-, Editor- und Auswahlflächen bleiben erhalten. Der Patch verändert keine globalen KOReader-Widgetklassen.

Neue Regressionen prüfen dChats Textflächen in allen Ansichten mit einem nichtweißen Theme, den optionalen Host-Renderer und den Updater sowohl mit als auch ohne das neue Modul. Pixel-Regressionen des Renderers liegen im AppDock-Repository.
