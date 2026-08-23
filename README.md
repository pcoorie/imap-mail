# Cobalt Mail

A personal, multi-account email client built for people who just want IMAP and SMTP to work — no OAuth consent screens, no provider lock-in, no third-party mail APIs sitting between you and your inbox. Add any standard IMAP/SMTP account (Gmail, Outlook, Fastmail, a work server, your own domain) with its host and port, and you're reading mail.

## Why

Most consumer mail apps either force you through a provider's OAuth flow or funnel your mail through their own servers. Cobalt Mail talks directly to your mail server over standard IMAP and SMTP — your credentials are stored in the device's secure keychain, never in plaintext, and your mail is cached locally for fast, offline-friendly reading.

## Features

### Mail, done properly
- **Multi-account** — add as many IMAP/SMTP accounts as you like, each configured manually (host, port, security, credentials).
- **Unified Inbox** — every account's Inbox merged into one chronological view, with a per-account color indicator on each row so you always know where a message came from. Drill into a single account's full folder tree whenever you want.
- **Full folder access** — Inbox, Sent, and Trash front and center, with every other folder your server reports (Archive, custom labels, etc.) one tap away.
- **Compose, reply, and forward**, with file attachments, sent straight over SMTP.
- **Swipeable triage actions** — swipe a message to archive, delete, flag, or mark read/unread. Every slot is customizable in Settings, and every action writes back to the server, not just the local cache.
- **Global search** — one search box finds a message by subject, sender, or snippet across every folder of every account at once.

### Attachments that behave
- Tap an attachment to download it and open it straight in your device's native preview — the same viewer Apple Mail itself uses for PDFs, Word docs, images, and more.
- No confusing "where did that save?" moment: the native preview's own Share button is where you send a file to Files, Photos, or AirDrop.

### Built to feel finished
- **Sender avatars** — a colored, initials-based avatar for every sender (Outlook-style), generated locally from their name or address. No external logo lookups, no tracking.
- **Smart relative dates** — a time for today's messages, "Yesterday", the weekday for the rest of the week, and a full date once mail gets older.
- **Unread badges everywhere that matter** — on the folder tabs, and on the app icon itself.
- **Friendly empty states** instead of a blank screen when a folder has nothing in it.
- **Light and dark mode**, both themed around the app's own accent color rather than a generic system default.
- **Real pull-to-refresh** — the spinner tracks the actual sync, not an instant no-op.

### Reliable by default
- **Offline-first caching** — accounts, folders, and messages are cached locally, so the app opens fast and stays readable without a connection. Sync happens in the foreground: on open, on pull-to-refresh, and after any action.
- **Graceful handling of mail deleted elsewhere** — opening a message that's since been removed from another device shows a clear explanation instead of a crash, and cleans up the stale local copy automatically.
- **Credentials stay on-device**, stored in the platform's secure keychain — never written to the local cache, never sent anywhere but your mail server.

## What it deliberately doesn't do (yet)

This is a v1 built around a clear set of tradeoffs, not a feature-complete client:

- No push notifications or background sync — mail updates when the app is open, by design (no server-side infrastructure, no battery drain from a background service).
- No OAuth providers (Gmail API, Microsoft Graph) — IMAP/SMTP only, by choice.
- No message threading — a flat, chronological list.

## Tech

Built with Flutter, talking to mail servers over standards-based IMAP/SMTP (via `enough_mail`), with a local SQLite cache and platform-native secure credential storage. Currently built and verified for iOS; the codebase targets Flutter's other platforms but they haven't been the focus of testing.

## Getting started

```bash
flutter pub get
flutter run
```

You'll need a device or simulator, and the IMAP/SMTP details for the account you want to add — there's no OAuth flow to walk through, just a form asking for your server settings.

## License

No license has been set for this project yet — all rights reserved by default until one is added.
