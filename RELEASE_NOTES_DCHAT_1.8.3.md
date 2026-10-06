# DChat 1.8.3 — Kontaktlisten-API-Fix

DChat 1.8.3 korrigiert den Fehler `The request is invalid` beim Aktualisieren oder Suchen der Kontaktliste. Die DApp verwendet wieder das vom veröffentlichten DM-Backend unterstützte Kontaktlimit von 30 Einträgen statt 120.

Der Fehler entstand durch einen zu großen `limit`-Queryparameter und war unabhängig von den gespeicherten Kontakten oder der lokalen Geräteidentität. DM- und Public-Daten bleiben unverändert.
