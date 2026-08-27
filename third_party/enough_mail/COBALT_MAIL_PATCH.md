# Local patches to enough_mail 2.1.7

This is a vendored copy of `enough_mail` 2.1.7, overridden via
`dependency_overrides` in the app's `pubspec.yaml`. It carries two local
patches, both in the `COPY`+flag-`\Deleted` fallback that
`MailClient._moveMessages` takes when the server doesn't advertise the IMAP
`MOVE` capability (RFC 6851 — several real-world providers don't, including
the one both bugs were found against). Search this directory for
`Cobalt Mail patch` to find every occurrence of both fixes.

## Patch 1: UID STORE in the COPY+flag-deleted fallback

Fixed in two places: `MailClient._moveMessages` and
`_IncomingImapClient.deleteMessages`.

**The bug:** the `COPY` call correctly branches between `uidCopy`/`copy`
based on `sequence.isUidSequence`, but the following STORE call was
hardcoded to the non-UID `_imapClient.store(...)` regardless — so a
UID-based sequence got sent as a plain `STORE <uid> +FLAGS (\Deleted)`,
which the server (correctly) rejects once the UID value exceeds the
mailbox's message count, e.g. `NO STORE failed`. `MailClient.store()` (the
public method used elsewhere, e.g. for marking messages read/flagged)
already branches correctly — this fallback path just didn't match that
established pattern.

**The fix:** branch the STORE call the same way the COPY call above it
already does.

## Patch 2: missing EXPUNGE after the STORE, in `_moveMessages` only

**The bug:** once the STORE above actually succeeds (which patch 1 made
reliable), the original message is flagged `\Deleted` in the source
mailbox but the code never expunges it — so it stays fully present on the
server, visible to every other IMAP client, forever. Cobalt's own local
database already relocated the message (optimistic move + `COPYUID`
confirmation), so Cobalt itself looks correct while the server-side move
never actually completed. This is the root cause behind: "I delete/move/
archive a message in Cobalt Mail, and it disappears from Cobalt, but every
other mail client still sees it sitting in the original folder." See
`docs/superpowers/specs/2026-08-27-imap-move-expunge-fix-design.md` for the
full writeup, including why this doesn't affect Cobalt's own Undo (Cobalt
never relies on the upstream `deleteMessages`/`undoMove` API this fallback
was originally designed to support undoing).

**The fix:** after the STORE, issue `UID EXPUNGE <sequence>` when the
server supports `UIDPLUS` (RFC 4315), otherwise a plain `EXPUNGE`. Applied
only in `_moveMessages` — `_IncomingImapClient.deleteMessages` is
untouched, since Cobalt never calls that method.

**Regression test:** `test/vendor/enough_mail_move_expunge_test.dart` runs
a real loopback IMAP conversation against a scripted fake server that
omits `MOVE`, and asserts an EXPUNGE-family command follows the STORE.

## Removing this override

Check whether a newer `enough_mail` release has fixed either bug upstream
(search their GitHub issues/changelog for `_moveMessages` UID STORE and for
missing EXPUNGE after a COPY-fallback move, or just diff against the
current release), and if so, drop `dependency_overrides` from
`pubspec.yaml`, delete this directory, and revert to the normal pub
dependency — but keep `test/vendor/enough_mail_move_expunge_test.dart`
pointed at whatever `enough_mail` version ships next, since it's testing
observable behavior, not this vendored copy specifically.
