# Minecraft 3D 3.0.3

Behebt einen Absturz beim Zeichnen der RGB-Palette auf KOReader-Geräten. RGB-Farbspans wurden bisher an die generische `BlitBuffer:paintRect`-Methode übergeben. Diese ist für Luminanzfarben gedacht. Der Renderer verwendet nun KOReaders dedizierte `paintRectRGB32`-Methode; falls sie in einer älteren KOReader-Version fehlt, wird sicher monochrom gezeichnet.

- RGB-Farbflächen gehen über `paintRectRGB32`; Schwarz-Weiß-Flächen bleiben bei `paintRect`.
- Der Farbmodus wird pro Frame nur aktiviert, wenn der Puffer RGB-fähig ist und die RGB-Zeichenmethode verfügbar ist.
- Der Regressionstest bildet beide Zeichenmethoden nach und prüft, dass RGB-Farben ausschließlich den RGB32-Pfad nehmen.
