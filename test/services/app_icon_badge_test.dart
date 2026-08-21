import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/services/app_icon_badge.dart';
import 'package:permission_handler/permission_handler.dart';

/// Exercises `PlatformAppIconBadge`'s iOS permission-gating state machine
/// directly — the provider-level tests in
/// `test/providers/badge_providers_test.dart` use a fake `AppIconBadge` and
/// never touch this logic at all.
///
/// There is no real iOS platform channel available in a `flutter test` unit
/// test, so `PlatformAppIconBadge` exposes an injectable
/// `requestNotificationPermission` seam used only here; production code
/// never supplies it and gets the real `Permission.notification.request()`
/// call. `defaultTargetPlatform` is forced via
/// `debugDefaultTargetPlatformOverride`, which is the standard Flutter test
/// mechanism for exercising platform-specific branches from a host test
/// runner.
void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('iOS', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });

    test('setCount(0) as the very first call ever does NOT request notification permission', () async {
      var requestCount = 0;
      final badge = PlatformAppIconBadge(
        requestNotificationPermission: () async {
          requestCount++;
          return PermissionStatus.granted;
        },
      );

      await badge.setCount(0);

      expect(requestCount, 0, reason: 'a zero count must never be the trigger for the iOS permission prompt');
    });

    test('repeated setCount(0) calls never request permission until a nonzero count arrives', () async {
      var requestCount = 0;
      final badge = PlatformAppIconBadge(
        requestNotificationPermission: () async {
          requestCount++;
          return PermissionStatus.granted;
        },
      );

      await badge.setCount(0);
      await badge.setCount(0);
      await badge.setCount(0);
      expect(requestCount, 0);

      await badge.setCount(5);
      expect(requestCount, 1, reason: 'the first nonzero count should lazily trigger exactly one permission request');

      await badge.setCount(0);
      await badge.setCount(3);
      expect(requestCount, 1, reason: 'once checked, the cached decision must not be re-requested by later calls of either kind');
    });

    test('a cached denial is not re-prompted by a later zero count', () async {
      var requestCount = 0;
      final badge = PlatformAppIconBadge(
        requestNotificationPermission: () async {
          requestCount++;
          return PermissionStatus.denied;
        },
      );

      await badge.setCount(7); // triggers the one real permission decision: denied
      expect(requestCount, 1);

      await badge.setCount(0);
      await badge.setCount(2);
      expect(requestCount, 1, reason: 'a cached denial must silently no-op forever, never re-prompting');
    });
  });

  group('Android', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    test('never requests notification permission, for any count, since Android has no such gate', () async {
      var requestCount = 0;
      final badge = PlatformAppIconBadge(
        requestNotificationPermission: () async {
          requestCount++;
          return PermissionStatus.granted;
        },
      );

      await badge.setCount(0);
      await badge.setCount(5);
      await badge.setCount(0);

      expect(requestCount, 0, reason: "Android's badge path must be completely unaffected by the iOS permission gate");
    });
  });
}
