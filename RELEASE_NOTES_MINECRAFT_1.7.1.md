# Minecraft 3D 1.7.1

Dies ist ein Stabilitätsupdate für die neue Touch-Steuerung aus 1.7.0. Der Joystick hatte eine falsche Tap-Callback-Signatur und aktualisierte seine absolute GestureRange nicht, wodurch Eingaben ins Leere liefen. Außerdem wurde die nicht notwendige `pan_release`-Geste entfernt, die nicht zur Handler-Konvention der vorhandenen KOReader-DApps passte.

Der virtuelle Joystick verwendet jetzt robuste Tap-/Swipe-Ereignisse, prüft fehlende Gestenpositionen und schützt fehlende Canvas-/Sitzungszustände. Horizontales Wischen zum Umsehen und Springen bleiben erhalten. Die bisherigen Hardware- und AppDock-Tasten bleiben unverändert.
