# Minecraft 3D 4.6.0

## Neu

- **Survival und Creative** sind echte getrennte Spielmodi und werden zusammen mit dem Schwierigkeitsgrad in jedem Welt-Eintrag abgelegt.
- **Survival:** begrenzter Startbestand, Blockplatzierung verbraucht Gegenstände, Abbau liefert Drops, 20 HP, Hunger, Brot essen, natürliche Heilung, Verhungern und Respawn mit Inventarerhalt. Zombies jagen den Spieler nachts; Easy/Normal/Hard skalieren den Schaden. Peaceful deaktiviert Hunger und feindliche Angriffe und regeneriert Gesundheit.
- **Creative:** startet ohne endliche Blöcke. Jeder Block kann direkt im Katalog gewählt und unbegrenzt gesetzt oder abgebaut werden; Hunger und Schaden durch feindliche Mobs sind deaktiviert.
- Brot ist als Pixel-Art-Gegenstand und Rezept (3 Weizen) verfügbar; der Survival-Start enthält vier Brote.
- Die Weltliste zeigt sechs Welten pro Seite mit Vor/Zurück-Steuerung; die ausgewählte Spielart und Schwierigkeit werden beim Öffnen der gespeicherten Welt wiederhergestellt.
- Die fünf Weltoptionen im Erstellungsmenü und die unteren Aktionen verwenden größere, an die Bildschirmhöhe angepasste Touch-Flächen.

## Tests

- Lua-5.1-Syntaxprüfung mit `luac5.1 -p minecraft.lua`.
- Isolierte Regressionen für endliche/unendliche Ressourcen, Brot/Hunger, Nachtangriffe und Schwierigkeit, Creative-Immunität, Menü-Hitboxen, Seitenwechsel und Wiederherstellen eines Creative-Spielstands.

## Hinweis

Wie zuvor bleiben gespeicherte Welt-Einträge (Name, Seed, Modus und Schwierigkeit) lokal erhalten. Veränderte Blöcke, Inventar, Gesundheit und Hunger werden nicht als fortlaufender Welt-Spielstand serialisiert.
