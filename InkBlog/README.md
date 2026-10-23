# InkBlog

**Write in ink. Read in peace.**

InkBlog ist eine native Lua-DApp für AppDock innerhalb von KOReader. Auf dem eReader lassen sich eigene Markdown-Blogs schreiben, andere Blogs abonnieren und Einträge in Ruhe seitenweise lesen. Die Anwendung ist keine Website und benötigt keinen Webbrowser auf dem Gerät.

## Installation und Anmeldung

Im AppDock-AppStore den Katalog aktualisieren und **InkBlog** installieren. Der Katalog verweist auf `InkBlog/inkblog.lua`; die gesamte Geräteanwendung steckt in dieser einzelnen Datei. Logoassets, Backenddateien und Tests müssen nicht zusätzlich auf den Reader kopiert werden. AppDock verlangt wie bei allen vertrauenswürdigen Lua-DApps die Installationsbestätigung auf dem Gerät. InkBlog fordert das vorhandene AppDock-TBS-Konto (`requires_tbs_account = true`) und nutzt die offizielle `appdock_tbs_account`-API. Beim ersten Profilaufruf oder bei der ersten kontoabhängigen Aktion bestätigt ein Edge-Endpunkt die TBS-Gerätecredentials beim vorhandenen TBS-Dienst, erstellt automatisch ein Supabase-Auth-Konto mit derselben TBS-UUID samt InkBlog-Profil und liefert eine gewöhnliche RLS-gebundene Sitzung. Es gibt keine zweite InkBlog-Registrierung, kein InkBlog-Passwort und keine E-Mail-Verifikation; das TBS-Gerätegeheimnis bleibt lokal und wird nur über HTTPS an den TBS-Verifizierer übermittelt.

Die DApp verwendet das vorhandene Supabase-Projekt **dchat**, Referenz `qndwbriqomqqaqhkasbh`, unter `https://qndwbriqomqqaqhkasbh.supabase.co`. Der öffentliche Publishable-Key entspricht dem bereits verwendeten Schlüssel aus `dchat.lua`. Er ist kein geheimes Servercredential. Service-Role-Schlüssel befinden sich ausschließlich in der Supabase-Edge-Laufzeit.

Für neue InkBlog-Nutzer ist keine manuelle Anmeldung nötig: AppDock stellt das bereits angemeldete TBS-Konto bereit, InkBlog richtet den zugehörigen Backend-Nutzer beim ersten Kontoabruf selbst ein. Der E-Mail-Dialog bleibt ausschließlich für bereits bestehende InkBlog-Legacy-Konten verfügbar; neue E-Mail-Konten lassen sich darüber nicht anlegen.

Die vorhandene DChat-DApp und AppDock-TBS verwenden Gerätecredentials. InkBlog gibt diese Geheimnisse niemals als Supabase-Token aus: Der Backend-Endpunkt verifiziert das TBS-Gerät über den bestehenden TBS-Dienst und stellt erst danach eine normale, konto- und RLS-gebundene InkBlog-Sitzung aus. DChat, bestehende TBS-Konten und vorhandene Auth-Einstellungen werden dabei nicht verändert.

## Schreiben und Lesen

**Tinte aufnehmen** beginnt einen Eintrag. Titel und Markdown-Text stehen als direkt antippbare Textfelder im Schreibbildschirm; das Textfeld zeigt mehrzeilige Inhalte. Für die Eingabe öffnet sich die AppDock-Tastatur. Im Markdown-Modus fügt `↵` einen Zeilenumbruch ein und **Fertig** übernimmt den Text. **Entwurf** hält den Eintrag privat, **Veröffentlichen** macht ihn lesbar. Einträge bleiben bearbeitbar und können nach einer Bestätigung gelöscht werden. Das Markdown unterstützt Überschriften, Fett/Kursiv, Listen, Zitate, Code, HTTPS-Links und Bilder. Benutzereingaben werden niemals als Lua, JavaScript oder aktive HTML-Inhalte ausgeführt.

Profilbilder und Beitragsbilder werden als lokale PNG- oder JPEG-Dateien hochgeladen. Der Alt-Text ist für Beitragsbilder Pflicht. Die serverseitige Verarbeitung begrenzt das Rohbild auf 2 MiB und 4 Megapixel; Beitragsbilder werden unter Erhalt ihres Seitenverhältnisses auf höchstens 800 × 1000 Pixel verkleinert. Profilbilder sind 128 × 128 Pixel mit kreisförmigem Siegelrand. Transparenz wird auf Weiß reduziert; Metadaten und Farbinformationen werden nicht übernommen. Die Ausgabe enthält entweder ausschließlich Schwarz/Weiß/#333333/#666666/#CCCCCC oder ist eine echte 1-Bit-Graustufen-PNG mit Floyd-Steinberg-Dithering.

Die DApp fügt verwaltete Beitragsbilder als `![Alt-Text](inkblog:BENUTZER-ID/EINTRAG-ID/BILD-ID.png)` ein. Fremde externe Bildquellen werden nicht automatisch geladen; ihr Alt-Text bleibt sichtbar. Das schützt vor Tracking, farbigen Fremdbildern und unkontrollierten Downloads. Bilder werden über den eigenen Media-Endpunkt mit denselben Inhaltsrechten wie der Beitrag ausgeliefert; Entwurfsbilder sind nicht öffentlich.

**Feed** zeigt abonnierte Blogs, **Entdecken** neueste oder beliebteste Einträge und das Blogprofil die Einträge einer Person. Alle Listen und Lesetexte verwenden explizite Seiten mit Vor-/Zurück-Blättern statt Endlosscroll. Netzwerkzugriffe starten nur durch eine Nutzeraktion; das Erstellen eines Pane löst keine Abfrage aus.

## Soziale Funktionen und Moderation

**Abonnieren** beziehungsweise Entfolgen steuert den Feed. Ein **Klecks** ist ein Like auf einen Eintrag oder eine Randnotiz. **Randnotizen** sind Kommentare mit genau einer Antwortebene. Nutzer können ihre eigenen Kommentare löschen; Blogbesitzer dürfen außerdem Kommentare unter ihren Einträgen entfernen. Benachrichtigungen für neue Follower, Likes und Kommentare erscheinen in einer einfachen Liste ohne Push.

Einträge und Kommentare können mit einer Begründung gemeldet werden. Eine Meldung zieht keinen automatischen Inhaltsentzug nach sich; sie ist eine nur für den Melder und vertrauenswürdige Backendadministratoren lesbare Moderationsmeldung. Blockieren unterbindet die Sichtbarkeit und soziale Interaktionen in beiden Richtungen. Entblockieren hebt diese Einschränkung auf. Es gibt keine öffentliche Administratoroberfläche und keine vorgetäuschte automatische Moderation.

## Backendstruktur

Alle neun neuen Tabellen liegen im Schema `public` und haben den isolierten Präfix `inkblog_`:

- `inkblog_profiles`: Supabase-Auth-ID, Anzeigename, Bio und Avatarpfad.
- `inkblog_posts`: Autor, Titel, Markdown, Entwurfs-/Publikationsstatus und Zeitstempel.
- `inkblog_post_images`: Zugehöriger Eintrag, Autor, Speicherpfad, Alt-Text und Bildabmessungen.
- `inkblog_follows`: Follower und abonnierter Blog.
- `inkblog_likes`: Benutzer und polymorpher Eintrags-/Kommentarbezug.
- `inkblog_comments`: Eintrag, Autor, optionaler Elternkommentar und Text.
- `inkblog_notifications`: Empfänger, Auslöser, Typ, Ziel und Lesestatus.
- `inkblog_reports`: Melder, Inhaltstyp, Ziel und Begründung.
- `inkblog_blocks`: Blockierender und blockierter Benutzer.

Alle Tabellen aktivieren Row Level Security. Veröffentlichte Inhalte sind lesbar; Entwürfe nur für den Autor. Schreibrechte, unveränderliche Eigentümerschaft, Kommentar-Löschrechte und eine Antwortebene werden serverseitig abgesichert. Likes und Meldungen müssen auf existierende erlaubte Ziele zeigen. Benachrichtigungen erzeugt ausschließlich das Backend, nicht der Client. Der Empfänger darf nur den vorgesehenen Lesestatus verändern. Auth-Claims werden pro SQL-Anweisung ausgewertet, nicht wiederholt für jede Ergebniszeile. Feed-, Like- und Fremdschlüsselindizes unterstützen paginierte Abfragen, Zähler und verknüpfte Einträge.

`inkblog_list_posts` liefert paginierte Einträge einschließlich Autorenname, Avatar, Like-/Kommentarzählern und eigenen Like-/Follow-Zuständen. Parameter: `p_mode` (`discover`, `feed`, `blog`, `mine`), optional `p_author`, `p_sort` (`newest`, `popular`), `p_limit`, `p_offset`. `inkblog_list_comments` nimmt `p_post`, `p_limit` und `p_offset` entgegen. Beide RPCs respektieren die Identität und RLS des Aufrufers.

Die Storage-Buckets **inkblog-avatars** und **inkblog-images** sind privat und erlauben ausschließlich PNG-Ausgabe. Direkte Clientuploads werden verweigert. Die additive Migration bringt eigene restriktive Storage-Schutzregeln mit, die auch bei später ergänzten breiten permissiven Policies wirksam bleiben. Vorhandene Storage-Buckets, Tabellen und Daten bleiben unverändert.

## Media-API

Die neue Edge Function heißt **inkblog-media**. `POST /functions/v1/inkblog-media` erwartet einen gültigen Benutzer-Bearer-Token und JSON mit `kind` (`avatar` oder `post`), `post_id` für Beitragsbilder, `alt_text`, `mime`, `image_base64` und optional `dither`. Antwort: `path`, `width`, `height` und bei Beitragsbildern `id`. Der Server speichert zuerst ausschließlich optimierte Bildbytes und ordnet anschließend den Pfad dem eigenen Profil beziehungsweise eigenen Eintrag zu. Eine fehlgeschlagene Zuordnung entfernt den gerade hochgeladenen Speichergegenstand.

`GET /functions/v1/inkblog-media?bucket=inkblog-images&path=...` liefert PNG-Bytes. Für Avatare heißt der Bucketparameter `inkblog-avatars`. Der Endpunkt prüft zunächst die sichtbaren Metadaten mit der RLS-Identität des Aufrufers. Der Service-Role-Download erfolgt nur nach dieser Berechtigungsprüfung. Authentifizierte Clients senden ihren Bearer-Token; anonyme Leser können nur veröffentlichte, nicht gesperrte Inhalte sehen.

`DELETE` auf demselben Bildpfad verlangt eine gültige Benutzersitzung und prüft den vollständigen Eigentümerpräfix des verwalteten Speicherpfads. Es entfernt nur die eigene Bildzuordnung und Bilddatei; fremde Bildlöschung ist ausgeschlossen. Damit lassen sich gelöschte Beiträge und eigene Testuploads ohne Storage-Reste bereinigen.

`verify_jwt=false` ist hier ausdrücklich kein Verzicht auf Anmeldung: Der Endpunkt unterstützt anonyme öffentliche Lesezugriffe und validiert jeden Schreibzugriff selbst über Supabase `getUser()`. Der Gateway allein wird nicht als Sicherheitsgrenze verwendet. Nicht angemeldete Uploads erhalten HTTP 401.

## Backend erneut einrichten

Die versionierten SQL-Dateien liegen in `supabase/migrations/`; die Edge-Quellen in `supabase/functions/inkblog-media/` und `supabase/functions/inkblog-tbs-auth/`. Bei einem neuen Backend zunächst die Migrationen in Dateireihenfolge über Supabase anwenden, dann beide InkBlog-Edge-Functions deployen. Die bestehende dchat-Instanz darf nicht mit einem Schemareset überschrieben werden. Die Standardvariablen `SUPABASE_URL`, `SUPABASE_ANON_KEY` und `SUPABASE_SERVICE_ROLE_KEY` stehen in der Supabase-Edge-Umgebung zur Verfügung.

Mit der Supabase CLI aus `InkBlog/` nach dem Login das gewünschte Projekt verknüpfen und ausschließlich die fehlenden Migrationen anwenden. Ein erstmaliger Einsatz der CLI auf einem bestehenden Projekt muss dessen vorhandene Migrationshistorie berücksichtigen; `db reset` ist für dchat ausdrücklich ungeeignet. Die Media-Funktion lässt sich mit `supabase functions deploy inkblog-media --project-ref qndwbriqomqqaqhkasbh --no-verify-jwt`, die TBS-Brücke mit `supabase functions deploy inkblog-tbs-auth --project-ref qndwbriqomqqaqhkasbh --no-verify-jwt` bereitstellen. Beide validieren ihre jeweilige Berechtigung selbst; `inkblog-tbs-auth` prüft die Geräte-ID und das TBS-Gerätegeheimnis beim vorhandenen `tbs-account`-Dienst. Für ein anderes Projekt den öffentlichen URL-/Publishable-Key im Lua-Client aktualisieren.

## E-Ink-Design und lokale Daten

Das Logo ist ein Tintentropfen mit einer Federspitze im weißen Negativraum; `assets/inkblog.svg` ist die editierbare Quelle. Die PNG-/BMP-/PBM-Varianten sind tatsächlich 1-Bit, keine bloß optisch monochromen RGB-Dateien. `/usr/bin/python3 tools/build_logo.py` reproduziert sie mit CairoSVG und Pillow.

Die Anwendung erzwingt eine monochrome Palette unabhängig von Farbgerät oder Host-Theme. Serif-Lesetext und Sans-UI, große Touch-Ziele, klare Linien und kurze poetische Leerzustände bilden eine ruhige Druckseitenästhetik. Es gibt keine Animationen, keine Hintergrundabfragen, kein Push und keine automatische Refreshschleife. Die Anwendung fordert nur nach einer bewussten Zustandsänderung einen UI-Neuaufbau an; die konkrete E-Ink-Wellenform verwaltet AppDock/KOReader.

Sitzung und lokale Schreibstände gehören in InkBlogs eigenes Datenverzeichnis. Sie enthalten private Auth-Token und Entwürfe; das Gerät sollte deshalb gegen fremden Dateizugriff geschützt sein. Passwörter werden nicht als persistente Einstellung gespeichert. Lokale Dateien werden begrenzt, als Daten validiert und atomar geschrieben. Ein Netzwerkfehler darf keinen vorhandenen Entwurf überschreiben. Eine Abmeldung muss private gecachte Bilder und sichtbare Nutzerdaten aus dem aktiven Zustand entfernen.

## Kurzer Testplan

Aus dem Repositoryroot `luac5.1 -p InkBlog/inkblog.lua` und `lua5.1 InkBlog/tests/test_inkblog.lua` ausführen. Die Lua-Tests verwenden KOReader-Testdoubles für TBS-Identität, Kontowechsel, Markdown, Gesten, Netzwerkfehler und normale sowie kleine Pane-Geometrien. Die Media-Tests laufen mit `deno test --config InkBlog/supabase/functions/inkblog-media/deno.json InkBlog/tests/media_test.ts` sowie `deno test --config InkBlog/supabase/functions/inkblog-tbs-auth/deno.json InkBlog/tests/tbs_auth_test.ts`. Deno-Typprüfung: `deno check --config InkBlog/supabase/functions/inkblog-media/deno.json InkBlog/supabase/functions/inkblog-media/index.ts` und `deno check --config InkBlog/supabase/functions/inkblog-tbs-auth/deno.json InkBlog/supabase/functions/inkblog-tbs-auth/index.ts`.

`tests/tbs_auth_test.ts` testet Credentialvalidierung, serverseitige TBS-Verifikation, automatische Auth-/Profilanlage und den Schutz vor UUID-Kollisionen. `tests/rls.sql` ist ein transaktionaler Zwei-Nutzer-Test. Er legt nur temporäre eigene Testidentitäten und InkBlog-Daten an und schließt mit Rollback. Getestet werden fremdes Ändern/Löschen, Entwurfsprivatsphäre, Folgen/Feed/Likes/Kommentare, Antworttiefe, Benachrichtigungen, Blockieren und Storage-Rechte. Die Abfragen erfolgen unter den tatsächlichen Rollen `anon` und `authenticated`, nicht nur als privilegierter Administrator.

`tests/live_api.py` ergänzt einen echten HTTPS-Zwei-Nutzer-Test einschließlich Supabase-Login, Upload, Bildprivatsphäre, Feed und sozialer Aktionen. `--prepare` schreibt nur eigene Fixture- und SQL-Payloads mit Dateimodus 0600 nach `/tmp`; die administrative Provisionierung und die anschließende Kontobereinigung werden separat direkt über Supabase ausgeführt. Der Test versendet keine E-Mails und verändert nur eindeutig markierte eigene Testidentitäten. Auch bei einem Fehlschlag muss der vorbereitete Bereinigungspayload ausgeführt werden. Kennwörter und Token gehören niemals in Logs oder ins Repository.

Auf einem echten eReader anschließend mit zwei Konten durchspielen: Profil und Avatar anlegen, Eintrag mit Alt-Text-Bild als Entwurf speichern und veröffentlichen; zweites Konto abonnieren, Feed öffnen, seitenweise lesen, Klecks vergeben und Randnotiz/Antwort schreiben. Eigene und Blogbesitzer-Kommentarlöschung, Meldung, Blockieren/Entblockieren, Benachrichtigung und Wiederanmeldung prüfen. Bei 600 × 760 sowie 600 × 350 Pane-Größe auf Lesbarkeit, Touchbereiche und fehlende Überlappungen achten. Tatsächliche Hardware-Wellenformen, Tastatur und Bilddecodierung erfordern einen Gerätepass; lokale Testdoubles können ihn nicht ersetzen.
