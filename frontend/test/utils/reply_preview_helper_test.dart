import 'dart:ui' show Locale;

import 'package:fireplace/config/app_config.dart';
import 'package:fireplace/l10n/app_localizations.dart';
import 'package:fireplace/models/message_model.dart';
import 'package:fireplace/providers/encryption_provider.dart';
import 'package:fireplace/utils/reply_preview_helper.dart';
import 'package:flutter_test/flutter_test.dart';

MessageModel _msg({
  required int id,
  required String content,
  MessageType type = MessageType.text,
  String? encryptedContent,
}) =>
    MessageModel(
      id: id,
      content: content,
      senderId: 1,
      senderUsername: 'alice',
      conversationId: 10,
      createdAt: DateTime.utc(2026, 1, 1),
      messageType: type,
      encryptedContent: encryptedContent,
    );

/// Minimal encryption fake: serves a decrypted-cache row per message id so the
/// note-URL guard on the decrypted-cache branch can be exercised.
class _CachedEnc extends EncryptionProvider {
  final Map<int, MessageModel> cache;
  _CachedEnc(this.cache);
  @override
  MessageModel? getCachedDecryption(int messageId) => cache[messageId];
}

void main() {
  const labels = kReplyPreviewLabels;
  // 32-hex token + b64url fragment, on this build's own origin so the
  // context-free isAntiQuantumNoteUrl() default baseUrl matches.
  final noteUrl =
      '${AppConfig.baseUrl}/note/0123456789abcdef0123456789abcdef#abcABC012_-';

  test('replyPreviewForMessageModel shows note label for note URL content', () {
    final result = replyPreviewForMessageModel(
      _msg(id: 1, content: noteUrl),
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
      antiQuantumNoteLabel: labels.antiQuantumNoteLabel,
    );
    expect(result, labels.antiQuantumNoteLabel);
  });

  test('replyPreviewForMessageModel shows note label for decrypted-cache note URL',
      () {
    final enc = _CachedEnc({7: _msg(id: 7, content: noteUrl)});
    final result = replyPreviewForMessageModel(
      _msg(id: 7, content: '[encrypted]', encryptedContent: 'cipher'),
      encryption: enc,
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
      antiQuantumNoteLabel: labels.antiQuantumNoteLabel,
    );
    expect(result, labels.antiQuantumNoteLabel);
  });

  test('enrichReplyToPreview uses TEXT encrypted label when cache empty', () {
    const replyTo = ReplyToPreview(
      id: 5,
      content: 'Encrypted message',
      senderUsername: 'bob',
      messageType: MessageType.text,
    );
    final enriched = enrichReplyToPreview(
      replyTo,
      encryption: null,
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
    );
    expect(enriched.content, labels.encryptedMessageLabel);
  });

  test('enrichReplyToPreview resolves quoted row from messages list', () {
    const replyTo = ReplyToPreview(
      id: 5,
      content: 'Encrypted message',
      senderUsername: 'bob',
      messageType: MessageType.text,
    );
    final enriched = enrichReplyToPreview(
      replyTo,
      encryption: null,
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
      messagesForLookup: [_msg(id: 5, content: 'Hello from history')],
    );
    expect(enriched.content, 'Hello from history');
  });

  test('resolvePinnedPreviewMessage prefers local plaintext over server encrypted', () {
    final server = _msg(
      id: 42,
      content: '[encrypted]',
      encryptedContent: 'cipher',
    );
    final local = _msg(id: 42, content: 'My pinned note');
    final resolved = resolvePinnedPreviewMessage(
      serverPreview: server,
      localMessage: local,
    );
    expect(resolved.content, 'My pinned note');
  });

  test('replyPreviewForMessageModel shows encrypted label for [encrypted] row', () {
    final text = replyPreviewForMessageModel(
      _msg(id: 1, content: '[encrypted]', encryptedContent: 'x'),
      encryption: null,
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
    );
    expect(text, labels.encryptedMessageLabel);
    expect(text, isNotEmpty);
  });

  test('replyPreviewForMessageModel shows ping label for encrypted PING row', () {
    final preview = replyPreviewForMessageModel(
      _msg(
        id: 2,
        content: '[encrypted]',
        type: MessageType.ping,
        encryptedContent: 'cipher',
      ),
      encryption: null,
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
    );
    expect(preview, labels.pingLabel);
  });

  test('replyPreviewForMessageModel shows gif label for encrypted GIF row', () {
    final preview = replyPreviewForMessageModel(
      _msg(
        id: 3,
        content: 'Encrypted message',
        type: MessageType.gif,
        encryptedContent: 'cipher',
      ),
      encryption: null,
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
    );
    expect(preview, labels.gifLabel);
  });

  test('enrichReplyToPreview uses ping label for encrypted ping reply snapshot', () {
    const replyTo = ReplyToPreview(
      id: 9,
      content: '[encrypted]',
      senderUsername: 'bob',
      messageType: MessageType.ping,
    );
    final enriched = enrichReplyToPreview(
      replyTo,
      encryption: null,
      encryptedMessageLabel: labels.encryptedMessageLabel,
      voiceMessageLabel: labels.voiceMessageLabel,
      imageLabel: labels.imageLabel,
      gifLabel: labels.gifLabel,
      documentLabel: labels.documentLabel,
      pingLabel: labels.pingLabel,
    );
    expect(enriched.content, labels.pingLabel);
  });

  test('resolvePinnedPreviewMessage prefers local gif keys over server encrypted', () {
    final server = _msg(
      id: 50,
      content: '[encrypted]',
      type: MessageType.gif,
      encryptedContent: 'cipher',
    );
    final local = _msg(
      id: 50,
      content: '',
      type: MessageType.gif,
      encryptedContent: 'cipher',
    ).copyWith(
      mediaUrl: 'http://localhost/media/msgs/a.bin',
      mediaKey: 'key',
      mediaIv: 'iv',
    );
    final resolved = resolvePinnedPreviewMessage(
      serverPreview: server,
      localMessage: local,
    );
    expect(resolved.mediaKey, 'key');
    expect(resolved.mediaUrl, contains('/media/msgs/'));
  });

  // A3-UTL-04: a quote written by the provider carries the English type label
  // ('Image'); once the quoted row has left the list it must still read in the
  // app's language.
  test('a quote of a vanished photo or voice note is shown in the app language', () {
    final pl = lookupAppLocalizations(const Locale('pl'));
    String shown(MessageType type, String stored) => replyDisplayContentForQuote(
      pl,
      ReplyToPreview(
        id: 5,
        content: stored,
        senderUsername: 'bob',
        messageType: type,
      ),
      conversationId: 10,
      createdAt: DateTime.utc(2026),
      messagesForLookup: const [],
    );

    expect(shown(MessageType.image, labels.imageLabel), pl.image);
    expect(shown(MessageType.voice, labels.voiceMessageLabel), pl.voiceMessage);
    expect(shown(MessageType.file, labels.documentLabel), pl.attachmentOptionDocument);
    // A caption that merely equals a label on a TEXT quote is text, untouched.
    expect(shown(MessageType.text, labels.imageLabel), labels.imageLabel);
  });
}
