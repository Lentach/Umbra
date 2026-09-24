import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays the local "incoming message" sound effect.
///
/// Extracted from `MessagingProvider`: owns the lazy [AudioPlayer] and the
/// enabled flag, and holds no message state — so it can be tested in isolation.
class IncomingMessageSoundService {
  static const String _asset = 'assets/sounds/incoming_message_long_pop.wav';

  AudioPlayer? _player;
  bool _enabled = true;

  @visibleForTesting
  bool get enabled => _enabled;

  int _requests = 0;

  /// How many times [play] was asked for, enabled or not — what a test can
  /// observe of the "which messages sound" rule. Not `@visibleForTesting`
  /// for the [setEnabledForTest] reason: the provider's test hook reads it.
  int get requests => _requests;

  /// Toggles the incoming-sound effect. Named `...ForTest` because the only
  /// caller is `MessagingProvider.setIncomingMessageSoundEnabledForTest`, the
  /// provider's test hook — so it is not annotated `@visibleForTesting`
  /// (that would flag the provider's own lib-side delegation call).
  void setEnabledForTest(bool enabled) {
    _enabled = enabled;
  }

  Future<void> play() async {
    _requests++;
    if (kIsWeb || !_enabled) return;
    try {
      _player ??= AudioPlayer();
      final player = _player!;
      if (player.audioSource == null) {
        await player.setAsset(_asset);
      }
      await player.seek(Duration.zero);
      await player.play();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[IncomingMessageSoundService] play failed: $e');
      }
    }
  }

  void dispose() {
    _player?.dispose().ignore();
    _player = null;
  }
}
