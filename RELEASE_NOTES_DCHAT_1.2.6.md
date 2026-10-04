# DChat 1.2.6

Behebt leere private Chatverläufe: MySQL lieferte Nachrichten-IDs als Zahlen, während der Lua-Client bisher nur String-IDs akzeptierte und deshalb jede DM aus dem Verlauf verwarf.

Der Manus-Server serialisiert Public- und DM-IDs jetzt ausdrücklich als Strings. Der Client normalisiert zusätzlich numerische IDs robust. Bereits gespeicherte Direktnachrichten werden nach dem Update angezeigt.
