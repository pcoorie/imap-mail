import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/enums.dart';
import '../models/mail_account.dart';
import '../models/mail_folder.dart';
import '../providers/account_providers.dart';
import '../providers/folder_providers.dart';
import '../providers/message_providers.dart';
import '../widgets/folder_tab_bar.dart';
import '../widgets/folder_tree_expander.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/sync_error_banner.dart';
import 'account_form_screen.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('Mail')),
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
              Padding(
                padding: const EdgeInsets.all(8),
                child: FolderTabBar(
                  folders: defaults,
                  selected: current,
                  onSelect: (folder) => setState(() => _selected = folder),
                ),
              ),
              FolderTreeExpander(
                folders: rest,
                onSelect: (folder) => setState(() => _selected = folder),
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

class _MessageList extends ConsumerWidget {
  const _MessageList({required this.folder});

  final MailFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(messagesProvider(folder));

    return messagesAsync.when(
      data: (messages) => RefreshIndicator(
        onRefresh: () async => ref.invalidate(messagesProvider(folder)),
        child: ListView.builder(
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[index];
            return MessageListTile(
              message: message,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => MessageDetailScreen(folder: folder, message: message)),
              ),
            );
          },
        ),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => SyncErrorBanner(
        message: error.toString(),
        onRetry: () => ref.invalidate(messagesProvider(folder)),
      ),
    );
  }
}
