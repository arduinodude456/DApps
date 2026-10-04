# DChat 1.2.4

DChat verwendet jetzt zwei getrennte Serviceadressen:

- **Public address:** der bisherige öffentliche DChat-Service, damit der öffentliche Raum erhalten bleibt.
- **DM address:** `https://dchatdm-qkwwnvdq.manus.space`, ausschließlich für Empfängersuche, private Konversationen und Direktnachrichten.

Beide Adressen werden in den DChat-Einstellungen angezeigt und können getrennt geändert werden. Alte lokale Public-Einstellungen bleiben erhalten; der DM-Endpunkt wird automatisch auf den Manus-DM-Server gesetzt.
