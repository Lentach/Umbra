import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme/rpg_theme.dart';
import '../widgets/glass/glass_top_bar.dart';

/// The server's About limit (`UpdateProfileAboutDto`, `@MaxLength(80)`).
const int kProfileAboutMaxLength = 80;

final RegExp _presentationSequence = RegExp('[^\uFE0F\uFE0E][\uFE0F\uFE0E]');
final RegExp _surrogatePair = RegExp('[\uD800-\uDBFF][\uDC00-\uDFFF]');

/// Length as the server counts it: validator's `isLength` — UTF-16 units minus
/// surrogate pairs and presentation sequences. Not user-visible characters
/// (Flutter's `maxLength`): a flag counts 2 here, a family emoji 5, so 41 flags
/// pass a grapheme counter and are refused with a 400.
int profileAboutLength(String text) =>
    text.length -
    _presentationSequence.allMatches(text).length -
    _surrogatePair.allMatches(text).length;

/// Keeps the field within [kProfileAboutMaxLength] by the server's count. Like
/// `LengthLimitingTextInputFormatter`: an edit to a field that is already full
/// is refused (the old value stays), and an over-long paste into a field with
/// room is cut at the last whole character that fits, keeping the selection
/// and the IME composing region while they still lie inside the kept text.
class _ProfileAboutLimiter extends TextInputFormatter {
  const _ProfileAboutLimiter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (profileAboutLength(newValue.text) <= kProfileAboutMaxLength) {
      // The database column counts code points, which the validator's count
      // undercounts for an emoji presentation sequence (R12-BE-01).
      return newValue.text.runes.length <= kProfileAboutMaxLength
          ? newValue
          : oldValue;
    }
    // Already full: typing mid-text must not push the last character out.
    if (profileAboutLength(oldValue.text) >= kProfileAboutMaxLength) {
      return oldValue;
    }
    final kept = StringBuffer();
    // Anything past twice the limit cannot fit: a character costs at least
    // one unit of the count, so a long paste is not measured rune by rune.
    for (final rune in newValue.text.runes.take(kProfileAboutMaxLength * 2 + 2)) {
      final next = StringBuffer()
        ..write(kept)
        ..writeCharCode(rune);
      if (profileAboutLength(next.toString()) > kProfileAboutMaxLength ||
          next.toString().runes.length > kProfileAboutMaxLength) {
        break;
      }
      kept.writeCharCode(rune);
    }
    final text = kept.toString();
    int clamp(int offset) => offset < 0 || offset > text.length
        ? text.length
        : offset;
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
              }) => Text(
                '${profileAboutLength(_controller.text)}/$kProfileAboutMaxLength',
              ),
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
