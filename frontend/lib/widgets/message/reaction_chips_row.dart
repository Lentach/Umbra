import 'package:flutter/material.dart';
import '../../services/reactions/reaction_display.dart';
import '../../utils/jumbo_emoji.dart';

/// The glyph a chip shows when this device cannot name the reaction yet.
///
/// A reaction whose conversation key is missing, locked or not yet pulled
/// arrives as a 22-character token. It is rendered as a neutral mark with its
/// real COUNT, never hidden and never printed raw: hiding it would make the
/// peer's reaction indistinguishable from no reaction at all (design
/// falsification R4), and printing the token would put base64 in the bubble.
/// The chip re-renders for real as soon as the key lands.
const String kUnresolvedReactionGlyph = '•';

/// Displays a row of emoji reaction chips with counts.
class ReactionChipsRow extends StatelessWidget {
  final Map<String, List<int>> reactions;
  final int currentUserId;
  final void Function(String emoji, bool isMine) onTap;

  const ReactionChipsRow({
    super.key,
    required this.reactions,
    required this.currentUserId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chips = reactions.entries.where((e) => e.value.isNotEmpty).map((e) {
      final isMine = e.value.contains(currentUserId);
      final unresolved = isUnresolvedReactionKey(e.key);
      final shown = unresolved ? kUnresolvedReactionGlyph : e.key;
      return Semantics(
        label: unresolved
            // Never claims WHICH reaction it is, because this device does not
            // know — a screen reader must not invent one.
            ? 'Reaction not readable on this device (${e.value.length})'
            : isMine
            ? 'Remove ${e.key} reaction (${e.value.length})'
            : 'React with ${e.key} (${e.value.length})',
        button: true,
        excludeSemantics: true,
        child: GestureDetector(
          // Tapping an unnameable reaction cannot toggle it: this device cannot
          // compute the token, so it would ask the server to add a reaction it
          // cannot name. Inert until the key arrives.
          onTap: unresolved ? null : () => onTap(e.key, isMine),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isMine
                  ? Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.15)
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isMine
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: 0.4),
              ),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: shown,
                    style: const TextStyle(
                      fontFamily: kEmojiFontFamily,
                      fontFamilyFallback: kEmojiFontFamilyFallback,
                    ),
                  ),
                  TextSpan(text: ' ${e.value.length}'),
                ],
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      );
    }).toList();

    return Wrap(spacing: 4, runSpacing: 2, children: chips);
  }
}
