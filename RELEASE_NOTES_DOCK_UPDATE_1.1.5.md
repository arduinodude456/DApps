# DockUpdate 1.1.5

Boot-Fix: DockUpdate bleibt beim Start und im Hintergrund aktiv, führt den Background-/Autostart-Hook aber über einen geschützten `pcall`-Wrapper aus. Ein Fehler beim Netzwerkcheck oder in der Benachrichtigung beendet dadurch nicht mehr den KOReader-Start.

Die PNG-Unterstützung und die vorhandenen AppDock-Bilder bleiben unverändert.
