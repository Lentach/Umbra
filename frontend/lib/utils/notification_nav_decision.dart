/// Pure navigation policy for a consumed notification deep-link in [MainShell].
///
/// Extracted from `MainShell.build()` so the branching (stale id, desktop vs
/// mobile, already-active no-op, tab switch) is unit-testable WITHOUT mounting
/// the full shell — the reason a divergent copy used to live in the test.
/// [MainShell] owns only the imperative glue (setState / Navigator / provider
/// calls); this file owns the decision.
library;

/// What the shell should do with a freshly-consumed notification id.
enum NotificationNavAction {
  /// No navigation: null/raced id, stale (non-local) id, or an already-active
  /// mobile conversation.
  none,

  /// Desktop master/detail: select the conversation in the detail pane.
  setActiveDesktop,

  /// Mobile: replace any open chat route with the target chat.
  pushMobileChat,
}

/// The tab-switch flag plus the navigation action for a notification tap.
class NotificationNavDecision {
  /// Whether to force the shell onto the Conversations tab (index 0). True
  /// whenever a real id was consumed — even a stale one lands on the list.
  final bool switchToConversationsTab;
  final NotificationNavAction action;

  const NotificationNavDecision({
    required this.switchToConversationsTab,
    required this.action,
  });
}

/// True when a pending notification deep-link may be consumed: an id is pending
/// AND the chat list was read from the contact store. Consuming earlier races
/// an empty list (cold start) or mounts a chat for a stale/deleted id.
bool shouldConsumeNotificationNav({
  required int? pendingConversationId,
  required bool hasLoadedConversations,
}) => pendingConversationId != null && hasLoadedConversations;

/// Decide what the shell does with a freshly-consumed notification id.
///
/// [consumedId] is the result of consuming the pending id (null when it was
/// already consumed on a prior rebuild). When non-null the shell always lands
/// on the Conversations tab first; navigation then depends on whether the
/// conversation exists locally, the layout, and the currently-active chat.
NotificationNavDecision decideNotificationNav({
  required int? consumedId,
  required bool conversationExistsLocally,
  required bool isDesktop,
  required bool isAlreadyActive,
}) {
  if (consumedId == null) {
    return const NotificationNavDecision(
      switchToConversationsTab: false,
      action: NotificationNavAction.none,
    );
  }
  // A real id was consumed → land on the Conversations tab regardless.
  if (!conversationExistsLocally) {
    // Stale/deleted id: stay on the list, mount nothing.
    return const NotificationNavDecision(
      switchToConversationsTab: true,
      action: NotificationNavAction.none,
    );
  }
  if (isDesktop) {
    return const NotificationNavDecision(
      switchToConversationsTab: true,
      action: NotificationNavAction.setActiveDesktop,
    );
  }
  if (isAlreadyActive) {
    return const NotificationNavDecision(
      switchToConversationsTab: true,
      action: NotificationNavAction.none,
    );
  }
  return const NotificationNavDecision(
    switchToConversationsTab: true,
    action: NotificationNavAction.pushMobileChat,
  );
}
