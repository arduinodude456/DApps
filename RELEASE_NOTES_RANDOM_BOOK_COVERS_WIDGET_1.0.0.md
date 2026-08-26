# Random Book Covers Widget 1.0.0

This AppDock Store widget displays up to **three randomly chosen real local books** from KOReader’s reading history.

## Local covers only

The widget obtains candidate files solely from local `readhistory.hist` entries. It excludes deleted and duplicate entries, uses only their existing local titles or filenames, and asks KOReader’s existing BookInfo interface for a cover blitbuffer. It does not download covers, query book services, create cover art, or invent book data.

When a selected local book has no available cover, the card displays its real title with **No local cover**. If there is no local history, the widget asks the reader to open local books first.

## Limits

Selection is capped at three distinct slots and the first 24 shuffled history candidates. There is no network access, background task, saved personal copy of the history, or active content. Cover buffers remain owned by KOReader’s normal ImageWidget lifecycle and are released when the widget closes.
