# DChat 1.5.1

Die Schnellreaktions-Emojis werden jetzt als echte PNG-Bitmap-Anhänge gesendet statt als Unicode-Text. Dadurch funktionieren die Emoji-Schaltflächen auch auf Geräten, auf denen die Unicode-Emoji-Schrift fehlt.

Die vorhandenen PNG-Bitmaps werden lokal gelesen, größenbegrenzt und als `image/png` über den bestehenden DChat-Anhangsweg übertragen.
