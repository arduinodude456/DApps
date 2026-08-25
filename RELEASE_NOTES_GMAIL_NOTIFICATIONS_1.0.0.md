# Gmail Notifications 1.0.0

Gmail Notifications is a manual, E-Ink-friendly AppDock DApp for checking a Gmail Inbox through the accompanying local Gmail adapter. The user taps **Check Gmail**; there is no background polling, remote push service or automatic refresh loop.

The adapter uses Google OAuth with the Gmail metadata scope and keeps the Google refresh token on the user’s own computer. The Kobo receives only a message ID, sender and subject over HTTPS. The first check creates a quiet deduplication baseline; later checks create normal-priority local AppDock notifications only for newly observed IDs.

The DApp rejects non-HTTPS endpoints, verifies TLS certificates, can use a user-supplied local CA certificate for a self-managed home-network certificate, limits responses to 12 messages and provides **Forget local data** to remove local pairing and deduplication information.

Setup is documented in `gmail_local_adapter/README.md`. AppDock 2.1.0 or later is required.
