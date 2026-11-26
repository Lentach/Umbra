import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme/rpg_theme.dart';
import '../widgets/glass/glass_top_bar.dart';

/// The About limit as the user sees it: 80 characters (grapheme clusters, the
/// server's `MaxGraphemes(80)`), and 640 code points (its `MaxCodePoints(640)`
/// and the column CHECK of migration 0032), the backstop for one cluster with
/// an unbounded number of combining marks.
const int kProfileAboutMaxGraphemes = 80;
const int kProfileAboutMaxCodePoints = 640;

/// Keeps the field within both limits. Like `LengthLimitingTextInputFormatter`:
/// an edit to a field that is already full is refused (the old value stays),
/// and an over-long paste into a field with room is cut at the last whole
/// character that fits, keeping the selection and the IME composing region
/// while they still lie inside the kept text.
class _ProfileAboutLimiter extends TextInputFormatter {
  const _ProfileAboutLimiter();

  static bool _fits(int graphemes, int codePoints) =>
      graphemes <= kProfileAboutMaxGraphemes &&
      codePoints <= kProfileAboutMaxCodePoints;

  static bool _textFits(String text) =>
      _fits(text.characters.length, text.runes.length);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (_textFits(newValue.text)) return newValue;
    // Already full: typing mid-text must not push the last character out.
    if (!_textFits(oldValue.text) ||
        oldValue.text.characters.length >= kProfileAboutMaxGraphemes ||
        oldValue.text.runes.length >= kProfileAboutMaxCodePoints) {
      return oldValue;
    }
    final kept = StringBuffer();
    var graphemes = 0;
    var codePoints = 0;
    for (final cluster in newValue.text.characters) {
      graphemes += 1;
      codePoints += cluster.runes.length;
      if (!_fits(graphemes, codePoints)) break;
      kept.write(cluster);
    }
    final text = kept.toString();
    int clamp(int offset) =>
        offset < 0 || offset > text.length ? text.length : offset;
    final composing = newValue.composing;
    return TextEditingValue(
      text: text,
      selection: newValue.selection.copyWith(
        baseOffset: clamp(newValue.selection.baseOffset),
        extentOffset: clamp(newValue.selection.extentOffset),
      ),
      composing: composing.isValid && composing.end <= text.length
          ? composing
          : TextRange.empty,
    );
  }
}

/// The counter shows whichever limit is closer to binding, so a field stopped
/// by the code-point backstop does not read "5/80".
String profileAboutCounter(String text) {
  final graphemes = text.characters.length;
  final codePoints = text.runes.length;
  return codePoints * kProfileAboutMaxGraphemes >
          graphemes * kProfileAboutMaxCodePoints
      ? '$codePoints/$kProfileAboutMaxCodePoints'
      : '$graphemes/$kProfileAboutMaxGraphemes';
}

/// Full-screen About editor (replaces the centered autofocus dialog).
///
/// The field is anchored to the TOP of the screen on purpose: iOS WebKit
/// pans the page to reveal a focused input the keyboard would cover, and a
/// mid-screen dialog field made the whole app jump (frontend/CLAUDE.md §7
/// keyboard-inset trap). A top-anchored field is never covered, so WebKit
/// leaves the viewport alone.
///
/// Pops with the edited text (caller persists it); pops with null on cancel.
class EditAboutScreen extends StatefulWidget {
  final String? initialAbout;

  const EditAboutScreen({super.key, this.initialAbout});

  @override
  State<EditAboutScreen> createState() => _EditAboutScreenState();
}

class _EditAboutScreenState extends State<EditAboutScreen> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialAbout ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        leading: IconButton(
          tooltip: l10n.userCardCancel,
          icon: Icon(Icons.close, color: theme.colorScheme.onSurface),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          l10n.userCardEditAbout,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        trailing: [
          IconButton(
            tooltip: l10n.userCardSave,
            icon: Icon(Icons.check, color: theme.colorScheme.primary),
            onPressed: _save,
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          MediaQuery.paddingOf(context).top + GlassTopBar.capsuleHeight + 32,
          20,
          0,
        ),
        child: TextField(
          controller: _controller,
          autofocus: true,
          inputFormatters: const [_ProfileAboutLimiter()],
          buildCounter:
              (
                context, {
                required currentLength,
                required isFocused,
                required maxLength,
              }) => Text(profileAboutCounter(_controller.text)),
          maxLines: 3,
          minLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          style: RpgTheme.bodyFont(
            fontSize: 15,
            color: theme.colorScheme.onSurface,
          ),
          decoration: InputDecoration(
            hintText: l10n.userCardAboutHint,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }
}
