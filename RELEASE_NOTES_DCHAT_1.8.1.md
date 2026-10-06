# DChat 1.8.1 — Layout-Fix

DChat 1.8.1 korrigiert die Layoutregression aus 1.8.0. Alle pane-internen Abstände, Schriften und Bubble-Größen verwenden jetzt dieselbe Skalierung wie der AppDock-Host. Dadurch bleiben Sidebar, Composer und Konversationen auch in Splitscreen- und Compact-Panes konsistent.

Zusätzlich sind die Einstellungen höhenabhängig abgesichert, sehr kleine Detailansichten vermeiden negative Textbereiche und Button-/Bubble-Inhalte werden innerhalb ihrer tatsächlichen Innenfläche begrenzt. Das Update ändert weder Netzwerkprotokoll noch gespeicherte Chatdaten.
