# DChat 1.2.3

Dieses Patchupdate normalisiert gespeicherte DChat-Serveradressen vor der Migration. Dadurch wird auch der alte Serverwert mit abschließendem `/` zuverlässig auf `https://dchatdm-qkwwnvdq.manus.space` umgestellt.

Der neue Server ist per LuaSec/TLS erreichbar; die Änderung behebt ausschließlich den lokal gespeicherten Endpoint-Zustand. Die lokale Geräteidentität bleibt erhalten.
