import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/swipe_action.dart';
import 'theme_providers.dart';

const _keys = {
  SwipeSlot.leftPrimary: 'swipe_left_primary',
  SwipeSlot.leftSecondary: 'swipe_left_secondary',
  SwipeSlot.rightPrimary: 'swipe_right_primary',
  SwipeSlot.rightSecondary: 'swipe_right_secondary',
};

class SwipeActionConfigNotifier extends Notifier<SwipeActionConfig> {
  @override
  SwipeActionConfig build() {
    // Synchronous by design: the preference is already in memory (loaded via
    // sharedPreferencesProvider, preloaded in main() before the first frame),
    // so frame 1 renders the user's real configuration instead of flashing
    // the defaults. See ThemeModeNotifier for the established pattern.
    final prefs = ref.watch(sharedPreferencesProvider);
    return SwipeActionConfig(
      leftPrimary: _fromName(prefs.getString(_keys[SwipeSlot.leftPrimary]!)) ??
          SwipeActionConfig.defaults.leftPrimary,
      leftSecondary: _fromName(prefs.getString(_keys[SwipeSlot.leftSecondary]!)) ??
          SwipeActionConfig.defaults.leftSecondary,
      rightPrimary: _fromName(prefs.getString(_keys[SwipeSlot.rightPrimary]!)) ??
          SwipeActionConfig.defaults.rightPrimary,
      rightSecondary: _fromName(prefs.getString(_keys[SwipeSlot.rightSecondary]!)) ??
          SwipeActionConfig.defaults.rightSecondary,
    );
  }

  Future<void> setSlot(SwipeSlot slot, SwipeAction action) async {
    final previous = state;
    state = state.withSlot(slot, action);
    try {
      await ref.read(sharedPreferencesProvider).setString(_keys[slot]!, action.name);
    } catch (_) {
      // Don't let in-memory state diverge from what's actually stored.
      state = previous;
      rethrow;
    }
  }

  SwipeAction? _fromName(String? name) {
    if (name == null) return null;
    return SwipeAction.values.firstWhereOrNull((a) => a.name == name);
  }
}

final swipeActionConfigProvider = NotifierProvider<SwipeActionConfigNotifier, SwipeActionConfig>(
  SwipeActionConfigNotifier.new,
);
