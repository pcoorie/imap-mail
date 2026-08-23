import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/swipe_action.dart';
import '../providers/search_providers.dart';
import '../providers/swipe_action_providers.dart';
import '../widgets/account_color.dart';
import '../widgets/empty_folder_state.dart';
import '../widgets/message_list_tile.dart';
import '../widgets/message_swipe_controller.dart';
import 'message_detail_screen.dart';

/// Search across every account's every folder at once — see the design
/// spec's "Everything, everywhere" scope decision. Reached from a search
/// icon on both FolderViewScreen's and UnifiedInboxScreen's app bars; takes
/// no parameters itself, so it's always the same full global search
/// regardless of which screen launched it.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  // Same purpose as FolderViewScreen's/UnifiedInboxScreen's own
  // _pendingRemoval: a dismissed Slidable must not be resurrected by a
  // stale/in-flight searchResultsProvider refresh before that refresh
  // actually lands.
  final Set<int> _pendingRemoval = {};
  late final MessageSwipeController _swipeController;
  Timer? _debounce;
  String _query = '';

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
    _debounce?.cancel();
    _controller.dispose();
    _swipeController.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // 300ms: long enough that a normal typing cadence doesn't re-query the
    // local cache on every keystroke, short enough to still feel live. See
    // the design spec's "Timing & errors" section.
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value);
    });
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    // Watched unconditionally at the top of build (not inside the results
    // branch below) — same reasoning as FolderViewScreen's/
    // UnifiedInboxScreen's own _MessageList: it's needed to build every
    // row's Slidable action pane, so it's read once here regardless of
    // which body branch ends up rendering.
    final swipeConfig = ref.watch(swipeActionConfigProvider);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search mail',
            border: InputBorder.none,
            suffixIcon: IconButton(icon: const Icon(Icons.clear), onPressed: _clear),
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _buildBody(swipeConfig),
    );
  }

  Widget _buildBody(SwipeActionConfig swipeConfig) {
    if (_query.trim().isEmpty) {
      return const EmptyFolderState(message: 'Search your mail');
    }
    final resultsAsync = ref.watch(searchResultsProvider(_query));
    return resultsAsync.when(
      data: (results) {
        _pendingRemoval.retainAll(results.map((u) => u.message.id).whereType<int>());
        final visible = results.where((u) => !_pendingRemoval.contains(u.message.id)).toList();
        if (visible.isEmpty) {
          return EmptyFolderState(message: 'No results for "$_query"');
        }
        return ListView.separated(
          itemCount: visible.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final unified = visible[index];
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
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('$error')),
    );
  }
}
