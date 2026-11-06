import 'dart:async';

import '../providers/conversations_provider.dart';
import '../utils/app_badge_math.dart';
import '../utils/e2e_diag_log.dart';
import 'badging_bridge_stub.dart'
    if (dart.library.html) 'badging_bridge_web.dart';
import 'push_sw_channel_stub.dart'
    if (dart.library.html) 'push_sw_channel_web.dart';

/// Keeps the PWA app icon badge in sync with [ConversationsProvider.unreadCounts].
///
/// Writes route through the **push SW** (set-badge/clear-badge messages, see
/// web-push-sw.js) so the SW is the single badge writer — its push handler and
/// the app's reads serialize in one worker instead of racing. The window-context
/// Badging API is only a fallback when the push SW is not registered.
///
/// Flushes are gated on [ConversationsProvider.hasLoadedConversations]:
/// before the contact store is read the local unread map is empty, and
/// writing that "0" would wipe a legitimate badge the SW set while the app
/// was closed. After the first read a zero **is** written — clearing stale
/// badges on read is the whole point (the old `_lastSentCapped != null` guard
/// refused to clear badges the SW wrote, which is why stale counts stuck
/// forever).
class UnreadBadgeSync {
  UnreadBadgeSync(
    this._conversations, {
    BadgingBridge? bridge,
    PushSwChannel? channel,
    Duration debounce = const Duration(milliseconds: 200),
  })  : _bridge = bridge ?? createBadgingBridge(),
        _channel = channel ?? createPushSwChannel(),
        _debounce = debounce {
    // Capability marker for on-device triage: Android Chrome has NO Badging
    // API (numeric badges are launcher-rendered notification counts there) —
    // `badgingApi: false` in the diag log proves a missing number is the
    // platform, not a code bug. Visible via Privacy & Safety → E2E diag log.
    E2eDiagLog.add('badge.support', {'badgingApi': _bridge.isSupported});
    _conversations.addListener(_onConversationsChanged);
    _scheduleFlush();
  }

  final ConversationsProvider _conversations;
  final BadgingBridge _bridge;
  final PushSwChannel _channel;
  final Duration _debounce;

  Timer? _debounceTimer;

  void _onConversationsChanged() {
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _flush);
  }

  Future<void> _flush() async {
    _debounceTimer = null;
    if (!_conversations.hasLoadedConversations) return;

    // No value-dedupe: the SW may have written a different value in between
    // (push race), so an "unchanged" local value can still need re-asserting.
    // The debounce already rate-limits writes.
    final raw = sumUnreadBadgeCounts(_conversations.unreadCounts);
    final capped = capUnreadForBadge(raw);

    final delivered = await _channel.postMessage(
      capped == 0
          ? const {'type': 'clear-badge'}
          : {'type': 'set-badge', 'count': capped},
    );
    if (delivered) return;

    if (!_bridge.isSupported) return;
    if (capped == 0) {
      await _bridge.clearBadge();
    } else {
      await _bridge.setBadgeCount(capped);
    }
  }

  /// Stops listening. Does **not** clear the OS badge — closing the PWA (recents swipe)
  /// must not wipe the icon badge while unread remain; badge clears via [_flush] when
  /// unread hits zero, or [clearPwaAppBadgeOnLogout] on logout.
  Future<void> dispose() async {
    _conversations.removeListener(_onConversationsChanged);
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }
}
