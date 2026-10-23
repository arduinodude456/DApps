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

Die Oberfläche folgt einer ruhigen Buch-/Druckseitenästhetik. Ausschließlich Schwarz, Weiß und #333333/#666666/#CCCCCC sind zulässig, auch auf Farbgeräten und bei andersfarbigem Host-Theme. Serifenschrift trägt Lesetext, Sans-Serif die Bedienung. Der Tintentropfen hat eine weiße Federspitze als Negativraum. Profilbilder erhalten einen runden Stempelrand. Große Touch-Ziele, feste Seiten und explizites Blättern ersetzen Endlosscroll und Animationen. Netzwerkdaten werden nur bei bewusstem Laden aktualisiert. Claim: „Write in ink. Read in peace.“ Aktionen heißen „Tinte aufnehmen“, „Klecks“, „Abonnieren“ und „Randnotiz“. Leere Zustände sind kurze poetische Hinweise.

Die Umsetzung erfolgt Auth/Profil → Einträge und Uploads → Lesen/Feed → Folgen → Likes → Kommentare → Meldungen/Blockieren/Benachrichtigungen. Vor dem Push werden Lua-5.1-Kompatibilität und die sicherheitskritischen Backend-Pfade geprüft. Tests dürfen vorhandene dchat-Daten weder verändern noch löschen.
