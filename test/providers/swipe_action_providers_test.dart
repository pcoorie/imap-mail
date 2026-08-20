import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:imap_mail/models/swipe_action.dart';
import 'package:imap_mail/providers/swipe_action_providers.dart';
import 'package:imap_mail/providers/theme_providers.dart';

/// Builds a container whose [sharedPreferencesProvider] is backed by a freshly
/// mocked, explicitly injected [SharedPreferences] instance.
Future<ProviderContainer> _containerWith(Map<String, Object> initialValues) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  test('defaults to Archive/Flag on the left and Delete/Mark-read-unread on the right', () async {
    final container = await _containerWith({});
    addTearDown(container.dispose);

    final config = container.read(swipeActionConfigProvider);
    expect(config.leftPrimary, SwipeAction.archive);
    expect(config.leftSecondary, SwipeAction.flag);
    expect(config.rightPrimary, SwipeAction.delete);
    expect(config.rightSecondary, SwipeAction.toggleRead);
  });

  test('loads a previously persisted configuration on startup', () async {
    final container = await _containerWith({
      'swipe_left_primary': 'delete',
      'swipe_left_secondary': 'none',
      'swipe_right_primary': 'archive',
      'swipe_right_secondary': 'flag',
    });
    addTearDown(container.dispose);

    // Deliberately no await/pump between build and this read: the first
    // frame must already see the persisted config.
    final config = container.read(swipeActionConfigProvider);
    expect(config.leftPrimary, SwipeAction.delete);
    expect(config.leftSecondary, SwipeAction.none);
    expect(config.rightPrimary, SwipeAction.archive);
    expect(config.rightSecondary, SwipeAction.flag);
  });

  test('an unrecognized persisted value falls back to the default for that slot', () async {
    final container = await _containerWith({
      'swipe_left_primary': 'not-a-real-action',
    });
    addTearDown(container.dispose);

    final config = container.read(swipeActionConfigProvider);
    expect(config.leftPrimary, SwipeAction.archive);
  });

  test('setSlot updates just that slot, persists it, and leaves the rest unchanged', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await container.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.rightSecondary, SwipeAction.none);

    final config = container.read(swipeActionConfigProvider);
    expect(config.rightSecondary, SwipeAction.none);
    expect(config.leftPrimary, SwipeAction.archive);
    expect(prefs.getString('swipe_right_secondary'), 'none');
  });

  test('a fresh notifier backed by an independent SharedPreferences instance '
      'picks up a configuration persisted by a previous one', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs1 = await SharedPreferences.getInstance();
    final container1 = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs1)],
    );
    addTearDown(container1.dispose);
    await container1.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.leftPrimary, SwipeAction.toggleRead);

    // Drop the cached singleton so the second instance genuinely re-reads the
    // underlying store instead of sharing prefs1's in-memory cache.
    SharedPreferences.resetStatic();
    final prefs2 = await SharedPreferences.getInstance();
    expect(identical(prefs1, prefs2), isFalse,
        reason: 'the round-trip must go through a second, independent instance');

    final container2 = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs2)],
    );
    addTearDown(container2.dispose);

    expect(container2.read(swipeActionConfigProvider).leftPrimary, SwipeAction.toggleRead);
  });

  test('setSlot reverts state and rethrows when the write fails', () async {
    final prefs = _WriteFailingPreferences({'swipe_left_primary': 'archive'});
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    expect(container.read(swipeActionConfigProvider).leftPrimary, SwipeAction.archive);

    await expectLater(
      container.read(swipeActionConfigProvider.notifier).setSlot(SwipeSlot.leftPrimary, SwipeAction.delete),
      throwsA(isA<Exception>()),
    );

    // State must not diverge from what actually made it to storage.
    expect(container.read(swipeActionConfigProvider).leftPrimary, SwipeAction.archive);
  });
}

/// A [SharedPreferences] whose writes always fail, to exercise the
/// revert-on-failure path. Only the members the notifier touches are
/// implemented; anything else throws via [noSuchMethod].
class _WriteFailingPreferences implements SharedPreferences {
  _WriteFailingPreferences(this._values);

  final Map<String, String> _values;

  @override
  String? getString(String key) => _values[key];

  @override
  Future<bool> setString(String key, String value) async {
    throw Exception('simulated storage failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
