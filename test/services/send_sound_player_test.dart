import 'package:flutter_test/flutter_test.dart';
import 'package:imap_mail/services/send_sound_player.dart';

/// just_audio's AudioPlayer needs a real platform channel to do anything —
/// under `flutter test` it can't actually play a sound, so the injectable
/// `playAsset` seam is what lets these tests exercise
/// JustAudioSendSoundPlayer's own logic (which asset it requests, that
/// failures are swallowed) without touching the real player. Same pattern
/// as attachment_opener_test.dart's `openFile` seam.
void main() {
  test('plays the bundled send-swoosh asset', () async {
    String? requestedPath;
    final player = JustAudioSendSoundPlayer(
      playAsset: (path) async => requestedPath = path,
    );

    await player.play();

    expect(requestedPath, 'assets/sounds/send_swoosh.mp3');
  });

  test('never throws even when the underlying player fails '
      '(silent switch, no audio session, missing hardware, ...)', () async {
    final player = JustAudioSendSoundPlayer(
      playAsset: (path) async => throw Exception('no audio session'),
    );

    await expectLater(player.play(), completes);
  });
}
