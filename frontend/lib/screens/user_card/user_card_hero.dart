part of '../user_card_screen.dart';

/// Collapsing full-bleed photo hero (Telegram-style shrink-to-circle).
///
/// The photo fills the header while expanded; past 55% collapse it morphs
/// (rect + border radius lerp) into a 40px circle sitting where a top-bar
/// avatar would be, and the bar title fades in. [photo] null shows the
/// initials placeholder with the same collapse.
class _ProfileHeroDelegate extends SliverPersistentHeaderDelegate {
  final UserCardVisualData data;
  final ImageProvider? photo;
  final double topInset;
  final VoidCallback onCopy;
  final Color scaffoldColor;
  final Color onSurface;
  final double photoExtent;

  const _ProfileHeroDelegate({
    required this.data,
    required this.photo,
    required this.topInset,
    required this.onCopy,
    required this.scaffoldColor,
    required this.onSurface,
    required this.photoExtent,
  });

  static const double _barHeight = 68;
  static const double _circleSize = 40;

  @override
  double get maxExtent => topInset + photoExtent;

  @override
  double get minExtent => topInset + _barHeight;

  @override
  bool shouldRebuild(_ProfileHeroDelegate oldDelegate) =>
      oldDelegate.data != data ||
      oldDelegate.photo != photo ||
      oldDelegate.topInset != topInset ||
      oldDelegate.scaffoldColor != scaffoldColor ||
      oldDelegate.photoExtent != photoExtent;

  /// Telegram-style placeholder: same gradient family as AvatarCircle, big
  /// initial, scaled down with the morph so the collapsed circle reads like
  /// a normal avatar.
  Widget _placeholder(BuildContext context, double morphT) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: RpgTheme.isDark(context)
              ? [colors.secondary, colors.primary]
              : [colors.primary, colors.secondary],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        data.username.isNotEmpty ? data.username[0].toUpperCase() : '?',
        style: RpgTheme.bodyFont(
          fontSize: lerpDouble(96, 22, morphT)!,
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final l10n = AppLocalizations.of(context);
    final t = (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0);
    // Photo stays full-bleed for the first 55% of the collapse, then morphs
    // into the bar circle over the remaining 45%.
    // Snap the endpoints: (1 - 0.55) / 0.45 is 0.9999999999999999 in FP, so
    // without this the `morphT == 1` state (rect exactly the bar circle) is
    // never reached even at full collapse.
    final rawMorphT = Curves.easeInOut.transform(
      ((t - 0.55) / 0.45).clamp(0.0, 1.0),
    );
    final morphT = rawMorphT > 0.999
        ? 1.0
        : (rawMorphT < 0.001 ? 0.0 : rawMorphT);
    // Overlays (name, scrim) fade out early.
    final heroOpacity = (1 - t / 0.55).clamp(0.0, 1.0);
    // Bar title fades in across the whole morph (review nit: thresholding
    // morphT AGAIN made the title pop in abruptly near full collapse).
    final barOpacity = morphT;
    final shown = photo;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = math.max(minExtent, maxExtent - shrinkOffset);
        final circleTop = topInset + (_barHeight - _circleSize) / 2;
        final photoRect = Rect.lerp(
          Rect.fromLTWH(0, 0, width, height),
          Rect.fromLTWH(66, circleTop, _circleSize, _circleSize),
          morphT,
        )!;
        final radius = lerpDouble(0, _circleSize / 2, morphT)!;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: ColoredBox(color: scaffoldColor)),
            Positioned.fromRect(
              rect: photoRect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (shown == null)
                      _placeholder(context, morphT)
                    else
                      // Single cover layer: the hero box follows the photo's
                      // aspect (photoExtent), so cover fills the full width
                      // with no crop and no bars while expanded, and crops
                      // naturally as the rect morphs into the 40px bar
                      // circle. A photo that cannot be drawn is the same
                      // placeholder as no photo.
                      Semantics(
                        image: true,
                        label: data.handle,
                        child: Image(
                          image: shown,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              _placeholder(context, morphT),
                        ),
                      ),
                    // Edge scrim for status-bar icons and the identity block.
                    // MUST stay pointer-transparent: a full-bleed BoxDecoration
                    // hit-tests as a solid rectangle and would swallow taps
                    // meant for the hero.
                    IgnorePointer(
                      child: Opacity(
                        opacity: heroOpacity,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x59000000),
                                Color(0x00000000),
                                Color(0x8A000000),
                              ],
                              stops: [0, 0.42, 1],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (heroOpacity > 0)
              Positioned(
                left: 18,
                right: 12,
                bottom: 14,
                child: Opacity(
                  opacity: heroOpacity,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.username,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RpgTheme.bodyFont(
                                fontSize: 23,
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: onCopy,
                              child: Text(
                                data.handle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: RpgTheme.bodyFont(
                                  fontSize: 12.5,
                                  color: Colors.white.withValues(alpha: 0.78),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.userCardCopyHandle,
                        onPressed: onCopy,
                        color: Colors.white,
                        icon: const Icon(Icons.copy_outlined, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            // Collapsed bar title next to the shrunken circle avatar.
            if (barOpacity > 0)
              Positioned(
                left: 66 + _circleSize + 10,
                top: circleTop,
                height: _circleSize,
                right: 16,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: barOpacity,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        data.handle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RpgTheme.bodyFont(
                          fontSize: 16,
                          color: onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: topInset + 8,
              left: 14,
              child: GlassCircle(
                size: 52,
                child: Center(
                  child: IconButton(
                    tooltip: l10n.userCardBack,
                    icon: Icon(
                      Icons.arrow_back,
                      color: morphT > 0.5 ? onSurface : Colors.white,
                    ),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
