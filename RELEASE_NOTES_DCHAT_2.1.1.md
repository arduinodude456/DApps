# DChat 2.1.1 — Bubble-Texthintergrund

KOReaders `TextBoxWidget` setzt standardmäßig einen weißen `bgcolor` und rendert den Text in einem eigenen undurchsichtigen Buffer. `background = nil` schaltete diese weiße Fläche daher nicht ab. DChat setzt nun den `bgcolor` des Textwidgets explizit auf dieselbe Farbe wie die jeweilige Nachrichtenblase. Dadurch verschwindet der weiße Kasten und der Textbereich wirkt nahtlos in die Bubble eingebettet – unabhängig von hellem/dunklem Thema und RGB-/E-Ink-Anzeige.

Der Regressionstest prüft, dass das tatsächliche `bgcolor` des gerenderten Textwidgets exakt mit der Bubble-Hintergrundfarbe übereinstimmt.
