# DockUpdate 2.1.3

- Unterstützt AppDock 9.0.0 vollständig.
- Installiert die neuen Kernmodule `appdock_media.lua` und `appdock_whatsnew.lua` nur ab Release 9.0.0.
- Die Versionsgrenze verhindert, dass ältere AppDock-Releases Dateien angefordert werden, die in diesen Releases noch nicht vorhanden waren.
- Der Regressionstest prüft den vollständigen 9.0.0-Dateibaum einschließlich der neuen Module.
