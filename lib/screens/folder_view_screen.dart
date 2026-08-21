import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/enums.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../models/swipe_action.dart';
import '../providers/account_providers.dart';
import '../providers/folder_providers.dart';
import '../providers/message_providers.dart';
import '../providers/repository_providers.dart';
import '../providers/sync_status_providers.dart';
import '../providers/swipe_action_providers.dart';
import '../widgets/folder_tab_bar.dart';
import '../widgets/folder_tree_expander.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/sync_error_banner.dart';
import 'account_form_screen.dart';
import 'compose_screen.dart';
import 'message_detail_screen.dart';

class FolderViewScreen extends ConsumerStatefulWidget {
  const FolderViewScreen({super.key, required this.accountId});

  final int accountId;

  @override
  ConsumerState<FolderViewScreen> createState() => _FolderViewScreenState();
}

class _FolderViewScreenState extends ConsumerState<FolderViewScreen> {
  MailFolder? _selected;

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider(widget.accountId));
    final syncError = ref.watch(lastSyncErrorProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mail')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ComposeScreen(accountId: widget.accountId)),
        ),
        child: const Icon(Icons.edit),
      ),
      body: foldersAsync.when(
        data: (folders) {
          final defaults = <MailFolder>[
            for (final type in [MailFolderType.inbox, MailFolderType.sent, MailFolderType.trash])
              ...folders.where((f) => f.type == type),
          ];
          final rest = folders.where((f) => !defaults.contains(f)).toList();
          final current = _selected ?? (defaults.isNotEmpty ? defaults.first : (folders.isNotEmpty ? folders.first : null));

          return Column(
            children: [
              // Informational-only: a sync failure once cached data already
              // exists must not blank the screen (unlike the full-screen
              // `error` branch below, which only fires when there is no
              // cache at all). Dismissible so it doesn't nag forever.
              if (syncError != null)
                MaterialBanner(
                  content: Text('Showing saved data — sync failed: $syncError'),
                  actions: [
                    TextButton(
                      onPressed: () => ref.invalidate(foldersProvider(widget.accountId)),
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: () => ref.read(lastSyncErrorProvider.notifier).state = null,
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: FolderTabBar(
                  folders: defaults,
                  selected: current,
                  onSelect: (folder) => setState(() => _selected = folder),
                ),
              ),
              // Bounded + scrollable: FolderTreeExpander's expanded list is a
              // plain (unscrollable) Column, so with many "other" folders it
              // can be taller than the screen. Without this cap, that would
              // overflow the outer Column and starve the message list
              // (Expanded below) of space. ConstrainedBox+SingleChildScrollView
              // shrink-wraps up to maxHeight — short lists (the common case)
              // still take only their natural height, no wasted space.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: FolderTreeExpander(
                    folders: rest,
                    onSelect: (folder) => setState(() => _selected = folder),
                  ),
                ),
              ),
              const Divider(height: 1),
              if (current != null) Expanded(child: _MessageList(folder: current)),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => SyncErrorBanner(
          message: error.toString(),
          onRetry: () => ref.invalidate(foldersProvider(widget.accountId)),
          onEditAccount: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AccountFormScreen(existing: _findAccount())),
          ),
        ),
      ),
    );
  }

  MailAccount? _findAccount() {
    final accounts = ref.read(accountsProvider).valueOrNull;
    if (accounts == null) return null;
    for (final account in accounts) {
      if (account.id == widget.accountId) return account;
    }
    return null;
  }
}

class _MessageList extends ConsumerStatefulWidget {
  const _MessageList({required this.folder});

  final MailFolder folder;

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  // Message ids dismissed via a swipe action but not yet confirmed gone by
  // messagesProvider. Riverpod's FutureProvider keeps serving the previous
  // (stale) list while a ref.invalidate()-triggered refresh is in flight
  // (AsyncData with isRefreshing:true) — without this, that stale rebuild
  // would resurrect the just-dismissed Slidable under the same key mid
  // refresh, and flutter_slidable asserts if a dismissed Slidable is
  // rebuilt back into the tree. Filtering these out locally closes that gap
  // regardless of how long the underlying refresh takes.
  final Set<int> _pendingRemoval = {};

  // See _showAutoDismissingSnackBar's doc comment for why this exists.
  // Owned by this State (not fire-and-forget) so it never fires after —
  // or leaks past — this widget's own lifetime: cancelled and replaced
  // whenever a new snackbar supersedes an old one, and cancelled in
  // dispose() so the widget test framework's "no pending timers" check
  // doesn't trip on a snackbar shown just before a test ends.
  Timer? _snackBarDismissTimer;

  MailFolder get folder => widget.folder;

  @override
  void dispose() {
    _snackBarDismissTimer?.cancel();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(folder));
    final swipeConfig = ref.watch(swipeActionConfigProvider);

    return messagesAsync.when(
      data: (messages) {
        _pendingRemoval.retainAll(messages.map((m) => m.id).whereType<int>());
        final visible = messages.where((m) => !_pendingRemoval.contains(m.id)).toList();
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(messagesProvider(folder)),
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final message = visible[index];
              return Slidable(
                key: ValueKey(message.id),
                startActionPane: _buildActionPane(
                  ref,
                  primary: swipeConfig.leftPrimary,
                  secondary: swipeConfig.leftSecondary,
                  message: message,
                ),
                endActionPane: _buildActionPane(
                  ref,
                  primary: swipeConfig.rightPrimary,
                  secondary: swipeConfig.rightSecondary,
                  message: message,
                ),
                child: MessageListTile(
                  message: message,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => MessageDetailScreen(folder: folder, message: message)),
                  ),
                ),
              );
            },
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SyncErrorBanner(
        message: error.toString(),
        onRetry: () => ref.invalidate(messagesProvider(folder)),
      ),
    );
  }

  /// Builds one side's ActionPane from its configured primary/secondary
  /// actions. Returns null (no pane — no reveal on that side) if both slots
  /// are SwipeAction.none. A full swipe dismisses using the primary action;
  /// if primary is none but secondary isn't, secondary becomes the dismiss
  /// action too, so a full swipe always does *something* useful when at
  /// least one slot on that side is configured.
  ActionPane? _buildActionPane(
    WidgetRef ref, {
    required SwipeAction primary,
    required SwipeAction secondary,
    required MailMessage message,
  }) {
    final configured = [primary, secondary].where((a) => a != SwipeAction.none).toList();
    if (configured.isEmpty) return null;
    final dismissAction = primary != SwipeAction.none ? primary : secondary;
    // Capture the folder this message is actually displayed under right now
    // — not read lazily later via the `folder` getter (== widget.folder).
    // `_MessageList` has no key, so switching folder tabs updates
    // widget.folder on this same State instead of recreating it; if a swipe
    // action's awaits were still in flight when that happened, reading
    // `folder` again afterwards would invalidate/undo into the newly
    // selected folder instead of the one this swipe actually started in.
    final swipeFolder = folder;

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
        confirmDismiss: () => _performSwipeAction(ref, swipeFolder, dismissAction, message),
        closeOnCancel: true,
        onDismissed: () {
          // Only reached when confirmDismiss returned true (the message was
          // actually removed) and the resize animation has finished. Mark it
          // pending-removal now so a stale/in-flight messagesProvider
          // refresh (see _pendingRemoval's doc comment) can't resurrect this
          // same Slidable under the same key before the refresh lands.
          if (mounted && message.id != null) {
            setState(() => _pendingRemoval.add(message.id!));
          }
        },
      ),
      children: [
        for (final action in configured)
          SlidableAction(
            onPressed: (_) => _performSwipeAction(ref, swipeFolder, action, message),
            icon: _iconFor(action),
            label: action.label,
            backgroundColor: _colorFor(action),
          ),
      ],
    );
  }

  IconData _iconFor(SwipeAction action) => switch (action) {
        SwipeAction.archive => Icons.archive_outlined,
        SwipeAction.delete => Icons.delete_outline,
        SwipeAction.flag => Icons.flag_outlined,
        SwipeAction.toggleRead => Icons.mark_email_unread_outlined,
        SwipeAction.none => Icons.block,
      };

  Color _colorFor(SwipeAction action) => switch (action) {
        SwipeAction.archive => Colors.blueGrey,
        SwipeAction.delete => Colors.red,
        SwipeAction.flag => Colors.orange,
        SwipeAction.toggleRead => Colors.teal,
        SwipeAction.none => Colors.grey,
      };

  /// Runs [action] against [message] (which belongs to [folder] — captured
  /// by the caller at the moment the gesture/tap started, never re-read from
  /// the `folder` getter after an await; see the doc comment where this is
  /// called from). Returns true if the message actually left [folder]
  /// (archive, or a delete that moved-to-Trash or permanently removed it) —
  /// this is also used by DismissiblePane's confirmDismiss to decide whether
  /// the dismiss/resize animation should proceed at all. Returns false for
  /// non-removing actions (flag, toggleRead) or if the repository call threw.
  ///
  /// Deliberately takes no BuildContext: it runs across awaits that can
  /// outlive both the individual list row and this whole list, so it
  /// resolves the ScaffoldMessenger once up front (while definitely mounted)
  /// and never touches a possibly-defunct context afterwards.
  Future<bool> _performSwipeAction(
    WidgetRef ref,
    MailFolder folder,
    SwipeAction action,
    MailMessage message,
  ) async {
    if (action == SwipeAction.none) return false;
    // Resolved before any await, from this State's own context (not a list
    // row's, which can be unmounted independently). The messenger itself is
    // owned by the app-level Scaffold and outlives this list.
    final messenger = mounted ? ScaffoldMessenger.maybeOf(context) : null;
    try {
      // Account/repository resolution lives INSIDE the try: a failure here
      // (provider error, or firstWhere finding no matching account) must
      // resolve confirmDismiss's future to `false` — an erroring future
      // instead leaves the row stuck open past the dismiss threshold with
      // nothing to close it.
      //
      // Every `mounted` check below guards a subsequent `ref` use: reading
      // or invalidating through a disposed ConsumerState's `ref` throws a
      // StateError (popping the folder view or switching accounts during a
      // slow archive/delete is enough to hit it).
      final repository = await ref.read(mailRepositoryProvider.future);
      if (!mounted) return false;
      final accounts = await ref.read(accountsProvider.future);
      if (!mounted) return false;
      final account = accounts.firstWhere((a) => a.id == folder.accountId);
      switch (action) {
        case SwipeAction.archive:
          final moved = await repository.archiveMessage(account, folder, message);
          if (!mounted) return false;
          ref.invalidate(messagesProvider(folder));
          // Re-fetch from the DAO rather than trusting `moved`'s uid
          // directly: when the server doesn't report a new UID on move (no
          // UIDPLUS), `moved` still carries the pre-move uid even though the
          // DB row was persisted under a different (synthetic placeholder)
          // uid. Undo's server-side move-back must use whatever uid is
          // actually persisted, so re-read it fresh here.
          final freshList = await repository.getCachedMessages(moved.folderId);
          if (!mounted) return false;
          final freshMessage = freshList.firstWhere((m) => m.id == moved.id, orElse: () => moved);
          _showUndoSnackBar(ref, account, folder, freshMessage, 'Archived');
          return true;
        case SwipeAction.delete:
          final result = await repository.deleteMessage(account, folder, message);
          if (!mounted) return false;
          ref.invalidate(messagesProvider(folder));
          // Only offer Undo when the message actually moved (a permanent
          // removal — no Trash folder, or already in Trash — can't be
          // undone). Either way it left `folder`, so this branch always
          // returns true below.
          if (result.folderId != folder.id) {
            // See the archive branch above for why we re-fetch instead of
            // trusting `result`'s uid directly.
            final freshList = await repository.getCachedMessages(result.folderId);
            if (!mounted) return false;
            final freshMessage = freshList.firstWhere((m) => m.id == result.id, orElse: () => result);
            _showUndoSnackBar(ref, account, folder, freshMessage, 'Deleted');
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
      if (!mounted) return false;
      ref.invalidate(messagesProvider(folder));
      return false;
    } catch (e) {
      if (mounted) {
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
              onPressed: () => _performSwipeAction(ref, folder, action, message),
            ),
          ),
        );
      }
      return false;
    }
  }

  void _showUndoSnackBar(
    WidgetRef ref,
    MailAccount account,
    MailFolder originalFolder,
    MailMessage movedMessage,
    String verb,
  ) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
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
                    if (!mounted) {
                      throw StateError('the message list is no longer open');
                    }
                    final repository = await ref.read(mailRepositoryProvider.future);
                    final folders = await repository.getCachedFolders(originalFolder.accountId);
                    final currentFolder = folders.firstWhere(
                      (f) => f.id == movedMessage.folderId,
                      orElse: () => throw StateError(
                          'the folder it was moved to is no longer available'),
                    );
                    await repository.moveMessage(account, currentFolder, originalFolder, movedMessage);
                    if (!mounted) return;
                    ref.invalidate(messagesProvider(originalFolder));
                  } catch (e) {
                    if (messenger.mounted) {
                      _showAutoDismissingSnackBar(
                        messenger,
                        SnackBar(content: Text("Couldn't undo — $e")),
                      );
                    }
                  }
                },
              )
            : null,
      ),
    );
  }
}
