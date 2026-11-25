import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show kIsWeb, visibleForTesting, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../constants/app_constants.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/messaging_provider.dart';
import '../../providers/settings_provider.dart';
import '../../theme/glass_theme.dart';
import '../../theme/rpg_theme.dart';
import '../glass/glass_surface.dart';
import '../../utils/composer_paste.dart';
import '../../utils/message_expiry.dart';
import '../../utils/message_length.dart';
import '../../utils/reply_preview_helper.dart';
import '../../utils/soft_keyboard.dart';
import '../../utils/web_keyboard_inset.dart';
import '../../utils/web_focus_guard.dart';
import '../../utils/web_ios_webkit.dart';
import '../../utils/web_viewport_scroll.dart';
import '../../utils/web_ios_viewport_pin.dart';
import '../../services/media_crypto_service.dart';
import '../../utils/video_preview.dart';
import '../../utils/video_probe_stub.dart'
    if (dart.library.html) '../../utils/video_probe_web.dart'
    if (dart.library.io) '../../utils/video_probe_io.dart'
    as video_probe;
import '../../utils/video_transcode_stub.dart'
    if (dart.library.io) '../../utils/video_transcode_io.dart'
    as video_transcode;
import '../chat_action_tiles.dart';
import '../hearth_fade_hex.dart';
import '../top_snackbar.dart' show showTopSnackBar;
import '../emoji/fireplace_emoji_picker.dart';
import 'attachment_handler.dart';
import 'composer_attachment_bar.dart';
import 'composer_attachment_controller.dart';
import 'focus_guard_area.dart';
import 'hex_send_button.dart';
import 'recording_controller.dart';
import 'reply_preview_bar.dart';
import 'edit_preview_bar.dart';
import 'composer_keyboard_signals.dart';
import 'composer_emoji_text_editing.dart';
import 'picked_attachment.dart';

part 'chat_input_bar/core.dart';
part 'chat_input_bar/emoji_panel.dart';
part 'chat_input_bar/focus.dart';
part 'chat_input_bar/send.dart';
part 'chat_input_bar/trailing_slot.dart';

class ChatInputBar extends StatefulWidget {
  const ChatInputBar({super.key});

  @override
  State<ChatInputBar> createState() => ChatInputBarState();
}

class ChatInputBarState extends State<ChatInputBar>
    with
        SingleTickerProviderStateMixin,
        _ComposerCore,
        _ComposerEmojiPanel,
        _ComposerFocus,
        _ComposerSend,
        _ComposerTrailingSlot {
  static const Duration _kTrailingSendFadeDuration = Duration(
    milliseconds: 175,
  );
  static const Object _composerTapRegionGroup = Object();
  /// Test seam for the oversize-video transcode: unit tests cannot reach the
  /// native codec channel, and the real thing is pinned on-device instead.
  /// Non-null only under test.
  @visibleForTesting
  static Future<Uint8List?> Function(Uint8List bytes)? debugTranscodeOverride;

  /// Test seam for the video probe: under `flutter test` the dart:io probe
  /// answers [VideoPreview.unknown] at once, so nothing can happen DURING it.
  /// Non-null only under test.
  @visibleForTesting
  static Future<VideoPreview> Function(Uint8List bytes)? debugProbeOverride;

  @visibleForTesting
  bool get isActionPanelOpenForTest => _showActionPanel;

  @visibleForTesting
  bool get isEmojiPickerOpenForTest => _showEmojiPicker;

  /// Mobile = Android/iOS regardless of native-vs-web: [defaultTargetPlatform]
  /// reflects the underlying OS on web, so a phone PWA counts as mobile while
  /// desktop web does not (kIsWeb would misclassify both).
  static bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Timer? _typingDebounceTimer;

  @override
  void initState() {
    super.initState();
    _emojiPanelController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _emojiPanelOffset =
        Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _emojiPanelController,
            curve: Curves.easeOutCubic,
          ),
        );
    _controller.addListener(() {
      if (_controller.text.trim().isEmpty) return;
      _typingDebounceTimer?.cancel();
      _typingDebounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) context.read<MessagingProvider>().emitTyping();
      });
    });

    _attachment.addListener(_onAttachmentChanged);

    // Telegram/Signal contract: keyboard and emoji panel are mutually
    // exclusive. Any composer focus gain (field tap, reply/edit refocus)
    // closes the panel so they never stack.
    _focusNode.addListener(_closeEmojiPickerOnFocusGain);
    _sharedInsetSource = sharedKeyboardInsetSource();
    if (kIsWeb) {
      _focusNode.addListener(_onComposerFocusForWebViewport);
      // Single source of truth for keyboard visibility (iOS WebKit's
      // viewInsets read 0): drives bottomInteractivePadding. The inactive
      // source never fires off iOS web.
      _lastSharedInsetVisible = _sharedInsetSource.inset.value > 0;
      _sharedInsetSource.inset.addListener(_onSharedKeyboardInsetChanged);
      ensureFocusGuardListenerInstalled();
      installComposerPasteListener(
        shouldHandle: _canAcceptPaste,
        onImage: _onPastedImage,
        onText: _insertPastedText,
      );
    }
  }

  void _onAttachmentChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final messaging = context.read<MessagingProvider>();
    if (_messagingProvider != messaging) {
      _messagingProvider?.removeListener(_onMessagingProviderChanged);
      _messagingProvider = messaging;
      messaging.addListener(_onMessagingProviderChanged);
      messaging.setComposerFocusRequest(_requestComposerFocus);
      _onReplyTargetChanged(messaging.replyingToMessage);
      _onEditTargetChanged(messaging.editingMessage);
    }
    _conversationsProvider = context.read<ConversationsProvider>();
  }

  @override
  void dispose() {
    // Reset the pin so the next chat opens unpinned, but DEFER it: a sync
    // notify here fires the still-mounted ancestor viewport's
    // setState during tree finalization (locked-tree assert when leaving the
    // chat with the panel open). By microtask time the tree is unlocked (or
    // the viewport is unmounted and its listener no-ops on the mounted guard).
    scheduleMicrotask(() => composerBottomPanelPinned.value = false);
    _focusNode.removeListener(_closeEmojiPickerOnFocusGain);
    if (kIsWeb) {
      _focusNode.removeListener(_onComposerFocusForWebViewport);
      _sharedInsetSource.inset.removeListener(_onSharedKeyboardInsetChanged);
      setIOSComposerViewportPin(false);
      uninstallComposerPasteListener();
    }
    _collapseGuardTimer?.cancel();
    composerKeyboardCollapseGuard.value = false;
    _messagingProvider?.setComposerFocusRequest(null);
    _messagingProvider?.removeListener(_onMessagingProviderChanged);
    _attachment.removeListener(_onAttachmentChanged);
    _attachment.dispose();
    _controller.dispose();
    _focusNode.dispose();
    _typingDebounceTimer?.cancel();
    _emojiPanelController.dispose();
    super.dispose();
  }

  /// Widget tests: mirror recording state without mic hardware.
  @visibleForTesting
  void setRecordingForTest(bool isRecording) {
    _onRecordingStateChanged(isRecording);
  }

  /// Widget tests: stage attachments without a paste source (Phases 3/4 add those).
  @visibleForTesting
  ComposerAttachmentController get attachmentControllerForTest => _attachment;

  /// Widget tests: trigger and await the send path (the tap overlay is private).
  @visibleForTesting
  Future<void> sendForTest() async {
    if (_attachment.staged != null) {
      await _sendStaged();
    } else {
      _send();
    }
  }

  /// Widget tests: drive the paste-image handler without a DOM paste event.
  @visibleForTesting
  void handlePastedImageForTest(
    Uint8List bytes,
    String mimeType,
    String filename,
  ) => _onPastedImage(bytes, mimeType, filename);

  /// Widget tests: drive cursor-aware pasted-text insertion.
  @visibleForTesting
  void insertPastedTextForTest(String text) => _insertPastedText(text);

  /// Widget tests: exercise trailing spinner / send precedence without upload pipeline.
  @visibleForTesting
  void setSendingVoiceForTest(bool isSendingVoice) {
    setState(() => _isSendingVoice = isSendingVoice);
  }

  String _bannerDurationLabel(AppLocalizations l10n, int seconds) {
    final parts = splitDisappearingSeconds(seconds);
    final summaryParts = <String>[];
    if (parts.days > 0) {
      summaryParts.add(l10n.disappearingTimerDays(parts.days));
    }
    if (parts.hours > 0) {
      summaryParts.add(l10n.disappearingTimerHours(parts.hours));
    }
    if (parts.minutes > 0) {
      summaryParts.add(l10n.disappearingTimerMinutes(parts.minutes));
    }
    if (parts.seconds > 0) {
      summaryParts.add(l10n.disappearingTimerSeconds(parts.seconds));
    }
    return summaryParts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild only for composer-relevant provider slices so message list / decrypt
    // updates do not dismiss the Android soft keyboard while typing.
    final replyingTo = context.select<MessagingProvider, MessageModel?>(
      (m) => m.replyingToMessage,
    );
    final editing = context.select<MessagingProvider, MessageModel?>(
      (m) => m.editingMessage,
    );

    final activeTimer = context.select<ConversationsProvider, int?>(
      (c) => c.conversationDisappearingTimer,
    );
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final glass = GlassTheme.of(context);
    final themePref = context.select<SettingsProvider, String>(
      (s) => s.themePreference,
    );
    final ephemeral = RpgTheme.ephemeralAccent(
      context,
      themePreference: themePref,
    );
    final mediaQuery = MediaQuery.of(context);
    final pad = mediaQuery.padding;
    final isCompactLayout =
        mediaQuery.size.width < AppConstants.layoutBreakpointDesktop;
    // Phone / narrow PWA: keep trailing mic off the physical right edge so OS back-swipe
    // and browser edge gestures are less likely to steal a touch on it.
    const trailingGestureBufferDp = 14.0;
    final trailingGestureBuffer = isCompactLayout
        ? trailingGestureBufferDp
        : 0.0;
    // Insets for notches / home indicator: chat body no longer applies horizontal SafeArea
    // around the composer (see ChatDetailScreen), so we pad here instead.
    final composerHorizontalPadding = EdgeInsets.fromLTRB(
      8.0 + pad.left,
      8.0,
      4.0 + pad.right + trailingGestureBuffer,
      8.0,
    );
    // Single source of truth (D2 fix): MediaQuery.viewInsets reads 0 on iOS
    // WebKit while the keyboard is up — fold in the shared visualViewport
    // inset so the ergonomic bottom buffer never renders underneath a raised
    // keyboard.
    //
    // FOCUS IS DELIBERATELY NOT A TERM HERE (H1 reverted 2026-09-12, owner
    // report + desktop/mobile screenshots). The buffer is the composer's
    // resting clearance over the home indicator and — inside MainShell's
    // `extendBody: true` Scaffold, where the bottom nav height arrives as
    // MediaQuery.padding.bottom — over the bottom nav. Collapsing it on focus
    // moved the composer DOWN by that clearance with nothing lifting it:
    // desktop web (no soft keyboard at all) buried the input row behind the
    // nav bar, and on phones it dropped to the physical bottom edge in the
    // window before the keyboard inset ticks up. Only a real inset — which
    // simultaneously lifts the composer via ChatComposerViewport's
    // `bottom: effectiveInset` — may collapse it.
    final keyboardVisible =
        mediaQuery.viewInsets.bottom > 0 ||
        _sharedInsetSource.inset.value > 0;
    final bottomSystemInset = math.max(
      mediaQuery.viewPadding.bottom,
      mediaQuery.padding.bottom,
    );
    const additionalBottomSpacing = 16.0;
    final needsErgonomicBuffer = bottomSystemInset > 0;
    final webMobileFallbackInset =
        !needsErgonomicBuffer && kIsWeb && isCompactLayout && !keyboardVisible
        ? 16.0
        : 0.0;
    final bottomInteractivePadding = keyboardVisible
        ? 0.0
        : (needsErgonomicBuffer
              ? bottomSystemInset + additionalBottomSpacing
              : webMobileFallbackInset);

    // Cap multiline growth: Row/Expanded can still pass a tall maxHeight; keep the
    // composer Telegram-like even under large text scale or IME quirks.
    final textScaler = MediaQuery.textScalerOf(context);
    final maxComposerHeight = (textScaler.scale(22.0) * 12 + 36).clamp(
      120.0,
      480.0,
    );

    // Telegram/Signal parity: system back with the emoji panel open closes
    // the panel instead of leaving the chat.
    return PopScope(
      canPop: !_showEmojiPicker,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showEmojiPicker) {
          setState(() => _setEmojiPickerVisible(false, animateExit: true));
        }
      },
      child: TapRegion(
        groupId: _composerTapRegionGroup,
        onTapOutside: _handleComposerRegionTapOutside,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Reply preview
            if (replyingTo != null)
              Selector<MessagingProvider, MessageModel>(
                selector: (_, messaging) {
                  return findMessageById(replyingTo.id, messaging.messages) ??
                      replyingTo;
                },
                builder: (context, resolvedReply, _) {
                  return ReplyPreviewBar(
                    message: resolvedReply,
                    onDismiss: () =>
                        context.read<MessagingProvider>().clearReplyingTo(),
                  );
                },
              ),

            // Editing banner
            if (editing != null)
              EditPreviewBar(
                onDismiss: () =>
                    context.read<MessagingProvider>().cancelEditMessage(),
              ),

            if (activeTimer != null)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ephemeral.withValues(alpha: 0.5)),
                ),
                child: Semantics(
                  label: l10n.disappearingComposerBannerSemantics(
                    _bannerDurationLabel(l10n, activeTimer),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CustomPaint(
                          size: const Size(14, 14),
                          painter: HearthFadeHexPainter(
                            color: ephemeral,
                            preRead: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            l10n.disappearingComposerBanner(
                              _bannerDurationLabel(l10n, activeTimer),
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: RpgTheme.bodyFont(
                              fontSize: 11,
                              color: ephemeral,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Staged pasted image (Clipboard Phase 2)
            if (_attachment.staged != null && !_isRecording)
              ComposerAttachmentBar(
                attachment: _attachment.staged!,
                onRemove: _attachment.clear,
              ),

            // Input row
            TapRegion(
              groupId: _composerTapRegionGroup,
              // Liquid Glass: the input row is a floating glass pill; the
              // surrounding area is transparent so chat content scrolls
              // behind it. Structure (TapRegion/FocusGuardArea/trailing
              // stack) is unchanged — glass is paint, not layout.
              child: Padding(
                padding: composerHorizontalPadding,
                child: GlassSurface(
                  borderRadius: BorderRadius.circular(28),
                  child: Row(
                    children: [
                      // Action panel toggle (hidden during recording)
                      if (!_isRecording)
                        FocusGuardArea(
                          id: 'composer_action_toggle',
                          child: Focus(
                            canRequestFocus: false,
                            child: IconButton(
                              icon: Icon(
                                _showActionPanel
                                    ? Icons.keyboard_arrow_up
                                    : Icons.keyboard_arrow_down,
                              ),
                              iconSize: 24,
                              color: glass.onGlassMuted,
                              onPressed: _toggleActionPanel,
                            ),
                          ),
                        ),
                      if (!_isRecording)
                        FocusGuardArea(
                          id: 'composer_emoji_toggle',
                          child: Focus(
                            canRequestFocus: false,
                            child: Semantics(
                              button: true,
                              label: l10n.chatComposerEmojiSemantics,
                              excludeSemantics: true,
                              child: IconButton(
                                key: const ValueKey('composer-emoji-toggle'),
                                tooltip: l10n.chatComposerEmojiTooltip,
                                icon: Icon(
                                  _showEmojiPicker
                                      ? Icons.keyboard_alt_outlined
                                      : Icons.emoji_emotions_outlined,
                                ),
                                iconSize: 24,
                                color: _showEmojiPicker
                                    ? glass.onGlassAccent
                                    : glass.onGlassMuted,
                                onPressed: _toggleEmojiPicker,
                              ),
                            ),
                          ),
                        ),
                      // Text field or recording bar
                      Expanded(
                        child: _isRecording
                            ? Builder(
                                builder: (context) {
                                  final recordingState =
                                      _recordingKey.currentState;
                                  if (recordingState == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return recordingState.buildRecordingBar(
                                    context,
                                  );
                                },
                              )
                            : CallbackShortcuts(
                                bindings: <ShortcutActivator, VoidCallback>{
                                  // Web/desktop: multiline fields often lack an IME “Send”; keep one send path.
                                  const SingleActivator(
                                    LogicalKeyboardKey.enter,
                                    control: true,
                                  ): _send,
                                  const SingleActivator(
                                    LogicalKeyboardKey.enter,
                                    meta: true,
                                  ): _send,
                                },
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: maxComposerHeight,
                                  ),
                                  child: TextField(
                                    controller: _controller,
                                    focusNode: _focusNode,
                                    // Incognito keyboard (Signal parity):
                                    // message text must not feed the IME's
                                    // personal dictionary / cloud sync.
                                    // Android-IME hint; no-op on web/iOS.
                                    enableIMEPersonalizedLearning: false,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    style: RpgTheme.bodyFont(
                                      fontSize: 14,
                                      color: colorScheme.onSurface,
                                    ),
                                    // Borderless inside the glass pill (spec
                                    // §5): the pill IS the field chrome.
                                    decoration: InputDecoration(
                                      hintText: AppLocalizations.of(
                                        context,
                                      ).chatMessageHint,
                                      hintStyle: RpgTheme.bodyFont(
                                        fontSize: 14,
                                        color: glass.onGlassMuted,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 10,
                                          ),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      filled: false,
                                    ),
                                    // Cap height so the composer does not consume the whole screen (matches
                                    // WhatsApp/Telegram-style behavior: grow to a few lines, then scroll inside).
                                    minLines: 1,
                                    maxLines: 12,
                                    // Platform matrix (owner ruling 2026-07-28):
                                    // - Mobile (Android/iOS, native or PWA): the
                                    //   IME action key inserts a NEWLINE; sending
                                    //   is the on-screen send button only.
                                    // - Desktop (web or native): UNCHANGED — IME
                                    //   "Send" action + Ctrl/Cmd+Enter shortcuts;
                                    //   plain Enter inserts '\n' in this
                                    //   multiline field.
                                    textInputAction: _isMobilePlatform
                                        ? TextInputAction.newline
                                        : TextInputAction.send,
                                    // Default [onEditingComplete] unfocuses after "Send", which dismisses
                                    // the keyboard while the node can still report focused in the same sync turn.
                                    onEditingComplete: () {},
                                    onSubmitted: _isMobilePlatform
                                        ? null
                                        : (_) => _send(),
                                    // Android/desktop should hide the keyboard when
                                    // the user taps the chat outside the whole
                                    // composer. Composer controls sit in the same
                                    // [TapRegion] group, so send/emoji/attachment
                                    // taps do not trigger this callback. iOS WebKit
                                    // keeps the old no-op because tap-outside blur
                                    // caused the send-button keyboard bounce.
                                    groupId: _composerTapRegionGroup,
                                    onTapOutside: _handleComposerTapOutside,
                                    // Android IME rich-content insertion (Phase 4);
                                    // other platforms never emit commitContent.
                                    contentInsertionConfiguration:
                                        ContentInsertionConfiguration(
                                          allowedMimeTypes:
                                              kStageableImageMimeTypes.toList(),
                                          onContentInserted:
                                              _onKeyboardContentInserted,
                                        ),
                                  ),
                                ),
                              ),
                      ),

                      const SizedBox(width: 2),

                      // Trailing 48×48 stack: mic always mounted; text send fades on top (Phase 0).
                      // CLAUDE.md: never swap mic/send as Row siblings — unmount dismisses keyboard.
                      FocusGuardArea(
                        id: 'composer_trailing',
                        child: _buildTrailingSlot(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (!_showActionPanel &&
                !_emojiPanelOccupiesLayout &&
                bottomInteractivePadding > 0)
              SizedBox(height: bottomInteractivePadding),

            // Action panel: instant mount/unmount, mirroring the emoji panel
            // (H3 — the 0.0.88 treatment). The 250ms SizeTransition kept a
            // ~300px block relayouting through the exact window where iOS
            // counter-pans the viewport and Android Chrome leaves stale
            // composited regions. The Listener captures focus state BEFORE
            // the tap's DOM blur so ping's keyboard-neutral refocus knows
            // whether the keyboard was up.
            if (_showActionPanel)
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) =>
                    _actionPanelPointerDownHadFocus = _focusNode.hasFocus,
                child: ChatActionTiles(
                  bottomPadding: bottomInteractivePadding,
                  onPingSent: _refocusComposerAfterPing,
                  onPickedFiles: sendPickedFiles,
                ),
              ),

            // Emoji panel: full 320px layout from the first frame (the bottom
            // pin reserves the keyboard's space instantly); only the CONTENT
            // slides, clipped to the panel's box — a pure paint transform,
            // for the same H3 reason the action panel above stays instant.
            if (_emojiPanelOccupiesLayout)
              ClipRect(
                child: SlideTransition(
                  position: _emojiPanelOffset,
                  child: FireplaceEmojiPicker(
                    onEmojiSelected: _insertEmoji,
                    onBackspacePressed: _deletePreviousEmoji,
                    height: 320,
                  ),
                ),
              ),
          ],
        ), // Column
      ), // TapRegion
    ); // PopScope
  }
}
