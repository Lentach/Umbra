import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/conversations_provider.dart';
import 'package:fireplace/providers/messaging_provider.dart';
import 'package:fireplace/utils/chat_resume_reassert.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_seed.dart';

Map<String, dynamic> _convJson(int id) => {
      'id': id,
      'userOne': {'id': 1, 'username': 'alice', 'tag': '0001'},
      'userTwo': {'id': 2, 'username': 'bob', 'tag': '0002'},
      'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      'unreadCount': 0,
    };

/// Minimal observer host that calls the REAL resume re-assert on `resumed` —
/// mirrors how [ChatDetailScreen] wires `didChangeAppLifecycleState`. The real
/// screen can't be full-mounted in tests (its `build` needs `AuthProvider.currentUser`,
/// which has no test seam), so we drive the real lifecycle mechanism through a host.
class _ResumeHost extends StatefulWidget {
  const _ResumeHost({
    required this.conversations,
    required this.messaging,
    required this.conversationId,
  });

  final ConversationsProvider conversations;
  final MessagingProvider messaging;
  final int conversationId;

  @override
  State<_ResumeHost> createState() => _ResumeHostState();
}

class _ResumeHostState extends State<_ResumeHost> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      reassertOpenConversationOnResume(
        widget.conversations,
        widget.messaging,
        widget.conversationId,
      );
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  test('reassertOpenConversationOnResume re-sets active conversation + reloads',
      () {
    final convs = ConversationsProvider();
    seedConversations(convs, [_convJson(10)]);
    final messaging = MessagingProvider();
    messaging.setConversationsProvider(convs);
    messaging.seedMessagesForTest(10, [
      MessageModel(
        id: 5,
        content: 'hi',
        senderId: 2,
        senderUsername: 'bob',
        conversationId: 10,
        createdAt: DateTime.utc(2026, 1, 1, 12),
      ),
    ]);

    // Simulate the iOS-resume clear: ChatDetailScreen.dispose() nulled the
    // active conversation and the shown rows while the chat was on screen.
    convs.closeConversation();
    messaging.clearMessages();
    expect(convs.activeConversationId, isNull);
    expect(messaging.messages, isEmpty);

    reassertOpenConversationOnResume(convs, messaging, 10);

    expect(convs.activeConversationId, 10);
    expect(messaging.messages.map((m) => m.id), [5],
        reason: 'open chat must be reloaded on resume');
  });

  testWidgets('app resume re-asserts the open conversation via lifecycle hook',
      (tester) async {
    final convs = ConversationsProvider();
    seedConversations(convs, [_convJson(10)]);
    final messaging = MessagingProvider();
    messaging.setConversationsProvider(convs);

    await tester.pumpWidget(_ResumeHost(
      conversations: convs,
      messaging: messaging,
      conversationId: 10,
    ));

    // Active id cleared while the chat is still "open" (resume/dispose churn).
    convs.closeConversation();
    expect(convs.activeConversationId, isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(convs.activeConversationId, 10);
  });
}
