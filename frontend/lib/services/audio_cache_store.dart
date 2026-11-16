import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// Owns the on-disk cache of voice notes.
///
/// Native only. A played voice note is cached as
/// `<app documents>/audio_cache/<messageId>.audio`, SEALED under the content
/// store's active key ([writeSealed]; hardening A5). Older builds wrote it in
/// the clear; those files are sealed in place once per launch
/// (`sealPlainAudioCacheFiles`). A message purge that ignores this directory
/// still leaves the note behind, and the documents directory is swept into
/// iCloud / Android auto-backup. Web never writes here (audio stays in
/// memory), so every entry point returns early under [kIsWeb].
///
/// This is a service rather than state on the playback widget so the filename
/// convention has exactly ONE owner: the legacy `.m4a` extension is still on
/// disk for older messages, and a purge that only knew about `.audio` would
/// silently miss them.
class AudioCacheStore {
  const AudioCacheStore._();

  static const String _dirName = 'audio_cache';

  /// Current and legacy filenames for [messageId]. Both are checked on read
  /// and both are destroyed on purge.
  static List<String> fileNamesFor(int messageId) => [
    '$messageId.audio',
    '$messageId.m4a',
  ];

  /// Suffix of the temp file every atomic replace writes first.
  static const String _tmpSuffix = '.tmp';

  /// Temp-file suffixes this cache leaves when a process dies between a
  /// write and its rename: [_tmpSuffix], and `.reseal` from older builds'
  /// rotation pass. Holds sealed bytes, but a purge must still take it.
  static const List<String> _tempSuffixes = [_tmpSuffix, '.reseal'];

  /// Whether [name] is a cached note (any id, current or legacy name).
  static bool isNoteName(String name) =>
      name.endsWith('.audio') || name.endsWith('.m4a');

  /// Whether [name] is a temp file left by an interrupted [replaceAtomically].
  static bool isTempName(String name) => _tempSuffixes.any(
    (suffix) =>
        name.endsWith(suffix) &&
        isNoteName(name.substring(0, name.length - suffix.length)),
  );

  static Future<void> _tail = Future<void>.value();

  /// Runs [action] alone against the cache. Purges, cache writes and both
  /// seal passes (launch and rotation) read a file and then rename over it;
  /// interleaved, a seal could rename a note back after a purge deleted it,
  /// or seal it under a key a rotation had already passed over. Never nest.
  static Future<T> exclusive<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Replaces [target] with [bytes] through a temp file and a rename, so a
  /// reader never sees a half-written note. Call inside [exclusive].
  static Future<void> replaceAtomically(File target, Uint8List bytes) async {
    final tmp = File('${target.path}$_tmpSuffix');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  /// The cache directory, or null on web.
  static Future<Directory?> directory() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/$_dirName');
  }

  /// The existing cached file for [messageId], or null.
  static Future<File?> find(int messageId) async {
    final dir = await directory();
    if (dir == null) return null;
    for (final name in fileNamesFor(messageId)) {
      final file = File('${dir.path}/$name');
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// Destination for a freshly downloaded voice note, creating the directory.
  /// Null on web.
  static Future<File?> createTarget(int messageId) async {
    final dir = await directory();
    if (dir == null) return null;
    await dir.create(recursive: true);
    return File('${dir.path}/$messageId.audio');
  }

  /// Caches a downloaded voice note in [target] ONLY sealed (hardening A5):
  /// [seal] is the content store's `sealAudioBytes`, null when there is no
  /// store. No store, or a seal that answers null, writes nothing at all —
  /// the note plays from memory and the next play downloads it again.
  /// Sealed and written inside [exclusive], so the key it seals under is the
  /// one a concurrent rotation will see. Returns whether [target] now holds
  /// the sealed note.
  static Future<bool> writeSealed(
    File target,
    Uint8List plain,
    Future<Uint8List?> Function(Uint8List plain)? seal,
  ) {
    if (seal == null) return Future.value(false);
    return exclusive(() async {
      final sealed = await seal(plain);
      if (sealed == null) return false;
      await replaceAtomically(target, sealed);
      return true;
    });
  }

  /// Destroy the cached audio for [messageIds].
  ///
  /// Returns the ids whose file could not be removed and may still hold
  /// readable audio. Callers folding this into a purge result MUST treat a
  /// non-empty return as an incomplete purge.
  ///
  /// Never throws. It is called from a fire-and-forget purge, so an escaping
  /// exception would become an unhandled async error and abandon the rest of
  /// the work. Web returns empty because nothing was ever written there; a
  /// failure to even resolve the directory returns EVERY id, because at that
  /// point we cannot say whether decrypted audio is still on disk and
  /// reporting success would be a guess.
  static Future<Set<int>> remove(Iterable<int> messageIds) async {
    final ids = messageIds.toSet();
    if (kIsWeb || ids.isEmpty) return <int>{};

    final Directory dir;
    try {
      final resolved = await directory();
      if (resolved == null) return <int>{};
      dir = resolved;
    } catch (_) {
      return ids;
    }

    return removeIn(dir, ids);
  }

  /// [remove] against an explicit cache directory. Takes the notes' temp
  /// files too, inside [exclusive] so no seal can rename a note back.
  @visibleForTesting
  static Future<Set<int>> removeIn(Directory dir, Iterable<int> ids) =>
      exclusive(() async {
        final failed = <int>{};
        for (final id in ids) {
          for (final note in fileNamesFor(id)) {
            for (final name in [
              note,
              for (final suffix in _tempSuffixes) '$note$suffix',
            ]) {
              try {
                final file = File('${dir.path}/$name');
                if (file.existsSync()) await file.delete();
              } on Object {
                failed.add(id);
              }
            }
          }
        }
        return failed;
      });

  /// Destroy every cached voice note. Returns how many files were removed.
  static Future<int> clear() async {
    final dir = await directory();
    if (dir == null || !dir.existsSync()) return 0;
    return exclusive(() async {
      var deleted = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) deleted++;
      }
      await dir.delete(recursive: true);
      return deleted;
    });
  }
}
