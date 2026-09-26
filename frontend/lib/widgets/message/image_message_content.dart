import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../theme/rpg_theme.dart';
import 'box_media_source.dart';
import 'media_preview_frame.dart';
import '../../utils/encrypted_media_loader.dart';
import '../../utils/download_utils_web.dart'
    if (dart.library.io) '../../utils/download_utils_io.dart'
    as download_utils;
import '../../utils/image_clipboard.dart';
import '../top_snackbar.dart';
import '../media/fullscreen_image_viewer.dart';

/// IMAGE message: fetch URL, optional AES-GCM decrypt, display with fullscreen viewer.
class ImageMessageContent extends StatefulWidget {
  final MessageModel message;

  const ImageMessageContent({super.key, required this.message});

  @override
  State<ImageMessageContent> createState() => _ImageMessageContentState();
}

class _ImageMessageContentState extends State<ImageMessageContent> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadDecryptedBytes();
  }

  @override
  void didUpdateWidget(ImageMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.message.mediaUrl != widget.message.mediaUrl ||
        oldWidget.message.mediaKey != widget.message.mediaKey ||
        oldWidget.message.mediaIv != widget.message.mediaIv) {
      _future = _loadDecryptedBytes();
    }
  }

  Future<Uint8List?> _loadDecryptedBytes() async {
    final url = widget.message.mediaUrl;
    if (url == null || url.isEmpty) return null;
    final token = context.read<AuthProvider>().token ?? '';
    final box = boxMediaSourceFor(context, url);
    try {
      return await loadDecryptedMediaBytes(
        url: url,
        token: token,
        key: widget.message.mediaKey,
        iv: widget.message.mediaIv,
        box: box,
      );
    } catch (_) {
      // Any failure (fetch, oversize, decrypt) renders the same failure text
      // via the FutureBuilder null/error branch below.
      return null;
    }
  }

  void _showFullscreen(BuildContext context, Uint8List bytes) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: FullscreenImageViewer(
          image: Image.memory(bytes, fit: BoxFit.contain),
          actions: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (canCopyImageToClipboard)
                    _viewerAction(
                      icon: Icons.content_copy,
                      tooltip: l10n.copyImage,
                      onTap: () => _copyImage(bytes),
                    ),
                  _viewerAction(
                    icon: Icons.download,
                    tooltip: l10n.saveImage,
                    onTap: () => _saveImage(bytes),
                  ),
                  _viewerAction(
                    icon: Icons.close,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onTap: () => Navigator.pop(dialogContext),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewerAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: IconButton(
          icon: Icon(icon, color: Colors.white),
          tooltip: tooltip,
          onPressed: onTap,
        ),
      ),
    );
  }

  Future<void> _saveImage(Uint8List bytes) async {
    final l10n = AppLocalizations.of(context);
    try {
      await download_utils.saveBytesAsDownload(bytes, _imageFilename(bytes));
      if (mounted) showTopSnackBar(context, l10n.imageSaved);
    } catch (_) {
      if (mounted) showTopSnackBar(context, l10n.imageSaveFailed);
    }
  }

  Future<void> _copyImage(Uint8List bytes) async {
    final l10n = AppLocalizations.of(context);
    try {
      await copyImageToClipboard(bytes, _detectImageMime(bytes));
      if (mounted) showTopSnackBar(context, l10n.imageCopied);
    } catch (_) {
      if (mounted) showTopSnackBar(context, l10n.imageCopyFailed);
    }
  }

  /// Sniff the real image type from magic bytes — [MessageModel] carries no
  /// MIME/filename, so trusting the URL extension would mislabel PNG/WebP/GIF.
  String _detectImageMime(Uint8List b) {
    if (b.length >= 4 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (b.length >= 4 &&
        b[0] == 0x47 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x38) {
      return 'image/gif';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  String _imageFilename(Uint8List bytes) {
    final ext = switch (_detectImageMime(bytes)) {
      'image/png' => 'png',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    return 'image_${widget.message.id}.$ext';
  }

  @override
  Widget build(BuildContext context) {
    return MediaPreviewFrame(
      mediaWidth: widget.message.mediaWidth,
      mediaHeight: widget.message.mediaHeight,
      mediaThumbHash: widget.message.mediaThumbHash,
      child: FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (snap.hasError || snap.data == null) {
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                AppLocalizations.of(context).imageFailedToLoad,
                style: RpgTheme.bodyFont(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            );
          }
          final bytes = snap.data!;
          return GestureDetector(
            onTap: () => _showFullscreen(context, bytes),
            child: Image.memory(bytes, fit: BoxFit.contain),
          );
        },
      ),
    );
  }
}
