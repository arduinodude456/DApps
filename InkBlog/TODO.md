# InkBlog – Ergebnisziele

## Aktuelle Ausbaustufe

- [x] Einen Beitrag erfolgreich veröffentlichen, ohne dass KOReader aufgrund einer unvollständigen oder unerwarteten POST-Antwort beim Wechsel zur Leseseite abstürzt; der vollständige lokale Entwurf bleibt bei Fehlern erhalten.
- [x] In jeder Beitragsvorschau und auf der Leseseite einen runden Autorenstempel mit dem Profilbild zeigen; sichtbare Avatare nach der bewussten Ladeaktion nur innerhalb des bestehenden begrenzten lokalen Bildcaches abrufen und einen Initialenstempel als robusten Fallback verwenden.
- [x] Von einem fremden Beitrag über einen eindeutigen **Profil**-Button das öffentliche Konto der Person öffnen; Name, Bio, Avatar und deren veröffentlichte Beiträge anzeigen, während Folgen und Blockieren weiterhin RLS-geschützt bleiben.
- [x] Die Oberfläche im farbigen Old-Paper-Stil mit warmem Papier, Pergament, Sepia, Tintenblau und kleinen Ocker-/Moosakzenten gestalten und auf monochromen Geräten automatisch kontrastreiche Graustufen einsetzen.

- [ ] Eigener Ordner im Repo dapps; vorhandene Lua-DApps analysiert und Struktur, Konventionen und API-Muster übernommen; single-file AppDock-Vertrag und passender Katalogeintrag.
- [ ] Konto über den bereits aktivierten Supabase-Auth-Pfad; Anzeigename, Bio, Profilbild-Upload mit serverseitiger Verkleinerung/Graustufen; persistente Sitzung und Abmeldung.
- [ ] Einträge erstellen, bearbeiten, löschen und als Entwurf speichern; Markdown mit Überschriften, Fett/Kursiv, Listen, Zitaten, Code, Links und Bildern; Bilder in privaten Supabase-Buckets mit Alt-Text und E-Ink-Optimierung.
- [ ] Navigation Feed, Entdecken, Schreiben, Profil und Benachrichtigungen; abonnierte Blogs, neueste/beliebteste Einträge, Blogprofil mit Eintragsliste; seitenweises Lesen und Blättern statt Endlosscroll.
- [ ] Abonnieren/Entfolgen; Klecks auf Einträge und Kommentare; Randnotizen mit maximal einer Antwortebene; eigene Kommentare und Kommentare am eigenen Blog löschen; Benachrichtigungen für neue Follower, Likes und Kommentare als einfache Liste ohne Push.
- [ ] Einträge/Kommentare melden; Nutzer blockieren/entblockieren; Eigentum, Entwurfsprivatsphäre und Blockregeln serverseitig durchsetzen.
- [ ] Alle neun verlangten inkblog_-Tabellen mit RLS, Feed-/Like-Indizes und SQL-Migrationen; Buckets inkblog-avatars und inkblog-images; vorhandene dchat-Tabellen/Daten unverändert.
- [ ] Name InkBlog, Claim „Write in ink. Read in peace.“, Tintentropfen mit Federspitze im Negativraum als SVG und 1-Bit-Bitmap; Old-Paper-Farbrollen mit #000/#FFF/Grau-33/66/CC-Fallback, Serif-Lesetext, Sans-UI, große Touch-Ziele, runde Siegel-Avatare, poetische Leerzustände; keine Animationen oder automatischen Refreshschleifen.
- [ ] Zwei-Nutzer-Szenario und fremdes Bearbeiten durch RLS geprüft; Lua-Vertrag, Markdown, Fehlerfälle und normale/kleine Pane-Geometrien geprüft; README mit Setup, Schema, Designrichtlinien und kurzem Testplan.
