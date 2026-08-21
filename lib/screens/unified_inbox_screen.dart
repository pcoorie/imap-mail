import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/mail_account.dart';
import '../models/unified_message.dart';
import '../providers/account_providers.dart';
import '../providers/message_providers.dart';
import '../providers/swipe_action_providers.dart';
import '../providers/sync_status_providers.dart';
import '../providers/unified_inbox_providers.dart';
import '../widgets/account_color.dart';
import '../widgets/compose_account_picker.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/message_swipe_controller.dart';
import '../widgets/sync_error_banner.dart';
import 'compose_screen.dart';
import 'message_detail_screen.dart';

class UnifiedInboxScreen extends ConsumerWidget {
  const UnifiedInboxScreen({super.key});

  Future<void> _compose(BuildContext context, WidgetRef ref) async {
    final accounts = await ref.read(accountsProvider.future);
    if (!context.mounted) return;
    final MailAccount? chosen =
        accounts.length == 1 ? accounts.single : await showComposeAccountPicker(context, accounts);
    if (chosen == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ComposeScreen(accountId: chosen.id!)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('All Inboxes')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _compose(context, ref),
        child: const Icon(Icons.edit),
      ),
      body: const _UnifiedMessageList(),
    );
  }
}

class _UnifiedMessageList extends ConsumerStatefulWidget {
  const _UnifiedMessageList();

  @override
  ConsumerState<_UnifiedMessageList> createState() => _UnifiedMessageListState();
}

class _UnifiedMessageListState extends ConsumerState<_UnifiedMessageList> {
  // Same purpose as FolderViewScreen's _pendingRemoval: a dismissed Slidable
  // must not be resurrected by a stale/in-flight unifiedInboxProvider
  // refresh before that refresh actually lands.
  final Set<int> _pendingRemoval = {};
  late final MessageSwipeController _swipeController;

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
    final unifiedAsync = ref.watch(unifiedInboxProvider);
    final accountsAsync = ref.watch(accountsProvider);
    final swipeConfig = ref.watch(swipeActionConfigProvider);

    // One sync-error banner covering every contributing account, rather
    // than one per account — mirrors FolderViewScreen's single banner, just
    // aggregated. Only meaningful once we know which accounts exist.
    final failedAccountCount = accountsAsync.valueOrNull
            ?.where((a) => ref.watch(syncErrorProvider(a.id!)) != null)
            .length ??
        0;

    return unifiedAsync.when(
      data: (messages) {
        _pendingRemoval.retainAll(messages.map((u) => u.message.id).whereType<int>());
        final visible = messages.where((u) => !_pendingRemoval.contains(u.message.id)).toList();

        return Column(
          children: [
            if (failedAccountCount > 0)
              MaterialBanner(
                content: Text(
                  '$failedAccountCount account${failedAccountCount == 1 ? '' : 's'} failed to sync — showing saved data',
                ),
                actions: [
                  TextButton(
                    onPressed: () => ref.invalidate(unifiedInboxProvider),
                    child: const Text('Retry'),
                  ),
                  TextButton(
                    onPressed: () {
                      for (final account in accountsAsync.valueOrNull ?? const []) {
                        ref.read(syncErrorProvider(account.id!).notifier).state = null;
                      }
                    },
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  final current = ref.read(unifiedInboxProvider).valueOrNull ?? const [];
                  final folders = {for (final u in current) u.folder.id: u.folder}.values;
                  for (final folder in folders) {
                    ref.invalidate(messagesProvider(folder));
                  }
                  ref.invalidate(unifiedInboxProvider);
                },
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final UnifiedMessage unified = visible[index];
                    return Slidable(
                      key: ValueKey(unified.message.id),
                      startActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.leftPrimary,
                        secondary: swipeConfig.leftSecondary,
                        account: unified.account,
                        folder: unified.folder,
                        message: unified.message,
                        onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
                      ),
                      endActionPane: _swipeController.buildActionPane(
                        primary: swipeConfig.rightPrimary,
                        secondary: swipeConfig.rightSecondary,
                        account: unified.account,
                        folder: unified.folder,
                        message: unified.message,
                        onRemoved: (id) => setState(() => _pendingRemoval.add(id)),
                      ),
                      child: MessageListTile(
                        message: unified.message,
                        accountColor: accountColorFor(unified.account.id!),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MessageDetailScreen(folder: unified.folder, message: unified.message),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SyncErrorBanner(
        message: error.toString(),
        onRetry: () => ref.invalidate(unifiedInboxProvider),
      ),
    );
  }
}
