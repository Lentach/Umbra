import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/file_utils_stub.dart'
    if (dart.library.io) '../utils/file_utils_io.dart'
    as file_utils;
import '../utils/web_ios_webkit.dart';
import '../utils/web_file_input.dart';
import '../utils/video_preview.dart' show kSendableVideoExtensions;
import 'input/composer_keyboard_signals.dart';
import '../models/conversation_model.dart';
import '../providers/auth_provider.dart';
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

/// Hands the files of one paperclip pick to the composer, which sends them
/// IMMEDIATELY, one message per file, in order (owner ruling 2026-10-27:
/// a gallery pick is the confirmation; no staging step). Policy checks and
/// rejection toasts happen inside.
typedef PickedFilesCallback = Future<void> Function(List<PickedAttachment>);

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

  static String _dotAccept(List<String> extensions) =>
      extensions.map((e) => '.$e').join(',');

  /// Paperclip door, per platform (owner rulings 2026-08-19/21/30):
  ///
  /// - iOS PWA: file_picker fallback, byte-identical to pre-branch behavior
  ///   (owner ruling 2026-08-30). The anchored-input path was removed after a
  ///   9-variant on-device probe proved the opening mechanism is NOT what
  ///   causes the standalone orb/flash — the real app orbs identically on
  ///   both paths, and only in the installed standalone shell. Parked until
  ///   macOS Web Inspector can observe the presentation (PR #151 comment,
  ///   2026-08-30 session summary). The native-picker span still wraps the
  ///   fallback: the dismiss-slide gate and freeze-reload pick protection are
  ///   mechanism-independent wins.
  /// - Android PWA: Chrome's chooser for a mixed image+video accept lists the
  ///   camera twice (stills + camcorder; emulator s27 AND owner's real device
  ///   2026-08-30) and offers no gallery door, so the paperclip opens an
  ///   in-app glass sheet with three unambiguous doors: Gallery / Camera /
  ///   File (owner ruling 2026-08-19, re-confirmed wanted 2026-08-30).
  /// - Desktop web + native: system picker via file_picker.
  ///
  /// Every door that can browse (all but the two capture doors) allows
  /// selecting several files; the composer sends them all immediately, in
  /// order, capped at [kMaxFilesPerPick].
  Future<void> _pickAttachment(
    BuildContext context,
    BuildContext tileContext,
  ) async {
    if (_requireActiveConversation(context) == null) return;

    if (kIsWeb &&
        webAnchoredFileInputSupported &&
        !isIOSWebKit() &&
        defaultTargetPlatform == TargetPlatform.android) {
      await _showAndroidAttachmentSheet(context, _tileAnchorRect(tileContext));
      return;
    }

    beginComposerNativePicker();
    FilePickerResult? pickResult;
    try {
      pickResult = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          ...kPickableImageExtensions,
          ...kSendableVideoExtensions,
          ...kPickableDocumentExtensions,
        ],
        allowMultiple: true,
        // Web has no path, so bytes come eagerly there; native reads each
        // file from its path when its turn to send comes.
        withData: kIsWeb,
      );
    } finally {
      endComposerNativePicker();
    }
    if (pickResult == null || pickResult.files.isEmpty) return;
    await onPickedFiles?.call([
      for (final file in pickResult.files)
        PickedAttachment(name: file.name, readBytes: () => _readBytes(file)),
    ]);
  }

  static Future<Uint8List?> _readBytes(PlatformFile file) async {
    if (file.bytes != null) return file.bytes;
    if (kIsWeb || file.path == null) return null;
    try {
      return Uint8List.fromList(await file_utils.readFileBytes(file.path!));
    } on Object {
      return null;
    }
  }

  static Rect _tileAnchorRect(BuildContext tileContext) {
    final box = tileContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      // Degenerate but rendered fallback: bottom-center of the screen, where
      // the composer lives — still a real anchor for Safari.
      final size = MediaQuery.sizeOf(tileContext);
      return Rect.fromCenter(
        center: Offset(size.width / 2, size.height - 100),
        width: 48,
        height: 48,
      );
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Android four-door sheet: Gallery / Camera / Record video / File. Each
  /// door opens the anchored input with a door-specific accept, so Chrome
  /// never shows its ambiguous camera/camcorder/media chooser.
  ///
  /// Video capture is its own door because Android has no single input that
  /// offers "photo or video": `image/*` + `capture` opens the camera in photo
  /// mode and `video/*` + `capture` opens the camcorder. iOS ignores `capture`
  /// and shows its own "Take Photo or Video" sheet, which is why iOS could
  /// record a video from the camera and Android could not (owner report
  /// 2026-09-05).
  Future<void> _showAndroidAttachmentSheet(
    BuildContext context,
    Rect anchor,
  ) async {
    // The modal sheet route unfocuses the composer and drops the keyboard
    // before any door is tapped — that drop is not a user dismiss either.
    // Depth-counted: a door begins its own span synchronously BEFORE this
    // await resumes, so the flag never flickers between sheet and dialog.
    beginComposerNativePicker();
    final l10n = AppLocalizations.of(context);
    final glass = GlassTheme.of(context);
    try {
      await showGlassSheet<void>(
        context,
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              _AttachmentDoorRow(
                key: const Key('attachment-door-gallery'),
                icon: Icons.photo_library_outlined,
                label: l10n.attachmentOptionGallery,
                color: glass.onGlassAccent,
                onTap: () => _openDoor(
                  sheetContext,
                  anchor,
                  accept: 'image/*,video/*',
                  multiple: true,
                ),
              ),
              _AttachmentDoorRow(
                key: const Key('attachment-door-camera'),
                icon: Icons.photo_camera_outlined,
                label: l10n.attachmentOptionCamera,
                color: glass.onGlassAccent,
                onTap: () => _openDoor(
                  sheetContext,
                  anchor,
                  accept: 'image/*',
                  capture: 'environment',
                ),
              ),
              _AttachmentDoorRow(
                key: const Key('attachment-door-record-video'),
                icon: Icons.videocam_outlined,
                label: l10n.attachmentOptionRecordVideo,
                color: glass.onGlassAccent,
                onTap: () => _openDoor(
                  sheetContext,
                  anchor,
                  accept: 'video/*',
                  capture: 'environment',
                ),
              ),
              _AttachmentDoorRow(
                key: const Key('attachment-door-file'),
                icon: Icons.folder_outlined,
                label: l10n.attachmentOptionFile,
                color: glass.onGlassAccent,
                onTap: () => _openDoor(
                  sheetContext,
                  anchor,
                  accept: _dotAccept(kPickableDocumentExtensions),
                  multiple: true,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    } finally {
      endComposerNativePicker();
    }
  }

  /// Door tap: pop the sheet and open the input SYNCHRONOUSLY in the same
  /// gesture stack (a deferred click is silently blocked — 08-19 §3.5), then
  /// hand the files to the composer. Fire-and-forget by design: the row's
  /// onTap is sync.
  void _openDoor(
    BuildContext sheetContext,
    Rect anchor, {
    required String accept,
    String? capture,
    bool multiple = false,
  }) {
    beginComposerNativePicker();
    Navigator.of(sheetContext).pop();
    pickFilesViaAnchoredInput(
          anchorRect: anchor,
          accept: accept,
          capture: capture,
          multiple: multiple,
        )
        .then((picked) async {
          if (picked == null || picked.isEmpty) return;
          await onPickedFiles?.call([
            for (final file in picked)
              PickedAttachment(name: file.name, readBytes: file.readBytes),
          ]);
        })
        .whenComplete(endComposerNativePicker)
        .ignore();
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
    final auth = context.read<AuthProvider>();

    GifPickerSheet.show(
      context,
      onGifSelected: (gifUrl) {
        messaging.sendGif(auth.token!, gifUrl, result.$2);
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

/// One row of the Android attachment sheet: icon + label, full-width tap
/// target. Android may look like itself (owner ruling 2026-08-19) — this is
/// deliberately NOT a Cupertino action sheet or a dark iOS UIMenu clone.
class _AttachmentDoorRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AttachmentDoorRow({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: theme.textTheme.bodyLarge),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData? icon;
  final Widget? customIcon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;
  final bool showBadge;

  const _ActionTile({
    this.icon,
    this.customIcon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.showBadge = false,
  }) : assert((icon == null) != (customIcon == null));

  @override
  Widget build(BuildContext context) {
    final badgeColor = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: customIcon ?? Icon(icon, size: 24, color: color),
              ),
              if (showBadge)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: badgeColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LongPressActionTile extends StatefulWidget {
  final IconData icon;
  final Color color;

  /// Named like every sibling [_ActionTile]: an unlabelled destructive tile
  /// tells the user nothing about what completing the hold will do.
  final String tooltip;

  /// Shown under the progress ring WHILE holding, so the scope is on screen
  /// during the window where releasing still aborts.
  final String holdLabel;
  final VoidCallback onLongPressComplete;

  const _LongPressActionTile({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.holdLabel,
    required this.onLongPressComplete,
  });

  @override
  State<_LongPressActionTile> createState() => _LongPressActionTileState();
}

class _LongPressActionTileState extends State<_LongPressActionTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  bool _isPressed = false;
  OverlayEntry? _progressOverlay;

  @override
  void initState() {
    super.initState();
    // No per-frame listener here: build() renders a static icon and reads
    // nothing controller-derived. The visible progress ring is painted by the
    // overlay's own AnimatedBuilder, so a setState listener was ~90 wasted
    // rebuilds per 1500 ms gesture.
    _animationController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1500),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && _isPressed) {
            widget.onLongPressComplete();
            _reset();
          }
        });
  }

  @override
  void dispose() {
    _removeProgressOverlay();
    _animationController.dispose();
    super.dispose();
  }

  void _removeProgressOverlay() {
    _progressOverlay?.remove();
    _progressOverlay = null;
  }

  void _reset() {
    _removeProgressOverlay();
    setState(() {
      _isPressed = false;
      _animationController.reset();
    });
  }

  void _showProgressOverlay() {
    _removeProgressOverlay();
    final overlay = Overlay.of(context);
    final accentColor = Theme.of(context).colorScheme.primary;
    _progressOverlay = OverlayEntry(
      builder: (context) => _CenterProgressOverlay(
        progress: _animationController,
        color: accentColor,
        label: widget.holdLabel,
      ),
    );
    overlay.insert(_progressOverlay!);
  }

  void _onLongPressStart(LongPressStartDetails details) {
    setState(() => _isPressed = true);
    _animationController.forward();
    _showProgressOverlay();
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_animationController.status != AnimationStatus.completed) {
      _reset();
    }
  }

  void _onLongPressCancel() {
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onLongPressStart: _onLongPressStart,
        onLongPressEnd: _onLongPressEnd,
        onLongPressCancel: _onLongPressCancel,
        child: Container(
          width: 40,
          height: 40,
          padding: const EdgeInsets.all(8),
          child: Icon(widget.icon, size: 24, color: widget.color),
        ),
      ),
    );
  }
}

class _CenterProgressOverlay extends StatelessWidget {
  final Animation<double> progress;
  final Color color;
  final String label;

  const _CenterProgressOverlay({
    required this.progress,
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: progress,
              builder: (context, _) {
                return CustomPaint(
                  size: const Size(100, 100),
                  painter: _CircularProgressPainter(
                    progress: progress.value,
                    color: color,
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            // Was `clearingChat` ("Clearing…") — present tense while the
            // gesture is still abortable and the wipe has not been requested,
            // and silent about the scope. The label now says what completing
            // the hold does.
            // Bounded so the caption WRAPS instead of running to the screen
            // edges: the old `clearingChat` was one short word, this is a
            // sentence, and `textAlign` alone centres nothing when the Text is
            // free to size to its full intrinsic width.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: RpgTheme.bodyFont(fontSize: 14, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircularProgressPainter extends CustomPainter {
  final double progress; // 0.0 to 1.0
  final Color color;

  _CircularProgressPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Background circle (light gray)
    final bgPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawCircle(center, radius, bgPaint);

    // Progress arc (red)
    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    final sweepAngle = 2 * 3.14159 * progress; // Full circle = 2π
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159 / 2, // Start at top (-90 degrees)
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(_CircularProgressPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
