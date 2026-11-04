import 'package:fireplace/utils/notification_nav_decision.dart';
import 'package:flutter_test/flutter_test.dart';

/// Notification-navigation POLICY for MainShell.
///
/// These drive the SAME pure functions `MainShell.build()` calls
/// (`shouldConsumeNotificationNav` + `decideNotificationNav`), so every branch
/// is exercised against the real production logic: the first-snapshot gate,
/// the always-land-on-the-list tab switch, a stale id, desktop vs mobile, and
/// the mobile already-active no-op.
///
/// This replaces a hand-written `_NotificationNavHost` widget replica that had
/// already DIVERGED from MainShell — it omitted the `_selectedIndex = 0` tab
/// switch and the entire desktop `setActiveConversation` branch, so two of the
/// four real branches were never covered. The remaining glue in MainShell
/// (setState / Navigator.pushAndRemoveUntil / setActiveConversation) is thin
/// and device-proven.
void main() {
  group('shouldConsumeNotificationNav (contact-store gate)', () {
    test('does not consume when no id is pending', () {
      expect(
        shouldConsumeNotificationNav(
          pendingConversationId: null,
          hasLoadedConversations: true,
        ),
        isFalse,
      );
    });

    test('does not consume before the chat list was read', () {
      // Cold start: a tap arriving before the store was read would otherwise
      // mount a chat for an unverified id (empty screen, dead send).
      expect(
        shouldConsumeNotificationNav(
          pendingConversationId: 3,
          hasLoadedConversations: false,
        ),
        isFalse,
      );
    });

    test('consumes once an id is pending AND the list was read', () {
      expect(
        shouldConsumeNotificationNav(
          pendingConversationId: 3,
          hasLoadedConversations: true,
        ),
        isTrue,
      );
    });
  });

  group('decideNotificationNav', () {
    test('null consumed id (already consumed/raced): no tab switch, no nav', () {
      final d = decideNotificationNav(
        consumedId: null,
        conversationExistsLocally: false,
        isDesktop: false,
        isAlreadyActive: false,
      );
      expect(d.switchToConversationsTab, isFalse);
      expect(d.action, NotificationNavAction.none);
    });

    test('stale id (not in local list): switches to list, mounts nothing', () {
      final d = decideNotificationNav(
        consumedId: 99,
        conversationExistsLocally: false,
        isDesktop: false,
        isAlreadyActive: false,
      );
      expect(d.switchToConversationsTab, isTrue);
      expect(d.action, NotificationNavAction.none);
    });

    test('desktop + existing conv: switches to list and sets the active pane',
        () {
      final d = decideNotificationNav(
        consumedId: 2,
        conversationExistsLocally: true,
        isDesktop: true,
        isAlreadyActive: false,
      );
      expect(d.switchToConversationsTab, isTrue);
      expect(d.action, NotificationNavAction.setActiveDesktop);
    });

    test('desktop sets the active pane even when already active', () {
      // Mirrors MainShell: the desktop branch calls setActiveConversation
      // unconditionally (no already-active short-circuit, unlike mobile).
      final d = decideNotificationNav(
        consumedId: 2,
        conversationExistsLocally: true,
        isDesktop: true,
        isAlreadyActive: true,
      );
      expect(d.action, NotificationNavAction.setActiveDesktop);
    });

    test('mobile + new conv: switches to list and pushes the chat route', () {
      final d = decideNotificationNav(
        consumedId: 2,
        conversationExistsLocally: true,
        isDesktop: false,
        isAlreadyActive: false,
      );
      expect(d.switchToConversationsTab, isTrue);
      expect(d.action, NotificationNavAction.pushMobileChat);
    });

    test('mobile + already-active conv: switches to list but does not re-push',
        () {
      final d = decideNotificationNav(
        consumedId: 5,
        conversationExistsLocally: true,
        isDesktop: false,
        isAlreadyActive: true,
      );
      expect(d.switchToConversationsTab, isTrue);
      expect(d.action, NotificationNavAction.none);
    });
  });
}
