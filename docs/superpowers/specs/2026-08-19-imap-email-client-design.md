# IMAP Email Client — Design Spec

Date: 2026-08-19
Status: Approved

## 1. Purpose

A simple, personal, multi-account IMAP/SMTP email client built in Flutter. No OAuth, no third-party provider APIs — pure standards-based IMAP for reading and SMTP for sending, configured manually per account. Targets iOS and Android.

## 2. Goals / Non-goals

**Goals**
- Add multiple IMAP/SMTP accounts via manual server configuration (host, port, security, credentials).
- View Inbox, Sent, and Trash by default per account, with the full discovered IMAP folder tree available via an expandable control.
- Read messages (text and HTML bodies), view and download attachments.
- Compose, reply, and forward messages, with the ability to attach files, sent via SMTP.
- Cache accounts, folders, and messages locally (sqflite) for offline viewing and fast reopen.
- Store credentials securely (platform Keychain/Keystore via `flutter_secure_storage`), never in plaintext or in the sqlite database.
- Sync in the foreground only — on app open and manual refresh. No background service, no push notifications.

**Non-goals (explicitly deferred, not in v1)**
- Push notifications / periodic background sync.
- OAuth-based providers (Gmail API, Microsoft Graph, etc.) — IMAP/SMTP only.
- Full-text search across message bodies (server-side IMAP SEARCH is a plausible fast-follow, not v1).
- Conversation/threading view — flat chronological message list only.
- Multiple identities/signatures per account, mail filters/rules.

## 3. Architecture

Four layers, each independently testable:

```
UI (screens/widgets)
   |
Riverpod providers (per-account, per-folder state; FutureProvider/AsyncNotifier)
   |
Repository (cache-first: read local store; refresh from IMAP on open/pull-to-refresh/forced;
            write results back to local store)
   |
   +-- ImapService (wraps `enough_mail`: connect, list/discover folders, fetch headers/bodies,
   |                fetch attachments)
   +-- SmtpService (wraps `enough_mail`: send composed messages)
   +-- LocalStore (sqflite: accounts, folders, messages, attachments)
   +-- SecureCredentialStore (flutter_secure_storage: password per account, keyed by account id)
```

Each account's `ImapService`/`SmtpService` connection is opened on demand for a sync/send operation and closed afterward — no persistent background connections, consistent with foreground-only sync.

Errors and connection state for one account never block or corrupt state for another account — each account's repository operations are isolated.

## 4. Data model (sqflite)

- **accounts**: `id`, `display_name`, `email`, `imap_host`, `imap_port`, `imap_security` (none/ssl/starttls), `smtp_host`, `smtp_port`, `smtp_security`, `username`. (Password is *not* stored here — it lives in `SecureCredentialStore`, keyed by `account.id`.)
- **folders**: `id`, `account_id`, `name`, `path`, `type` (inbox/sent/trash/other), `unread_count`.
- **messages**: `id`, `folder_id`, `uid` (IMAP UID, used for delta sync), `subject`, `from`, `to`, `date`, `snippet`, `body_text`, `body_html`, `is_read`, `is_downloaded` (whether full body has been fetched, vs. headers-only).
- **attachments**: `id`, `message_id`, `filename`, `mime_type`, `size`, `local_path` (null until downloaded).

Headers are fetched first for fast list scrolling; full body and attachment metadata are fetched lazily when a message is opened; attachment bytes are fetched lazily when a user chooses to download.

## 5. Screens & navigation

- **Account list / switcher**: shown as a drawer or top switcher when more than one account exists; with exactly one account, the app opens straight to that account's Inbox.
- **Folder view**: message list for the current account + folder. Inbox, Sent, and Trash appear as default quick-access tabs/entries; a collapsible "▾ More folders" control reveals the full folder tree discovered from the server.
- **Message detail**: rendered body (HTML sanitized and rendered, e.g. via `flutter_widget_from_html`), attachment list with download/open actions, reply/forward/delete actions.
- **Compose**: used for new messages and for reply/forward (pre-filled). To/Cc/Bcc fields, file attachment picker, send via SMTP.
- **Add/edit account**: manual form for IMAP host/port/security and SMTP host/port/security, username, password. Includes a "Test connection" action that performs a real IMAP login and SMTP handshake before the account can be saved.
- **Settings**: manage accounts (add/edit/remove).

## 6. Data flow / sync behavior

1. On app open or manual pull-to-refresh, the repository asks IMAP for new/changed headers since the last known UID per folder (delta fetch, not a full re-download every time).
2. New/changed headers are written to sqlite; the message list UI updates reactively via Riverpod, which watches the local store.
3. Opening a message: if `body_text`/`body_html` isn't cached yet, fetch the full body (and attachment metadata) on demand and cache it.
4. Downloading an attachment: fetch bytes, save to the app's documents directory, record `local_path`.
5. Sending: SMTP send via `enough_mail`. On success, the message is also appended to the account's IMAP Sent folder (many providers require the client to do this explicitly) and cached locally as sent, even if the IMAP append step fails (best-effort — the send itself succeeding is what matters to the user).

## 7. Error handling

- Connection/auth failures surface inline on the folder view (e.g. "Can't connect to account X — [Retry] [Edit account]"), never fail silently.
- One account's sync failure does not block or affect other accounts.
- If sending fails, the composed message is kept as a local "Failed to send" draft (not discarded) with a retry action.
- The "Test connection" step during account setup performs an actual IMAP login and SMTP handshake, catching bad credentials/host config immediately rather than surfacing as a confusing sync failure later.

## 8. Security

- Passwords are stored only in `flutter_secure_storage` (iOS Keychain / Android Keystore) — never in sqlite, never in plaintext, never logged.
- IMAP/SMTP connections default to implicit TLS (SSL) or STARTTLS. Plaintext auth over an unencrypted connection is disallowed by default; allowing it would require an explicit advanced override, discouraged in the UI copy.

## 9. Testing strategy

- Unit tests: repository logic (cache-first read, delta sync merge logic), `LocalStore` CRUD operations.
- Widget tests: folder list rendering (default tabs + expandable full tree), compose form validation, account setup form validation.
- `ImapService`/`SmtpService` are mocked at their interface boundary in tests — no test suite makes real connections to live mail servers.

## 10. Key dependencies

- `enough_mail` — IMAP/SMTP protocol implementation, MIME parsing.
- `flutter_riverpod` — state management.
- `sqflite` — local relational cache.
- `flutter_secure_storage` — credential storage.
- `flutter_widget_from_html` (or equivalent) — HTML message body rendering.
- `file_picker` — attaching files when composing.

## 11. Open items deferred to implementation planning

None — this spec is scoped for a single implementation plan covering account management, sync, read, compose/send, and local caching as one coherent v1.
