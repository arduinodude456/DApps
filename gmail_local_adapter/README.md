# AppDock Gmail Local Adapter

This small local program supplies **Gmail Notifications 1.0.0** with the newest Gmail Inbox metadata when the user presses **Check Gmail** in AppDock. It has no scheduled job and no background polling.

The adapter runs on a computer in the same home network as the Kobo. Google refresh tokens remain in the adapter state file on that computer. The Kobo receives only the Gmail message ID, `From` header and `Subject` header over a TLS-protected connection. No mail text, attachments, recipients or HTML content are returned.

## Security model

| Asset | Stored location | Design rule |
|---|---|---|
| Google refresh token | Adapter computer only, `stateFile` with Unix mode `0600` | Never copied to the Kobo or written into the DApp. |
| Adapter pairing token | Adapter configuration and Kobo DApp settings | A random local-network bearer secret; never use a Google password here. |
| Gmail data returned to Kobo | HTTPS response | At most 12 recent Inbox message IDs plus `From` and `Subject`. |
| Seen message IDs | Kobo DApp settings | Up to 200 IDs for deduplication; removable through **Forget local data**. |
| TLS trust | Kobo trust store or a local CA PEM file | Certificate verification stays enabled. |

## Requirements

You need Node.js 18 or later, a computer that is reachable from the Kobo over the local network, a Google Cloud project and an OAuth **Desktop** client. The Gmail API must be enabled for that project.

The adapter requests only `https://www.googleapis.com/auth/gmail.metadata`. This scope allows labels and mail headers but not the message body. Google classifies it as a restricted Gmail scope, so keep this adapter private to your own account and network. [Google scope documentation](https://developers.google.com/workspace/gmail/api/auth/scopes)

## 1. Prepare Google OAuth

Create a Google Cloud project, enable the Gmail API, configure the OAuth consent screen, and create an OAuth client of type **Desktop app**. If the consent screen is in testing mode, add the Gmail account that will be checked as a test user. Copy the Desktop client ID into a new `config.json` based on `config.example.json`.

The adapter uses the documented installed-app OAuth authorization-code flow with PKCE and a loopback listener on `127.0.0.1`. Google login therefore occurs in the browser on the adapter computer, never on the Kobo. [Google OAuth documentation](https://developers.google.com/identity/protocols/oauth2/native-app)

## 2. Create a local TLS certificate

The Kobo must call the adapter through `https://`, and the server certificate must match the address entered in the DApp. A certificate from an existing trusted local HTTPS setup is suitable. If you create a private local CA, copy its **public CA certificate** to the Kobo and set that file path in the DApp; never copy the CA private key or the adapter server private key to the Kobo.

For a self-managed local CA, create a server certificate whose Subject Alternative Name contains the adapter computer’s stable local IP address or DNS name. Configure the server private key and certificate paths in `config.json`, then configure the corresponding Kobo IP address in `allowedClientIPs`. Do not use a wildcard, `0.0.0.0`, or a public-network address in `allowedClientIPs`.

> The adapter deliberately refuses to start without an explicit Kobo IP allow-list and an adapter token of at least 32 characters.

## 3. Configure and authorize

Copy the example configuration, insert the Desktop OAuth client ID, TLS paths and the Kobo IP address, then create a pairing token:

```bash
cd gmail_local_adapter
cp config.example.json config.json
npm run token
```

Place the generated token in `adapterToken`. Keep it private. Do **not** paste a Google password, an OAuth refresh token or a client secret into the DApp.

Run the one-time authorization flow on the computer:

```bash
npm run authorize
```

Open the displayed Google address in a browser on that same computer and approve the limited Gmail metadata permission. The resulting state file remains local.

## 4. Start the adapter

Start the HTTPS service while the computer is available:

```bash
npm run start
```

The adapter exposes only `GET /health` and authenticated `GET /v1/messages`. It rate-limits each approved Kobo IP to 12 requests per minute. It does not log individual senders or subjects.

## 5. Configure the DApp on the Kobo

Install **Gmail Notifications** from AppDock AppStore, then enter:

1. **Adapter address** — for example `https://192.168.1.10:8443`; it must exactly match the certificate’s IP/DNS subject alternative name.
2. **Pairing token** — the random token generated above.
3. **Trusted CA certificate** — leave empty only when the Kobo already trusts the adapter certificate. Otherwise copy the public CA PEM file to a local Kobo path, for example `/mnt/onboard/.adds/appdock/gmail-local-ca.pem`, and enter that absolute path.

Tap **Check Gmail**. The first successful check records current message IDs without producing notifications. Every later manual check sends an AppDock notification for each newly observed message, using only the sender and subject. A failed check does not change the saved baseline.

Use **Forget local data** in the DApp to remove the local endpoint, pairing token and deduplication IDs from the Kobo. To revoke the Google grant, remove the app from the Google account’s third-party access settings and delete the adapter state file on the computer.

## Operational limits

The adapter is intended for a private home network and a single owner. It is not an internet-facing mail service, does not send mail, and should not be port-forwarded. The adapter must be running when the user taps **Check Gmail**. Gmail Notifications does not wake KOReader, run automatically, or show notifications while KOReader is closed.
