import 'package:flutter/material.dart';

import '../../models/message_model.dart';
import '../../providers/messaging_provider.dart';
import '../../providers/settings_provider.dart';
import 'file_message_content.dart';
import 'voice_message_content.dart';
import 'gif_message_content.dart';
import 'image_message_content.dart';
import 'ping_message_content.dart';
import 'text_message_content.dart';
import 'video_message_content.dart';

/// Factory that picks the right content widget based on message type.
class MessageContentFactory {
  const MessageContentFactory._();

  static Widget build({
    required BuildContext context,
    required MessageModel message,
    required bool isMine,
    required bool isDark,
    required Color textColor,
    required double contentAreaWidth,
    String themePreference = SettingsProvider.kDefaultThemePreference,
  }) {
    if (message.content == kRetiredMessageLabel) {
      return TextMessageContent(
        message: message,
        isMine: isMine,
        textColor: textColor,
        isDark: isDark,
        maxWidth: contentAreaWidth,
        themePreference: themePreference,
      );
    }
    switch (message.messageType) {
      case MessageType.voice:
        return VoiceMessageContent(message: message, isMine: isMine);

      case MessageType.text:
        return TextMessageContent(
          message: message,
          isMine: isMine,
          textColor: textColor,
          isDark: isDark,
          maxWidth: contentAreaWidth,
          themePreference: themePreference,
        );

      case MessageType.ping:
        return PingMessageContent(isMine: isMine, textColor: textColor);

      case MessageType.image:
        return ImageMessageContent(message: message);

      case MessageType.gif:
        return GifMessageContent(message: message);

      case MessageType.file:
        return FileMessageContent(message: message, textColor: textColor);

      case MessageType.video:
        return VideoMessageContent(message: message);
    }
  }
}
