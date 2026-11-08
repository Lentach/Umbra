import 'package:flutter/material.dart';
import '../theme/rpg_theme.dart';
import '../config/app_config.dart';
import '../models/profile_photo.dart';
import '../services/profile/profile_photo_cache.dart';

/// A round avatar: the decrypted E2E photo [avatar] names (decision 138) —
/// which, once set, decides: initials while this device does not hold the
/// file, and never the legacy [profilePictureUrl] behind it — else that
/// legacy server photo, else initials.
class AvatarCircle extends StatefulWidget {
  final String displayName;
  final double radius;
  final String? profilePictureUrl;
  final ProfilePhotoRef? avatar;

  const AvatarCircle({
    super.key,
    required this.displayName,
    this.radius = 22,
    this.profilePictureUrl,
    this.avatar,
  });

  @override
  State<AvatarCircle> createState() => _AvatarCircleState();
}

class _AvatarCircleState extends State<AvatarCircle> {
  bool _imageLoadError = false;

  @override
  void didUpdateWidget(AvatarCircle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profilePictureUrl != widget.profilePictureUrl) {
      _imageLoadError = false;
    }
  }

  String _buildImageUrl() {
    final url = widget.profilePictureUrl;
    if (url == null || url.trim().isEmpty) return '';
    final isAbsolute = url.startsWith('http://') || url.startsWith('https://');
    final base = isAbsolute ? url : '${AppConfig.baseUrl}$url';
    // Avatar URLs are unique per upload (server filename = randomUUID().ext),
    // so the URL itself is the cache key; a ?t= bust only forced a re-download
    // on every remount and defeated the browser cache.
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final letter = widget.displayName.isNotEmpty
        ? widget.displayName[0].toUpperCase()
        : '?';
    final isDark = RpgTheme.isDark(context);
    final gradientColors = isDark
        ? [
            Theme.of(context).colorScheme.secondary,
            Theme.of(context).colorScheme.primary,
          ]
        : [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ];
    // The letter sits on a primary->secondary gradient, so white is not a
    // given: on the light themes those fills are pale. Ask the same helper the
    // button/FAB foregrounds use, against the gradient's midpoint.
    final letterColor = RpgTheme.readableOn(
      Color.lerp(gradientColors[0], gradientColors[1], 0.5)!,
    );

    final avatar = widget.avatar;
    if (avatar != null) {
      return ListenableBuilder(
        listenable: ProfilePhotoCache.shared,
        builder: (context, _) {
          final bytes = ProfilePhotoCache.shared.bytesFor(avatar);
          Widget initials() => _initialsCircle(
            gradientColors: gradientColors,
            letter: letter,
            letterColor: letterColor,
          );
          if (bytes == null) return initials();
          final size = widget.radius * 2;
          return SizedBox(
            width: size,
            height: size,
            child: ClipOval(
              child: Image.memory(
                bytes,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => initials(),
              ),
            ),
          );
        },
      );
    }

    return Stack(
      children: [
        // Main avatar
        Container(
          width: widget.radius * 2,
          height: widget.radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: widget.profilePictureUrl != null && !_imageLoadError
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: gradientColors,
                  ),
          ),
          child: widget.profilePictureUrl != null && !_imageLoadError
              ? ClipOval(
                  child: Image.network(
                    _buildImageUrl(),
                    width: widget.radius * 2,
                    height: widget.radius * 2,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() => _imageLoadError = true);
                        }
                      });
                      return Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: gradientColors,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          letter,
                          style: RpgTheme.bodyFont(
                            fontSize: widget.radius * 0.8,
                            color: letterColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    },
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: gradientColors,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!
                              : null,
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      );
                    },
                  ),
                )
              : Container(
                  alignment: Alignment.center,
                  child: Text(
                    letter,
                    style: RpgTheme.bodyFont(
                      fontSize: widget.radius * 0.8,
                      color: letterColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _initialsCircle({
    required List<Color> gradientColors,
    required String letter,
    required Color letterColor,
  }) {
    return Container(
      width: widget.radius * 2,
      height: widget.radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: RpgTheme.bodyFont(
          fontSize: widget.radius * 0.8,
          color: letterColor,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
