/// Application-wide constants. Prefer these over magic numbers.
class AppConstants {
  AppConstants._();

  /// Layout breakpoint: width >= this = desktop (master-detail), below = mobile (stacked)
  static const double layoutBreakpointDesktop = 600;

  /// Shortest logical side below this → show rotate overlay in landscape (phones/tablets).
  static const double portraitLockMaxShortestSide = 900;

  /// Delay before re-fetching conversations on connect (handles slow initial response)
  static const Duration conversationsRefreshDelay = Duration(milliseconds: 500);

  /// Default number of messages loaded per page
  static const int messagePageSize = 50;

  /// Max UTF-8 byte size of the JSON-encoded E2E envelope for a sendable
  /// message, checked by the composer (`isMessageWithinByteLimit`) in EVERY
  /// chat. Sized so the longest text it accepts, with a link preview and the
  /// send path's metadata, still fits ONE box frame as a first (PreKey)
  /// message (`BoxFrame.maxSignalBytes`, 16 315 B; pinned by
  /// `box_frame_test.dart`): the box never truncates, it refuses. One limit
  /// for every chat, so it does not shrink the day a contact moves to the
  /// box (metadata-privacy PR3.1 slice (c), decision 18). Budgeting the
  /// ENVELOPE bytes accounts for JSON escaping and multi-byte emoji.
  static const int maxEnvelopeBytes = 14000;

  /// A TEXT message longer than this many wrapped lines collapses in the chat
  /// bubble behind a "Read more" toggle so one long message cannot fill the
  /// screen (Telegram-parity). Tapping expands to the full text.
  static const int maxCollapsedMessageLines = 12;

  /// WebSocket reconnection
  static const int reconnectMaxAttempts = 5;
  static const Duration reconnectInitialDelay = Duration(seconds: 1);
  static const Duration reconnectMaxDelay = Duration(seconds: 30);

  /// Minimum spacing between full [ConnectionProvider.connect] calls (PWA reconnect storms).
  static const Duration reconnectConnectCooldown = Duration(seconds: 2);
}
