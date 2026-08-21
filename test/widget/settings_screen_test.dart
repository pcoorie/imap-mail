import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/models/enums.dart';
import 'package:imap_mail/models/mail_account.dart';
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/providers/account_providers.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/providers/theme_providers.dart';
import 'package:imap_mail/screens/account_form_screen.dart';
import 'package:imap_mail/screens/settings_screen.dart';

void main() {
  const account = MailAccount(
    id: 1,
    displayName: 'Work',
    email: 'me@example.com',
    imapHost: 'imap.example.com',
    imapPort: 993,
    imapSecurity: MailSecurity.ssl,
    smtpHost: 'smtp.example.com',
    smtpPort: 465,
    smtpSecurity: MailSecurity.ssl,
    username: 'me@example.com',
  );

  testWidgets('tapping Remove shows a confirmation dialog', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => _FakeThemeModeNotifier(ThemeMode.system)),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('Remove this account?'), findsOneWidget);
  });

  testWidgets('an Add account icon opens AccountFormScreen in add mode — the only path there once single-account routing skips AccountListScreen entirely', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => _FakeThemeModeNotifier(ThemeMode.system)),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final form = tester.widget<AccountFormScreen>(find.byType(AccountFormScreen));
    expect(form.existing, isNull);
  });

  testWidgets('theme segmented control reflects the current mode and calls setThemeMode on change', (tester) async {
    final fakeNotifier = _FakeThemeModeNotifier(ThemeMode.dark);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => fakeNotifier),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    final segmented = tester.widget<SegmentedButton<ThemeMode>>(
      find.byType(SegmentedButton<ThemeMode>),
    );
    expect(segmented.selected, {ThemeMode.dark});

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(fakeNotifier.state, ThemeMode.light);
  });

  testWidgets('theme picker fits a phone-width screen with every segment tappable', (tester) async {
    // flutter_test's default 800x600 surface hides layout overflow that every
    // real phone would hit, so pin the surface to a common phone size.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fakeNotifier = _FakeThemeModeNotifier(ThemeMode.light);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => fakeNotifier),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    // A RenderFlex overflow during layout surfaces here.
    expect(tester.takeException(), isNull);

    // Every segment must be laid out inside the viewport and hit-testable.
    for (final label in ['Light', 'Dark', 'System']) {
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: '"$label" segment should be present');
      final rect = tester.getRect(finder);
      expect(
        rect.right,
        lessThanOrEqualTo(390.0),
        reason: '"$label" segment must not render past the right screen edge',
      );
      expect(rect.left, greaterThanOrEqualTo(0.0), reason: '"$label" segment must not render off the left edge');
    }

    // Tap through more than just "Light" — "System" is the default and the one
    // that used to be pushed off-screen.
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(fakeNotifier.state, ThemeMode.system);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(fakeNotifier.state, ThemeMode.dark);

    expect(tester.takeException(), isNull);
  });

  testWidgets('theme picker also fits the narrowest common phone width', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => _FakeThemeModeNotifier(ThemeMode.system)),
        swipeActionConfigProvider.overrideWith(() => _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults)),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final label in ['Light', 'Dark', 'System']) {
      expect(tester.getRect(find.text(label)).right, lessThanOrEqualTo(320.0));
    }
  });

  testWidgets('swipe action dropdowns reflect the current config and call setSlot on change', (tester) async {
    final fakeSwipeNotifier = _FakeSwipeActionConfigNotifier(SwipeActionConfig.defaults);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        accountsProvider.overrideWith(() => _FakeAccountsNotifier([account])),
        themeModeProvider.overrideWith(() => _FakeThemeModeNotifier(ThemeMode.system)),
        swipeActionConfigProvider.overrideWith(() => fakeSwipeNotifier),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButton<SwipeAction>), findsNWidgets(4));

    final leftPrimaryDropdown = tester.widget<DropdownButton<SwipeAction>>(
      find.byKey(const ValueKey('swipe_left_primary_dropdown')),
    );
    expect(leftPrimaryDropdown.value, SwipeAction.archive);

    await tester.tap(find.byKey(const ValueKey('swipe_left_primary_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(fakeSwipeNotifier.state.leftPrimary, SwipeAction.delete);
  });
}

class _FakeAccountsNotifier extends AccountsNotifier {
  _FakeAccountsNotifier(this._accounts);
  final List<MailAccount> _accounts;

  @override
  Future<List<MailAccount>> build() async => _accounts;
}

class _FakeThemeModeNotifier extends ThemeModeNotifier {
  _FakeThemeModeNotifier(this._initial);
  final ThemeMode _initial;

  @override
  ThemeMode build() => _initial;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
  }
}

class _FakeSwipeActionConfigNotifier extends SwipeActionConfigNotifier {
  _FakeSwipeActionConfigNotifier(this._initial);
  final SwipeActionConfig _initial;

  @override
  SwipeActionConfig build() => _initial;

  @override
  Future<void> setSlot(SwipeSlot slot, SwipeAction action) async {
    state = state.withSlot(slot, action);
  }
}
