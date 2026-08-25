# DReader: Architekturentscheidung

DReader wird als **eine installierbare Store-DApp-Datei** ausgeliefert, weil der AppDock-AppStore nur einzelne, sichere `.lua`-DApps installiert. Innerhalb dieser Datei bleiben die Verantwortlichkeiten trotzdem explizit getrennt, damit spätere Funktionen ohne Vermischung erweitert werden können.

| Logisches Modul | Verantwortung | Grenzen |
|---|---|---|
| `Store` | Atomisches Speichern von Bibliothek, Lesezustand und Reader-Einstellungen | Speichert nur DReader-eigene Daten im KOReader-Datenspeicher. |
| `HTML` | Sichere Normalisierung: Skripte, Styles und externe/interaktive Elemente entfernen; Entitäten/UTF-8 aufbereiten | Kein Browser, kein JavaScript, keine Netzwerkzugriffe. |
| `EPUB` | `container.xml`, OPF, Manifest, Spine, NCX und EPUB-3-Navigation aus dem Archiv lesen | Liest ausschließlich reguläre Archiveinträge in den Speicher; keine pauschale Extraktion. |
| `Book` | Metadaten, Kapitel, Text-Cache und Positionen | Beschränkt Größen, Kapitelanzahl und Cache, damit ungewöhnliche Bücher den Reader nicht blockieren. |
| `Paginator` | Wortgrenzen- und zeilenorientierte, stabile Seitenaufteilung mit Positionsanker | Seiten hängen nur von DReader-Schriftstufe, Rändern und Pane-Größe ab. |
| `Reader UI` | Bibliothek, Leseseite, Kapitelbrowser, Einstellungen, Tap-Zonen und Buttons | Kennt ausschließlich `context.dimen`; keine globalen Bildschirmmaße. |

## Dateisicherheit

DReader akzeptiert nur lokale `.html`, `.htm`, `.xhtml` und `.epub`-Dateien. Für EPUB gelten ein Archivgrößenlimit, reguläre Dateieinträge, Grenzen für OPF/Spine/Einzelkapitel und sichere relative Pfade ohne `..`. Beschädigte Strukturen zeigen verständliche Fehler an, statt die DApp abstürzen zu lassen.

## Funktionsumfang der ersten Veröffentlichung

Die erste DApp-Version enthält eine eigene Bibliothek, HTML/XHTML-Analyse, EPUB-Container/OPF/Spine-Lesen, EPUB-3-NAV- und NCX-Kapiteltitel, paginationierte Textseiten, Fortschrittsspeicherung, Kapitelwahl, Schriftstufen, Ränder, sichtbare Seitennavigation und zentrale Tap-Zonen. Bildreferenzen, komplexes CSS, interaktive HTML-Inhalte und DRM-EPUBs werden bewusst nicht als vollständige Browser-/Layout-Engine unterstützt.
