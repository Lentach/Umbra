import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/messaging_provider.dart';
import '../../theme/rpg_theme.dart';
import '../../utils/download_utils_web.dart'
    if (dart.library.io) '../../utils/download_utils_io.dart'
    as download_utils;
import '../../utils/encrypted_media_loader.dart';
import '../../utils/gif_blob_url_stub.dart'
    if (dart.library.html) '../../utils/gif_blob_url_web.dart'
    as gif_blob;
import '../../utils/image_clipboard.dart';
import '../media/fullscreen_image_viewer.dart';
import '../top_snackbar.dart';
import 'box_media_source.dart';

/// What the fullscreen gallery pages through: the chat's photos and GIFs that
/// have media to show. Videos keep their own player (owner, 2026-10-27).
bool isGalleryMedia(MessageModel m) =>
    (m.messageType == MessageType.image || m.messageType == MessageType.gif) &&
    (m.mediaUrl?.isNotEmpty ?? false);

/// Decrypted bytes of [message]'s media, as the bubbles and the gallery load
/// them. Throws when the fetch, size check or decrypt fails.
Future<Uint8List> loadMessageMediaBytes(
  BuildContext context,
  MessageModel message,
) {
  final url = message.mediaUrl!;
  return loadDecryptedMediaBytes(
    url: url,
    token: context.read<AuthProvider>().token ?? '',
    key: message.mediaKey,
    iv: message.mediaIv,
    box: boxMediaSourceFor(context, url),
  );
}

/// Opens the chat's photos and GIFs fullscreen at [message]; a swipe left or
/// right moves to the next or previous one (oldest first, as in the chat).
/// [bytes] are [message]'s already-decrypted media, so the tapped photo is
/// not fetched twice.
Future<void> showMediaGallery(
  BuildContext context, {
  required MessageModel message,
  Uint8List? bytes,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: _MediaGallery(initial: message, initialBytes: bytes),
    ),
  );
}

class _MediaGallery extends StatefulWidget {
  const _MediaGallery({required this.initial, this.initialBytes});

  final MessageModel initial;
  final Uint8List? initialBytes;

  @override
  State<_MediaGallery> createState() => _MediaGalleryState();
}

class _MediaGalleryState extends State<_MediaGallery> {
  late final MessagingProvider _messaging;
  late List<MessageModel> _items;
  late final int _initialIndex;

  /// True when the tapped message is not in the provider's list (it never
  /// should be); the viewer then shows it alone and ignores list updates.
  bool _standalone = false;

  /// Decrypted media by url, kept only for the pages near the current one:
  /// the page and its copy/save controls share one load, and paging through
  /// a long chat never holds every photo in RAM.
  final Map<String, Future<Uint8List?>> _bytes = {};
  static const _kKeepAround = 2;

  @override
  void initState() {
    super.initState();
    _messaging = context.read<MessagingProvider>();
    _items = _galleryItems();
    var index = _items.indexWhere((m) => m.id == widget.initial.id);
    if (index == -1) {
      index = _items.indexWhere((m) => m.mediaUrl == widget.initial.mediaUrl);
    }
    if (index == -1) {
      _items = [widget.initial];
      index = 0;
      _standalone = true;
    }
    _initialIndex = index;
    if (widget.initialBytes case final bytes?) {
      _bytes[widget.initial.mediaUrl!] = Future.value(bytes);
    }
    _messaging.addListener(_onMessagesChanged);
  }

  @override
  void dispose() {
    _messaging.removeListener(_onMessagesChanged);
    super.dispose();
  }

  List<MessageModel> _galleryItems() =>
      _messaging.messages.where(isGalleryMedia).toList(growable: false);

  /// A new, deleted or expired message changes the pages under the open
  /// viewer, which keeps its place by url (and closes if the photo on screen
  /// is the one that went).
  void _onMessagesChanged() {
    if (_standalone) return;
    final next = _galleryItems();
    final changed =
        next.length != _items.length ||
        [
          for (var i = 0; i < next.length; i++)
            next[i].mediaUrl != _items[i].mediaUrl,
        ].any((differs) => differs);
    if (!changed) {
      // Same pages; a row may still have been replaced (temp → acked).
      _items = next;
      return;
    }
    setState(() => _items = next);
  }

  Future<Uint8List?> _bytesFor(MessageModel m) => _bytes.putIfAbsent(
    m.mediaUrl!,
    () => loadMessageMediaBytes(context, m).then<Uint8List?>(
      (bytes) => bytes,
      onError: (Object _) => null,
    ),
  );

  void _onPageChanged(int index) {
    final keep = {
      for (
        var i = index - _kKeepAround;
        i <= index + _kKeepAround;
        i++
      )
        if (i >= 0 && i < _items.length) _items[i].mediaUrl,
    };
    _bytes.removeWhere((url, _) => !keep.contains(url));
  }

  @override
  Widget build(BuildContext context) {
    return FullscreenImageViewer(
      pageKeys: [for (final m in _items) m.mediaUrl!],
      initialIndex: _initialIndex,
      pageBuilder: (context, index) {
        final message = _items[index];
        return _GalleryPage(
          message: message,
          bytes: _bytesFor(message),
        );
      },
      onPageChanged: _onPageChanged,
      overlayBuilder: (context, index) {
        final message = _items[index];
        return _GalleryActions(
          message: message,
          bytes: message.messageType == MessageType.image
              ? _bytesFor(message)
              : null,
        );
      },
    );
  }
}

/// One page: the decrypted photo, or the GIF (on web through a blob URL, as
/// the bubble does, so it animates).
class _GalleryPage extends StatefulWidget {
  const _GalleryPage({required this.message, required this.bytes});

  final MessageModel message;
  final Future<Uint8List?> bytes;

  @override
  State<_GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<_GalleryPage> {
  String? _gifUrl;

  @override
  void didUpdateWidget(_GalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.mediaUrl != widget.message.mediaUrl) _revokeGif();
  }

  @override
  void dispose() {
    _revokeGif();
    super.dispose();
  }

  void _revokeGif() {
    if (_gifUrl == null) return;
    gif_blob.revokeGifObjectUrl(_gifUrl);
    _gifUrl = null;
  }

  Widget _image(Uint8List bytes) {
    if (kIsWeb && widget.message.messageType == MessageType.gif) {
      _gifUrl ??= gif_blob.createGifObjectUrl(bytes);
      return Image.network(_gifUrl!, fit: BoxFit.contain);
    }
    return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: widget.bytes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          );
        }
        final bytes = snap.data;
        if (bytes == null) {
          return Center(
            child: Text(
              AppLocalizations.of(context).imageFailedToLoad,
              style: RpgTheme.bodyFont(color: Colors.white70),
            ),
          );
        }
        return SizedBox.expand(child: _image(bytes));
      },
    );
  }
}

/// Top-right controls for the current page: copy and save for a photo once
/// it has loaded, close always.
class _GalleryActions extends StatelessWidget {
  const _GalleryActions({required this.message, required this.bytes});

  final MessageModel message;

  /// Null for a GIF, which has no copy/save.
  final Future<Uint8List?>? bytes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FutureBuilder<Uint8List?>(
          future: bytes,
          builder: (context, snap) {
            final loaded = snap.data;
            return Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (loaded != null && canCopyImageToClipboard)
                  _ViewerAction(
                    icon: Icons.content_copy,
                    tooltip: l10n.copyImage,
                    onTap: () => _copyImage(context, loaded),
                  ),
                if (loaded != null)
                  _ViewerAction(
                    icon: Icons.download,
                    tooltip: l10n.saveImage,
                    onTap: () => _saveImage(context, loaded),
                  ),
                _ViewerAction(
                  icon: Icons.close,
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).closeButtonTooltip,
                  onTap: () => Navigator.pop(context),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _saveImage(BuildContext context, Uint8List bytes) async {
    final l10n = AppLocalizations.of(context);
    try {
      await download_utils.saveBytesAsDownload(bytes, _imageFilename(bytes));
      if (context.mounted) showTopSnackBar(context, l10n.imageSaved);
    } on Object {
      if (context.mounted) showTopSnackBar(context, l10n.imageSaveFailed);
    }
  }

  Future<void> _copyImage(BuildContext context, Uint8List bytes) async {
    final l10n = AppLocalizations.of(context);
    try {
      await copyImageToClipboard(bytes, _detectImageMime(bytes));
      if (context.mounted) showTopSnackBar(context, l10n.imageCopied);
    } on Object {
      if (context.mounted) showTopSnackBar(context, l10n.imageCopyFailed);
    }
  }

  /// Sniff the real image type from magic bytes — [MessageModel] carries no
  /// MIME/filename, so trusting the URL extension would mislabel PNG/WebP/GIF.
  static String _detectImageMime(Uint8List b) {
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
    return 'image_${message.id}.$ext';
  }
}

class _ViewerAction extends StatelessWidget {
  const _ViewerAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
}
