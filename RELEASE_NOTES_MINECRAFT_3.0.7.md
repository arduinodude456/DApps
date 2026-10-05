# Minecraft 3D 3.0.7

Behebung des wiederkehrenden Absturzes beim Farb-Rendering. Die Ursache war der Nil-Test im RGB-Farbcache: `color == nil` ruft bei einem gecachten KOReader-`ColorRGB32`-cdata-Wert dessen `__eq`-Metamethode auf. Diese Methode versucht anschließend, den `nil`-Vergleichswert als Farbe zu lesen und stürzt ab.

Der Cache prüft jetzt per Lua-Wahrheitswert (`if not color`), ohne `__eq` auszulösen. Der bereits in 3.0.6 angeglichene Square-Zeichenpfad (`Blitbuffer.colorFromString()` und `paintRectRGB32()`) bleibt unverändert. Der LuaJIT-Regressionstest verwendet cdata mit KOReaders Gleichheitsverhalten und deckt genau diesen Crash ab.
