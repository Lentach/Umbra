import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';

import '../theme/rpg_theme.dart';

/// Shimmer placeholder shown while the chat list is still being read from the
/// contact store (`ConversationsProvider.hasLoadedConversations == false`).
///
/// A skeleton beats a bare spinner: it shows the SHAPE of what is loading, so
/// the arrival of real rows feels like content filling in rather than a screen
/// swap. Gate it on a real load signal only — never a timer — or it lies about
/// state (an empty account is not "loading").
class ConversationListSkeleton extends StatelessWidget {
  final EdgeInsets padding;
  final int rowCount;

  const ConversationListSkeleton({
    super.key,
    required this.padding,
    this.rowCount = 8,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = RpgTheme.isDark(context);
    // Derive the bone from the theme's onSurface so it picks up each theme's
    // warm/cool tint instead of a flat black/white wash (playbook §1).
    final boneColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.08 : 0.06);
    final borderColor = FireplaceColors.of(context).convItemBorder;
    // Honor reduce-motion: a static fill instead of a perpetual shimmer sweep.
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final PaintingEffect effect = reduceMotion
        ? SolidColorEffect(color: boneColor)
        : ShimmerEffect(
            baseColor: boneColor,
            highlightColor: boneColor.withValues(alpha: boneColor.a + 0.04),
            duration: const Duration(milliseconds: 1100),
          );

    return Skeletonizer(
      enabled: true,
      effect: effect,
      child: ListView.separated(
        padding: padding,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: rowCount,
        separatorBuilder: (_, _) => Divider(height: 1, color: borderColor),
        itemBuilder: (context, index) => const _SkeletonRow(),
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          const Bone.circle(size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Bone.text(width: 120, fontSize: 15),
                const SizedBox(height: 8),
                Bone.text(width: 200, fontSize: 13),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Bone.text(width: 34, fontSize: 12),
        ],
      ),
    );
  }
}
