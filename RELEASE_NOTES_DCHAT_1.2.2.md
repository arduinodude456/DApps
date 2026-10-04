# DChat 1.2.2

Dieses Patchupdate migriert den zuvor gespeicherten DChat-Server `https://appdock-bd7bcrzm.manus.space` automatisch auf den neuen Manus-Server `https://dchatdm-qkwwnvdq.manus.space`.

Der neue Default-Endpoint stand bereits in `dchat.lua`, wurde aber von der lokal gespeicherten Endpoint-Einstellung überschrieben. DChat verwendet nach dem Update den neuen Server, ohne die lokale Geräteidentität zu löschen oder neu zu erzeugen.
