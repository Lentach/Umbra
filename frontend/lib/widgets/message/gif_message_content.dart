import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../utils/gif_blob_url_stub.dart'
    if (dart.library.html) '../../utils/gif_blob_url_web.dart'
    as gif_blob;
import 'box_media_source.dart';
import 'media_preview_frame.dart';
import '../../utils/encrypted_media_loader.dart';
import '../media/fullscreen_image_viewer.dart';

/// GIF message: fetch, optional decrypt; web uses blob URL for animation.
class GifMessageContent extends StatefulWidget {
  final MessageModel message;

  const GifMessageContent({super.key, required this.message});

  @override
  State<GifMessageContent> createState() => _GifMessageContentState();
}

class _GifMessageContentState extends State<GifMessageContent> {
  late Future<_GifDisplay> _future;
  String? _objectUrl;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    if (_objectUrl != null) {
      gif_blob.revokeGifObjectUrl(_objectUrl);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(GifMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.message.mediaUrl != widget.message.mediaUrl ||
        oldWidget.message.mediaKey != widget.message.mediaKey ||
        oldWidget.message.mediaIv != widget.message.mediaIv) {
      if (_objectUrl != null) {
        gif_blob.revokeGifObjectUrl(_objectUrl);
        _objectUrl = null;
      }
      _future = _load();
    }
  }

  Future<_GifDisplay> _load() async {
    final url = widget.message.mediaUrl;
    if (url == null || url.isEmpty) {
      return const _GifDisplay.error();
    }

    final token = context.read<AuthProvider>().token ?? '';
    final box = boxMediaSourceFor(context, url);
    Uint8List bytes;
    try {
      bytes = await loadDecryptedMediaBytes(
        url: url,
        token: token,
        key: widget.message.mediaKey,
        iv: widget.message.mediaIv,
        box: box,
      );
    } catch (_) {
      return const _GifDisplay.error();
    }

    if (kIsWeb) {
      final blobUrl = gif_blob.createGifObjectUrl(bytes);
      if (!mounted) {
        // Disposed between create and here: dispose() already ran and saw a
        // null _objectUrl, so nothing else will ever revoke this handle and it
        // pins the full decoded GIF until the tab reloads.
        gif_blob.revokeGifObjectUrl(blobUrl);
        return const _GifDisplay.error();
      }
      setState(() => _objectUrl = blobUrl);
      return _GifDisplay.network(blobUrl);
    }
    return _GifDisplay.memory(bytes);
  }

  void _showFullscreen(BuildContext context, _GifDisplay display) {
    final image = display.networkUrl != null
        ? Image.network(display.networkUrl!, fit: BoxFit.contain)
        : display.memoryBytes != null
        ? Image.memory(display.memoryBytes!, fit: BoxFit.contain)
        : null;
    if (image == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: FullscreenImageViewer(image: image),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MediaPreviewFrame(
      mediaWidth: widget.message.mediaWidth,
      mediaHeight: widget.message.mediaHeight,
      mediaThumbHash: widget.message.mediaThumbHash,
      child: FutureBuilder<_GifDisplay>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final display = snap.data;
          if (display == null || display.isError) {
            return const Center(child: Icon(Icons.broken_image, size: 48));
          }

          final Widget preview;
          if (display.networkUrl != null) {
            preview = Image.network(
              display.networkUrl!,
              fit: BoxFit.contain,
              loadingBuilder: (context, child, loadingProgress) {
                return loadingProgress == null
                    ? child
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
              },
              errorBuilder: (_, _, _) =>
                  const Center(child: Icon(Icons.broken_image, size: 48)),
            );
          } else {
            preview = Image.memory(
              display.memoryBytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            );
          }

          return GestureDetector(
            onTap: () => _showFullscreen(context, display),
            child: preview,
          );
        },
      ),
    );
  }
}

class _GifDisplay {
  final String? networkUrl;
  final Uint8List? memoryBytes;
  final bool isError;

  const _GifDisplay.network(this.networkUrl)
    : memoryBytes = null,
      isError = false;

  const _GifDisplay.memory(this.memoryBytes)
    : networkUrl = null,
      isError = false;

  const _GifDisplay.error()
    : networkUrl = null,
      memoryBytes = null,
      isError = true;
}
