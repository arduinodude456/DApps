# DChat 2.1.0 — Replies und bessere Nachrichtenblasen

- Tippe eine private Nachricht an, um sie vollständig zu öffnen, und wähle **Reply**. Der Entwurf beginnt mit einem kurzen Zitat der beantworteten Nachricht. Replies verwenden weiterhin das bestehende Nachrichtentextfeld und funktionieren damit auch mit älteren DChat-Servern.
- Bildanhänge werden direkt im privaten Nachrichtenverlauf als verkleinerte Vorschau in der Bubble angezeigt; die Vollansicht bleibt per Tap erreichbar.
- Der Text in der Nachrichtenblase wird nicht mehr über eine feste Zeichenanzahl mit Auslassungspunkten abgeschnitten. Tippe die Bubble an, um den vollständigen Nachrichteninhalt in der Detailansicht zu lesen.
- Die Textfläche der Nachricht ist transparent, sodass die Hintergrundfarbe der Bubble durchgehend sichtbar bleibt.

Die Vorschau verwendet den dedizierten DChat-Bildcache und umgeht den geteilten KOReader-ImageWidget-Cache. Android und E-Ink-KOReader-Geräte erhalten denselben Vorschaupfad; wenn ein Bildwidget nicht erstellt werden kann, bleibt die Text-/Detailansicht nutzbar.

## Prüfung

Der DChat-Layouttest prüft Reply-Entwurf, transparente Textfläche, Bildvorschauen auf Android und Kobo, sowie vollständigen Nachrichtentext in der Bubble.
