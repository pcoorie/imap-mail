import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../models/swipe_action.dart';
import '../providers/message_providers.dart';
import '../providers/repository_providers.dart';

IconData swipeActionIcon(SwipeAction action) => switch (action) {
      SwipeAction.archive => Icons.archive_outlined,
      SwipeAction.delete => Icons.delete_outline,
      SwipeAction.flag => Icons.flag_outlined,
      SwipeAction.toggleRead => Icons.mark_email_unread_outlined,
      SwipeAction.none => Icons.block,
    };

Color swipeActionColor(SwipeAction action) => switch (action) {
      SwipeAction.archive => Colors.blueGrey,
      SwipeAction.delete => Colors.red,
      SwipeAction.flag => Colors.orange,
      SwipeAction.toggleRead => Colors.teal,
      SwipeAction.none => Colors.grey,
    };

/// Owns the archive/delete/flag/mark-read swipe-action behavior for one
/// message list (Slidable pane construction, the actual repository calls,
/// undo, and error snackbars). Extracted out of `FolderViewScreen` so
/// `UnifiedInboxScreen` (which shows rows from many accounts at once, not
/// one ambient account/folder) can reuse it unchanged — every method takes
/// the row's own `MailAccount`/`MailFolder`/`MailMessage` explicitly rather
/// than assuming a single shared one.
///
/// [isMounted] and [messengerOf] are supplied by the owning State so this
/// controller can safely no-op after that State is disposed, exactly as
/// the original inline implementation did via its own `mounted` checks.
class MessageSwipeController {
  MessageSwipeController(this.ref, {required this.isMounted, required this.messengerOf});

  final WidgetRef ref;
  final bool Function() isMounted;
  final ScaffoldMessengerState? Function() messengerOf;

  // See _showAutoDismissingSnackBar's doc comment for why this exists.
  // Owned by this controller (not fire-and-forget) so it never fires after
  // — or leaks past — its owning State's lifetime: cancelled and replaced
  // whenever a new snackbar supersedes an old one, and cancelled in
  // dispose() so the widget test framework's "no pending timers" check
  // doesn't trip on a snackbar shown just before a test ends.
  Timer? _snackBarDismissTimer;

  void dispose() {
    _snackBarDismissTimer?.cancel();
  }

  /// Shows [snackBar] via [messenger] and guarantees it disappears after
  /// [snackBar]'s own `duration` (Material's default is 4 seconds), even if
  /// its built-in auto-dismiss timer doesn't fire — observed happening in
  /// this screen (confirmed via `ScaffoldFeatureController.closed` never
  /// completing, well past the expected duration, with no custom
  /// SnackBarTheme or timeDilation override anywhere in the app) but not
  /// root-caused. Also clears any snackbar already showing/queued first, so
  /// a new action's feedback is never stuck waiting behind a stale one.
  void _showAutoDismissingSnackBar(ScaffoldMessengerState messenger, SnackBar snackBar) {
    _snackBarDismissTimer?.cancel();
    messenger.clearSnackBars();
    messenger.showSnackBar(snackBar);
    _snackBarDismissTimer = Timer(snackBar.duration, () {
      if (messenger.mounted) {
        messenger.hideCurrentSnackBar();
      }
    });
  }

  /// Builds one side's ActionPane from its configured primary/secondary
  /// actions. Returns null (no pane — no reveal on that side) if both slots
  /// are SwipeAction.none. A full swipe dismisses using the primary action;
  /// if primary is none but secondary isn't, secondary becomes the dismiss
  /// action too, so a full swipe always does *something* useful when at
  /// least one slot on that side is configured.
  ActionPane? buildActionPane({
    required SwipeAction primary,
    required SwipeAction secondary,
    required MailAccount account,
    // Captured by value at build time, not re-read lazily after an await:
    // the callers of this method (_MessageList / _UnifiedMessageList) have
    // no Key, so a tab/folder switch can mutate the owning State's folder
    // out from under an in-flight swipe action. Closing over this parameter
    // (rather than e.g. a `folder` getter read fresh post-await) guarantees
    // performSwipeAction always acts on the folder the swipe actually
    // started in.
    required MailFolder folder,
    required MailMessage message,
    required void Function(int messageId) onRemoved,
  }) {
    final configured = [primary, secondary].where((a) => a != SwipeAction.none).toList();
    if (configured.isEmpty) return null;
    final dismissAction = primary != SwipeAction.none ? primary : secondary;

    return ActionPane(
      motion: const DrawerMotion(),
      dismissible: DismissiblePane(
        // The action itself runs here, not in onDismissed: confirmDismiss
        // is awaited *before* flutter_slidable commits to the resize/dismiss
        // animation, so returning false (action didn't actually remove the
        // message — flag/toggleRead, or the repository call threw) vetoes
        // the animation entirely and the pane just closes back up. Running
        // the action in onDismissed instead would commit to the resize
        // animation first, leaving a zombie row (or tripping
        // flutter_slidable's "dismissed widget still in tree" assertion)
        // whenever the message doesn't actually disappear from this folder.
        confirmDismiss: () => performSwipeAction(account: account, folder: folder, action: dismissAction, message: message),
        closeOnCancel: true,
        onDismissed: () {
          // Only reached when confirmDismiss returned true (the message was
          // actually removed) and the resize animation has finished. Let the
          // caller mark it pending-removal now so a stale/in-flight
          // messagesProvider refresh can't resurrect this same Slidable
          // under the same key before the refresh lands.
          if (isMounted() && message.id != null) {
            onRemoved(message.id!);
          }
        },
      ),
      children: [
        for (final action in configured)
          SlidableAction(
            onPressed: (_) => performSwipeAction(account: account, folder: folder, action: action, message: message),
            icon: swipeActionIcon(action),
            label: action.label,
            backgroundColor: swipeActionColor(action),
          ),
      ],
    );
  }

  /// Runs [action] against [message] in [folder], belonging to [account].
  /// Returns true if the message actually left [folder] (archive, or a
  /// delete that moved-to-Trash or permanently removed it) — this is also
  /// used by DismissiblePane's confirmDismiss to decide whether the
  /// dismiss/resize animation should proceed at all. Returns false for
  /// non-removing actions (flag, toggleRead) or if the repository call threw.
  ///
  /// Deliberately takes no BuildContext: it runs across awaits that can
  /// outlive both the individual list row and this whole list, so it
  /// resolves the ScaffoldMessenger once up front (while definitely mounted)
  /// and never touches a possibly-defunct context afterwards.
  Future<bool> performSwipeAction({
    required MailAccount account,
    required MailFolder folder,
    required SwipeAction action,
    required MailMessage message,
  }) async {
    if (action == SwipeAction.none) return false;
    // Resolved before any await, from the owning State's own context (not a
    // list row's, which can be unmounted independently). The messenger
    // itself is owned by the app-level Scaffold and outlives this list.
    final messenger = isMounted() ? messengerOf() : null;
    try {
      // Every `mounted`/`isMounted()` check below guards a subsequent `ref`
      // use: reading or invalidating through a disposed ConsumerState's
      // `ref` throws a StateError (popping the folder view or switching
      // accounts during a slow archive/delete is enough to hit it).
      final repository = await ref.read(mailRepositoryProvider.future);
      if (!isMounted()) return false;
      switch (action) {
        case SwipeAction.archive:
          final moved = await repository.archiveMessage(account, folder, message);
          if (!isMounted()) return false;
          ref.invalidate(messagesProvider(folder));
          // Re-fetch from the DAO rather than trusting `moved`'s uid
          // directly: when the server doesn't report a new UID on move (no
          // UIDPLUS), `moved` still carries the pre-move uid even though the
          // DB row was persisted under a different (synthetic placeholder)
          // uid. Undo's server-side move-back must use whatever uid is
          // actually persisted, so re-read it fresh here.
          final freshList = await repository.getCachedMessages(moved.folderId);
          if (!isMounted()) return false;
          final freshMessage = freshList.firstWhere((m) => m.id == moved.id, orElse: () => moved);
          _showUndoSnackBar(account, folder, freshMessage, 'Archived');
          return true;
        case SwipeAction.delete:
          final result = await repository.deleteMessage(account, folder, message);
          if (!isMounted()) return false;
          ref.invalidate(messagesProvider(folder));
          // Only offer Undo when the message actually moved (a permanent
          // removal — no Trash folder, or already in Trash — can't be
          // undone). Either way it left `folder`, so this branch always
          // returns true below.
          if (result.folderId != folder.id) {
            // See the archive branch above for why we re-fetch instead of
            // trusting `result`'s uid directly.
            final freshList = await repository.getCachedMessages(result.folderId);
            if (!isMounted()) return false;
            final freshMessage = freshList.firstWhere((m) => m.id == result.id, orElse: () => result);
            _showUndoSnackBar(account, folder, freshMessage, 'Deleted');
          }
          return true;
        case SwipeAction.flag:
          await repository.markFlagged(account, folder, message, !message.isFlagged);
          break;
        case SwipeAction.toggleRead:
          await repository.markRead(account, folder, message, !message.isRead);
          break;
        case SwipeAction.none:
          break;
      }
      if (!isMounted()) return false;
      ref.invalidate(messagesProvider(folder));
      return false;
    } catch (e) {
      if (isMounted()) {
        ref.invalidate(messagesProvider(folder));
      }
      // Use the messenger captured before the awaits: `context` may belong
      // to a list item that has since been unmounted, but the failure still
      // deserves feedback.
      if (messenger != null && messenger.mounted) {
        _showAutoDismissingSnackBar(
          messenger,
          SnackBar(
            content: Text("Couldn't ${action.label.toLowerCase()} — $e"),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => performSwipeAction(account: account, folder: folder, action: action, message: message),
            ),
          ),
        );
      }
      return false;
    }
  }

  void _showUndoSnackBar(MailAccount account, MailFolder originalFolder, MailMessage movedMessage, String verb) {
    if (!isMounted()) return;
    final messenger = messengerOf();
    if (messenger == null) return;

    // A move whose server didn't report a post-move UID (no UIDPLUS) is
    // persisted under a synthetic negative placeholder uid. Undoing it would
    // move it back by that uid — i.e. send `UID MOVE -1 ...`, which
    // MessageSequence.fromId happily builds and the server cannot honour.
    // Offer no Undo in that case rather than an affordance that can only
    // fail.
    final canUndo = movedMessage.uid >= 0;

    _showAutoDismissingSnackBar(
      messenger,
      SnackBar(
        content: Text(canUndo ? verb : "$verb — can't be undone"),
        action: canUndo
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  // Everything here can fail (offline, the message's folder no
                  // longer cached, this list disposed while the snackbar was
                  // still up). Unhandled, the user taps Undo and sees nothing
                  // happen at all; the repository already reverts its own
                  // local state, so this is purely about feedback.
                  try {
                    if (!isMounted()) {
                      throw StateError('the message list is no longer open');
                    }
                    final repository = await ref.read(mailRepositoryProvider.future);
                    final folders = await repository.getCachedFolders(originalFolder.accountId);
                    final currentFolder = folders.firstWhere(
                      (f) => f.id == movedMessage.folderId,
                      orElse: () => throw StateError('the folder it was moved to is no longer available'),
                    );
                    await repository.moveMessage(account, currentFolder, originalFolder, movedMessage);
                    if (!isMounted()) return;
                    ref.invalidate(messagesProvider(originalFolder));
                  } catch (e) {
                    if (messenger.mounted) {
                      _showAutoDismissingSnackBar(messenger, SnackBar(content: Text("Couldn't undo — $e")));
                    }
                  }
                },
              )
            : null,
      ),
    );
  }
}
