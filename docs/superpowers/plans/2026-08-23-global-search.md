# Global Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one search that covers every folder of every configured account at once, reachable from a search icon on both `FolderViewScreen` and `UnifiedInboxScreen`.

**Architecture:** A new `searchResultsProvider` (`FutureProvider.family<List<UnifiedMessage>, String>`) reads straight from `MailRepository.getCachedFolders`/`getCachedMessages` — no new DAO, no schema change, no IMAP calls — filtering every account's every non-local-only folder's cached messages by subject/sender-name/sender-address/snippet and merging into one newest-first list. A new `SearchScreen` renders that list exactly like `UnifiedInboxScreen` does (same `MessageListTile`, same `Slidable` + `MessageSwipeController` wiring, so archive/delete/flag/mark-read all work on results), debouncing text input locally before it drives the provider. Two small edits wire a search icon into each existing screen's app bar.

**Tech Stack:** Flutter, Riverpod (`flutter_riverpod`), `flutter_slidable`, `mocktail` + `flutter_test` for tests. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-23-global-search-design.md` — follow it exactly; this plan implements it task-by-task.

## Global Constraints

- Search covers every account and every non-local-only folder (Outbox excluded) — "everything, everywhere," not scoped to the launching screen.
- Matches only subject, sender name (`fromName`), sender address (`from`), and snippet — case-insensitive substring. No full-body search, no relevance ranking (always sort newest-first).
- Local cache only: `searchResultsProvider` calls `MailRepository.getCachedFolders`/`getCachedMessages` directly, never `foldersProvider`/`messagesProvider` (those trigger live IMAP syncs) and never the transport layer.
- A blank/whitespace-only query returns `[]` immediately without any repository call.
- Text input debounces 300ms in `SearchScreen`'s own local state before it changes the `searchResultsProvider` family key.
- No new schema/migration, no FTS5, no search history.
- Every new/changed provider and widget gets a test in the same task that introduces it — no task is "done" until its own tests pass.
- Run `flutter test` at the end of every task; only commit on green.

---

### Task 1: `searchResultsProvider`

**Files:**
- Create: `lib/providers/search_providers.dart`
- Test: `test/providers/search_providers_test.dart`

**Interfaces:**
- Consumes: `accountsProvider` (`account_providers.dart`), `mailRepositoryProvider` (`repository_providers.dart`), `MailRepository.getCachedFolders(int accountId)`, `MailRepository.getCachedMessages(int folderId)`, `UnifiedMessage { final MailMessage message; final MailFolder folder; final MailAccount account; }` (`models/unified_message.dart`).
- Produces: `searchResultsProvider = FutureProvider.family<List<UnifiedMessage>, String>(...)`, keyed by the raw query string. Used by `SearchScreen` (Task 2).

- [ ] **Step 1: Write the failing tests**

```dart
// test/providers/search_providers_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/search_providers.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class MockMailRepository extends Mock implements MailRepository {}

void main() {
  const work = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personal = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );
  final workInbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final workTrash = MailFolder(id: 11, accountId: 1, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final workOutbox = MailFolder(
    id: 12, accountId: 1, name: 'Outbox', path: 'Outbox', type: MailFolderType.other, isLocalOnly: true,
  );
  final personalInbox = MailFolder(id: 20, accountId: 2, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);

  MailMessage msg({
    required int id,
    required int folderId,
    required String subject,
    String from = 'a@example.com',
    String? fromName,
    String snippet = 'snippet',
    required DateTime date,
  }) =>
      MailMessage(
        id: id, folderId: folderId, uid: id, subject: subject, from: from,
        fromName: fromName, to: 'me@example.com', date: date, snippet: snippet,
      );

  late MockMailRepository repository;
  late ProviderContainer container;

  setUp(() {
    repository = MockMailRepository();
    container = ProviderContainer(overrides: [
      accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
      mailRepositoryProvider.overrideWith((ref) async => repository),
    ]);
    addTearDown(container.dispose);
  });

  test('a blank query returns no results without touching the repository', () async {
    final result = await container.read(searchResultsProvider('   ').future);

    expect(result, isEmpty);
    verifyNever(() => repository.getCachedFolders(any()));
  });

  test(
      'matches subject, sender name, sender address, and snippet, case-insensitively, '
      'across accounts and folders, newest match first', () async {
    when(() => repository.getCachedFolders(1)).thenAnswer((_) async => [workInbox, workTrash]);
    when(() => repository.getCachedFolders(2)).thenAnswer((_) async => [personalInbox]);
    when(() => repository.getCachedMessages(10)).thenAnswer((_) async => [
          msg(id: 1, folderId: 10, subject: 'Invoice attached', date: DateTime.utc(2026, 8, 20)),
        ]);
    when(() => repository.getCachedMessages(11)).thenAnswer((_) async => [
          msg(id: 2, folderId: 11, subject: 'Old', fromName: 'Invoice Bot', date: DateTime.utc(2026, 8, 19)),
        ]);
    when(() => repository.getCachedMessages(20)).thenAnswer((_) async => [
          msg(id: 3, folderId: 20, subject: 'Party', from: 'invoice@example.com', date: DateTime.utc(2026, 8, 21)),
          msg(id: 4, folderId: 20, subject: 'Unrelated', snippet: 'see attached INVOICE', date: DateTime.utc(2026, 8, 18)),
          msg(id: 5, folderId: 20, subject: 'No match here', date: DateTime.utc(2026, 8, 17)),
        ]);

    final result = await container.read(searchResultsProvider('invoice').future);

    // id 5 matches nothing and is excluded; the rest sort newest-first.
    expect(result.map((u) => u.message.id), [3, 1, 2, 4]);
  });

  test('excludes local-only folders (e.g. Outbox) without even reading their messages', () async {
    when(() => repository.getCachedFolders(1)).thenAnswer((_) async => [workOutbox]);
    when(() => repository.getCachedFolders(2)).thenAnswer((_) async => []);

    final result = await container.read(searchResultsProvider('invoice').future);

    expect(result, isEmpty);
    verifyNever(() => repository.getCachedMessages(12));
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/providers/search_providers_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'imap_mail/providers/search_providers.dart'` (file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

```dart
// lib/providers/search_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mail_message.dart';
import '../models/unified_message.dart';
import 'account_providers.dart';
import 'repository_providers.dart';

/// Matches [query] (case-insensitive substring) against a message's
/// subject, sender name, sender address, or snippet — the fields already
/// cached locally and already shown in every list row. Per the design
/// spec's non-goal on full-body search: bodies aren't searched here, only
/// what's already cached without opening the message.
bool _matches(MailMessage message, String query) {
  final q = query.toLowerCase();
  return message.subject.toLowerCase().contains(q) ||
      (message.fromName?.toLowerCase().contains(q) ?? false) ||
      message.from.toLowerCase().contains(q) ||
      message.snippet.toLowerCase().contains(q);
}

/// Every account's every non-local-only folder, filtered to messages
/// matching [query] and merged into one newest-first list — "global"
/// search across every account and every folder, not just whichever screen
/// launched it. Deliberately reads only the local cache
/// (`getCachedFolders`/`getCachedMessages`, not `foldersProvider`'s or
/// `messagesProvider`'s live IMAP sync) — see the design spec's non-goal on
/// live server search. A blank/whitespace-only query short-circuits to `[]`
/// without touching the repository at all, so an empty search field never
/// triggers N accounts' worth of local DB reads for nothing.
final searchResultsProvider = FutureProvider.family<List<UnifiedMessage>, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final repository = await ref.watch(mailRepositoryProvider.future);
  final accounts = await ref.watch(accountsProvider.future);
  final results = <UnifiedMessage>[];
  for (final account in accounts) {
    final folders = await repository.getCachedFolders(account.id!);
    for (final folder in folders.where((f) => !f.isLocalOnly)) {
      final messages = await repository.getCachedMessages(folder.id!);
      for (final message in messages) {
        if (_matches(message, trimmed)) {
          results.add(UnifiedMessage(message: message, folder: folder, account: account));
        }
      }
    }
  }
  results.sort((a, b) => b.message.date.compareTo(a.message.date));
  return results;
});
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/providers/search_providers_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/providers/search_providers.dart test/providers/search_providers_test.dart
git commit -m "feat(search): add searchResultsProvider

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: `SearchScreen`

**Files:**
- Create: `lib/screens/search_screen.dart`
- Test: `test/widget/search_screen_test.dart`

**Interfaces:**
- Consumes: `searchResultsProvider` (Task 1), `swipeActionConfigProvider` (`providers/swipe_action_providers.dart`), `SwipeActionConfig` (`models/swipe_action.dart`), `MessageSwipeController` (`widgets/message_swipe_controller.dart`), `EmptyFolderState` (`widgets/empty_folder_state.dart`), `MessageListTile` (`widgets/message_list_tile.dart`), `accountColorFor` (`widgets/account_color.dart`), `MessageDetailScreen` (`screens/message_detail_screen.dart`).
- Produces: `SearchScreen` (`ConsumerStatefulWidget`, no constructor params). Pushed by `FolderViewScreen` and `UnifiedInboxScreen` (Task 3).

- [ ] **Step 1: Write the failing tests**

```dart
// test/widget/search_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:imap_mail/data/repository/mail_repository.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/mail_folder.dart';
import 'package:imap_mail/models/mail_message.dart';
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/models/unified_message.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/repository_providers.dart';
import 'package:imap_mail/providers/search_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/screens/message_detail_screen.dart';
import 'package:imap_mail/screens/search_screen.dart';

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;
  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeSwipeActionConfigNotifier extends SwipeActionConfigNotifier {
  _FakeSwipeActionConfigNotifier(this._initial);
  final SwipeActionConfig _initial;
  @override
  SwipeActionConfig build() => _initial;
}

class MockMailRepository extends Mock implements MailRepository {}

void main() {
  const work = MailAccount(
    id: 1, displayName: 'Work', email: 'work@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'work@example.com',
  );
  const personal = MailAccount(
    id: 2, displayName: 'Personal', email: 'personal@example.com',
    imapHost: 'imap.example.com', imapPort: 993, imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com', smtpPort: 465, smtpSecurity: MailSecurity.ssl,
    username: 'personal@example.com',
  );
  final workInbox = MailFolder(id: 10, accountId: 1, name: 'Inbox', path: 'INBOX', type: MailFolderType.inbox);
  final personalTrash = MailFolder(id: 21, accountId: 2, name: 'Trash', path: 'Trash', type: MailFolderType.trash);
  final workMessage = MailMessage(
    id: 100, folderId: 10, uid: 1, subject: 'Invoice from work', from: 'a@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 20), snippet: 'Hi',
  );
  final personalMessage = MailMessage(
    id: 200, folderId: 21, uid: 1, subject: 'Old invoice', from: 'b@example.com',
    to: 'me@example.com', date: DateTime.utc(2026, 8, 21), snippet: 'Hey',
  );

  setUpAll(() {
    registerFallbackValue(work);
    registerFallbackValue(workInbox);
    registerFallbackValue(workMessage);
  });

  Future<void> pumpSearchScreen(WidgetTester tester, {required List<Override> overrides}) {
    return tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work, personal])),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
        ...overrides,
      ],
      child: const MaterialApp(home: SearchScreen()),
    ));
  }

  testWidgets('shows a prompt instead of results while the query is blank', (tester) async {
    await pumpSearchScreen(tester, overrides: []);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, 'Search mail');
    expect(find.text('Search your mail'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('does not query before the debounce window elapses, and does after', (tester) async {
    var searchCalls = 0;
    await pumpSearchScreen(tester, overrides: [
      searchResultsProvider.overrideWith((ref, query) async {
        searchCalls++;
        return const [];
      }),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 100));
    expect(searchCalls, 0);

    await tester.pump(const Duration(milliseconds: 250)); // now past the 300ms debounce
    expect(searchCalls, 1);
  });

  testWidgets('shows a "no results" state for a query that matches nothing', (tester) async {
    await pumpSearchScreen(tester, overrides: [
      searchResultsProvider.overrideWith((ref, query) async => const []),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nothing matches this');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('No results for "nothing matches this"'), findsOneWidget);
  });

  testWidgets('renders matching results from every account, newest first', (tester) async {
    await pumpSearchScreen(tester, overrides: [
      searchResultsProvider.overrideWith((ref, query) async => [
            UnifiedMessage(message: personalMessage, folder: personalTrash, account: personal),
            UnifiedMessage(message: workMessage, folder: workInbox, account: work),
          ]),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles[0].title as Text).data, 'Old invoice'); // newest first
    expect((tiles[1].title as Text).data, 'Invoice from work');
  });

  testWidgets(
      "tapping a result opens MessageDetailScreen with THAT result's own folder/message, "
      'not a fixed one', (tester) async {
    await pumpSearchScreen(tester, overrides: [
      searchResultsProvider.overrideWith((ref, query) async => [
            UnifiedMessage(message: personalMessage, folder: personalTrash, account: personal),
          ]),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old invoice'));
    // Deliberately a single pump, not pumpAndSettle: MessageDetailScreen's
    // own body-fetch (repository.fetchBodyIfNeeded/getAttachments) isn't
    // stubbed here — this test only cares about which folder/message it was
    // pushed with, which is already decided by the time the route builds.
    await tester.pump();

    final pushed = tester.widget<MessageDetailScreen>(find.byType(MessageDetailScreen));
    expect(pushed.folder, personalTrash);
    expect(pushed.message, personalMessage);
  });

  testWidgets(
      "swipe-delete on a result calls deleteMessage against that result's own account/folder "
      'and removes the row', (tester) async {
    final repository = MockMailRepository();
    final deletedMessage = personalMessage.copyWith(folderId: 999);
    var deleted = false;
    when(() => repository.deleteMessage(personal, personalTrash, personalMessage)).thenAnswer((_) async {
      deleted = true;
      return deletedMessage;
    });
    when(() => repository.getCachedMessages(any())).thenAnswer((_) async => [deletedMessage]);

    await pumpSearchScreen(tester, overrides: [
      mailRepositoryProvider.overrideWith((ref) async => repository),
      searchResultsProvider.overrideWith((ref, query) async => deleted
          ? const []
          : [UnifiedMessage(message: personalMessage, folder: personalTrash, account: personal)]),
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'invoice');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.timedDrag(find.text('Old invoice'), const Offset(-700, 0), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    verify(() => repository.deleteMessage(personal, personalTrash, personalMessage)).called(1);
    expect(find.text('Old invoice'), findsNothing);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/search_screen_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'imap_mail/screens/search_screen.dart'` (file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

```dart
// lib/screens/search_screen.dart
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/widget/search_screen_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/screens/search_screen.dart test/widget/search_screen_test.dart
git commit -m "feat(search): add SearchScreen with debounced global search and swipe actions

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: Wire up entry points

**Files:**
- Modify: `lib/screens/folder_view_screen.dart` (imports; `AppBar.actions`)
- Modify: `lib/screens/unified_inbox_screen.dart` (imports; `AppBar`)
- Modify: `test/widget/folder_view_screen_test.dart` (add one test)
- Modify: `test/widget/unified_inbox_screen_test.dart` (add one test)
- Modify: `README.md` (drop the now-stale "no search" non-goal, add a features bullet)

**Interfaces:**
- Consumes: `SearchScreen` (Task 2).

- [ ] **Step 1: Add the failing tests**

Append to `test/widget/folder_view_screen_test.dart` (add `import 'package:imap_mail/screens/search_screen.dart';` alongside its existing imports; reuses the file's existing `account`/`accountId`/`inbox`/`sent`/`trash`/`archive` fixtures and `_FakeAccountsNotifier`/`_FakeSwipeActionConfigNotifier`):

```dart
  testWidgets('the app bar search icon opens SearchScreen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        foldersProvider.overrideWith((ref, id) async => [inbox, sent, trash, archive]),
        messagesProvider.overrideWith((ref, folder) async => const []),
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: FolderViewScreen(accountId: accountId)),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.byType(SearchScreen), findsOneWidget);
  });
```

Append to `test/widget/unified_inbox_screen_test.dart` (add `import 'package:imap_mail/screens/search_screen.dart';` alongside its existing imports; reuses the file's existing `work` fixture and `_FakeAccountsNotifier`/`_FakeSwipeActionConfigNotifier`):

```dart
  testWidgets('the app bar search icon opens SearchScreen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([work])),
        unifiedInboxProvider.overrideWith((ref) async => []),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: UnifiedInboxScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.byType(SearchScreen), findsOneWidget);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/widget/folder_view_screen_test.dart test/widget/unified_inbox_screen_test.dart`
Expected: FAIL — both new tests fail with "no icon matching Icons.search found" (there is no search icon in either app bar yet). Every other case in both files stays green.

- [ ] **Step 3: Add the search icon to `FolderViewScreen`**

In `lib/screens/folder_view_screen.dart`, add the import alongside the existing screen imports (alphabetical: after `message_detail_screen.dart`, before `settings_screen.dart`):

```dart
import 'search_screen.dart';
```

Change the `AppBar`:

```dart
      appBar: AppBar(
        title: const Text('Mail'),
        actions: [
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
      ),
```

to:

```dart
      appBar: AppBar(
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
      ),
```

- [ ] **Step 4: Add the search icon to `UnifiedInboxScreen`**

In `lib/screens/unified_inbox_screen.dart`, add the import alongside the existing screen imports (alphabetical: after `compose_screen.dart`, before `message_detail_screen.dart`):

```dart
import 'search_screen.dart';
```

Change:

```dart
    return Scaffold(
      appBar: AppBar(title: const Text('All Inboxes')),
      floatingActionButton: FloatingActionButton(
```

to:

```dart
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Inboxes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
```

- [ ] **Step 5: Update the README**

In `README.md`, remove this line from "## What it deliberately doesn't do (yet)":

```markdown
- No in-app search yet — planned as a fast-follow.
```

And add a bullet to the "### Mail, done properly" list (placed after the "Swipeable triage actions" bullet):

```markdown
- **Global search** — one search box finds a message by subject, sender, or snippet across every folder of every account at once.
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test`
Expected: PASS — the full suite, including the two new tests and every pre-existing case in both modified files.

- [ ] **Step 7: Commit**

```bash
git add lib/screens/folder_view_screen.dart lib/screens/unified_inbox_screen.dart test/widget/folder_view_screen_test.dart test/widget/unified_inbox_screen_test.dart README.md
git commit -m "feat(search): wire a search icon into FolderViewScreen and UnifiedInboxScreen

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## Manual verification (after all tasks land)

Per the spec's Verification section — not automated, run through these on a real build:

- From a single-account setup, search from `FolderViewScreen`'s icon and confirm results include matches from Sent/Trash, not just Inbox.
- Multi-account: search from both `FolderViewScreen` and `UnifiedInboxScreen` and confirm results include matches from every account, not just the one currently in view.
- Swipe-archive and swipe-delete a search result belonging to a non-default account/folder, confirm it affects the correct mailbox.
- Confirm typing quickly doesn't cause visible flicker/lag, and that clearing the field returns to the blank-query prompt.
