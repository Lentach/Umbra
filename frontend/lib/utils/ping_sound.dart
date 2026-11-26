import 'ping_sound_stub.dart'
    if (dart.library.js_interop) 'ping_sound_web.dart' as impl;

/// Plays the PING alert sound once.
///
/// **Web:** routed through the Web Audio API (a decoded [AudioBuffer] played via
/// a transient `AudioBufferSourceNode`) so it registers **no MediaSession**. An
/// HTML `<audio>` element — what `just_audio` (`just_audio_web`) uses — registers
/// a MediaSession on play, which on iOS Safari leaves a stale, un-startable
/// media-control card in Control Center / the lock screen for this one-shot
/// sound. Web Audio is the standard pattern for short sound effects and avoids
/// the card entirely.
///
/// **Native:** unchanged — plays via `just_audio`.
///
/// Best-effort: playback failures are swallowed so a sound effect can never
/// surface as an error in the chat UI.
Future<void> playPingSound() => impl.playPingSound();

/// Warms up web ping playback so a later ping can actually produce sound.
///
/// On iOS an `AudioContext` starts `suspended` and only begins producing sound
/// once `resume()`d from inside a real user gesture. A ping fires on message
/// receipt — not during a gesture — so this installs a one-shot gesture
/// listener that unlocks the context. Call when a screen that can show a ping
/// opens. No-op off web.
void primePingSound() => impl.primePingSound();
