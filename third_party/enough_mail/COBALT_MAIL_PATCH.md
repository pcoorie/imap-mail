# Local patch: UID STORE in the COPY+flag-deleted fallback

This is a vendored copy of `enough_mail` 2.1.7, overridden via
`dependency_overrides` in the app's `pubspec.yaml`, with one upstream bug
fixed in two places (`MailClient._moveMessages` and
`_IncomingImapClient.deleteMessages`).

**The bug:** when a server doesn't advertise the IMAP `MOVE` capability
(RFC 6851 — several real-world providers don't, including the one this was
found against), both methods fall back to `COPY` + mark-`\Deleted`. The
`COPY` call correctly branches between `uidCopy`/`copy` based on
`sequence.isUidSequence`, but the following STORE call was hardcoded to
the non-UID `_imapClient.store(...)` regardless — so a UID-based sequence
got sent as a plain `STORE <uid> +FLAGS (\Deleted)`, which the server
(correctly) rejects once the UID value exceeds the mailbox's message
count, e.g. `NO STORE failed`. `MailClient.store()` (the public method
used elsewhere, e.g. for marking messages read/flagged) already branches
correctly — this fallback path just didn't match that established
pattern.

**The fix:** branch the STORE call the same way the COPY call above it
already does. Search this directory for `Cobalt Mail patch` to find both
occurrences.

**Removing this override:** check whether a newer `enough_mail` release
has fixed this upstream (search their GitHub issues/changelog for
`_moveMessages` UID STORE, or just diff against the current release), and
if so, drop `dependency_overrides` from `pubspec.yaml`, delete this
directory, and revert to the normal pub dependency.
