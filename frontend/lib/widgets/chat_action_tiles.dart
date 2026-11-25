import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import '../utils/file_utils_stub.dart'
    if (dart.library.io) '../utils/file_utils_io.dart'
    as file_utils;
import '../utils/web_ios_webkit.dart';
import '../utils/web_file_input.dart';
import '../utils/video_preview.dart' show kSendableVideoExtensions;
import 'input/composer_keyboard_signals.dart';
import '../models/conversation_model.dart';
import '../providers/conversations_provider.dart';
import '../providers/messaging_provider.dart';
import '../l10n/app_localizations.dart';
import '../theme/glass_theme.dart';
import 'glass/glass_sheet.dart';
import 'glass/glass_surface.dart';
import '../theme/rpg_theme.dart';
import 'input/focus_guard_area.dart';
import 'input/picked_attachment.dart';
export 'disappearing_timer_sheet.dart';
import 'disappearing_timer_sheet.dart';
import 'top_snackbar.dart';
import 'anti_quantum_note_dialog.dart';
import 'dialogs/clear_chat_dialog.dart';
import 'gif_picker_sheet.dart';
import 'ping_glyph.dart';

part 'chat_action_tiles/attachment_doors.dart';
part 'chat_action_tiles/tiles.dart';

/// Hands the files of one paperclip pick to the composer, which sends them
/// IMMEDIATELY, one message per file, in order (owner ruling 2026-10-27:
/// a gallery pick is the confirmation; no staging step). [pickedIn] is the
/// conversation the paperclip was tapped in: the files arrive only after the
/// picker closes (and, on web, after every file is read), and on the desktop
/// split view the user may have opened another chat by then. Policy checks
/// and rejection toasts happen inside.
typedef PickedFilesCallback =
    Future<void> Function(
      List<PickedAttachment> files, {
      required int pickedIn,
    });

class ChatActionTiles extends StatelessWidget {
  final double bottomPadding;

  /// Fired after a ping send so the composer can restore keyboard focus.
  /// Ping is keyboard-neutral (user ruling 2026-07-09): on iOS WebKit the
  /// [FocusGuardArea] below stops the tap's DOM blur outright; off iOS the
  /// composer heals the blur post-frame through this callback.
  final VoidCallback? onPingSent;

  /// Composer seam (null only in standalone test mounts, where a pick then
  /// does nothing).
  final PickedFilesCallback? onPickedFiles;

  const ChatActionTiles({
    super.key,
    this.bottomPadding = 0,
    this.onPingSent,
    this.onPickedFiles,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final iconColor = GlassTheme.of(context).onGlassAccent;
    final convs = context.watch<ConversationsProvider>();
    final timerActive = convs.conversationDisappearingTimer != null;

    // Liquid Glass: the panel is a floating glass pill matching the composer
    // pill footprint; total height (56 + insets + bottomPadding) stays a
    // plain function of layout so the composer viewport measures it as
    // before. Glass is paint, not layout.
    //
    // The transparent gutter around the pill must still HIT-TEST as part of
    // the composer tap region: a mis-tap 4px off the pill edge must not
    // dismiss the keyboard (the exact iOS jank class fixed in 0.0.93-0.0.99).
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Hit-test shim only — never an announced control.
      excludeFromSemantics: true,
      onTap: () {},
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 8 + bottomPadding),
        child: GlassSurface(
          borderRadius: BorderRadius.circular(28),
          height: 56,
          shadow: false,
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: box.maxWidth - 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LongPressActionTile(
                      icon: Icons.delete_forever,
                      color: iconColor,
                      tooltip: l10n.actionTileClearChat,
                      holdLabel: l10n.clearChatHoldLabel,
                      onLongPressComplete: () =>
                          _handleClearChatHistory(context),
                    ),
                    const SizedBox(width: 12),
                    _ActionTile(
                      icon: Icons.hourglass_bottom_outlined,
                      tooltip: l10n.actionTileDisappearingMessages,
                      color: iconColor,
                      showBadge: timerActive,
                      onTap: () => _showTimerDialog(context),
                    ),
                    const SizedBox(width: 12),
                    FocusGuardArea(
                      id: 'action_tile_ping',
                      child: _ActionTile(
                        customIcon: PingGlyph(size: 24, color: iconColor),
                        tooltip: l10n.ping,
                        color: iconColor,
                        onTap: () => _sendPing(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Builder(
                      builder: (tileContext) => _ActionTile(
                        icon: Icons.attach_file,
                        tooltip: l10n.attachment,
                        color: iconColor,
                        onTap: () => _pickAttachment(context, tileContext),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ActionTile(
                      icon: Icons.gif_box,
                      tooltip: l10n.actionTileGif,
                      color: iconColor,
                      onTap: () => _openGifPicker(context),
                    ),
                    const SizedBox(width: 12),
                    _ActionTile(
                      icon: Icons.science_outlined,
                      tooltip: l10n.actionTileAntiQuantumNote,
                      color: iconColor,
                      onTap: () => _showAntiQuantumNoteDialog(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showTimerDialog(BuildContext context) {
    showDisappearingTimerSheet(context);
  }

  /// Returns (conv, recipientId) if conversation is active; otherwise shows snackbar and returns null.
  (ConversationModel, int)? _requireActiveConversation(BuildContext context) {
    if (!_ensureHasActiveConversation(context)) return null;
    final convs = context.read<ConversationsProvider>();
    final conv = convs.getConversationById(convs.activeConversationId!);
    if (conv == null) return null;
    return (conv, convs.getOtherUserId(conv));
  }

  void _sendPing(BuildContext context) {
    final result = _requireActiveConversation(context);
    if (result == null) return;
    context.read<MessagingProvider>().sendPing(result.$2);
    onPingSent?.call();
  }

  bool _ensureHasActiveConversation(BuildContext context) {
    if (context.read<ConversationsProvider>().activeConversationId == null) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context).snackbarOpenConversationFirst,
      );
      return false;
    }
    return true;
  }

  void _showAntiQuantumNoteDialog(BuildContext context) {
    final result = _requireActiveConversation(context);
    if (result == null) return;

    final messaging = context.read<MessagingProvider>();
    final l10n = AppLocalizations.of(context);

    showGlassSheet<void>(
      context,
      isScrollControlled: true,
      builder: (_) => AntiQuantumNoteDialog(
        onSend: (content, ttl) async {
          try {
            await messaging.sendAntiQuantumNote(
              content: content,
              expiresInSeconds: ttl,
            );
            if (context.mounted) {
              Navigator.of(context).pop();
              showTopSnackBar(context, l10n.antiQuantumNoteSent);
            }
          } catch (e) {
            if (context.mounted) {
              showTopSnackBar(
                context,
                l10n.antiQuantumNoteSendFailed(e.toString()),
                backgroundColor: Theme.of(context).colorScheme.error,
              );
            }
          }
        },
      ),
    );
  }

  void _openGifPicker(BuildContext context) {
    final result = _requireActiveConversation(context);
    if (result == null) return;

    final messaging = context.read<MessagingProvider>();

    GifPickerSheet.show(
      context,
      onGifSelected: (gifUrl) {
        messaging.sendGif(gifUrl, result.$2);
      },
    );
  }

  /// The hold gesture guards against an ACCIDENT; it cannot obtain informed
  /// consent for a wipe that also destroys the other person's copy, so the
  /// scope is spelled out in [showClearChatDialog] before anything is emitted.
  Future<void> _handleClearChatHistory(BuildContext context) async {
    if (!_ensureHasActiveConversation(context)) return;

    final convs = context.read<ConversationsProvider>();
    final messaging = context.read<MessagingProvider>();
    final l10n = AppLocalizations.of(context);
    final conversationId = convs.activeConversationId!;

    await showClearChatDialog(
      context: context,
      onConfirm: () {
        messaging.clearChatHistory(conversationId);

        if (context.mounted) {
          showTopSnackBar(context, l10n.snackbarChatHistoryDeleted);
        }

        // Close action panel (navigate back if possible)
        if (context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      },
    );
  }
}
