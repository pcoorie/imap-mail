import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Sets the OS-level unread-count badge on the app icon. Cosmetic only —
/// every implementation must never throw out of `setCount` and never block
/// the caller on anything beyond what's needed to attempt the update.
abstract class AppIconBadge {
  Future<void> setCount(int count);
}

/// iOS + Android only, per this feature's design spec — badges are
/// meaningless on desktop/web platforms this app also ships to, so this
/// no-ops everywhere else rather than attempting anything.
class PlatformAppIconBadge implements AppIconBadge {
  bool _permissionChecked = false;
  bool _permissionGranted = true; // Android needs no explicit grant for this.

  @override
  Future<void> setCount(int count) async {
    if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
      return;
    }
    try {
      if (!_permissionChecked) {
        _permissionChecked = true;
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          // Badge-setting on iOS is gated behind notification authorization
          // (the `.badge` option specifically). Requested here — lazily, on
          // the first real badge update — rather than at cold start, so a
          // fresh install with zero accounts never sees a permission prompt
          // before it's done anything.
          final status = await Permission.notification.request();
          _permissionGranted = status.isGranted;
        }
      }
      if (!_permissionGranted) return;
      await AppBadgePlus.updateBadge(count);
    } catch (_) {
      // Cosmetic feature: a plugin/platform failure (e.g. an Android
      // launcher with no badge support) must never surface to the user or
      // block anything else in the app.
    }
  }
}
