import 'dart:io';
import 'dart:typed_data';

import '../audio_cache_store.dart';
import 'sealed_audio_codec.dart';

/// Rotation pass over the voice-note cache: re-seals every note whose header
/// names a retiring content key, so the rotation may destroy those keys
/// without bricking any voice note.
///
/// Returns whether the cache is provably clean of the retiring kids. Notes
/// that are NOT sealed (legacy plaintext `.audio`/`.m4a`) are left alone here
/// — they hold no reference to any key, so key destruction cannot hurt them;
/// [sealPlainAudioCacheFiles] seals them once per launch. Temp files are
/// skipped: they die with their key, and the launch pass deletes them.
///
/// Each note is re-sealed inside `AudioCacheStore.exclusive` with an atomic
/// replace, so a kill mid-reseal leaves either the old file (still sealed
/// under the retiring key — the rotation aborts and retries, key survives)
/// or the new one, and a purge cannot be undone by the rename.
Future<bool> resealAudioCacheFiles(
  Map<String, Uint8List> retiringKeys,
  String newKid,
  Uint8List newKey,
) async {
  final Directory? dir;
  try {
    dir = await AudioCacheStore.directory();
  } on Object {
    return false;
  }
  if (dir == null) return true; // web / no cache: nothing to re-seal
  if (!dir.existsSync()) return true;

  var clean = true;
  try {
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      if (!AudioCacheStore.isNoteName(entry.uri.pathSegments.last)) continue;
      try {
        await AudioCacheStore.exclusive(() async {
          if (!entry.existsSync()) return; // purged since the listing
          final bytes = await entry.readAsBytes();
          final kid = SealedAudioCodec.kidOf(bytes);
          if (kid == null) return; // legacy plaintext
          final retiringKey = retiringKeys[kid];
          if (retiringKey == null) return; // already on a surviving key
          final plain = await SealedAudioCodec.unseal(
            bytes: bytes,
            keyBytes: retiringKey,
          );
          // Unreadable under the key that allegedly sealed it: corrupt, and
          // equally unreadable whether the key lives or dies. Not a reason
          // to keep the key alive.
          if (plain == null) return;
          final resealed = await SealedAudioCodec.seal(
            kid: newKid,
            keyBytes: newKey,
            plaintext: plain,
          );
          await AudioCacheStore.replaceAtomically(entry, resealed);
        });
      } on Object {
        // This note may still need the retiring key; the rotation must not
        // destroy it. Abort-and-retry semantics, same as a refused DB batch.
        clean = false;
      }
    }
  } on Object {
    return false;
  }
  return clean;
}

enum _Sealing { skipped, sealed, refused }

/// Launch pass over the voice-note cache (hardening A5): seals in place every
/// legacy PLAINTEXT note an older build wrote (`<id>.audio` / `<id>.m4a`
/// without the sealed header), using [seal] — the content store's
/// `sealAudioBytes`, so the files land under the active key and rotation
/// carries them from then on — and deletes temp files a killed write left.
/// Only files last modified before [before] (default: now) are touched:
/// anything newer is a write that began after the pass. Stops at the first
/// refused seal (no armed key: nothing else would seal either). Each file is
/// handled inside `AudioCacheStore.exclusive`, so a purge between the read
/// and the rename cannot be undone, and the key read is the one a concurrent
/// rotation sees. Never throws; returns how many notes it sealed.
Future<int> sealPlainAudioCacheFiles(
  Future<Uint8List?> Function(Uint8List plain) seal, {
  Directory? dir,
  DateTime? before,
}) async {
  final cutoff = before ?? DateTime.now();
  var sealed = 0;
  try {
    final cache = dir ?? await AudioCacheStore.directory();
    if (cache == null || !cache.existsSync()) return 0;
    await for (final entry in cache.list()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final isTemp = AudioCacheStore.isTempName(name);
      if (!isTemp && !AudioCacheStore.isNoteName(name)) continue;
      try {
        final outcome = await AudioCacheStore.exclusive(() async {
          if (!entry.existsSync()) return _Sealing.skipped; // purged
          if (!entry.lastModifiedSync().isBefore(cutoff)) {
            return _Sealing.skipped;
          }
          if (isTemp) {
            await entry.delete();
            return _Sealing.skipped;
          }
          final bytes = await entry.readAsBytes();
          if (SealedAudioCodec.hasMagic(bytes)) return _Sealing.skipped;
          final sealedBytes = await seal(bytes);
          if (sealedBytes == null) return _Sealing.refused;
          await AudioCacheStore.replaceAtomically(entry, sealedBytes);
          return _Sealing.sealed;
        });
        if (outcome == _Sealing.refused) return sealed;
        if (outcome == _Sealing.sealed) sealed++;
      } on Object {
        // This note stays as it was; the next launch tries again.
      }
    }
  } on Object {
    // No directory to read: nothing this pass can do.
  }
  return sealed;
}
