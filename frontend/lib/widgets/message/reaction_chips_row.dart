import 'package:flutter/material.dart';
import '../../utils/jumbo_emoji.dart';

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
      return Semantics(
        label: isMine
            ? 'Remove ${e.key} reaction (${e.value.length})'
            : 'React with ${e.key} (${e.value.length})',
        button: true,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: () => onTap(e.key, isMine),
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
                    text: e.key,
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
