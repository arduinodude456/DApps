# Minecraft 3D 4.3.5

- Die Welt verwendet dauerhaft das flüssige E-Ink-Sampling 6; auch nach Pan, Laufbewegung oder dem Loslassen wird nicht mehr in den teuren High-Resolution-Modus gewechselt.
- Das Steuerkreuz unterstützt Gedrückthalten: Nach dem Hold-Event werden Bewegungen automatisch wiederholt und beim Loslassen beendet.
- D-Pad und Sprungtaste werden nach dem Dirty-Flush zuletzt mit den tatsächlich gezeichneten Widget-Ursprüngen neu gezeichnet.
- Die Touch-Hitboxen verwenden dieselben tatsächlichen Ursprünge wie die sichtbaren Controls. Dadurch lösen Taps nicht mehr versehentlich oberhalb der sichtbaren Taste oder in der Welt eine Blockaktion aus.
