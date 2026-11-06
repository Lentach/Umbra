// The peer-identity alarm row must be reachable in an EMPTY conversation.
//
// It was not. `_buildMessagesArea` gated the whole timeline on
// `messages.isEmpty` and rendered the row ONLY inside the `ListView.builder`
// of the non-empty branch, so `identityRowOffset` was computed and then
// discarded. The single machine-in-the-middle warning this product has was
// therefore suppressed in exactly the conversations most likely to be empty:
// cleared history, fully expired history, a conversation deleted and refriended,
// or a peer who reset before the first message — and the server
// `peerIdentityChanged` event (connection_provider.dart -> 
// recordPeerIdentityChangedFromServer) raises the warning with NO local message
// required, so the empty chat is not a corner case.
//
// SCOPE OF THIS FILE: the SCREEN's render decision only. A fake provider is
// used deliberately here, because the production chain that SETS this state
// (store -> service callback -> provider notifyListeners) is proven separately
// against real objects in
// `test/providers/encryption_provider_identity_alarm_test.dart`. Faking it in
// both places is what left this hole unguarded.

import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/auth_provider.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/providers/friends_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/screens/chat_detail_screen.dart';
import 'package:fireplace/theme/rpg_theme.dart';
import 'package:fireplace/widgets/glass/glass_top_bar.dart';
import 'package:fireplace/widgets/peer_identity_changed_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/chat_seed.dart';

const _currentUserJwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInVzZXJuYW1lIjoiYWxpY2UiLCJ0YWciOiIwMDAxIiwiZXhwIjo5OTk5OTk5OTl9.abc';

/// The peer of conversation 10. `otherUser` resolves to this id, which is what
/// `peersWithChangedIdentity` is checked against.
const _peerId = 2;

class _AlarmedEncryption extends EncryptionProvider {
  _AlarmedEncryption({
    this.changedPeers = const <int>{},
    Map<int, String> notedPeers = const <int, String>{},
    this.refusedPeers = const <int>{},
  }) : notedPeers = Map<int, String>.of(notedPeers);

  final Set<int> refusedPeers;

  @override
  Set<int> get peersRefusedIdentity => refusedPeers;

  final Set<int> changedPeers;

  /// Mutable, like the service's map: a dismissal must make the next build
  /// see NO note, or the test proves nothing about convergence.
  final Map<int, String> notedPeers;

  @override
  Set<int> get peersWithChangedIdentity => changedPeers;

  @override
  Map<int, String> get peerKeyChangeNotes => notedPeers;

  /// (lxxxiv): peers whose superseded note the screen asked to forget.
  final List<int> dismissed = <int>[];

  /// Mirrors `EncryptionService.dismissPeerKeyChangeNote`: compare-and-remove
  /// on the instant, then the callback the real provider wires to
  /// `notifyListeners`.
  @override
  Future<void> dismissPeerKeyChangeNote(
    int peerId, {
    required String occurredAt,
  }) async {
    dismissed.add(peerId);
    if (notedPeers[peerId] != occurredAt) return;
    notedPeers.remove(peerId);
    notifyListeners();
  }

  @override
  Future<String?> getPeerIdentityFingerprint(int peerId) async => 'AAAA BBBB';

  @override
  Future<String?> getIdentityFingerprint() async => 'CCCC DDDD';
}

Map<String, dynamic> _conversationJson({String? lastMessageAt}) => {
  'id': 10,
  'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
  'userTwo': {'id': _peerId, 'username': 'bob', 'tag': '0002'},
  'createdAt': '2026-01-01T00:00:00.000Z',
  'unreadCount': 0,
  'lastMessage': lastMessageAt == null
      ? null
      : {..._messageJson(2000), 'createdAt': lastMessageAt},
};

Map<String, dynamic> _messageJson(int id, {int conversationId = 10}) => {
  'id': id,
  'content': 'note $id',
  'senderId': 1,
  'senderUsername': 'alice',
  'conversationId': conversationId,
  'deliveryStatus': 'DELIVERED',
  'messageType': 'TEXT',
  'createdAt': DateTime.utc(2026, 1, 1, 12, id % 60).toIso8601String(),
};

Future<_AlarmedEncryption> _pumpChat(
  WidgetTester tester, {
  required bool alarmed,
  required bool withMessages,
  // (lxxix): warnings are DEMOTED by default; the pre-(lxxix) tests below
  // opt back in because they assert the manual-confirmation red pill.
  bool keyChangeWarnings = true,
  bool noted = false,
  // (lxxxiv): the note's instant. The fixture messages are stamped
  // 2026-01-01T12:40–12:42 (`id % 60`), so the default keeps the note NEWER
  // than all of them.
  String noteAt = '2026-09-08T00:00:00.000Z',
  bool refused = false,
  // (lxxxiv): what the conversations LIST knows as the newest message, for
  // the window before this chat's history has loaded.
  String? listLastMessageAt,
  // (lxxxiv): the loaded rows belong to ANOTHER conversation — the frame
  // right after an embedded-pane switch, before `didUpdateWidget` reloads.
  int messagesConversationId = 10,
  // Seeds one OWN row stuck on `failed`, i.e. a send that already bounced.
  bool failedOwnRow = false,
  // Whether THAT row's last send attempt was the one the account-anchor gate
  // refused. Independent of [refused] on purpose: a chat can be awaiting the
  // ceremony while a given row bounced on something else entirely.
  bool rowRefusedForIdentity = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'key_change_warnings': keyChangeWarnings,
  });

  final conversations = ConversationsProvider()..setCurrentUserId(1);
  seedConversations(conversations, [
    _conversationJson(lastMessageAt: listLastMessageAt),
  ]);
  conversations.openConversation(10, notify: false);

  final messaging = MessagingProvider();
  messaging.setIncomingMessageSoundEnabledForTest(false);
  messaging.setConversationsProvider(conversations);
  messaging.setCurrentUserId(1);
  messaging.setToken('tok');
  messaging.setEmitCallback((event, data) {});
  messaging.onConnect(false);
  messaging.setActiveConversationIdForTest(10);
  messaging.seedCacheForTest(10, [
    if (withMessages)
      for (var i = 0; i < 3; i++)
        MessageModel.fromJson(
          _messageJson(1000 + i, conversationId: messagesConversationId),
        ),
    if (failedOwnRow)
      MessageModel.fromJson({
        ..._messageJson(1003, conversationId: messagesConversationId),
        'deliveryStatus': 'FAILED',
        'tempId': 'temp-1003',
      }),
  ]);
  messaging.loadCachedMessages(10);
  if (failedOwnRow && rowRefusedForIdentity) {
    messaging.markSendRefusedForIdentityForTest('temp-1003');
  }

  final auth = AuthProvider()..setAccessTokenForTest(_currentUserJwt);

  final encryption = _AlarmedEncryption(
    changedPeers: alarmed ? const {_peerId} : const <int>{},
    notedPeers: noted ? {_peerId: noteAt} : const <int, String>{},
    refusedPeers: refused ? const {_peerId} : const <int>{},
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConversationsProvider>.value(
          value: conversations,
        ),
        ChangeNotifierProvider<MessagingProvider>.value(value: messaging),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider(create: (_) => FriendsProvider()),
        ChangeNotifierProvider<EncryptionProvider>.value(value: encryption),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(initialThemePreference: 'dark'),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: RpgTheme.themeDataDarkGray,
        home: const ChatDetailScreen(conversationId: 10),
      ),
    ),
  );
  await tester.pump();
  // Let the SettingsProvider async prefs load land before asserting.
  await tester.pump();
  return encryption;
}

void main() {
  testWidgets('an EMPTY conversation still shows the identity alarm', (
    tester,
  ) async {
    await _pumpChat(tester, alarmed: true, withMessages: false);

    expect(
      find.byType(PeerIdentityChangedRow),
      findsOneWidget,
      reason:
          'a cleared or never-used chat is where a peer reset is most likely '
          'to arrive unannounced; suppressing the warning there makes it '
          'decorative',
    );
  });

  testWidgets('the EMPTY-chat alarm row clears the floating top bar', (
    tester,
  ) async {
    await _pumpChat(tester, alarmed: true, withMessages: false);

    final barBottom = tester.getRect(find.byType(GlassTopBar)).bottom;
    final rowTop = tester.getRect(find.byType(PeerIdentityChangedRow)).top;

    expect(
      rowTop,
      greaterThanOrEqualTo(barBottom),
      reason:
          'the empty-state column is static, so its first child sits under '
          'the floating chrome forever: with only the status-bar inset the '
          'row painted BEHIND the glass capsule and the back button, title '
          'pill and avatar covered the one takeover warning this app has '
          '(owner report, 2026-09-14)',
    );
  });

  testWidgets('an empty conversation with no alarm shows no row', (
    tester,
  ) async {
    await _pumpChat(tester, alarmed: false, withMessages: false);

    expect(
      find.byType(PeerIdentityChangedRow),
      findsNothing,
      reason:
          'a standing false alarm would train people to dismiss the one '
          'surface that detects a real takeover',
    );
  });

  testWidgets('the populated-timeline path still shows the row', (
    tester,
  ) async {
    await _pumpChat(tester, alarmed: true, withMessages: true);

    expect(find.byType(PeerIdentityChangedRow), findsOneWidget);
  });

  testWidgets('a populated timeline with no alarm shows no row', (
    tester,
  ) async {
    await _pumpChat(tester, alarmed: false, withMessages: true);

    expect(find.byType(PeerIdentityChangedRow), findsNothing);
  });
  // ---- Amendment (lxxix): the demoted surface (falsification F11) ----

  testWidgets(
      'an UNABSORBED change surfaces the pill even with warnings OFF '
      '(supersedes F11)', (tester) async {
    // (lxxix) demoted a key change to one muted line, and F11 pinned that the
    // setting was honoured even for an alarmed peer. That is right for a
    // change the anchor ABSORBED — but a peer stays in
    // `peersWithChangedIdentity` EXACTLY when the anchor did not advance, and
    // then `buildSession` fails closed and every send to them is refused
    // (`AccountIdentityMismatch`). The old gate therefore left a calm "keys
    // updated" note in front of a chat that could not send, and the user found
    // out only when a message bounced with "Ponów" — field-observed
    // 2026-09-13 after a peer reinstalled.
    //
    // OWNER-APPROVED 2026-09-13, with the counter-argument stated (warnings
    // off was chosen to mean "do not alarm me about key changes", and this
    // does alarm on a peer reinstall). The ruling: the setting chooses how an
    // ABSORBED change is announced; it was never a licence to hide a blocked
    // chat. So (lxxix) is narrowed, not overridden — the absorbed shape keeps
    // its own case below (`alarmed: false` → note, no pill), untouched.
    await _pumpChat(
      tester,
      alarmed: true,
      noted: true,
      keyChangeWarnings: false,
      withMessages: true,
    );

    expect(
      find.byType(PeerIdentityChangedRow),
      findsOneWidget,
      reason: 'a stale anchor blocks sending, so the door to the ceremony must '
          'be visible BEFORE the user composes anything',
    );
    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsNothing,
      reason: 'the two surfaces stay mutually exclusive — a blocked chat must '
          'not also claim the keys were quietly updated',
    );
  });

  // ---- Amendment (lxxxiv): the note lives until the next message ----

  testWidgets(
      'F46: a message NEWER than the note evicts it, and the note is forgotten '
      'durably', (tester) async {
    final enc = await _pumpChat(
      tester,
      alarmed: false,
      noted: true,
      // Between the last two fixture messages: only the newest is after it.
      noteAt: '2026-01-01T12:41:30.000Z',
      keyChangeWarnings: false,
      withMessages: true,
    );

    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsNothing,
      reason: 'the first message after the change pushes the line out (F46)',
    );
    expect(enc.dismissed, [_peerId],
        reason: 'left in storage, the line would flash on every later open '
            'of this chat until history loads');
  });

  testWidgets(
      'a message stamped at the SAME instant as the note does not evict it',
      (tester) async {
    final enc = await _pumpChat(
      tester,
      alarmed: false,
      noted: true,
      noteAt: '2026-01-01T12:42:00.000Z',
      keyChangeWarnings: false,
      withMessages: true,
    );

    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsOneWidget,
    );
    expect(enc.dismissed, isEmpty);
  });

  testWidgets(
      'F46b: history not loaded yet, but the LIST knows a newer message → '
      'no note (the post-reload window)', (tester) async {
    final enc = await _pumpChat(
      tester,
      alarmed: false,
      noted: true,
      noteAt: '2026-01-01T12:41:30.000Z',
      keyChangeWarnings: false,
      withMessages: false,
      listLastMessageAt: '2026-01-01T12:43:00.000Z',
    );

    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsNothing,
      reason: 'an empty timeline cannot out-date the note; the list preview '
          'can, and must, or the evicted line flashes on every open',
    );
    expect(enc.dismissed, [_peerId]);
  });

  testWidgets(
      'history not loaded and the LIST\'s newest message is OLDER → note stays',
      (tester) async {
    final enc = await _pumpChat(
      tester,
      alarmed: false,
      noted: true,
      noteAt: '2026-01-01T12:41:30.000Z',
      keyChangeWarnings: false,
      withMessages: false,
      listLastMessageAt: '2026-01-01T12:40:00.000Z',
    );

    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsOneWidget,
    );
    expect(enc.dismissed, isEmpty);
  });

  testWidgets(
      'F46d: the loaded rows belong to ANOTHER conversation (the frame right '
      'after a pane switch) → note stays and is NOT dismissed', (tester) async {
    final enc = await _pumpChat(
      tester,
      alarmed: false,
      noted: true,
      // Older than every loaded row — but those rows are conversation 11's.
      noteAt: '2026-01-01T12:00:00.000Z',
      keyChangeWarnings: false,
      withMessages: true,
      messagesConversationId: 11,
    );

    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsOneWidget,
      reason: 'the previous chat\'s newer rows are not evidence about THIS '
          'peer; evicting here would durably delete an un-superseded note',
    );
    expect(enc.dismissed, isEmpty);
  });

  testWidgets('F11: setting OFF + noted peer, empty chat → muted note only',
      (tester) async {
    await _pumpChat(
      tester,
      alarmed: false,
      noted: true,
      keyChangeWarnings: false,
      withMessages: false,
    );

    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsOneWidget,
    );
    expect(find.byType(PeerIdentityChangedRow), findsNothing);
  });

  testWidgets('setting OFF with no note shows neither surface', (tester) async {
    await _pumpChat(
      tester,
      alarmed: false,
      noted: false,
      keyChangeWarnings: false,
      withMessages: true,
    );

    expect(find.byType(PeerIdentityChangedRow), findsNothing);
    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsNothing,
    );
  });
  testWidgets(
      'a REFUSED peer gets the red pill even with warnings off, never the note',
      (tester) async {
    await _pumpChat(
      tester,
      alarmed: true,
      noted: true, // even a recorded note must not soften a refusal
      refused: true,
      keyChangeWarnings: false,
      withMessages: true,
    );

    expect(
      find.byType(PeerIdentityChangedRow),
      findsOneWidget,
      reason: 'a refusal blocks sending; hiding the pill behind the (lxxix) '
          'setting would leave a dead chat with zero UI',
    );
    expect(
      find.byKey(const ValueKey('peer-identity-changed-note')),
      findsNothing,
      reason: 'the muted note never renders for a refused peer',
    );
  });

  testWidgets('a refused peer shows the pill in an EMPTY chat too',
      (tester) async {
    await _pumpChat(
      tester,
      alarmed: false,
      refused: true,
      keyChangeWarnings: false,
      withMessages: false,
    );

    expect(find.byType(PeerIdentityChangedRow), findsOneWidget);
  });

  testWidgets('a bounced row names the refusal, not just "Retry"',
      (tester) async {
    await _pumpChat(
      tester,
      alarmed: true,
      refused: true,
      keyChangeWarnings: false,
      withMessages: true,
      failedOwnRow: true,
      rowRefusedForIdentity: true,
    );
    final en = await AppLocalizations.delegate.load(const Locale('en'));

    expect(
      find.text(en.messageSendBlockedKeysChanged),
      findsOneWidget,
      reason: 'the anchor is stale, so every retry fails the same way — the '
          'row must point at the fingerprint comparison instead',
    );
    expect(find.text(en.messageRetrySend), findsOneWidget);
  });

  testWidgets('an ordinary failed row says only "Retry"', (tester) async {
    await _pumpChat(
      tester,
      alarmed: false,
      refused: false,
      keyChangeWarnings: false,
      withMessages: true,
      failedOwnRow: true,
    );
    final en = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(en.messageRetrySend), findsOneWidget);
    expect(
      find.text(en.messageSendBlockedKeysChanged),
      findsNothing,
      reason: 'a timeout or a dropped socket IS worth retrying; blaming the '
          "peer's keys for it would send the user on a pointless ceremony",
    );
  });

  testWidgets(
      'a NON-identity failure in a refused chat still says only "Retry"',
      (tester) async {
    // The peer-level refusal answers "is a ceremony outstanding for this
    // chat", which is NOT "is THIS row the one that bounced on it". Keying the
    // sentence on the peer alone blamed the key change for an "Image too
    // large" or timeout bounce in the same chat.
    await _pumpChat(
      tester,
      alarmed: true,
      refused: true,
      keyChangeWarnings: false,
      withMessages: true,
      failedOwnRow: true,
      rowRefusedForIdentity: false,
    );
    final en = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.byType(PeerIdentityChangedRow), findsOneWidget);
    expect(find.text(en.messageRetrySend), findsOneWidget);
    expect(
      find.text(en.messageSendBlockedKeysChanged),
      findsNothing,
      reason: 'this row did not bounce on the anchor, so it must not claim the '
          "peer's keys are why",
    );
  });
}
