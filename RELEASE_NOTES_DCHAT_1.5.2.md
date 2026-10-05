# DChat 1.5.2

Die Emoji-PNGs sind jetzt direkt in `dchat.lua` eingebettet. Dadurch können Store-Installationen die Bitmaps senden, auch wenn der AppStore nur die einzelne DApp-Datei herunterlädt und keinen zusätzlichen `assets/`-Ordner installiert.

Die Emojis werden weiterhin als `image/png`-Anhänge versendet und bleiben durch das bestehende Größenlimit geschützt.
