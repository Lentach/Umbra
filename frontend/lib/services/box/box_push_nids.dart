import 'dart:async';

import '../contacts/contact_record.dart';
import '../contacts/contact_store.dart';
import 'box_push_nids_stub.dart'
    if (dart.library.html) 'box_push_nids_web.dart';

/// Where [BoxPushNids] puts the table: the platform sink by default.
typedef BoxPushNidsSink = Future<void> Function(Map<String, int> table);

/// The one thing the push service worker needs to turn a box wake-up into a
/// card for the right chat (owner decisions 77, 78): which chat each of this
/// device's contact queues belongs to, by nid. The worker runs while the app
/// is closed and holds no key, so the page leaves the table where both can
/// read it (web: IndexedDB `fireplace-push`, `box-nids`; nothing elsewhere —
/// the native app is woken by FCM, which carries no nid).
///
/// Chat NUMBERS only — never a name, never a state. It is plain storage,
/// readable without the passcode; that residual is decision 77's. Removed on
/// logout and account switch ([clearBoxPushNids]).
///
/// The table is every queue of every contact that can still be written to
/// (not `blocked`, not `former`), so a wake-up for a queue whose notifier is
/// already active finds its chat. It is written whole, only when it changed.
class BoxPushNids {
  BoxPushNids({required ContactStore store, BoxPushNidsSink? sink})
    : _store = store,
      _sink = sink ?? writeBoxPushNids;

  final ContactStore _store;
  final BoxPushNidsSink _sink;

  /// The last table handed to the sink and not known to have failed.
  Map<String, int>? _written;

  /// Writes land in the order they were asked.
  Future<void> _tail = Future<void>.value();

  /// Removes the table (and the worker's wake-up counts): logout and account
  /// switch, so another account is never shown this one's chats.
  static Future<void> clear() => clearBoxPushNids();

  /// The table [records] imply.
  static Map<String, int> tableOf(Iterable<ContactRecord> records) => {
    for (final record in records)
      if (record.state != ContactState.blocked &&
          record.state != ContactState.former)
        if (record.chatId case final int chat)
          for (final queue in record.queues) queue.nid: chat,
  };

  /// Writes the table if it differs from the last one written.
  void sync() {
    if (!_store.isOpen) return;
    final table = tableOf(_store.all);
    if (_same(table, _written)) return;
    _written = table;
    _tail = _tail.then((_) async {
      try {
        await _sink(table);
      } on Object {
        // Asked again by the next trigger.
        if (identical(_written, table)) _written = null;
      }
    });
  }

  static bool _same(Map<String, int> a, Map<String, int>? b) {
    if (b == null || a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (b[key] != value) return false;
    }
    return true;
  }
}
