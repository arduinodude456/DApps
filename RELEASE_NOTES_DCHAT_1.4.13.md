# DChat 1.4.13

## Fehlerbehebung

- Nach einem manuellen DM-Refresh wird der Conversation-Host nicht mehr direkt im Abschluss-Callback des synchronen HTTPS-Aufrufs neu aufgebaut. Der Rebuild wird um zwei KOReader-UI-Ticks verschoben; dabei wird geprüft, dass die Unterhaltung noch geöffnet ist. Das vermeidet den unmittelbaren `forceRePaint()`-Pfad im Netzwerk-Callback, der mit dem auf Android protokollierten Lifecycle-/Mutex-Crash vereinbar ist. Die genaue native Ursache ist ohne Android-Backtrace weiterhin nicht bewiesen.
- Die Android-Inlinevorschau für DM-Bilder ist wieder aktiv. Der vorangegangene Release 1.4.12 hatte sie deaktiviert, aber der Crash trat laut Gerätetest trotzdem auf; die Vorschau war daher nicht die Ursache.

## Prüfung

- Regressionstest deckt das verzögerte Rebuild, den geschlossenen Chat und die weiterhin sichtbare Bildvorschau ab.
- Vor Veröffentlichung sind Lua-5.1-Syntax, Regressionstest und `git diff --check` auszuführen.
