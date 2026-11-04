import 'package:flutter_test/flutter_test.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/services/badging_bridge_stub.dart';
import 'package:fireplace/services/push_sw_channel_stub.dart';
import 'package:fireplace/services/unread_badge_sync.dart';

/// Provider double — only the two members UnreadBadgeSync reads.
class _FakeConversationsProvider extends ConversationsProvider {
  Map<int, int> fakeUnread = {};
  bool fakeLoadedOnce = false;

  @override
  Map<int, int> get unreadCounts => fakeUnread;

  @override
  bool get hasLoadedConversations => fakeLoadedOnce;

  void poke() => notifyListeners();
}

class _RecordingChannel extends PushSwChannel {
  _RecordingChannel({this.delivered = true});
  final bool delivered;
  final List<Map<String, Object?>> messages = [];

  @override
  Future<bool> postMessage(Map<String, Object?> message) async {
    messages.add(message);
    return delivered;
  }
}

class _RecordingBridge extends BadgingBridge {
  final List<int> setCalls = [];
  int clearCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> setBadgeCount(int cappedNonZero) async {
    setCalls.add(cappedNonZero);
  }

  @override
  Future<void> clearBadge() async {
    clearCalls++;
  }
}

void main() {
  const debounce = Duration(milliseconds: 1);
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  late _FakeConversationsProvider conversations;
  late _RecordingChannel channel;
  late _RecordingBridge bridge;

  setUp(() {
    conversations = _FakeConversationsProvider();
    channel = _RecordingChannel();
    bridge = _RecordingBridge();
  });

  UnreadBadgeSync buildSync({_RecordingChannel? overrideChannel}) =>
      UnreadBadgeSync(
        conversations,
        bridge: bridge,
        channel: overrideChannel ?? channel,
        debounce: debounce,
      );

  test('does not write before the chat list was read (no startup wipe)',
      () async {
    conversations.fakeLoadedOnce = false;
    final sync = buildSync();
    await settle();

    expect(channel.messages, isEmpty);
    expect(bridge.clearCalls, 0);
    expect(bridge.setCalls, isEmpty);
    await sync.dispose();
  });

  test('sends set-badge with capped sum through the push SW channel', () async {
    conversations.fakeLoadedOnce = true;
    conversations.fakeUnread = {1: 2, 2: 3};
    final sync = buildSync();
    await settle();

    expect(channel.messages, [
      {'type': 'set-badge', 'count': 5},
    ]);
    // Delivered via SW — window bridge untouched.
    expect(bridge.setCalls, isEmpty);
    await sync.dispose();
  });

  test('clears a badge it never set itself (stale SW badge regression)',
      () async {
    // App opens with zero local unread while the OS badge still shows an old
    // SW-written count: the first flush after the store was read must send clear.
    conversations.fakeLoadedOnce = true;
    conversations.fakeUnread = {};
    final sync = buildSync();
    await settle();

    expect(channel.messages, [
      {'type': 'clear-badge'},
    ]);
    await sync.dispose();
  });

  test('clears when unread drops to zero after a set', () async {
    conversations.fakeLoadedOnce = true;
    conversations.fakeUnread = {1: 4};
    final sync = buildSync();
    await settle();

    conversations.fakeUnread = {};
    conversations.poke();
    await settle();

    expect(channel.messages.last, {'type': 'clear-badge'});
    await sync.dispose();
  });

  test('falls back to the window Badging API when the push SW is absent',
      () async {
    conversations.fakeLoadedOnce = true;
    conversations.fakeUnread = {1: 7};
    final undelivered = _RecordingChannel(delivered: false);
    final sync = buildSync(overrideChannel: undelivered);
    await settle();

    expect(bridge.setCalls, [7]);

    conversations.fakeUnread = {};
    conversations.poke();
    await settle();

    expect(bridge.clearCalls, 1);
    await sync.dispose();
  });
}
