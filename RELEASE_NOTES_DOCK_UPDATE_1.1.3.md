# DockUpdate 1.1.3

DockUpdate kann AppDock-Releases mit gebündelten PNG-Assets aktualisieren. Die Dateien werden aus dem geprüften `appdock.koplugin/assets/...`-Pfad geladen, in verschachtelte Staging-Verzeichnisse geschrieben und zusammen mit den Lua-Modulen atomar installiert.

Die Sicherheitsgrenzen bleiben aktiv: akzeptiert werden ausschließlich PNG-Dateien unter dem festgelegten Asset-Pfad, mit gültiger PNG-Signatur, einer Größe bis 3 MiB pro Asset und einer Gesamtgröße von höchstens 8 MiB. Lua-Quellen werden weiterhin separat auf Syntax geprüft. Andere Binärdateien, Archive, native Bibliotheken, versteckte Pfade und Directory-Traversal bleiben ausgeschlossen.

Der Regressionstest deckt nun den Download, die Signaturprüfung, das Anlegen des Asset-Unterverzeichnisses und die gemeinsame Installation eines PNGs mit den AppDock-Modulen ab.
