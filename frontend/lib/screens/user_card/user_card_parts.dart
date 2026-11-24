part of '../user_card_screen.dart';

/// D1 action tiles: Message / Mute as equal glass-tinted cards. Copy-tag
/// lives ONLY on the hero photo (icon + tappable handle) — the tile version
/// duplicated it (owner round-2 ask).
class _ActionTilesRow extends StatelessWidget {
  final bool hasConversation;
  final UserCardMute mute;
  final VoidCallback? onMessage;
  final void Function(BuildContext anchorContext)? onMute;

  const _ActionTilesRow({
    required this.hasConversation,
    required this.mute,
    required this.onMessage,
    required this.onMute,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: _ActionTile(
            icon: Icons.chat_bubble_outline,
            label: l10n.userCardMessage,
            onTap: onMessage,
          ),
        ),
        if (onMute != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Builder(
              builder: (tileContext) => _ActionTile(
                icon: mute == UserCardMute.off
                    ? Icons.notifications_outlined
                    : Icons.notifications_off_outlined,
                label: mute == UserCardMute.off
                    ? l10n.userCardMute
                    : l10n.userCardMuted,
                onTap: () => onMute!(tileContext),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final glass = GlassTheme.of(context);
    final accent = glass.onGlassAccent;
    final radius = BorderRadius.circular(14);
    final inner = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Column(
            children: [
              Icon(icon, size: 20, color: accent),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RpgTheme.bodyFont(
                  fontSize: 11.5,
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return _StyledPanel(borderRadius: radius, child: inner);
  }
}

/// The ONE place body chrome styling lives — sections and action tiles both
/// route through it (S2 frosted: true backdrop-blur glass).
class _StyledPanel extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;

  const _StyledPanel({
    required this.borderRadius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // GlassSurface's highlight Stack passes LOOSE constraints down, so its
    // fill Container shrink-wraps; panels must fill their slot instead.
    final full = SizedBox(width: double.infinity, child: child);
    return GlassSurface(
      borderRadius: borderRadius,
      shadow: false,
      child: full,
    );
  }
}

/// The photo, heavily blurred and scrimmed back toward the scaffold color,
/// washes the area behind the glass sections (photo-less profiles get a
/// theme-gradient wash instead).
class _AmbientBackdrop extends StatelessWidget {
  final ImageProvider? photo;

  const _AmbientBackdrop({required this.photo});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (photo != null)
            ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: 60,
                sigmaY: 60,
                tileMode: TileMode.clamp,
              ),
              child: Image(
                image: photo!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    theme.colorScheme.primary.withValues(alpha: 0.22),
                    theme.colorScheme.secondary.withValues(alpha: 0.10),
                  ],
                ),
              ),
            ),
          // Scrim back toward the scaffold so section text keeps contrast.
          ColoredBox(
            color: theme.scaffoldBackgroundColor.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final glass = GlassTheme.of(context);
    return _StyledPanel(
      borderRadius: BorderRadius.circular(18),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.toUpperCase(),
                style: RpgTheme.bodyFont(
                  fontSize: 11,
                  color: glass.onGlassMuted,
                  fontWeight: FontWeight.w800,
                ).copyWith(letterSpacing: 0.9),
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    this.danger = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = danger
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      minVerticalPadding: 0,
      leading: Icon(icon, color: color),
      title: Text(
        label,
        style: RpgTheme.bodyFont(
          fontSize: 15,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: color.withValues(alpha: 0.7)),
      onTap: onTap,
    );
  }
}
