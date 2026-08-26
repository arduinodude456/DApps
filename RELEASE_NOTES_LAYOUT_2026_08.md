# Store-DApps: AppDock-3.0-Layoutupdate

Die zentralen Store-DApps wurden auf den relativen AppDock-3.0-Pane-Vertrag umgestellt. Sie verwenden nun `context.px(...)` für sichtbare Mindestgrößen, Abstände und wesentliche Textgrößen. Dadurch bleiben sie sowohl im normalen DApp-Fenster als auch in kürzeren Split-Panes besser lesbar und bedienbar.

| DApps | Layoutanpassung |
|---|---|
| DReader, NightLua, Draw, Calc und 2048 | Leseflächen, Werkzeugleisten, Schaltflächen und Raster skalieren relativ zur zugewiesenen Pane-Größe. |
| Calendar, RSS Reader und BookTranslator | Karten, Listen- und Termin-/Feed-Steuerungen erhalten relative Mindestgrößen für kurze Pane-Höhen. |
| VideoPlayer, Gmail Notifications und DockUpdate | Medien-, Adapter- und Aktualisierungssteuerungen folgen der lokalen Pane-Geometrie, ohne ihre bestehenden Sicherheitsgrenzen zu ändern. |

Alle aktualisierten DApps behalten ihre bisherigen lokalen Datenmodelle, Netzgrenzen und expliziten Bestätigungsabläufe bei. Die Aktualisierungen erscheinen über die im Katalog angehobenen Versionen im AppStore.
