import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../utils/encrypted_media_loader.dart';
import '../message/box_media_source.dart';

/// Horizontal strip of image/GIF media exchanged in a conversation, shown on
/// the other-user card ("shared media", Telegram parity).
///
/// Sources ONLY the MessagingProvider RAM cache (via `cachedMessagesFor`):
/// media blobs are E2E-encrypted and the server never holds the keys, so the
/// decrypted history the client already fetched is the sole possible source.
/// A cold cache (card opened outside a chat) simply renders nothing — the
/// card hides the section entirely.
class SharedMediaStrip extends StatelessWidget {
  final List<MessageModel> mediaMessages;

  const SharedMediaStrip({super.key, required this.mediaMessages});

  /// Newest-first image/GIF messages that can actually be rendered.
  static List<MessageModel> mediaMessagesOf(List<MessageModel> messages) {
    final media = messages
        .where(
          (m) =>
              (m.messageType == MessageType.image ||
                  m.messageType == MessageType.gif) &&
              m.mediaUrl != null &&
              m.mediaUrl!.isNotEmpty,
        )
        .toList(growable: true);
    media.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    // The strip is a peek, not an archive — cap so a long chat can't inflate
    // the card with dozens of decrypt fetches.
    return media.length > 24 ? media.sublist(0, 24) : media;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: mediaMessages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) =>
            _SharedMediaThumb(message: mediaMessages[index]),
      ),
    );
  }
}

class _SharedMediaThumb extends StatefulWidget {
  final MessageModel message;

  const _SharedMediaThumb({required this.message});

  @override
  State<_SharedMediaThumb> createState() => _SharedMediaThumbState();
}

class _SharedMediaThumbState extends State<_SharedMediaThumb> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(_SharedMediaThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.mediaUrl != widget.message.mediaUrl) {
      _future = _load();
    }
  }

  Future<Uint8List?> _load() async {
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
      // Fetch/oversize/decrypt failure -> placeholder tile below.
      return null;
    }
  }

  void _showFullscreen(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: GestureDetector(
          onTap: () => Navigator.pop(dialogContext),
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        Widget child;
        if (bytes != null) {
          child = GestureDetector(
            onTap: () => _showFullscreen(context, bytes),
            child: Image.memory(
              bytes,
              width: 92,
              height: 92,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          );
        } else {
          child = Container(
            width: 92,
            height: 92,
            color: theme.colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: snapshot.connectionState == ConnectionState.waiting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.broken_image_outlined,
                    size: 22,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: child,
        );
      },
    );
  }
}
