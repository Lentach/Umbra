import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../models/profile_photo.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/friends_provider.dart';
import '../providers/messaging_provider.dart';
import '../l10n/app_localizations.dart';
import '../services/profile/profile_photo_cache.dart';
import '../services/profile/profile_photos.dart' show ProfilePhotoOutcome;
import '../theme/rpg_theme.dart';
import '../utils/linkify.dart';
import '../theme/glass_theme.dart';
import '../widgets/glass/glass_dialog.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/glass/glass_menu.dart';
import '../widgets/top_snackbar.dart' show showTopSnackBar;
import '../widgets/user_card/shared_media_section.dart';
import '../widgets/peer_identity_fingerprint_dialog.dart';
import 'edit_about_screen.dart';
import 'user_card_photo_actions.dart';

/// Relationship-aware card presentation for a contact or the current user
/// (accepted round-1 direction D1 "Telegram Full-Bleed", 2026-07-15).
///
/// Self cards derive their photo/about LIVE from [AuthProvider] so photo and
/// About edits apply in place — the screen must never pop itself to "refresh"
/// (the pre-rework nav-bounce bug). Other-user cards render the snapshot the
/// entry route assembled.
///
/// The card shows the account's ONE profile photo (decision 138): the
/// decrypted file from [ProfilePhotoCache] when [UserCardVisualData.avatar]
/// names one this device holds, initials otherwise — and only a contact
/// without any end-to-end reference falls back to the legacy server photo.
class UserCardScreen extends StatefulWidget {
  final UserCardVisualData data;
  final VoidCallback? onMessage;
  final ValueChanged<UserCardMute>? onMuteChanged;

  /// How the own card changes the photo; the messaging provider's by default.
  final ProfilePhotoActions? photoActions;

  const UserCardScreen({
    super.key,
    required this.data,
    this.onMessage,
    this.onMuteChanged,
    this.photoActions,
  });

  @override
  State<UserCardScreen> createState() => _UserCardScreenState();
}

class _UserCardScreenState extends State<UserCardScreen> {
  UserCardMute _mute = UserCardMute.off;

  @override
  void initState() {
    super.initState();
    _mute = widget.data.mute;
    ProfilePhotoCache.shared.addListener(_onPhotoCacheChanged);
  }

  @override
  void dispose() {
    ProfilePhotoCache.shared.removeListener(_onPhotoCacheChanged);
    super.dispose();
  }

  /// A decrypted photo landed (or was dropped): show it.
  void _onPhotoCacheChanged() {
    if (mounted) setState(() {});
  }

  /// Self cards re-derive from the live provider; other cards keep the
  /// snapshot assembled by the entry route.
  UserCardVisualData _effectiveData(BuildContext context) {
    if (!widget.data.isSelf) return widget.data;
    final user = Provider.of<AuthProvider>(context).currentUser;
    if (user == null) return widget.data;
    return UserCardVisualData.fromUser(
      user,
      isSelf: true,
      hasConversation: widget.data.hasConversation,
      mute: _mute,
    );
  }

  /// Natural width/height aspect of the shown photo, resolved off its image
  /// stream so the hero can size itself to it (full width, uncropped —
  /// round-3 owner ask). Unresolved or failed -> null -> the 300px default
  /// extent. The previous photo's aspect stays until the new one resolves,
  /// so replacing a photo does not flash the default height.
  ImageProvider? _aspectSource;
  double? _aspect;

  void _resolveAspect(ImageProvider? photo) {
    if (photo == _aspectSource) return;
    _aspectSource = photo;
    if (photo == null) {
      _aspect = null;
      return;
    }
    final stream = photo.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        final aspect = info.image.width / info.image.height;
        info.dispose();
        if (mounted && photo == _aspectSource && aspect > 0) {
          setState(() => _aspect = aspect);
        }
      },
      // A photo that fails to load keeps the default extent; the hero's
      // errorBuilder already renders the placeholder.
      onError: (_, _) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  void _showFeedback(String message) {
    showTopSnackBar(context, message);
  }

  Future<void> _copyHandle(String handle) async {
    await Clipboard.setData(ClipboardData(text: handle));
    if (!mounted) return;
    _showFeedback(AppLocalizations.of(context).userCardCopiedHandle(handle));
  }

  /// Profile mutations must FAIL LOUDLY: a swallowed exception here is how
  /// the broken 201-status check shipped unnoticed (bug-2 postmortem).
  Future<bool> _runProfileAction(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (e) {
      if (mounted) {
        _showFeedback(e.toString().replaceFirst('Exception: ', ''));
      }
      return false;
    }
  }

  /// The seam the own card changes the photo through: the injected one, else
  /// the messaging provider's. Resolved BEFORE the first await (callers).
  ProfilePhotoActions _photoActions() =>
      widget.photoActions ??
      MessagingProfilePhotoActions(context.read<MessagingProvider>());

  /// Runs a photo change and tells the user when it did not happen. Every
  /// outcome but `done` (and a backed-out picker, null) says why; a thrown
  /// error is logged and reported as a plain failure — never swallowed.
  Future<void> _runPhotoAction(
    Future<ProfilePhotoOutcome?> Function() action,
  ) async {
    final l10n = AppLocalizations.of(context);
    final error = Theme.of(context).colorScheme.error;
    ProfilePhotoOutcome? outcome;
    try {
      outcome = await action();
    } on Object catch (e, st) {
      debugPrint('Profile photo change failed: $e\n$st');
      outcome = ProfilePhotoOutcome.failed;
    }
    if (!mounted) return;
    final message = switch (outcome) {
      null || ProfilePhotoOutcome.done => null,
      ProfilePhotoOutcome.unreadable => l10n.userCardPhotoUnreadable,
      ProfilePhotoOutcome.noRoute => l10n.userCardPhotoNoRoute,
      ProfilePhotoOutcome.refused ||
      ProfilePhotoOutcome.failed => l10n.userCardPhotoFailed,
    };
    if (message != null) {
      showTopSnackBar(context, message, backgroundColor: error);
    }
  }

  Future<void> _pickProfilePhoto() {
    final actions = _photoActions();
    return _runPhotoAction(() async {
      final bytes = await actions.pick();
      return bytes == null ? null : actions.set(bytes);
    });
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return GlassDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _removeProfilePhoto() async {
    final actions = _photoActions();
    final l10n = AppLocalizations.of(context);
    if (!await _confirmAction(
      title: l10n.userCardDeletePhotoTitle,
      message: l10n.userCardDeletePhotoConfirm,
      confirmLabel: l10n.delete,
    )) {
      return;
    }
    if (!mounted) return;
    await _runPhotoAction(actions.remove);
  }

  Future<void> _removeContact() async {
    final userId = widget.data.userId;
    if (userId == null) return;
    final l10n = AppLocalizations.of(context);
    if (!await _confirmAction(
      title: l10n.removeFriendTitle,
      message: l10n.removeFriendConfirm(widget.data.username),
      confirmLabel: l10n.remove,
    )) {
      return;
    }
    if (!mounted) return;
    final friends = context.read<FriendsProvider>();
    final error = Theme.of(context).colorScheme.error;
    if (!await friends.unfriend(userId)) {
      if (mounted) {
        showTopSnackBar(context, l10n.boxEndNotSynced, backgroundColor: error);
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _blockContact() async {
    final userId = widget.data.userId;
    if (userId == null) return;
    final l10n = AppLocalizations.of(context);
    if (!await _confirmAction(
      title: l10n.userCardBlockTitle(widget.data.handle),
      message: l10n.userCardBlockConfirm,
      confirmLabel: l10n.block,
    )) {
      return;
    }
    if (!mounted) return;
    final friends = context.read<FriendsProvider>();
    final error = Theme.of(context).colorScheme.error;
    if (!await friends.blockUser(userId)) {
      if (mounted) {
        showTopSnackBar(context, l10n.boxEndNotSynced, backgroundColor: error);
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _editAbout(String? currentAbout) async {
    final auth = context.read<AuthProvider>();
    final next = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => EditAboutScreen(initialAbout: currentAbout),
      ),
    );
    if (next == null || !mounted) return;
    final trimmed = next.trim();
    await _runProfileAction(
      () => auth.updateProfileAbout(trimmed.isEmpty ? null : trimmed),
    );
    // Stay on the card — the watched provider refreshes the About section.
  }

  Future<void> _pickMute(BuildContext anchorContext) async {
    final l10n = AppLocalizations.of(anchorContext);
    final selected = await showGlassMenu<UserCardMute>(
      context: anchorContext,
      entries: [
        GlassMenuEntry(
          value: UserCardMute.off,
          child: Text(l10n.userCardNotificationsOn),
        ),
        GlassMenuEntry(
          value: UserCardMute.oneHour,
          child: Text(l10n.userCardMuteOneHour),
        ),
        GlassMenuEntry(
          value: UserCardMute.eightHours,
          child: Text(l10n.userCardMuteEightHours),
        ),
        GlassMenuEntry(
          value: UserCardMute.oneWeek,
          child: Text(l10n.userCardMuteOneWeek),
        ),
        GlassMenuEntry(
          value: UserCardMute.forever,
          child: Text(l10n.userCardMuteForever),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    setState(() => _mute = selected);
    widget.onMuteChanged?.call(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _effectiveData(context);
    final l10n = AppLocalizations.of(context);
    final photo = _cardPhotoOf(data);

    _resolveAspect(photo);
    // Hero height follows the photo's aspect so it fills the full width
    // UNCROPPED (round-3 owner ask; the round-2 contain-over-blur
    // pillarboxing was rejected). Clamped so panoramas don't pancake the
    // hero and tall portraits don't eat the screen — outside the clamp the
    // cover fit crops modestly, Telegram-style. Unresolved aspect -> 300.
    final screen = MediaQuery.sizeOf(context);
    double targetExtent = 300;
    final aspect = photo == null ? null : _aspect;
    if (aspect != null && screen.width > 0) {
      final maxH = math.max(
        260.0,
        math.min(screen.width * 4 / 3, screen.height * 0.62),
      );
      targetExtent = (screen.width / aspect).clamp(220.0, maxH);
    }

    Widget scrollViewFor(double photoExtent) => CustomScrollView(
        slivers: [
          // The hero renders ALWAYS — photo-less profiles get a gradient +
          // initials placeholder with the same collapse. The old compact
          // SliverAppBar fallback looked identical to the pre-rework card,
          // so every avatar-less account "kept the old view" (owner report
          // post branch-deploy).
          SliverPersistentHeader(
            pinned: true,
            delegate: _ProfileHeroDelegate(
              data: data,
              photo: photo,
              topInset: MediaQuery.paddingOf(context).top,
              onCopy: () => _copyHandle(data.handle),
              scaffoldColor: theme.scaffoldBackgroundColor,
              onSurface: theme.colorScheme.onSurface,
              photoExtent: photoExtent,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 44),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!data.isSelf) ...[
                    _ActionTilesRow(
                      hasConversation: data.hasConversation,
                      mute: _mute,
                      onMessage: widget.onMessage,
                      onMute: data.hasConversation ? _pickMute : null,
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (data.about != null) ...[
                    _Section(
                      title: l10n.userCardAbout,
                      child: Text.rich(
                        TextSpan(
                          children: buildLinkifiedSpans(
                            data.about!,
                            style: RpgTheme.bodyFont(
                              fontSize: 15,
                              color: theme.colorScheme.onSurface,
                            ).copyWith(height: 1.35),
                            linkStyle: RpgTheme.bodyFont(
                              fontSize: 15,
                              color: theme.colorScheme.primary,
                            ).copyWith(
                              height: 1.35,
                              decoration: TextDecoration.underline,
                              decorationColor: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  // Shared media: cache-only (E2E — server can't decrypt, so
                  // the client's fetched history is the only source). Cold
                  // cache or media-less chat -> section absent.
                  if (!data.isSelf && data.conversationId != null)
                    Builder(
                      builder: (context) {
                        final media = SharedMediaStrip.mediaMessagesOf(
                          context
                              .watch<MessagingProvider>()
                              .cachedMessagesFor(data.conversationId!),
                        );
                        if (media.isEmpty) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Section(
                              title: l10n.userCardSharedMedia,
                              child: SharedMediaStrip(mediaMessages: media),
                            ),
                            const SizedBox(height: 14),
                          ],
                        );
                      },
                    ),
                  if (data.isSelf)
                    _Section(
                      title: l10n.userCardMyProfile,
                      child: Column(
                        children: [
                          _ActionRow(
                            icon: Icons.edit_outlined,
                            label: l10n.userCardEditAbout,
                            onTap: () => _editAbout(data.about),
                          ),
                          _ActionRow(
                            icon: Icons.add_photo_alternate_outlined,
                            label: data.hasPhoto
                                ? l10n.userCardChangePhoto
                                : l10n.userCardAddPhoto,
                            onTap: _pickProfilePhoto,
                          ),
                          if (data.hasPhoto)
                            _ActionRow(
                              icon: Icons.delete_outline,
                              label: l10n.userCardDeletePhoto,
                              danger: true,
                              onTap: _removeProfilePhoto,
                            ),
                        ],
                      ),
                    ),
                  if (!data.isSelf && data.userId != null)
                    _Section(
                      title: l10n.userCardSafety,
                      child: Column(
                        children: [
                          // FIRST in Safety, and non-danger: this is the only
                          // defence against a server-side key substitution, and
                          // it must be reachable BEFORE anything looks wrong —
                          // a first-contact substitution produces no change to
                          // warn about.
                          _ActionRow(
                            icon: Icons.verified_user_outlined,
                            label: l10n.peerIdentityVerifyMenuAction,
                            onTap: () => showPeerIdentityFingerprintDialog(
                              context: context,
                              peerId: data.userId!,
                              peerName: data.username,
                            ),
                          ),
                          _ActionRow(
                            icon: Icons.person_remove_outlined,
                            label: l10n.userCardRemoveContact,
                            danger: true,
                            onTap: _removeContact,
                          ),
                          _ActionRow(
                            icon: Icons.block_outlined,
                            label: l10n.block,
                            danger: true,
                            onTap: _blockContact,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
    // Animate hero height changes (a photo of a different aspect, or the
    // aspect resolving after load) instead of snapping the sliver.
    final scrollView = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: targetExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, extent, _) => scrollViewFor(extent),
    );
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      // S2 "Frosted Backdrop" (owner pick, round 2): an ambient blur of the
      // primary photo washes the whole body behind true backdrop-blur glass
      // sections. Losing round-2 styles stripped at merge.
      body: Stack(
        fit: StackFit.expand,
        children: [
          _AmbientBackdrop(photo: photo),
          scrollView,
        ],
      ),
    );
  }
}

class UserCardVisualData {
  final int? userId;
  final String username;
  final String tag;
  final String? about;
  final bool isSelf;
  final bool hasConversation;

  /// Conversation with this contact when one exists — feeds the shared-media
  /// section. Always null for self cards.
  final int? conversationId;

  /// The account's end-to-end photo reference. When set it decides alone:
  /// the decrypted file, else initials — never [legacyPhotoUrl] behind it.
  final ProfilePhotoRef? avatar;

  /// The server-side photo path of a pre-E2E account; shown only while
  /// [avatar] is null.
  final String? legacyPhotoUrl;

  final UserCardMute mute;

  factory UserCardVisualData.fromUser(
    UserModel user, {
    required bool isSelf,
    required bool hasConversation,
    int? conversationId,
    UserCardMute mute = UserCardMute.off,
  }) {
    final legacy = user.profilePictureUrl;
    return UserCardVisualData(
      userId: user.id,
      username: user.username,
      about: user.about,
      tag: user.tag,
      isSelf: isSelf,
      hasConversation: hasConversation,
      conversationId: conversationId,
      avatar: user.avatar,
      legacyPhotoUrl: legacy == null || legacy.trim().isEmpty ? null : legacy,
      mute: mute,
    );
  }

  const UserCardVisualData({
    this.userId,
    required this.username,
    required this.tag,
    this.about,
    required this.isSelf,
    required this.hasConversation,
    this.conversationId,
    this.avatar,
    this.legacyPhotoUrl,
    this.mute = UserCardMute.off,
  });

  String get handle => '$username#$tag';

  /// Whether the account has a photo at all (shown or not here yet): what
  /// the own card offers to change or remove.
  bool get hasPhoto =>
      avatar?.hasPhoto ?? (legacyPhotoUrl?.trim().isNotEmpty ?? false);
}

/// The image the card shows for [data], or null for none (initials): the
/// decrypted file when [UserCardVisualData.avatar] names one this device
/// holds; with an avatar but no file (removed, or not here) nothing; only
/// without an avatar the legacy server photo.
ImageProvider? _cardPhotoOf(UserCardVisualData data) {
  final avatar = data.avatar;
  if (avatar != null) {
    final bytes = ProfilePhotoCache.shared.bytesFor(avatar);
    return bytes == null ? null : MemoryImage(bytes);
  }
  final url = data.legacyPhotoUrl;
  if (url == null || url.trim().isEmpty) return null;
  final isAbsolute = url.startsWith('http://') || url.startsWith('https://');
  return NetworkImage(isAbsolute ? url : '${AppConfig.baseUrl}$url');
}

enum UserCardMute {
  off,
  oneHour,
  eightHours,
  oneWeek,
  forever;

  static UserCardMute fromConversation({
    required bool muted,
    required DateTime? mutedUntil,
    DateTime? now,
  }) {
    if (!muted) return UserCardMute.off;
    if (mutedUntil == null) return UserCardMute.forever;
    final remaining = mutedUntil.difference(now ?? DateTime.now());
    if (remaining <= Duration.zero) return UserCardMute.off;
    if (remaining <= const Duration(hours: 2)) return UserCardMute.oneHour;
    if (remaining <= const Duration(hours: 12)) return UserCardMute.eightHours;
    return UserCardMute.oneWeek;
  }
}

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
