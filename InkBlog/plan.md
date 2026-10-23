# InkBlog – Umsetzungsplan

InkBlog wird eine native AppDock-DApp für KOReader, keine Browser-Webseite. Der AppStore lädt genau eine Lua-Datei; deshalb ist `InkBlog/inkblog.lua` der eigenständige Produktiveinstieg. Die Version ist `1.0.0`, die technische ID `inkblog`. Die einzelnen Funktionsbereiche werden innerhalb der Datei klar gegliedert, während Backend, Migrationen, Assets und Tests im eigenen InkBlog-Ordner liegen.

## Übernommene Konventionen

`DeveloperManual.md`, `dchat.lua`, `markup.lua` und die vorhandenen DChat-Tests sind die Referenzen. Der DApp-Vertrag gibt eine Tabelle mit `id`, `title`, `version`, `buildPane(instance, context)` zurück. Der langlebige Zustand liegt unter `instance.inkblog`; Geometrie folgt ausschließlich `context.dimen` und `context.px`. Gestenbereiche werden beim Zeichnen auf absolute Koordinaten aktualisiert. Standardaktionen fordern `context.requestRebuild("ui")` an, nicht einen unbedingten Vollbildrefresh. Die AppDock-Tastatur wird, falls vorhanden, an KOReaders InputDialog angehängt. Netzwerkzugriffe erfolgen ausschließlich durch Nutzeraktionen, über HTTPS, mit Zeit- und Größenlimits. Der Katalogpfad und die Version müssen mit dem Lua-Modul übereinstimmen.

## Backend und Identität

Das ausdrücklich gewünschte vorhandene Supabase-Projekt `dchat` hat die Referenz `qndwbriqomqqaqhkasbh`. Die bestehende DChat-DApp verwendet Geräte-ID und Gerätegeheimnis; diese sind keine Supabase-Auth-Konten. Supabase aktiviert bereits E-Mail/Passwort und verlangt E-Mail-Bestätigung; kein externer OAuth-Anbieter ist aktiviert. InkBlog verwendet diesen bereits aktivierten Supabase-Auth-Pfad, ohne Auth-Konfiguration, DChat-Geräte oder andere Tabellen zu verändern. Im Client steht ausschließlich der öffentliche Publishable-Key, niemals ein Service-Role-Key.

Alle neuen Tabellen heißen `inkblog_*`; RLS schützt veröffentlichte Inhalte, autoreneigene Entwürfe, Kommentare und Interaktionen. Blockieren gilt in beide Richtungen. Datenbanktrigger erzeugen Benachrichtigungen und validieren eine Antwortebene. Private Storage-Buckets verhindern den Zugriff auf unveröffentlichte Bilder. Die neue Edge Function `inkblog-media` authentifiziert Supabase-Benutzer selbst und verarbeitet Bilder ausschließlich serverseitig; nur sie besitzt die Berechtigung, optimierte PNGs zu speichern.

## Struktur

- `inkblog.lua`: Anmeldung, lokale Sitzung und Entwürfe, Navigation, Markdown, Leseseiten, Profil, soziale Aktionen und Moderation.
- `supabase/migrations/`: additives Schema, RLS, Indizes, Trigger und Storage-Regeln als versionierte SQL-Dateien.
- `supabase/functions/inkblog-media/`: authentifizierte Upload- und E-Ink-Konvertierung.
- `assets/`: monochromes SVG-Logo sowie echte 1-Bit-Bitmapvarianten.
- `tests/`: Lua-Vertrags-/Geometrietests, transaktionale RLS-Prüfung und Media-Tests.
- `tools/`: reproduzierbare Asset-Erstellung, falls benötigt.
- `README.md`: Einrichtung, API, Schema, E-Ink-Richtlinien und kurzer Geräte-Testplan.

## Gestaltung

Die Oberfläche folgt einer ruhigen Buch-/Druckseitenästhetik im unabhängigen Old-Paper-System: warmes Papier, Pergament, Sepia-Ränder, tiefes Tintenblau und sparsame Ocker-/Moosakzente auf Farb-E-Ink; auf monochromen Geräten werden diese Rollen automatisch zu #000/#FFF/#333333/#666666/#CCCCCC mit hohem Kontrast. Serifenschrift trägt Lesetext, Sans-Serif die Bedienung. Der Tintentropfen bleibt eine 1-Bit-Grafik mit weißer Federspitze als Negativraum. Profilbilder erhalten einen runden Stempelrand. Große Touch-Ziele, feste Seiten und explizites Blättern ersetzen Endlosscroll und Animationen. Netzwerkdaten werden nur bei bewusstem Laden aktualisiert. Claim: „Write in ink. Read in peace.“ Aktionen heißen „Tinte aufnehmen“, „Klecks“, „Abonnieren“ und „Randnotiz“. Leere Zustände sind kurze poetische Hinweise.

Die Umsetzung erfolgt Auth/Profil → Einträge und Uploads → Lesen/Feed → Folgen → Likes → Kommentare → Meldungen/Blockieren/Benachrichtigungen. Vor dem Push werden Lua-5.1-Kompatibilität und die sicherheitskritischen Backend-Pfade geprüft. Tests dürfen vorhandene dchat-Daten weder verändern noch löschen.

## Aktuelle Ausbaustufe: robuste Autorenansicht und altes Papier

Ein erfolgreicher POST darf nie eine unvollständige Serverantwort direkt an den KOReader-Renderer weiterreichen. Die Antwort wird deshalb zu einem sicheren Beitragsmodell normalisiert und mit dem eigenen öffentlichen Profil ergänzt, bevor die Leseseite geöffnet wird. Auch Beiträge aus Benachrichtigungen erhalten dieses Profilmodell. So bleiben Titel, Text, Zeitstempel, Autor und Avatar für die Darstellung stets in verträglichen Typen vorhanden; ein fehlgeschlagener Profilabruf lässt lediglich einen sicheren Platzhalter stehen.

Beitragsvorschauen und die Leseseite erhalten jeweils einen runden Autorenstempel. Nach dem bewussten Laden einer Beitragsseite werden sichtbare Profilbilder innerhalb des vorhandenen begrenzten Bildcaches nachgeladen; ohne Cache bleibt der lesbare Initialenstempel sichtbar. Der klare Button **Profil** auf fremden Leseseiten führt zum bereits RLS-geschützten öffentlichen Blogprofil mit Bio, Avatar, Folgen/Blockieren und Beitragsliste.

Die visuelle Sprache wird zu „Old Paper“: warmes Papier, Pergamentflächen, Sepia-Ränder, tiefes Tintenblau und sparsame Ocker-/Moosakzente. Auf Farb-E-Ink-Geräten werden diese RGB-Töne verwendet; monochrome Geräte erhalten automatisch kontrastreiche, bewährte Graustufen-Fallbacks. Große Touchziele, paginierte Seiten und fehlende Animationen bleiben unverändert.
