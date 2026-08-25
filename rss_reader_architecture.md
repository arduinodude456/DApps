# RSS Reader: Architekturentscheidung

RSS Reader wird als einzelne AppStore-kompatible Lua-DApp ausgeliefert, gliedert sich intern aber in Netzwerk, Parser, lokalen Speicher und E-Ink-UI.

| Bereich | Entscheidung |
|---|---|
| Feedliste | Nutzerinnen und Nutzer hinterlegen nur explizit eingegebene HTTPS-Feed-URLs. Feedname und URL werden lokal gespeichert. |
| Abruf | Striktes HTTPS, 12 Sekunden Verbindungszeit, 30 Sekunden Gesamtzeit, 768 KiB maximale Antwort und maximal sechs Weiterleitungen. HTTP, Datei-, Daten- und andere Schemata werden abgewiesen. |
| RSS/Atom | Begrenzter Parser für RSS 2.0 `channel/item` und Atom `feed/entry`; höchstens 60 Artikel je Feed. Es werden Titel, Datum, Link und textorientierte Zusammenfassung übernommen. |
| Darstellung | Feedübersicht, Artikelübersicht und lesbarer Textmodus. HTML aus Beschreibungen wird sanitisiert und nicht als aktive Webseite ausgeführt. Ein Original-Link wird ausschließlich angezeigt, nicht durch RSS Reader geöffnet. |
| Speicherung | Atomare Datei im KOReader-Datenverzeichnis: lokale Feeds, begrenzter Artikelcache und Lesestatus. Fehlgeschlagene Abrufe ersetzen den letzten erfolgreichen Cache nicht. |
| E-Ink | Aktualisierungen erfolgen nur nach bewussten Aktionen mit regulärem `ui`-Neubau. Keine Animationen, Polling-Tasks oder Vollrefreshes. |

Die erste Version verzichtet bewusst auf OPML-Import/Export, Feed-Authentifizierung, Web-Logins, JavaScript, Podcasts, eingebettete Bilder und Hintergrundaktualisierung.
