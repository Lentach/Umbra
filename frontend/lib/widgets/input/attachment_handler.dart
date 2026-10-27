import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/auth_provider.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/messaging_provider.dart';
import '../gif_picker_sheet.dart';
import '../top_snackbar.dart';

/// Utility class for file / image / GIF attachment handling.
///
/// Each static method receives a [BuildContext] and delegates to the
/// appropriate provider after gathering recipient / conversation context.
/// All UI error feedback uses [showTopSnackBar].
///
/// Note: Image picking and file picking are already fully implemented in
/// [ChatActionTiles]. This class exposes the core send helpers so they
/// can be reused independently of the action tiles widget.
class AttachmentHandler {
  const AttachmentHandler._();

  // ── image sending ─────────────────────────────────────────────────────────

  /// Sends an image from bytes (already loaded by the caller).
  ///
  /// Returns true only after the image's socket emit (see
  /// [MessagingProvider.sendImageMessage] ordering contract); false when the
  /// send failed before the emit.
  static Future<bool> sendImage(
    BuildContext context, {
    required Uint8List imageBytes,
    required String filename,
    required String mimeType,
  }) async {
    final messaging = context.read<MessagingProvider>();
    final auth = context.read<AuthProvider>();
    final convs = context.read<ConversationsProvider>();

    final conversationId = convs.activeConversationId;
    if (conversationId == null) {
      showTopSnackBar(
          context, AppLocalizations.of(context).snackbarNoActiveConversation);
      return false;
    }

    final conv = convs.getConversationById(conversationId);
    if (conv == null) return false;
    final recipientId = convs.getOtherUserId(conv);

    try {
      final xfile = XFile.fromData(
        imageBytes,
        name: filename,
        mimeType: mimeType,
      );
      return await messaging.sendImageMessage(auth.token!, xfile, recipientId);
    } catch (e) {
      if (!context.mounted) return false;
      showTopSnackBar(
          context, AppLocalizations.of(context).snackbarFailedToSendImage);
      debugPrint('AttachmentHandler.sendImage error: $e');
      return false;
    }
  }

  // ── video sending ─────────────────────────────────────────────────────────

  /// Sends a picked video from bytes — IMMEDIATELY, with no staging step.
  /// Mirrors [sendImage]: returns true only after the video's socket emit
  /// (caption ordering contract); false when the send failed before the emit
  /// (the optimistic bubble owns retry).
  ///
  /// [width], [height] and [thumbHash] come from the composer's single
  /// `probeVideoPreview` pass and ride inside the E2E envelope, so the
  /// receiving bubble can size itself to the real aspect ratio and paint a
  /// placeholder before fetching anything. Any of them may be null when the
  /// platform could not read the container.
  static Future<bool> sendVideo(
    BuildContext context, {
    required Uint8List videoBytes,
    int? durationSeconds,
    int? width,
    int? height,
    String? thumbHash,
  }) async {
    final messaging = context.read<MessagingProvider>();
    final auth = context.read<AuthProvider>();
    final convs = context.read<ConversationsProvider>();

    final conversationId = convs.activeConversationId;
    if (conversationId == null) {
      showTopSnackBar(
          context, AppLocalizations.of(context).snackbarNoActiveConversation);
      return false;
    }

    final conv = convs.getConversationById(conversationId);
    if (conv == null) return false;
    final recipientId = convs.getOtherUserId(conv);

    return messaging.sendVideoMessage(
      auth.token!,
      videoBytes,
      recipientId,
      duration: durationSeconds,
      width: width,
      height: height,
      thumbHash: thumbHash,
    );
  }

  // ── document sending ──────────────────────────────────────────────────────

  /// Sends a picked document as a FILE message — immediately (documents never
  /// stage), with an uploading toast and a sent / failed toast after.
  static Future<void> sendDocument(
    BuildContext context, {
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final l10n = AppLocalizations.of(context);
    final messaging = context.read<MessagingProvider>();
    final auth = context.read<AuthProvider>();
    final convs = context.read<ConversationsProvider>();

    final conversationId = convs.activeConversationId;
    if (conversationId == null) {
      showTopSnackBar(context, l10n.snackbarNoActiveConversation);
      return;
    }
    final conv = convs.getConversationById(conversationId);
    if (conv == null) return;
    final recipientId = convs.getOtherUserId(conv);
    final errorColor = Theme.of(context).colorScheme.error;

    showTopSnackBar(context, l10n.snackbarUploadingDocument);
    try {
      await messaging.sendFileMessage(
        auth.token!,
        bytes,
        fileName,
        mimeType,
        recipientId,
      );
      if (context.mounted) {
        showTopSnackBar(context, l10n.snackbarDocumentSent);
      }
    } on Object catch (e) {
      if (context.mounted) {
        showTopSnackBar(
          context,
          '${l10n.uploadFailed}: $e',
          backgroundColor: errorColor,
        );
      }
    }
  }

  // ── GIF picker ────────────────────────────────────────────────────────────

  /// Opens the GIF picker sheet and, on selection, calls
  /// [MessagingProvider.sendGif] with the selected Giphy URL.
  static void openGifPicker(BuildContext context) {
    final convs = context.read<ConversationsProvider>();
    final conversationId = convs.activeConversationId;
    if (conversationId == null) {
      showTopSnackBar(
          context, AppLocalizations.of(context).snackbarNoActiveConversation);
      return;
    }

    final conv = convs.getConversationById(conversationId);
    if (conv == null) return;
    final recipientId = convs.getOtherUserId(conv);

    final messaging = context.read<MessagingProvider>();
    final auth = context.read<AuthProvider>();

    GifPickerSheet.show(
      context,
      onGifSelected: (gifUrl) {
        messaging.sendGif(auth.token!, gifUrl, recipientId);
      },
    );
  }
}
