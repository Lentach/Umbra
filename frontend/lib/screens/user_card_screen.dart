import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../providers/auth_provider.dart';
import '../providers/friends_provider.dart';
import '../providers/messaging_provider.dart';
import '../l10n/app_localizations.dart';
import '../services/profile/profile_photo_cache.dart';
import '../services/profile/profile_photos.dart' show ProfilePhotoOutcome;
import '../theme/rpg_theme.dart';
import '../utils/linkify.dart';
import '../theme/glass_theme.dart';
import '../widgets/dialogs/confirm_dialog.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/glass/glass_menu.dart';
import '../widgets/top_snackbar.dart' show showTopSnackBar;
import '../widgets/user_card/shared_media_section.dart';
import '../widgets/peer_identity_fingerprint_dialog.dart';
import 'edit_about_screen.dart';
import 'user_card/user_card_data.dart';
import 'user_card_photo_actions.dart';

export 'user_card/user_card_data.dart';

part 'user_card/user_card_hero.dart';
part 'user_card/user_card_parts.dart';

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

  Future<void> _removeProfilePhoto() async {
    final actions = _photoActions();
    final l10n = AppLocalizations.of(context);
    if (!await showConfirmDialog(
      context: context,
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
    if (!await showConfirmDialog(
      context: context,
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
    if (!await showConfirmDialog(
      context: context,
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
