import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:video_player/video_player.dart';

import '../../models/message_model.dart';
import '../../services/box/box_media_url.dart';
import '../../utils/encrypted_media_loader.dart';
import '../../utils/e2e_persistent_diag.dart';
import '../../utils/video_blob_url_stub.dart'
    if (dart.library.html) '../../utils/video_blob_url_web.dart' as video_blob;
import '../../utils/video_temp_file_stub.dart'
    if (dart.library.io) '../../utils/video_temp_file_io.dart' as video_temp;
import '../../utils/video_preview.dart';

/// Display aspect ratio of [value], honouring the container rotation that
/// [VideoPlayerValue.aspectRatio] silently drops. Shared by the fullscreen
/// stage and the inline bubble player, which must letterbox identically.
double rotationAwareAspectRatio(VideoPlayerValue value) {
  final size = value.size;
  if (size.width <= 0 || size.height <= 0) return 1.0;
  return videoRotationSwapsAxes(value.rotationCorrection)
      ? size.height / size.width
      : size.width / size.height;
}

/// Why a video has nothing to show.
///
/// Two cases, not three: [loadDecryptedMediaBytes] throws ONE undifferentiated
/// exception for fetch failure, oversize and decrypt failure alike, so no
/// caller can honestly name decryption as the cause of a load error.
enum VideoStageError {
  /// The bubble is still optimistic — the blob has not finished uploading, so
  /// there is nothing to fetch yet. Not a failure; never say "failed" here.
  stillSending,

  /// Fetch, size guard, decrypt or codec initialisation failed. Which one is
  /// not knowable at this layer.
  unplayable,
}

/// Owns ONE decrypted video and the platform resources behind it.
///
/// Used only by the fullscreen viewer (the bubble is a static poster and never
/// plays in place). Web holds an object URL, native holds a temp file, and
/// BOTH leak without a matching teardown. Callers own the lifecycle —
/// construct, [load], then [dispose] exactly once.
class VideoPlaybackSession {
  final MessageModel message;
  final String token;

  /// Where a box attachment's bytes come from (item 3 / media wiring).
  final BoxCiphertextSource? box;

  VideoPlayerController? _controller;
  String? _objectUrl;
  String? _tempFilePath;
  bool _disposed = false;

  /// `stage · bytes · error` of the last failed [load], for the fullscreen
  /// error surface: a phone screenshot then names the failing stage without
  /// the owner having to dig the durable log out of hacker mode.
  String? failureDetail;

  VideoPlaybackSession({required this.message, required this.token, this.box});

  VideoPlayerController? get controller => _controller;

  bool get isReady => _controller?.value.isInitialized ?? false;

  /// Fetches, decrypts and initialises the player.
  ///
  /// Returns null on success, or the reason there is nothing to play. Safe to
  /// race against [dispose]: a session disposed mid-await tears down whatever
  /// it had already acquired and reports [VideoStageError.unplayable] to a
  /// caller that is, by then, gone.
  Future<VideoStageError?> load() async {
    final url = message.mediaUrl;
    // An optimistic bubble has no uploaded blob yet; nothing to fetch.
    if (url == null ||
        url.isEmpty ||
        !(url.startsWith('http') || isBoxMediaUrl(url))) {
      return VideoStageError.stillSending;
    }
    // Which step failed. The loader throws one undifferentiated exception,
    // so the stage is tracked here — the diag record below is the ONLY way a
    // field failure can be told apart (fetch vs decrypt vs decoder).
    var stage = 'fetch_decrypt';
    var byteCount = 0;
    try {
      final bytes = await loadDecryptedMediaBytes(
        url: url,
        token: token,
        key: message.mediaKey,
        iv: message.mediaIv,
        box: box,
      );
      byteCount = bytes.length;
      if (_disposed) return VideoStageError.unplayable;

      stage = 'source';
      final VideoPlayerController controller;
      if (kIsWeb) {
        final blobUrl = video_blob.createVideoObjectUrl(bytes);
        _objectUrl = blobUrl;
        controller = VideoPlayerController.networkUrl(Uri.parse(blobUrl));
      } else {
        final path = await video_temp.writeVideoTempFile(bytes, message.id);
        if (_disposed) {
          // dispose() already ran with a null _tempFilePath; nothing else
          // would ever delete this file.
          video_temp.deleteVideoTempFile(path).ignore();
          return VideoStageError.unplayable;
        }
        _tempFilePath = path;
        controller = video_temp.controllerForPath(path);
      }
      // Assign before initialize() so a dispose during the await still tears
      // the controller down.
      _controller = controller;
      stage = 'initialize';
      await controller.initialize();
      if (_disposed) return VideoStageError.unplayable;
      return null;
    } catch (e) {
      // Durable, not just the ring: the owner reproduces on a phone and
      // copies the hacker-mode log hours later. Bounded fields — no URL, no
      // key material.
      final text = e.toString().replaceAll(RegExp(r'\s+'), ' ');
      final bounded = text.length > 240 ? text.substring(0, 240) : text;
      failureDetail = '$stage · ${byteCount}B · $bounded';
      E2ePersistentDiag.record('VIDEO_LOAD_FAILED', {
        'msgId': message.id,
        'stage': stage,
        'bytes': byteCount,
        'keyed': message.mediaKey != null && message.mediaIv != null,
        'disposed': _disposed,
        'error': bounded,
      });
      _releaseResources();
      return VideoStageError.unplayable;
    }
  }

  void dispose() {
    _disposed = true;
    _releaseResources();
  }

  void _releaseResources() {
    final controller = _controller;
    _controller = null;
    controller?.dispose();
    if (_objectUrl != null) {
      video_blob.revokeVideoObjectUrl(_objectUrl);
      _objectUrl = null;
    }
    if (_tempFilePath != null) {
      video_temp.deleteVideoTempFile(_tempFilePath).ignore();
      _tempFilePath = null;
    }
  }
}
