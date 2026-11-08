import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/user_model.dart';
import '../providers/friends_provider.dart';
import '../theme/rpg_theme.dart';
import '../widgets/hex_avatar.dart';
import '../widgets/settings_console.dart';
import '../widgets/glass/glass_top_bar.dart';

class BlockedUsersScreen extends StatelessWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final friends = context.watch<FriendsProvider>();
    final blocked = friends.blockedUsers;
    final theme = Theme.of(context);
    final isDark = RpgTheme.isDark(context);
    final mutedColor = isDark
        ? RpgTheme.mutedDark
        : RpgTheme.textSecondaryLight;
    final media = MediaQuery.paddingOf(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          AppLocalizations.of(context).blocked,
          style: RpgTheme.bodyFont(
            fontSize: 16,
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: blocked.isEmpty
          ? Padding(
              padding: EdgeInsets.only(
                top: media.top + GlassTopBar.capsuleHeight + 16,
                bottom: media.bottom,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Sized natively rather than Transform.scale'd: scaling
                      // the widget would scale the 1.4 hairline outline with
                      // it and print a fatter hexagon than every other
                      // terminal in the app.
                      ConsoleHexIcon(
                        glyph: ConsoleGlyph.blocked,
                        tint: mutedColor,
                        height: 64,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        AppLocalizations.of(context).noBlockedUsers,
                        style: RpgTheme.bodyFont(
                          fontSize: 16,
                          color: mutedColor,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.only(
                top: media.top + GlassTopBar.capsuleHeight + 16,
                bottom: media.bottom + 8,
              ),
              itemCount: blocked.length,
              itemBuilder: (context, index) {
                final user = blocked[index];
                return _BlockedUserTile(user: user);
              },
            ),
    );
  }
}

class _BlockedUserTile extends StatelessWidget {
  final UserModel user;

  const _BlockedUserTile({required this.user});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final friendsProvider = context.read<FriendsProvider>();
    final displayHandle = user.displayHandle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(kConsoleHexLeft, 10, 12, 10),
      child: Row(
        children: [
          HexAvatar(
            size: kConsoleHexHeight,
            displayName: user.username,
            imageUrl: user.profilePictureUrl,
            avatar: user.avatar,
            surface: FireplaceColors.of(context).convItemBg,
            borderColor: FireplaceColors.of(context).convItemBorder,
            ember: 0,
            initialsStyle: RpgTheme.bodyFont(
              fontSize: kConsoleHexHeight * 0.34,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              displayHandle,
              style: RpgTheme.bodyFont(
                fontSize: 14,
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: '${AppLocalizations.of(context).unblock} $displayHandle',
            excludeSemantics: true,
            child: TextButton(
              onPressed: () => friendsProvider.unblockUser(user.id),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 36),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                foregroundColor: colorScheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(color: colorScheme.primary),
                ),
              ),
              child: Text(
                AppLocalizations.of(context).unblock,
                style: RpgTheme.bodyFont(
                  fontSize: 12,
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ).copyWith(letterSpacing: 1.2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
