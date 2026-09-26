import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../l10n/app_localizations.dart';
import '../../models/message_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/audio_cache_store.dart';
import '../../services/media_crypto_service.dart';
import '../../services/encryption/native_content_store.dart';
import '../../services/encryption/sealed_audio_codec.dart';
import '../../services/voice_audio_coordinator.dart';
import '../../utils/encrypted_media_loader.dart';
import '../message/box_media_source.dart';
import '../top_snackbar.dart';
import 'voice_player.dart';

/// Manages voice playback lifecycle: loading, caching, play/pause, seek, speed.
///
/// Playback runs through the [VoicePlayer] abstraction: just_audio on native,
/// the Web Audio API on web (no MediaSession ⇒ no iOS media-control card).
/// Exposes state via callbacks and boolean fields so the parent widget can
/// drive the UI without caring about the player internals.
class PlaybackController extends StatefulWidget {
  final MessageModel message;

  /// Called whenever playback state changes (isPlaying, isLoading, position, duration, speed).
  final Widget Function(
    BuildContext context,
    bool isPlaying,
    bool isLoading,
    Duration position,
    Duration duration,
    double speed,
    VoidCallback togglePlayPause,
    void Function(double localX, double width) seekFromWaveform,
    VoidCallback toggleSpeed,
  ) builder;

  /// Test seam: inject a fake [VoicePlayer]. Defaults to the platform player.
  final VoicePlayer Function()? playerFactory;

  const PlaybackController({
    super.key,
    required this.message,
    required this.builder,
    this.playerFactory,
  });

  /// Destroy every cached voice note.
  ///
  /// Delegates to [AudioCacheStore], which owns the filename convention —
  /// including the legacy `.m4a` names that a purge must not miss.
  static Future<int> clearAudioCache() => AudioCacheStore.clear();

  @override
  State<PlaybackController> createState() => _PlaybackControllerState();
}

class _PlaybackControllerState extends State<PlaybackController>
    implements ManagedAudioPlayback {
  late final VoicePlayer _player =
      widget.playerFactory?.call() ?? createVoicePlayer();
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _loadCancelled = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _playbackSpeed = 1.0;
  String? _cachedFilePath;

  @override
  void pauseForCoordinator() => _player.pause().ignore();

  /// Duration from message metadata (for display before audio loads).
  Duration get _messageDuration =>
      Duration(seconds: widget.message.mediaDuration ?? 0);

  /// Effective duration: from player when loaded, else from message metadata.
  Duration get _displayDuration =>
      _duration.inMilliseconds > 0 ? _duration : _messageDuration;

  @override
  void initState() {
    super.initState();

    _player.stateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state.completed ? false : state.playing;
      });
      if (state.playing && !state.completed) {
        VoiceAudioCoordinator.instance.onStartedPlaying(this);
      }
      if (state.completed) {
        VoiceAudioCoordinator.instance.onStoppedPlaying(this);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _player.stop();
            _player.seek(Duration.zero);
          }
        });
      }
    });

    _player.positionStream.listen((position) {
      if (mounted) {
        setState(() {
          _position = position;
        });
      }
    });

    _player.durationStream.listen((duration) {
      if (mounted && duration != null) {
        setState(() {
          _duration = duration;
        });
      }
    });
  }

  @override
  void dispose() {
    VoiceAudioCoordinator.instance.onStoppedPlaying(this);
    _player.dispose();
    super.dispose();
  }

  bool _isExpired() {
    if (widget.message.expiresAt == null) return false;
    return widget.message.expiresAt!.isBefore(DateTime.now());
  }

  Future<void> _togglePlayPause() async {
    if (_isLoading) {
      _loadCancelled = true;
      _player.stop();
      setState(() => _isLoading = false);
      return;
    }
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_player.duration == null) {
        await _loadAndPlayAudio();
      } else {
        await _player.play();
      }
    }
  }

  Future<void> _loadAndPlayAudio() async {
    if (_isExpired()) {
      if (mounted) {
        showTopSnackBar(
            context, AppLocalizations.of(context).snackbarAudioNoLongerAvailable);
      }
      return;
    }

    final mediaUrl = widget.message.mediaUrl;
    if (mediaUrl == null || mediaUrl.isEmpty) {
      throw Exception('No media URL');
    }
    final token = context.read<AuthProvider>().token ?? '';
    // A box voice note (item 3 / media wiring) comes from this device's
    // copy or the box, never `/media` with a token.
    final box = boxMediaSourceFor(context, mediaUrl);

    _loadCancelled = false;
    setState(() {
      _isLoading = true;
    });

    try {
      if (kIsWeb) {
        // Web Audio decodes raw bytes (no HTML <audio> element ⇒ no
        // MediaSession). Fetch the bytes ourselves (encrypted media already
        // does), decrypt when keyed, and hand the plaintext to the player.
        // The legacy unencrypted (Cloudinary) case fetches the same way, which
        // also avoids the CORS wall a bare fetch+decode would hit.
        final mk = widget.message.mediaKey;
        final mi = widget.message.mediaIv;
        final Uint8List plain;
        if (box != null) {
          plain = await loadDecryptedMediaBytes(
            url: mediaUrl,
            token: token,
            key: mk,
            iv: mi,
            box: box,
          );
        } else {
          final raw = await ApiService(
            baseUrl: AppConfig.baseUrl,
          ).fetchMediaBytes(mediaUrl, token);
          if (raw.length > MediaCryptoService.maxBytes) {
            throw Exception('Audio too large');
          }
          plain = (mk != null && mi != null)
              ? await MediaCryptoService().decrypt(Uint8List.fromList(raw), mk, mi)
              : Uint8List.fromList(raw);
        }
        await _player.setAudioBytes(plain);
      } else {
        _cachedFilePath = await _getCachedFilePath();

        if (_cachedFilePath != null && File(_cachedFilePath!).existsSync()) {
          final played = await _playCachedFile(_cachedFilePath!);
          if (!played) {
            // Sealed under a key this device no longer holds (or torn):
            // unlike message plaintext, voice audio IS re-derivable — the
            // message record still carries the only mediaKey/mediaIv. Drop
            // the dead file and fall through to a fresh download.
            try {
              File(_cachedFilePath!).deleteSync();
            } catch (_) {}
            _cachedFilePath = null;
          }
        }
        _cachedFilePath ??= await _downloadCacheAndPlay(mediaUrl, token, box);
      }

      if (mounted) setState(() => _isLoading = false);
      if (_loadCancelled || !mounted) return;
      await _player.play();
    } catch (e) {
      debugPrint('Audio load error: $e');
      if (mounted) {
        showTopSnackBar(
            context, AppLocalizations.of(context).snackbarFailedToLoadAudio);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<String?> _getCachedFilePath() async {
    final file = await AudioCacheStore.find(widget.message.id);
    return file?.path;
  }

  /// Plays a cached voice note, sealed or legacy-plain. False means the file
  /// is unreadable (sealed, key gone) and the caller should re-download.
  Future<bool> _playCachedFile(String path) async {
    final file = File(path);
    // Peek the header first: a legacy plaintext file plays via the zero-copy
    // file path and must not be read into memory just to learn that.
    final raf = await file.open();
    Uint8List head;
    try {
      head = await raf.read(SealedAudioCodec.magicPeekLength);
    } finally {
      await raf.close();
    }
    if (!SealedAudioCodec.hasMagic(head)) {
      // Legacy plaintext cache file: exactly as before.
      await _player.setFilePath(path);
      return true;
    }
    final bytes = await file.readAsBytes();
    final store = NativeContentStore.instance;
    final plain = store == null ? null : await store.unsealAudioBytes(bytes);
    if (plain == null) return false;
    await _player.setAudioBytes(plain);
    return true;
  }

  /// Downloads, decrypts, seals into the cache when the content store is
  /// armed (plaintext fallback otherwise — same honest rule as the record
  /// path), and starts playback from memory. Returns the cache path.
  Future<String> _downloadCacheAndPlay(
    String url,
    String token,
    BoxCiphertextSource? box,
  ) async {
    // Native-only: the web branch of _loadAndPlayAudio decrypts into memory
    // and never reaches here.
    final file = await AudioCacheStore.createTarget(widget.message.id);
    if (file == null) {
      throw StateError('Voice-note caching is unavailable on this platform');
    }

    final mk = widget.message.mediaKey;
    final mi = widget.message.mediaIv;
    Uint8List plain;
    if (box != null) {
      plain = await loadDecryptedMediaBytes(
        url: url,
        token: token,
        key: mk,
        iv: mi,
        box: box,
      );
    } else {
      final raw = await ApiService(baseUrl: AppConfig.baseUrl).fetchMediaBytes(
        url,
        token,
      );
      if (raw.length > MediaCryptoService.maxBytes) {
        throw Exception('Audio too large');
      }

      plain = Uint8List.fromList(raw);
      if (mk != null && mi != null) {
        plain = await MediaCryptoService().decrypt(plain, mk, mi);
      }
    }

    final store = NativeContentStore.instance;
    final sealed = store == null ? null : await store.sealAudioBytes(plain);
    await file.writeAsBytes(sealed ?? plain, flush: true);

    if (sealed != null) {
      await _player.setAudioBytes(plain);
    } else {
      await _player.setFilePath(file.path);
    }
    return file.path;
  }

  void _seekFromWaveformPosition(double localX, double width) {
    if (width <= 0 || _displayDuration.inMilliseconds <= 0) return;
    final progress = (localX / width).clamp(0.0, 1.0);
    final newPosition = Duration(
      milliseconds: (progress * _displayDuration.inMilliseconds).round(),
    );
    _player.seek(newPosition);
  }

  void _toggleSpeed() {
    setState(() {
      if (_playbackSpeed == 1.0) {
        _playbackSpeed = 1.5;
      } else if (_playbackSpeed == 1.5) {
        _playbackSpeed = 2.0;
      } else {
        _playbackSpeed = 1.0;
      }
      _player.setSpeed(_playbackSpeed);
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      context,
      _isPlaying,
      _isLoading,
      _position,
      _displayDuration,
      _playbackSpeed,
      _togglePlayPause,
      _seekFromWaveformPosition,
      _toggleSpeed,
    );
  }
}
