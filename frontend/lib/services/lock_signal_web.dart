import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'lock_signal.dart';

/// [web-only: retire with §7] Same-origin tabs only; `BroadcastChannel` never
/// delivers to the posting tab, so a received message is always a peer's.
const String _channelName = 'fireplace-passcode-lock';

LockSignal openLockSignal(void Function() onPeerLocked) {
  final web.BroadcastChannel channel;
  try {
    channel = web.BroadcastChannel(_channelName);
  } on Object {
    // No BroadcastChannel (an old WebView): the lock stays per tab, as before.
    return _WebLockSignal(null);
  }
  channel.onmessage = ((web.MessageEvent _) => onPeerLocked()).toJS;
  return _WebLockSignal(channel);
}

class _WebLockSignal implements LockSignal {
  _WebLockSignal(this._channel);

  final web.BroadcastChannel? _channel;

  @override
  void announce() {
    try {
      _channel?.postMessage('lock'.toJS);
    } on Object {
      // Closed channel: nothing to tell.
    }
  }

  @override
  void close() {
    _channel?.close();
  }
}
