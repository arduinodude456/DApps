# InkBlog – Ergebnisziele

- [ ] Eigener Ordner im Repo dapps; vorhandene Lua-DApps analysiert und Struktur, Konventionen und API-Muster übernommen; single-file AppDock-Vertrag und passender Katalogeintrag.
- [ ] Konto über den bereits aktivierten Supabase-Auth-Pfad; Anzeigename, Bio, Profilbild-Upload mit serverseitiger Verkleinerung/Graustufen; persistente Sitzung und Abmeldung.
- [ ] Einträge erstellen, bearbeiten, löschen und als Entwurf speichern; Markdown mit Überschriften, Fett/Kursiv, Listen, Zitaten, Code, Links und Bildern; Bilder in privaten Supabase-Buckets mit Alt-Text und E-Ink-Optimierung.
- [ ] Navigation Feed, Entdecken, Schreiben, Profil und Benachrichtigungen; abonnierte Blogs, neueste/beliebteste Einträge, Blogprofil mit Eintragsliste; seitenweises Lesen und Blättern statt Endlosscroll.
- [ ] Abonnieren/Entfolgen; Klecks auf Einträge und Kommentare; Randnotizen mit maximal einer Antwortebene; eigene Kommentare und Kommentare am eigenen Blog löschen; Benachrichtigungen für neue Follower, Likes und Kommentare als einfache Liste ohne Push.
- [ ] Einträge/Kommentare melden; Nutzer blockieren/entblockieren; Eigentum, Entwurfsprivatsphäre und Blockregeln serverseitig durchsetzen.
- [ ] Alle neun verlangten inkblog_-Tabellen mit RLS, Feed-/Like-Indizes und SQL-Migrationen; Buckets inkblog-avatars und inkblog-images; vorhandene dchat-Tabellen/Daten unverändert.
- [ ] Name InkBlog, Claim „Write in ink. Read in peace.“, Tintentropfen mit Federspitze im Negativraum als SVG und 1-Bit-Bitmap; ausschließlich #000/#FFF/Grau 33/66/CC, Serif-Lesetext, Sans-UI, große Touch-Ziele, runde Siegel-Avatare, poetische Leerzustände; keine Animationen oder automatischen Refreshschleifen.
- [ ] Zwei-Nutzer-Szenario und fremdes Bearbeiten durch RLS geprüft; Lua-Vertrag, Markdown, Fehlerfälle und normale/kleine Pane-Geometrien geprüft; README mit Setup, Schema, Designrichtlinien und kurzem Testplan.
