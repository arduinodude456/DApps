# Random Book Covers Widget

## Datenvertrag

Das Widget verwendet ausschließlich die lokale KOReader-Lesehistorie (`readhistory.hist`) als Kandidatenliste. Jede Auswahl enthält höchstens drei unterschiedliche, nicht als gelöscht markierte Buchdateien. Titel stammen aus dem lokalen Verlaufseintrag; falls dort kein Text vorhanden ist, wird ausschließlich der echte Dateiname angezeigt.

## Coververtrag

Für jeden ausgewählten lokalen Buchpfad fragt das Widget nur die vorhandene KOReader-BookInfo-Schnittstelle nach einem Cover-Blitbuffer. Ein Bild wird niemals aus dem Netz geladen, erzeugt oder aus einem fremden lokalen Pfad erraten. Der Bildabruf ist auf die ersten 24 zufällig gemischten Verlaufseinträge begrenzt und führt höchstens drei sichtbare Coveranfragen aus.

| Zustand | Darstellung |
|---|---|
| Lokale Historie und Cover verfügbar | Drei echte Buchcover mit ihren lokalen Titeln. |
| Lokales Buch ohne erreichbares Cover | Gleicher Buchslot mit „No local cover“ und dem echten lokalen Titel. |
| Keine lokale Lesehistorie | Klarer Hinweis, zunächst lokale Bücher zu öffnen. |
| Keine BookInfo-Schnittstelle | Derselbe ehrliche Platzhaltermodus ohne Coverextraktion. |

Die Cover werden an `ImageWidget` als übernommene Blitbuffer übergeben. KOReaders normaler Widget-Lebenszyklus gibt sie beim Schließen frei. Das Widget besitzt keine Hintergrundaufgabe und wird nur bei der bestehenden Homescreen-Widgetaktualisierung neu gemischt.
