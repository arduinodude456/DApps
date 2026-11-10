# DockUpdate 2.1.4

DockUpdate unterstützt die neue AppDock-Glass-Oberfläche in AppDock 9.1.0. Das neue Kernmodul `appdock_glass.lua` wird zusammen mit den Quick-Settings über die feste Allowlist geladen und atomar installiert. Für ältere AppDock-Releases bleibt das Modul versionsbedingt ausgeschlossen; bestehende Updates bleiben damit rückwärtskompatibel. Der Regressionstest prüft Allowlist, Versionsgrenze und die vollständige Installation des neuen Moduls.
