import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../data/repository/mail_repository.dart';
import '../models/enums.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../models/mail_message.dart';
import '../providers/account_providers.dart';
import '../providers/folder_providers.dart';
import '../providers/message_providers.dart';
import '../providers/repository_providers.dart';
import '../providers/sync_status_providers.dart';
import '../providers/swipe_action_providers.dart';
import '../widgets/empty_folder_state.dart';
import '../widgets/folder_picker_sheet.dart';
import '../widgets/folder_tab_bar.dart';
import '../widgets/folder_tree_expander.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/message_swipe_controller.dart';
import '../widgets/sync_error_banner.dart';
import 'account_form_screen.dart';
import 'compose_screen.dart';
import 'message_detail_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class FolderViewScreen extends ConsumerStatefulWidget {
  const FolderViewScreen({super.key, required this.accountId});

  final int accountId;

  @override
  ConsumerState<FolderViewScreen> createState() => _FolderViewScreenState();
}

class _FolderViewScreenState extends ConsumerState<FolderViewScreen> {
  MailFolder? _selected;
  bool _selecting = false;
  final Set<int> _selectedIds = {};

  // See _showAutoDismissingSnackBar's doc comment for why this exists —
  // same rationale and pattern as MessageSwipeController's own field.
  Timer? _snackBarDismissTimer;

  @override
  void dispose() {
    _snackBarDismissTimer?.cancel();
    super.dispose();
  }

  MailFolder? _currentFolder(List<MailFolder>? folders) {
    if (folders == null) return null;
    final defaults = <MailFolder>[
      for (final type in [
        MailFolderType.inbox,
        MailFolderType.sent,
        MailFolderType.trash,
      ])
        ...folders.where((f) => f.type == type),
    ];
    return _selected ??
        (defaults.isNotEmpty ? defaults.first : (folders.isNotEmpty ? folders.first : null));
  }

  void _enterSelection(int id) => setState(() {
        _selecting = true;
        _selectedIds.add(id);
      });

  void _toggleSelection(int id) => setState(() {
        if (!_selectedIds.remove(id)) {
          _selectedIds.add(id);
        }
        if (_selectedIds.isEmpty) {
          _selecting = false;
        }
      });

  void _exitSelection() => setState(() {
        _selecting = false;
        _selectedIds.clear();
      });

  /// Shows [snackBar] via [messenger] and guarantees it disappears after
  /// [snackBar]'s own `duration`, even if its built-in auto-dismiss timer
  /// doesn't fire — see MessageSwipeController._showAutoDismissingSnackBar
  /// for the same workaround and why it exists. Also clears any snackbar
  /// already showing/queued first, so a new bulk action's feedback is never
  /// stuck waiting behind a stale one.
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

  void _showBulkResultSnackBar(BulkResult result, {required String verb}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final succeededCount = result.succeeded.length;
    final failedCount = result.failed.length;
    final String text;
    if (failedCount == 0) {
      text = '$succeededCount $verb';
    } else if (succeededCount == 0) {
      text = "Couldn't move $failedCount message${failedCount == 1 ? '' : 's'}";
    } else {
      text = '$succeededCount moved, $failedCount failed';
    }
    _showAutoDismissingSnackBar(messenger, SnackBar(content: Text(text)));
  }

  Future<void> _bulkDelete(MailFolder folder) async {
    final messages = ref.read(messagesProvider(folder)).valueOrNull ?? const <MailMessage>[];
    final selected = messages.where((m) => _selectedIds.contains(m.id)).toList();
    _exitSelection();
    if (selected.isEmpty) return;
    final account = _findAccount();
    if (account == null) return;
    // Mirrors MailRepository.deleteMessage/deleteMessages' own branch
    // condition exactly: a Trash folder exists and it isn't the folder
    // already being viewed. Anything else is a PERMANENT local-only
    // removal (no Trash to catch it, or already viewing Trash) — the
    // summary snackbar must say so, not claim a move that never happened.
    final allFolders = ref.read(foldersProvider(widget.accountId)).valueOrNull ?? const <MailFolder>[];
    final trashFolder = allFolders.firstWhereOrNull((f) => f.type == MailFolderType.trash);
    final movesToTrash = trashFolder != null && trashFolder.id != folder.id;
    try {
      final repository = await ref.read(mailRepositoryProvider.future);
      final result = await repository.deleteMessages(account, folder, selected);
      if (!mounted) return;
      ref.invalidate(messagesProvider(folder));
      ref.read(unreadCountRefreshTickProvider.notifier).state++;
      _showBulkResultSnackBar(result, verb: movesToTrash ? 'moved to Trash' : 'deleted');
    } catch (e) {
      if (!mounted) return;
      // Match performSwipeAction's catch block: refresh the list/unread count
      // even on failure, since the repository call may have partially
      // committed local DB changes before the error was thrown.
      ref.invalidate(messagesProvider(folder));
      ref.read(unreadCountRefreshTickProvider.notifier).state++;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      _showAutoDismissingSnackBar(messenger, SnackBar(content: Text("Couldn't delete — $e")));
    }
  }

  Future<void> _bulkMove(MailFolder folder, List<MailFolder> allFolders) async {
    final destination = await showFolderPicker(
      context,
      allFolders.where((f) => f.id != folder.id).toList(),
    );
    if (destination == null) return;
    final messages = ref.read(messagesProvider(folder)).valueOrNull ?? const <MailMessage>[];
    final selected = messages.where((m) => _selectedIds.contains(m.id)).toList();
    _exitSelection();
    if (selected.isEmpty) return;
    final account = _findAccount();
    if (account == null) return;
    try {
      final repository = await ref.read(mailRepositoryProvider.future);
      final result = await repository.moveMessages(account, folder, destination, selected);
      if (!mounted) return;
      ref.invalidate(messagesProvider(folder));
      ref.read(unreadCountRefreshTickProvider.notifier).state++;
      _showBulkResultSnackBar(result, verb: 'moved to ${destination.name}');
    } catch (e) {
      if (!mounted) return;
      // Match _bulkDelete's/performSwipeAction's catch block: refresh the
      // list/unread count even on failure, since the repository call may
      // have partially committed local DB changes before the error was
      // thrown.
      ref.invalidate(messagesProvider(folder));
      ref.read(unreadCountRefreshTickProvider.notifier).state++;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      _showAutoDismissingSnackBar(messenger, SnackBar(content: Text("Couldn't move — $e")));
    }
  }

  PreferredSizeWidget _buildDefaultAppBar() {
    return AppBar(
      title: const Text('Mail'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
        ),
        // Single-account routing (app.dart) skips AccountListScreen
        // entirely — its gear icon was the only path to SettingsScreen,
        // so a single-account user would otherwise have no way to reach
        // theme/swipe-action settings at all.
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar(MailFolder current, List<MailFolder> allFolders) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelection,
      ),
      title: Text('${_selectedIds.length} selected'),
      actions: [
        IconButton(
          icon: const Icon(Icons.folder_outlined),
          tooltip: 'Move to folder',
          onPressed: () => _bulkMove(current, allFolders),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: () => _bulkDelete(current),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(foldersProvider(widget.accountId));
    final syncError = ref.watch(syncErrorProvider(widget.accountId));
    final current = _currentFolder(foldersAsync.valueOrNull);

    return Scaffold(
      appBar: _selecting && current != null
          ? _buildSelectionAppBar(current, foldersAsync.valueOrNull ?? const [])
          : _buildDefaultAppBar(),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ComposeScreen(accountId: widget.accountId),
                ),
              ),
              child: const Icon(Icons.edit),
            ),
      body: foldersAsync.when(
        data: (folders) {
          final defaults = <MailFolder>[
            for (final type in [
              MailFolderType.inbox,
              MailFolderType.sent,
              MailFolderType.trash,
            ])
              ...folders.where((f) => f.type == type),
          ];
          final rest = folders.where((f) => !defaults.contains(f)).toList();
          final current = _currentFolder(folders);

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
                      onPressed: () =>
                          ref.invalidate(foldersProvider(widget.accountId)),
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: () =>
                          ref
                                  .read(
                                    syncErrorProvider(
                                      widget.accountId,
                                    ).notifier,
                                  )
                                  .state =
                              null,
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: FolderTabBar(
                  folders: defaults,
                  selected: current,
                  onSelect: (folder) => setState(() {
                    _selected = folder;
                    _selecting = false;
                    _selectedIds.clear();
                  }),
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
                    onSelect: (folder) => setState(() {
                      _selected = folder;
                      _selecting = false;
                      _selectedIds.clear();
                    }),
                  ),
                ),
              ),
              const Divider(height: 1),
              if (current != null)
                Expanded(
                  child: _MessageList(
                    folder: current,
                    selecting: _selecting,
                    selectedIds: _selectedIds,
                    onEnterSelection: _enterSelection,
                    onToggleSelection: _toggleSelection,
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => SyncErrorBanner(
          message: error.toString(),
          onRetry: () => ref.invalidate(foldersProvider(widget.accountId)),
          onEditAccount: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AccountFormScreen(existing: _findAccount()),
            ),
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
  const _MessageList({
    required this.folder,
    required this.selecting,
    required this.selectedIds,
    required this.onEnterSelection,
    required this.onToggleSelection,
  });

  final MailFolder folder;
  final bool selecting;
  final Set<int> selectedIds;
  final ValueChanged<int> onEnterSelection;
  final ValueChanged<int> onToggleSelection;

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
        // `widget.selectedIds` is the SAME Set instance _FolderViewScreenState
        // owns (passed down, not copied) — mutating it here drops a
        // since-vanished message from the selection immediately, per the
        // design spec. This doesn't itself call the parent's setState, so
        // the app bar's "N selected" count can lag by one frame until the
        // next selection change triggers a rebuild — acceptable for this
        // rare edge case (a sync/refresh removing a selected message).
        widget.selectedIds.retainAll(messages.map((m) => m.id).whereType<int>());
        final visible = messages
            .where((m) => !_pendingRemoval.contains(m.id))
            .toList();
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
        final accounts = visible.isNotEmpty
            ? ref.watch(accountsProvider).valueOrNull
            : null;
        if (visible.isNotEmpty && accounts == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return RefreshIndicator(
          // ref.invalidate() is synchronous — it only marks the provider
          // dirty for its *next* read. Awaiting it (even wrapped in
          // `async =>`) resolves immediately, before messagesProvider's
          // rebuild (a real IMAP syncHeaders round-trip) has even started,
          // which is why the spinner used to spring back instantly instead
          // of reflecting how long the sync actually took. ref.refresh(...
          // .future) both invalidates and returns the future of the fresh
          // value, so awaiting it blocks until the resync genuinely finishes.
          onRefresh: () => ref.refresh(messagesProvider(folder).future),
          child: visible.isEmpty
              ? LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    // Still scrollable (not just Center()) so pull-to-refresh
                    // stays reachable on an empty folder, not just a full one.
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: constraints.maxHeight,
                        child: EmptyFolderState(
                          message: 'No messages in ${folder.name}',
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final message = visible[index];
                    // firstWhereOrNull, not firstWhere: the account can vanish out
                    // from under an still-mounted FolderViewScreen (e.g. removed
                    // in another screen while this one stays alive) — falling back
                    // to the same loading state used above rather than crashing
                    // with an unguarded StateError, exactly like the pre-Task-5
                    // inline version handled this same lookup failing inside
                    // _performSwipeAction's try block.
                    final account = accounts!.firstWhereOrNull(
                      (a) => a.id == folder.accountId,
                    );
                    if (account == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final tile = MessageListTile(
                      key: ValueKey(message.id),
                      message: message,
                      selected: widget.selecting ? widget.selectedIds.contains(message.id) : null,
                      onLongPress: () => widget.onEnterSelection(message.id!),
                      onTap: widget.selecting
                          ? () => widget.onToggleSelection(message.id!)
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MessageDetailScreen(
                                    folder: folder,
                                    message: message,
                                  ),
                                ),
                              ),
                    );
                    if (widget.selecting) {
                      return tile;
                    }
                    return Slidable(
                      key: ValueKey(message.id),
                      startActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.leftPrimary,
                        secondary: swipeConfig.leftSecondary,
                        account: account,
                        folder: folder,
                        message: message,
                        onRemoved: (id) =>
                            setState(() => _pendingRemoval.add(id)),
                      ),
                      endActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.rightPrimary,
                        secondary: swipeConfig.rightSecondary,
                        account: account,
                        folder: folder,
                        message: message,
                        onRemoved: (id) =>
                            setState(() => _pendingRemoval.add(id)),
                      ),
                      child: tile,
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
