# DockUpdate 1.2.9

DockUpdate fordert `appdock_surface.lua` nicht mehr an. Die Datei war in der Allowlist verblieben, ist aber in den aktuellen AppDock-Releases nicht enthalten; dadurch schlug jedes Update bei dieser Datei mit HTTP 404 fehl. Die Allowlist und Regressionstests entsprechen nun wieder exakt der tatsächlich veröffentlichten AppDock-Dateiliste.
