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

  MailFolder get folder => widget.folder;

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
                  context,
                  ref,
                  primary: swipeConfig.leftPrimary,
                  secondary: swipeConfig.leftSecondary,
                  message: message,
                ),
                endActionPane: _buildActionPane(
                  context,
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
    BuildContext context,
    WidgetRef ref, {
    required SwipeAction primary,
    required SwipeAction secondary,
    required MailMessage message,
  }) {
    final configured = [primary, secondary].where((a) => a != SwipeAction.none).toList();
    if (configured.isEmpty) return null;
    final dismissAction = primary != SwipeAction.none ? primary : secondary;

    return ActionPane(
      motion: const DrawerMotion(),
      dismissible: DismissiblePane(
        onDismissed: () => _performSwipeAction(context, ref, dismissAction, message),
      ),
      children: [
        for (final action in configured)
          SlidableAction(
            onPressed: (_) => _performSwipeAction(context, ref, action, message),
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

  Future<void> _performSwipeAction(
    BuildContext context,
    WidgetRef ref,
    SwipeAction action,
    MailMessage message,
  ) async {
    if (action == SwipeAction.none) return;
    final repository = await ref.read(mailRepositoryProvider.future);
    final accounts = await ref.read(accountsProvider.future);
    final account = accounts.firstWhere((a) => a.id == folder.accountId);
    try {
      switch (action) {
        case SwipeAction.archive:
          final moved = await repository.archiveMessage(account, folder, message);
          if (mounted && message.id != null) setState(() => _pendingRemoval.add(message.id!));
          ref.invalidate(messagesProvider(folder));
          // Re-fetch from the DAO rather than trusting `moved`'s uid
          // directly: when the server doesn't report a new UID on move (no
          // UIDPLUS), `moved` still carries the pre-move uid even though the
          // DB row was persisted under a different (synthetic placeholder)
          // uid. Undo's server-side move-back must use whatever uid is
          // actually persisted, so re-read it fresh here.
          final freshList = await repository.getCachedMessages(moved.folderId);
          final freshMessage = freshList.firstWhere((m) => m.id == moved.id, orElse: () => moved);
          _showUndoSnackBar(context, ref, account, folder, freshMessage, 'Archived');
          return;
        case SwipeAction.delete:
          final result = await repository.deleteMessage(account, folder, message);
          if (mounted && message.id != null) setState(() => _pendingRemoval.add(message.id!));
          ref.invalidate(messagesProvider(folder));
          // Only offer Undo when the message actually moved (a permanent
          // removal — no Trash folder, or already in Trash — can't be
          // undone).
          if (result.folderId != folder.id) {
            // See the archive branch above for why we re-fetch instead of
            // trusting `result`'s uid directly.
            final freshList = await repository.getCachedMessages(result.folderId);
            final freshMessage = freshList.firstWhere((m) => m.id == result.id, orElse: () => result);
            _showUndoSnackBar(context, ref, account, folder, freshMessage, 'Deleted');
          }
          return;
        case SwipeAction.flag:
          await repository.markFlagged(account, folder, message, !message.isFlagged);
          break;
        case SwipeAction.toggleRead:
          await repository.markRead(account, folder, message, !message.isRead);
          break;
        case SwipeAction.none:
          break;
      }
      ref.invalidate(messagesProvider(folder));
    } catch (e) {
      ref.invalidate(messagesProvider(folder));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Couldn't ${action.label.toLowerCase()} — $e"),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _performSwipeAction(context, ref, action, message),
          ),
        ));
      }
    }
  }

  void _showUndoSnackBar(
    BuildContext context,
    WidgetRef ref,
    MailAccount account,
    MailFolder originalFolder,
    MailMessage movedMessage,
    String verb,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(verb),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          final repository = await ref.read(mailRepositoryProvider.future);
          final folders = await repository.getCachedFolders(originalFolder.accountId);
          final currentFolder = folders.firstWhere((f) => f.id == movedMessage.folderId);
          await repository.moveMessage(account, currentFolder, originalFolder, movedMessage);
          ref.invalidate(messagesProvider(originalFolder));
        },
      ),
    ));
  }
}
