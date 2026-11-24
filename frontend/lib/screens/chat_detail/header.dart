part of '../chat_detail_screen.dart';

/// Header members of [_ChatDetailScreenState]: the conversation/peer lookups, the
/// title with its typing/recording status line, and the avatar tap that opens the
/// user card.
extension _ChatDetailHeader on _ChatDetailScreenState {
  Future<void> _onAvatarTap() async {
    final otherUser = _getOtherUser();
    if (otherUser == null) return;

    await Navigator.of(context).push(
      instantOpaqueRoute(
        builder: (cardContext) {
          // Resolved ONCE, still inside the builder so it is read at the same
          // moment as before.
          final conversation = _conversations.conversations
              .where((conversation) => conversation.id == widget.conversationId)
              .firstOrNull;
          return UserCardScreen(
            data: UserCardVisualData.fromUser(
              otherUser,
              isSelf: false,
              hasConversation: true,
              conversationId: widget.conversationId,
              mute: UserCardMute.fromConversation(
                muted: conversation?.muted ?? false,
                mutedUntil: conversation?.mutedUntil,
              ),
            ),
            onMessage: () {
              Navigator.of(cardContext).pop();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _composerKey.currentState?.focusComposer();
              });
            },
            onMuteChanged: (mute) {
              _conversations.setConversationMute(
                widget.conversationId,
                switch (mute) {
                  UserCardMute.off => 'off',
                  UserCardMute.oneHour => '1h',
                  UserCardMute.eightHours => '8h',
                  UserCardMute.oneWeek => '1w',
                  UserCardMute.forever => 'forever',
                },
              );
            },
          );
        },
      ),
    );
  }

  ConversationModel? _getActiveConversation() {
    return context.read<ConversationsProvider>().getConversationById(
      widget.conversationId,
    );
  }

  String _getContactName() {
    final conv = _getActiveConversation();
    return conv != null
        ? context.read<ConversationsProvider>().getOtherUserUsername(conv)
        : '';
  }

  UserModel? _getOtherUser() {
    final conv = _getActiveConversation();
    return conv != null
        ? context.read<ConversationsProvider>().getOtherUser(conv)
        : null;
  }

  /// statusText: e.g. "typing..." or "Recording voice..."
  Widget _buildHeaderTitle(
    BuildContext context,
    String contactName,
    UserModel? otherUser,
    String? statusText,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final accentColor = Theme.of(context).colorScheme.primary;
    final nameWidget = Text(
      contactName,
      style: RpgTheme.bodyFont(
        fontSize: 16,
        color: colorScheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      overflow: TextOverflow.ellipsis,
    );
    if (statusText == null || statusText.isEmpty) return nameWidget;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        nameWidget,
        Text(
          statusText,
          style: RpgTheme.bodyFont(
            fontSize: 12,
            color: accentColor,
          ).copyWith(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  String? _getHeaderStatusText(BuildContext context, MessagingProvider msg) {
    final l10n = AppLocalizations.of(context);
    if (msg.isRecordingVoice) return l10n.recordingVoice;
    if (msg.isPartnerRecordingVoice(widget.conversationId)) {
      return l10n.recordingVoice;
    }
    if (msg.isPartnerTyping(widget.conversationId)) return l10n.typing;
    return null;
  }
}
