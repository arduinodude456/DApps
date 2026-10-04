# Minecraft 3D 1.3.0

Die Blockdarstellung wurde erneut grundlegend korrigiert. Die vorherigen Rechteckflächen wirkten wie freistehende Karten, weil `paintRect` keine schrägen Würfelflächen erzeugt.

Minecraft 3D verwendet jetzt pro Weltzelle einen echten perspektivischen Würfelaufbau: eine rhombische Oberseite sowie zwei trapezförmige Seitenflächen mit schwarzen Kanten. Die Flächen werden über einen kleinen Scanline-Polygonfüller in horizontale `paintRect`-Spans zerlegt. Dadurch entstehen schräge Kanten und eine echte 3D-Blocksilhouette, ohne eine nicht vorhandene Blitbuffer-Polygon-API vorauszusetzen.

Die Navigation und der regionale `fast`-Refresh bleiben unverändert. Die Welt wird weiterhin ausschließlich lokal gerendert und besitzt keine Hintergrunddienste.
