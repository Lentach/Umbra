import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/conversations_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/rpg_theme.dart';
import '../utils/message_expiry.dart';
import 'glass/glass_sheet.dart';
import 'hearth_fade_hex.dart';

const double kDisappearingPickerHeight = 216;
const double kDisappearingPickerItemExtent = 32;
const int kDisappearingPickerMaxDays = 30;

/// How full the sheet's decorative hex looks for a timer of [totalSeconds].
///
/// Log scale over the valid range (5 s … 30 d), mapped to 0.35–1.0: a linear
/// scale put every timer under ~18 days on the same floor, so the hex said
/// nothing about the duration. The floor keeps a short timer from reading as
/// "almost expired"; 0 (timer off) is a separate, dimmer 0.15.
@visibleForTesting
double disappearingHeroProgress(int totalSeconds) {
  if (totalSeconds == 0) return 0.15;
  final t =
      math.log(totalSeconds / kDisappearingMinSeconds) /
      math.log(kDisappearingMaxSeconds / kDisappearingMinSeconds);
  return 0.35 + 0.65 * t.clamp(0.0, 1.0);
}

/// Opens the Hearth Fade disappearing-messages timer sheet.
void showDisappearingTimerSheet(BuildContext context) {
  final convs = context.read<ConversationsProvider>();
  final settings = context.read<SettingsProvider>();
  final initialSeconds = convs.conversationDisappearingTimer;
  showGlassSheet<void>(
    context,
    isScrollControlled: true,
    builder: (ctx) => MultiProvider(
      providers: [
        ChangeNotifierProvider<ConversationsProvider>.value(value: convs),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ],
      child: DisappearingTimerSheet(initialSeconds: initialSeconds),
    ),
  );
}

/// Branded D/H/M/S sheet for conversation disappearing timer (read-based).
class DisappearingTimerSheet extends StatefulWidget {
  final int? initialSeconds;

  const DisappearingTimerSheet({super.key, this.initialSeconds});

  @override
  State<DisappearingTimerSheet> createState() => _DisappearingTimerSheetState();
}

class _DisappearingTimerSheetState extends State<DisappearingTimerSheet> {
  late int _days;
  late int _hours;
  late int _minutes;
  late int _seconds;
  late final FixedExtentScrollController _daysController;
  late final FixedExtentScrollController _hoursController;
  late final FixedExtentScrollController _minutesController;
  late final FixedExtentScrollController _secondsController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final parts = splitDisappearingSeconds(widget.initialSeconds ?? 0);
    _days = parts.days.clamp(0, kDisappearingPickerMaxDays);
    _hours = parts.hours.clamp(0, 23);
    _minutes = parts.minutes.clamp(0, 59);
    _seconds = parts.seconds.clamp(0, 59);
    _daysController = FixedExtentScrollController(initialItem: _days);
    _hoursController = FixedExtentScrollController(initialItem: _hours);
    _minutesController = FixedExtentScrollController(initialItem: _minutes);
    _secondsController = FixedExtentScrollController(initialItem: _seconds);
  }

  @override
  void dispose() {
    _daysController.dispose();
    _hoursController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    super.dispose();
  }

  int get _totalSeconds => combineDisappearingSeconds(
    days: _days,
    hours: _hours,
    minutes: _minutes,
    seconds: _seconds,
  );

  void _turnOff() {
    _submit(null);
  }

  void _setTimer() {
    final l10n = AppLocalizations.of(context);
    final total = _totalSeconds;
    if (total == 0) {
      setState(() => _errorText = l10n.disappearingTimerOutOfRange);
      return;
    }
    if (total < kDisappearingMinSeconds || total > kDisappearingMaxSeconds) {
      setState(() => _errorText = l10n.disappearingTimerOutOfRange);
      return;
    }
    _submit(total);
  }

  void _submit(int? seconds) {
    final convs = context.read<ConversationsProvider>();
    final convId = convs.activeConversationId;
    if (convId != null) {
      convs.setDisappearingTimer(convId, seconds);
    }
    Navigator.pop(context);
  }

  String _summary(AppLocalizations l10n) {
    final total = _totalSeconds;
    if (total == 0) return l10n.disappearingTimerOff;
    final parts = <String>[];
    if (_days > 0) parts.add(l10n.disappearingTimerDays(_days));
    if (_hours > 0) parts.add(l10n.disappearingTimerHours(_hours));
    if (_minutes > 0) parts.add(l10n.disappearingTimerMinutes(_minutes));
    if (_seconds > 0) parts.add(l10n.disappearingTimerSeconds(_seconds));
    return parts.join(' ');
  }

  double _heroProgress() => disappearingHeroProgress(_totalSeconds);

  void _onDaysChanged(int index) {
    setState(() {
      _days = index;
      _errorText = null;
    });
  }

  void _onHoursChanged(int index) {
    setState(() {
      _hours = index;
      _errorText = null;
    });
  }

  void _onMinutesChanged(int index) {
    setState(() {
      _minutes = index;
      _errorText = null;
    });
  }

  void _onSecondsChanged(int index) {
    setState(() {
      _seconds = index;
      _errorText = null;
    });
  }

  Widget _columnLabel(String label, Color color) {
    return Expanded(
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }

  Widget _durationPicker({
    required String semanticsLabel,
    required int maxValue,
    required FixedExtentScrollController controller,
    required ValueChanged<int> onSelectedItemChanged,
  }) {
    return Expanded(
      child: Semantics(
        label: semanticsLabel,
        child: CupertinoPicker(
          scrollController: controller,
          itemExtent: kDisappearingPickerItemExtent,
          magnification: 1.1,
          squeeze: 1.1,
          useMagnifier: true,
          onSelectedItemChanged: onSelectedItemChanged,
          children: List<Widget>.generate(
            maxValue + 1,
            (i) => Center(child: Text('$i')),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final fc = FireplaceColors.of(context);
    final titleColor = colorScheme.onSurface;
    final labelColor = fc.mutedText;
    final accent = colorScheme.primary;
    final themePref = context.watch<SettingsProvider>().themePreference;
    final ephemeral = RpgTheme.ephemeralAccent(
      context,
      themePreference: themePref,
    );
    final summary = _summary(l10n);

    return CupertinoTheme(
      data: CupertinoTheme.of(context).copyWith(
        brightness: theme.brightness,
        primaryColor: accent,
        textTheme: CupertinoTextThemeData(
          pickerTextStyle: TextStyle(fontSize: 22, color: titleColor),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: labelColor.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Center(
                  child: HearthFadeHexHero(
                    color: ephemeral,
                    progress: _heroProgress(),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.disappearingTimerTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: fc.inputBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: fc.convItemBorder.withValues(alpha: 0.8),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.disappearingTimerExplainerLine1,
                        style: RpgTheme.bodyFont(
                          fontSize: 13,
                          color: titleColor.withValues(alpha: 0.92),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.disappearingTimerExplainerLine2,
                        style: RpgTheme.bodyFont(
                          fontSize: 13,
                          color: labelColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.disappearingTimerExplainerLine3,
                        style: RpgTheme.bodyFont(
                          fontSize: 13,
                          color: labelColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  label: l10n.disappearingTimerSummarySemantics(summary),
                  child: Text(
                    summary,
                    textAlign: TextAlign.center,
                    style: RpgTheme.bodyFont(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: titleColor,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.disappearingTimerRangeHint,
                  textAlign: TextAlign.center,
                  style: RpgTheme.bodyFont(fontSize: 12, color: labelColor),
                ),
                if (_errorText != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _errorText!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.error, fontSize: 14),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: fc.inputBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: fc.convItemBorder),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                        child: Row(
                          children: [
                            _columnLabel(
                              l10n.disappearingTimerDaysLabel,
                              labelColor,
                            ),
                            _columnLabel(
                              l10n.disappearingTimerHoursLabel,
                              labelColor,
                            ),
                            _columnLabel(
                              l10n.disappearingTimerMinutesLabel,
                              labelColor,
                            ),
                            _columnLabel(
                              l10n.disappearingTimerSecondsLabel,
                              labelColor,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: kDisappearingPickerHeight,
                        child: Row(
                          children: [
                            _durationPicker(
                              semanticsLabel: l10n.disappearingTimerDaysLabel,
                              maxValue: kDisappearingPickerMaxDays,
                              controller: _daysController,
                              onSelectedItemChanged: _onDaysChanged,
                            ),
                            _durationPicker(
                              semanticsLabel: l10n.disappearingTimerHoursLabel,
                              maxValue: 23,
                              controller: _hoursController,
                              onSelectedItemChanged: _onHoursChanged,
                            ),
                            _durationPicker(
                              semanticsLabel:
                                  l10n.disappearingTimerMinutesLabel,
                              maxValue: 59,
                              controller: _minutesController,
                              onSelectedItemChanged: _onMinutesChanged,
                            ),
                            _durationPicker(
                              semanticsLabel:
                                  l10n.disappearingTimerSecondsLabel,
                              maxValue: 59,
                              controller: _secondsController,
                              onSelectedItemChanged: _onSecondsChanged,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _turnOff,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: labelColor,
                          side: BorderSide(color: fc.convItemBorder),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(l10n.disappearingTimerTurnOff),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _setTimer,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: colorScheme.onPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(l10n.disappearingTimerSetTimer),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
