part of '../chat_input_bar.dart';

/// The always-mounted trailing 48x48 slot: mic, text send and voice send.
mixin _ComposerTrailingSlot on _ComposerSend {
  /// Trailing mic + text-send overlay. [ValueListenableBuilder] limits rebuilds to this slot.
  Widget _buildTrailingSlot(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final showTextSend =
            !_isRecording &&
            !_isSendingVoice &&
            !_isSendingStagedMedia &&
            (value.text.trim().isNotEmpty || _attachment.staged != null);
        final showVoiceSend = _isRecording && !_isSendingVoice;

        // ExcludeFocus on the whole trailing slot (mic + send overlay) so a tap
        // on either never steals focus from the text field. RecordingController
        // does not add a second ExcludeFocus — one ancestor is enough.
        return ExcludeFocus(
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ExcludeSemantics(
                  excluding: showTextSend || showVoiceSend,
                  child: IgnorePointer(
                    ignoring: _isRecording || _isSendingVoice,
                    child: AnimatedOpacity(
                      opacity: (showTextSend || showVoiceSend) ? 0.0 : 1.0,
                      duration: ChatInputBarState._kTrailingSendFadeDuration,
                      curve: Curves.easeInOut,
                      child: RecordingController(
                        key: _recordingKey,
                        onVoiceSent: _handleVoiceSent,
                        onRecordingStateChanged: _onRecordingStateChanged,
                        onMicTap: _onMicTap,
                        isSendingVoice: _isSendingVoice,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  key: const ValueKey('composer_text_send_layer'),
                  child: ExcludeSemantics(
                    excluding: !showTextSend,
                    child: IgnorePointer(
                      ignoring: !showTextSend,
                      child: AnimatedOpacity(
                        opacity: showTextSend ? 1 : 0,
                        duration: ChatInputBarState._kTrailingSendFadeDuration,
                        curve: Curves.easeInOut,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Ember hexagon — the app's shape language
                            // (paint only; the overlay below hits).
                            const IgnorePointer(child: HexSendButton()),
                            // Full 48×48 opaque tap target (was a left-nudged 22×22,
                            // easy to miss + leaked outer-ring taps to the mic).
                            Positioned.fill(
                              child: _ComposerTapSendOverlay(
                                enabled: showTextSend,
                                onTap: _send,
                                tooltip: l10n.chatComposerSendTooltip,
                                semanticsLabel: l10n.chatComposerSendSemantics,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  key: const ValueKey('composer_voice_send_layer'),
                  child: ExcludeSemantics(
                    excluding: !showVoiceSend,
                    child: IgnorePointer(
                      ignoring: !showVoiceSend,
                      child: AnimatedOpacity(
                        opacity: showVoiceSend ? 1 : 0,
                        duration: ChatInputBarState._kTrailingSendFadeDuration,
                        curve: Curves.easeInOut,
                        child: Tooltip(
                          message: l10n.voiceRecordingSendVoiceTooltip,
                          child: Semantics(
                            button: true,
                            label: l10n.voiceRecordingSendVoiceSemantics,
                            excludeSemantics: true,
                            child: IconButton(
                              onPressed: showVoiceSend
                                  ? () => _recordingKey.currentState
                                        ?.stopAndSend()
                                  : null,
                              padding: const EdgeInsets.all(12),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              icon: Icon(
                                Icons.send_rounded,
                                size: 22,
                                color: RpgTheme.primaryColor(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Tap-only trailing send, a plain [Listener] rather than an [IconButton]: an
/// [IconButton] here would win the gesture arena and block the mic beneath it
/// ([RecordingController] is tap-to-toggle, not hold-to-record).
class _ComposerTapSendOverlay extends StatefulWidget {
  const _ComposerTapSendOverlay({
    required this.enabled,
    required this.onTap,
    required this.tooltip,
    required this.semanticsLabel,
  });

  final bool enabled;
  final VoidCallback onTap;
  final String tooltip;
  final String semanticsLabel;

  @override
  State<_ComposerTapSendOverlay> createState() =>
      _ComposerTapSendOverlayState();
}

class _ComposerTapSendOverlayState extends State<_ComposerTapSendOverlay> {
  static const Duration _kTapMaxDuration = Duration(milliseconds: 300);
  static const double _kTapMaxMovement = 18.0;

  DateTime? _downTime;
  Offset? _downPosition;

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled) return;
    _downTime = DateTime.now();
    _downPosition = event.position;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!widget.enabled || _downTime == null || _downPosition == null) return;
    final duration = DateTime.now().difference(_downTime!);
    final moved = (event.position - _downPosition!).distance;
    _downTime = null;
    _downPosition = null;
    if (duration <= _kTapMaxDuration && moved <= _kTapMaxMovement) {
      widget.onTap();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _downTime = null;
    _downPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Tooltip(
        message: widget.tooltip,
        child: Semantics(
          button: true,
          label: widget.semanticsLabel,
          excludeSemantics: true,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
