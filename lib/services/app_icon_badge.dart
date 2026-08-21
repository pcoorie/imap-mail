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
  /// [requestNotificationPermission] is an injectable seam for tests — it
  /// defaults to the real `permission_handler` call and should never be
  /// supplied in production code. Public production behavior is unchanged
  /// by this parameter existing.
  PlatformAppIconBadge({Future<PermissionStatus> Function()? requestNotificationPermission})
    : _requestNotificationPermission = requestNotificationPermission ?? (() => Permission.notification.request());

  final Future<PermissionStatus> Function() _requestNotificationPermission;

  bool _permissionChecked = false;
  bool _permissionGranted = true; // Android needs no explicit grant for this.

  @override
  Future<void> setCount(int count) async {
    if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
      return;
    }
    try {
      // Only a nonzero count is allowed to trigger the (one-time) iOS
      // permission check. A `0` count must never be the thing that pops the
      // authorization prompt — per the design spec, the very first badge
      // update a fresh install with zero accounts sees is `setCount(0)`
      // (an empty local-DB query resolving instantly at cold start), and
      // that must stay silent. Once a real nonzero count has triggered a
      // genuine permission decision, `_permissionChecked` latches true and
      // that decision (granted or denied) is cached for every later call,
      // including subsequent `0`s — no re-prompting.
      if (!_permissionChecked && count > 0) {
        _permissionChecked = true;
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          // Badge-setting on iOS is gated behind notification authorization
          // (the `.badge` option specifically). Requested here — lazily, on
          // the first real (nonzero) badge update — rather than at cold
          // start, so a fresh install with zero accounts never sees a
          // permission prompt before it's done anything.
          final status = await _requestNotificationPermission();
          _permissionGranted = status.isGranted;
        }
      }
      if (!_permissionGranted) return;
      // Reached with permission either granted, cached-granted, or not yet
      // checked at all (a `0` count before any nonzero count has ever been
      // seen — `_permissionGranted` still holds its optimistic default).
      // Calling `updateBadge(0)` in that last case is harmless: it's the
      // same no-op-if-unauthorized outcome iOS would give a real permission
      // check, without popping a prompt to find out.
      await AppBadgePlus.updateBadge(count);
    } catch (_) {
      // Cosmetic feature: a plugin/platform failure (e.g. an Android
      // launcher with no badge support) must never surface to the user or
      // block anything else in the app.
    }
  }
}
