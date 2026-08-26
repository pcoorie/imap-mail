import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/send_sound_player.dart';

final sendSoundPlayerProvider = Provider<SendSoundPlayer>((ref) => JustAudioSendSoundPlayer());
