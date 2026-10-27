import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../theme/rpg_theme.dart';
import 'media_gallery.dart';
import 'media_preview_frame.dart';

/// IMAGE message: fetch URL, optional AES-GCM decrypt, display; a tap opens
/// the chat's swipeable photo/GIF gallery at this image.
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
    if (widget.message.mediaUrl?.isEmpty ?? true) return null;
    try {
      return await loadMessageMediaBytes(context, widget.message);
    } on Object {
      // Any failure (fetch, oversize, decrypt) renders the same failure text
      // via the FutureBuilder null/error branch below.
      return null;
    }
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
            onTap: () => showMediaGallery(
              context,
              message: widget.message,
              bytes: bytes,
            ).ignore(),
            child: Image.memory(bytes, fit: BoxFit.contain),
          );
        },
      ),
    );
  }
}
