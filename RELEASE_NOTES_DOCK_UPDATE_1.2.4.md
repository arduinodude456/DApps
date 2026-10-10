# DockUpdate 1.2.4

DockUpdate akzeptiert jetzt AppDock **7.9.7**: Die maximale Größe einzelner Lua-Quellen wurde kontrolliert von 192 KiB auf **256 KiB** angehoben. Damit passt das `appdock_dapps.lua`-Modul des Releases (199.796 Byte) innerhalb der festen, begrenzten Größenprüfung.

Allowlist, Pflichtdateien, Gesamtgrößenlimit, Lua-Syntaxprüfung und explizite Installationsbestätigung bleiben unverändert. Der Regressionstest installiert ein AppDock-Paket mit einem exakt 199.796 Byte großen `appdock_dapps.lua`-Fixture.
