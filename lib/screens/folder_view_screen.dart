import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/enums.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../providers/account_providers.dart';
import '../providers/folder_providers.dart';
import '../providers/message_providers.dart';
import '../providers/sync_status_providers.dart';
import '../providers/swipe_action_providers.dart';
import '../widgets/folder_tab_bar.dart';
import '../widgets/folder_tree_expander.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/message_swipe_controller.dart';
import '../widgets/sync_error_banner.dart';
import 'account_form_screen.dart';
import 'compose_screen.dart';
import 'message_detail_screen.dart';
import 'settings_screen.dart';

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
    final syncError = ref.watch(syncErrorProvider(widget.accountId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mail'),
        actions: [
          // Single-account routing (app.dart) skips AccountListScreen
          // entirely — its gear icon was the only path to SettingsScreen,
          // so a single-account user would otherwise have no way to reach
          // theme/swipe-action settings at all.
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
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
                      onPressed: () => ref.read(syncErrorProvider(widget.accountId).notifier).state = null,
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
  late final MessageSwipeController _swipeController;

  MailFolder get folder => widget.folder;

  @override
  void initState() {
    super.initState();
    _swipeController = MessageSwipeController(
      ref,
      isMounted: () => mounted,
      messengerOf: () => mounted ? ScaffoldMessenger.maybeOf(context) : null,
    );
  }

  @override
  void dispose() {
    _swipeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(folder));
    final swipeConfig = ref.watch(swipeActionConfigProvider);

    return messagesAsync.when(
      data: (messages) {
        _pendingRemoval.retainAll(messages.map((m) => m.id).whereType<int>());
        final visible = messages.where((m) => !_pendingRemoval.contains(m.id)).toList();
        // Only needed once there's an actual row to build (never touched by
        // an empty folder), and only watched here — not unconditionally at
        // the top of build — so an empty folder never needs accountsProvider
        // resolved at all. In real usage accountsProvider is guaranteed
        // already resolved by this point (both foldersProvider and
        // messagesProvider's real implementations await it before producing
        // data), but that ordering isn't guaranteed against test doubles that
        // override messagesProvider directly — so fall back to the same
        // loading state messagesAsync itself would show, rather than
        // asserting non-null and crashing mid-build on that transient race.
        final accounts = visible.isNotEmpty ? ref.watch(accountsProvider).valueOrNull : null;
        if (visible.isNotEmpty && accounts == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(messagesProvider(folder)),
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final message = visible[index];
              // firstWhereOrNull, not firstWhere: the account can vanish out
              // from under an still-mounted FolderViewScreen (e.g. removed
              // in another screen while this one stays alive) — falling back
              // to the same loading state used above rather than crashing
              // with an unguarded StateError, exactly like the pre-Task-5
              // inline version handled this same lookup failing inside
              // _performSwipeAction's try block.
              final account = accounts!.firstWhereOrNull((a) => a.id == folder.accountId);
              if (account == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return Slidable(
                key: ValueKey(message.id),
                startActionPane: _swipeController.buildActionPane(
                  primary: swipeConfig.leftPrimary,
                  secondary: swipeConfig.leftSecondary,
                  account: account,
                  folder: folder,
                  message: message,
                  onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
                ),
                endActionPane: _swipeController.buildActionPane(
                  primary: swipeConfig.rightPrimary,
                  secondary: swipeConfig.rightSecondary,
                  account: account,
                  folder: folder,
                  message: message,
                  onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
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
}
