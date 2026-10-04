# DChat 1.2.1

Dieses Patchupdate behebt die Erstverbindung der DM-Oberfläche mit dem neuen veröffentlichten DChat-Server. Wenn eine lokale DChat-Identität auf diesem Server noch nicht bekannt ist, registriert DChat dieselbe bereits vorhandene Geräte-ID/Secret-Kombination einmalig und lädt danach die Empfängerliste erneut.

Die lokale Identität wird dabei nicht ersetzt und der Server überschreibt keine bereits registrierte Geräte-ID. Die öffentliche Raumfunktion bleibt unverändert. Direktnachrichten bleiben serverseitig gespeichert und ausdrücklich nicht Ende-zu-Ende-verschlüsselt.
