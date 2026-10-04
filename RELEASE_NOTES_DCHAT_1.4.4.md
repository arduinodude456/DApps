# DChat 1.4.4

Private Chat-Bildanhänge werden jetzt direkt im Gesprächsverlauf und in der Nachrichtendetailansicht angezeigt. Die Base64-Daten werden validiert, temporär lokal dekodiert und mit KOReaders `ImageWidget` dargestellt; ungültige Anhänge erhalten einen verständlichen Fallback.
