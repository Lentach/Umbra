import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

const String _kPingAsset = 'assets/sounds/ping_alert.wav';

web.AudioContext? _ctx;
web.AudioBuffer? _buffer;
JSFunction? _unlockListener;

web.AudioContext _context() => _ctx ??= web.AudioContext();

/// Installs a permanent gesture listener that resumes the [web.AudioContext].
///
/// On iOS the context starts `suspended` and only produces sound once it has
/// been `resume()`d from inside a real user gesture. Pings fire on message
/// receipt (no gesture), so we resume on the first gesture after this is
/// installed — by which point an actively-chatting user has tapped/scrolled.
/// Idempotent; the listener stays installed (a `resume()` on an already-running
/// context is a harmless no-op, and a later OS-driven suspend re-unlocks).
void primePingSound() {
  if (_unlockListener != null) return;
  // Resume on EVERY gesture (cheap: resume() on an already-running context is a
  // no-op, so we only call it when not running). This self-heals after an iOS
  // suspend or `interrupted` (phone call, Siri, another app grabbing audio) —
  // `interrupted` can only be cleared by a user gesture, so a one-shot latch
  // would permanently silence the ping after the first interruption.
  void unlock(web.Event _) {
    final ctx = _context();
    if (ctx.state != 'running') ctx.resume().toDart.ignore();
  }

  final listener = unlock.toJS;
  _unlockListener = listener;
  final opts = web.AddEventListenerOptions(passive: true);
  web.window.addEventListener('pointerdown', listener, opts);
  web.window.addEventListener('touchend', listener, opts);
  web.window.addEventListener('mousedown', listener, opts);
  web.window.addEventListener('keydown', listener, opts);
}

/// Plays the ping alert once via the Web Audio API.
///
/// An `AudioBufferSourceNode` registers no MediaSession (unlike an HTML
/// `<audio>` element), so iOS Safari shows no media-control card for the ping.
Future<void> playPingSound() async {
  try {
    primePingSound();
    final ctx = _context();
    if (ctx.state != 'running') {
      try {
        await ctx.resume().toDart;
      } catch (_) {
        // May stay suspended until a user gesture — best effort.
      }
    }
    final buffer = _buffer ??= await _decodePing(ctx);
    final source = web.AudioBufferSourceNode(
      ctx,
      web.AudioBufferSourceOptions(buffer: buffer),
    );
    source.connect(ctx.destination);
    source.start();
  } catch (_) {
    // Best-effort sound effect — never surface playback failures.
  }
}

Future<web.AudioBuffer> _decodePing(web.AudioContext ctx) async {
  final data = await rootBundle.load(_kPingAsset);
  // Copy into a standalone buffer: rootBundle may return a view into a larger
  // backing store, and decodeAudioData consumes the whole ArrayBuffer.
  final bytes = Uint8List.fromList(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
  return await ctx.decodeAudioData(bytes.buffer.toJS).toDart;
}
