# IMAP Move/Delete Doesn't Reach the Server — Root Cause & Fix Design

Date: 2026-08-27
Status: Investigated — root cause confirmed, fix designed, not yet implemented

## 1. Bug report

Deleting a message moves it to Trash in Cobalt Mail, and moving/archiving a
message moves it to Archive/a subfolder in Cobalt Mail — but other IMAP
clients (another device, another mail app) syncing the *same account* never
see the change: the message is still sitting in its original folder,
unmoved, as far as the server and everyone else is concerned.

## 2. Root cause

Every user-facing delete/archive/move in Cobalt Mail bottoms out in the same
place: `MailRepository.moveMessage` / `.moveMessages`
(`lib/data/repository/mail_repository.dart:176-435`) — `deleteMessage` is
implemented as "move to Trash" (`mail_repository.dart:368-378`), `archiveMessage`
is "move to Archive" (`mail_repository.dart:212-222`), and folder moves are the
same call directly. All of them call down to
`EnoughMailTransport.moveMessage` / `.moveMessages`
(`lib/data/transport/enough_mail_transport.dart:258-318`), which call
`enough_mail`'s `MailClient.moveMessages()`.

Inside the vendored `enough_mail` copy
(`third_party/enough_mail/lib/src/mail/mail_client.dart`, `_moveMessages` at
line 2949), there are two branches depending on whether the server advertises
the IMAP `MOVE` capability (RFC 6851):

- **Server supports `MOVE`:** the code issues `UID MOVE` / `MOVE` directly.
  This is atomic per RFC 6851 — the message is transferred to the
  destination and removed from the source in one step. **Not buggy.**
- **Server does not support `MOVE`** (common — several real-world providers
  don't; this vendored copy already carries one prior patch,
  `COBALT_MAIL_PATCH.md`, found against such a provider): the code falls
  back to `UID COPY` (create the message in the destination) followed by
  `UID STORE +FLAGS (\Deleted)` on the original (flag it for removal in the
  source). **It never issues `EXPUNGE` (or `UID EXPUNGE`) afterward.**

Per IMAP semantics, flagging a message `\Deleted` does not remove it — the
message stays fully present in the mailbox, visible to any other client,
until something expunges it. Cobalt's connection is then torn down via a raw
socket close (`third_party/enough_mail/lib/src/private/util/client_base.dart:213`,
`disconnect()`) with no `LOGOUT`/`CLOSE`, so no implicit expunge happens
either.

Meanwhile, Cobalt's own local database row for the message *is* moved
immediately (`MessageDao.moveToFolder`, called optimistically before the
network call, then corrected with the real server UID once the `COPY`
response's `COPYUID` arrives). So Cobalt itself shows the message as moved —
it only exists as a local illusion. Any other client reading the same
mailbox on the server sees the original message untouched (and, depending on
that client's handling of the `\Deleted` flag, possibly showing it as
struck-through but still very much present) sitting in the original folder,
plus a duplicate copy in the destination folder. Nothing was actually moved.

This reproduces for **every** delete/archive/move Cobalt performs against
any account whose IMAP server doesn't advertise `MOVE` — which matches the
report exactly ("same behaviour... moving to Archive or any subfolder").

### Why the fix is safe (undo isn't affected)

`enough_mail`'s own `MailClient.deleteMessages()` has a similar
COPY+flag-deleted fallback and *deliberately* skips the expunge, with an
explicit comment: skipping it lets `MailClient.undoMove()` restore the
original by just clearing the `\Deleted` flag and removing the copy.

That rationale doesn't apply here: Cobalt never calls `deleteMessages`,
`undoMove`, or `undoMoveMessages` (confirmed — zero references in `lib/`).
Cobalt's own Undo (`message_swipe_controller.dart:242-284`) is implemented
independently, as a fresh reverse `moveMessage` call using the new UID
returned by the original move. It has no dependency on the source-folder
original still existing. So there is no undo behavior to preserve, and the
un-expunged original is pure leftover debris — the actual bug.

## 3. Desired behavior

When `_moveMessages` falls back to `COPY` + flag-`\Deleted` (no `MOVE`
capability), it must finish the job by expunging the flagged message(s) from
the source mailbox before returning, so the source folder on the server
converges to match what Cobalt already shows locally:

- If the sequence is UID-based and the server supports `UIDPLUS`
  (RFC 4315): issue `UID EXPUNGE <sequence>` — removes exactly the messages
  just flagged, nothing else.
- Otherwise: issue plain `EXPUNGE` — removes every `\Deleted`-flagged
  message in the mailbox. Slightly broader, but still correct per IMAP
  semantics (anything else flagged `\Deleted` was already asked to be
  removed by someone), and this is exactly the granularity the "server
  supports `MOVE`" branch already provides.

The `MOVE`-capable branch is untouched — it's already correct.

## 4. Non-goals

- Not touching `_IncomingImapClient.deleteMessages` (`enough_mail`'s own
  delete API) — Cobalt never calls it, so its behavior is out of scope.
- Not adding a permanent-delete (`STORE \Deleted` + `EXPUNGE` from the UI)
  feature — Cobalt's local-only permanent-delete branches
  (`mail_repository.dart:360-367`) are explicitly documented as deliberate
  and stay as-is.
- Not changing anything about how Undo works.

## 5. Testing strategy

The bug lives inside the vendored `third_party/enough_mail` copy, several
layers below any interface Cobalt's own repository tests mock out — a test
against `MailTransport`/`MailRepository` would not exercise the real
`_moveMessages` code path at all and wouldn't have caught this. The
regression test needs to run an actual (loopback, in-process) IMAP
conversation:

1. Bind a local `ServerSocket` on `127.0.0.1:0`.
2. Point a real `enough_mail` `MailClient`/`ImapClient` at it (plain, no
   TLS).
3. Script the fake server side to send a greeting/`CAPABILITY` response that
   omits `MOVE` (so the client is forced into the COPY-fallback branch),
   accept `LOGIN`/`SELECT`, then respond to whatever `COPY`/`STORE` command
   the client sends.
4. Assert that a `UID EXPUNGE` (or `EXPUNGE`) command is sent by the client
   after the `STORE`, which today it is not.

See the accompanying plan for the concrete task breakdown.
