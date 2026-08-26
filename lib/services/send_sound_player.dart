import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Plays the short "swoosh" sound effect on a successful send — a small
/// piece of UI polish, not part of the send operation itself.
abstract class SendSoundPlayer {
  /// Never throws: a sound failing to play (silent switch, no audio
  /// session, an environment with no audio hardware, ...) must never
  /// surface as a send error or block the send flow.
  Future<void> play();
}

class JustAudioSendSoundPlayer implements SendSoundPlayer {
  /// [playAsset] is an injectable seam for tests — it defaults to the real
  /// just_audio playback below and should never be supplied in production
  /// code. Mirrors PlatformAttachmentOpener's `openFile` seam: just_audio's
  /// AudioPlayer needs a real platform channel to do anything, so a widget
  /// test can't exercise this class's actual logic through it directly.
  JustAudioSendSoundPlayer({Future<void> Function(String assetPath)? playAsset})
      : _playAsset = playAsset ?? _playViaJustAudio;

  final Future<void> Function(String assetPath) _playAsset;

  static const _assetPath = 'assets/sounds/send_swoosh.mp3';

  static Future<void> _playViaJustAudio(String assetPath) async {
    final player = AudioPlayer();
    try {
      await player.setAsset(assetPath);
      await player.play();
    } finally {
      // Fire-and-forget: disposal failing (or taking a moment) shouldn't
      // hold up whatever awaited play() above.
      unawaited(player.dispose());
    }
  }

  @override
  Future<void> play() async {
    try {
      await _playAsset(_assetPath);
    } catch (_) {
      // See the class doc comment — deliberately swallowed.
    }
  }
}
