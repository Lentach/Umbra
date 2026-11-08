import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/profile_photo.dart';
import '../box/box_media_store.dart';
import '../media_crypto_service.dart';
import 'profile_photo_codec.dart';

/// The decrypted profile photos, in memory, keyed by the box media id
/// (decision 138). A photo is a few KiB, shown in many places at once (chat
/// list, app bar, contact card): the avatar widgets ask [bytesFor] and
/// rebuild when [notifyListeners] says a file landed.
///
/// The file itself rests as ciphertext in [BoxMediaStore] (decision 40's
/// copy, the sender's own included); this holds only what has been shown
/// since the app opened, and is gone with it. Never written anywhere.
///
/// A process-wide instance, like the app's other device-level services:
/// widgets read [shared]; the connect wiring [bind]s it to the account's
/// store, and a sign-out [unbind]s it.
class ProfilePhotoCache extends ChangeNotifier {
  ProfilePhotoCache({MediaCryptoService? crypto})
    : _crypto = crypto ?? MediaCryptoService();

  /// The cache every avatar widget reads. Replaced only by tests.
  static ProfilePhotoCache shared = ProfilePhotoCache();

  /// The most photos kept decrypted at once; the oldest goes first.
  static const int maxEntries = 256;

  final MediaCryptoService _crypto;
  BoxMediaStore? _store;
  int? _userId;

  /// Decrypted files by media id, oldest first.
  final LinkedHashMap<String, Uint8List> _bytes = LinkedHashMap();

  /// References (media id, key and nonce) whose lookup in the store is
  /// running, or found nothing: not asked again until a download lands
  /// ([ingest]). Per REFERENCE, never per media id: a friend can name any
  /// id, and a reference that does not open must not stop the reference
  /// that really holds the file from reading it.
  final Set<String> _asked = {};

  /// References whose file did not open or is no sound photo: never shown,
  /// never asked again — and only themselves, for the same reason.
  final Set<String> _refused = {};

  static String _refKey(String id, String key, String iv) => '$id|$key|$iv';

  /// Binds the cache to [userId]'s device store: where a photo not shown yet
  /// is read from. Called at every connect; a different account starts empty.
  void bind({required BoxMediaStore store, required int userId}) {
    if (_userId != userId) _clear();
    _store = store;
    _userId = userId;
  }

  /// Forgets everything: sign-out, or another account.
  void unbind() {
    _store = null;
    _userId = null;
    _clear();
  }

  void _clear() {
    final had = _bytes.isNotEmpty;
    _bytes.clear();
    _asked.clear();
    _refused.clear();
    if (had) notifyListeners();
  }

  /// The decrypted photo [ref] names, or null: it names none (cleared), the
  /// file is not here (yet), or it is no sound photo. A file not shown yet
  /// is read from the store in the background and [notifyListeners] fires
  /// once it is in; nothing here ever touches the network.
  Uint8List? bytesFor(ProfilePhotoRef? ref) {
    final id = ref?.mediaId;
    final key = ref?.key;
    final iv = ref?.iv;
    if (ref == null || id == null || key == null || iv == null) return null;
    final held = _bytes[id];
    if (held != null) return held;
    final known = _refKey(id, key, iv);
    if (_refused.contains(known) || !_asked.add(known)) return null;
    unawaited(_readFromStore(ref));
    return null;
  }

  Future<void> _readFromStore(ProfilePhotoRef ref) async {
    final store = _store;
    final userId = _userId;
    final idBytes = ref.mediaIdBytes;
    if (store == null || userId == null || idBytes == null) return;
    try {
      final ciphertext = await store.get(userId, idBytes);
      if (ciphertext == null || _userId != userId) return;
      await ingest(ref, ciphertext);
    } on Object {
      // An unreadable store is "not here": a download's [ingest] fills it.
    }
  }

  /// Decrypts [ciphertext] (the UNFRAMED file) under [ref]'s key and keeps
  /// it. True when the photo is held now. A file that does not authenticate,
  /// is too big, or is no JPEG within the accepted size is refused for good:
  /// the sender's key and file are the sender's word, never trusted as an
  /// image until they pass.
  Future<bool> ingest(ProfilePhotoRef ref, Uint8List ciphertext) async {
    final id = ref.mediaId;
    final key = ref.key;
    final iv = ref.iv;
    if (id == null || key == null || iv == null) return false;
    if (_bytes.containsKey(id)) return true;
    final known = _refKey(id, key, iv);
    if (ciphertext.length > ProfilePhotoCodec.kMaxCiphertextBytes) {
      _refused.add(known);
      return false;
    }
    final Uint8List plain;
    try {
      plain = await _crypto.decrypt(ciphertext, key, iv);
    } on Object {
      _refused.add(known);
      return false;
    }
    if (!ProfilePhotoCodec.isSound(plain)) {
      _refused.add(known);
      return false;
    }
    _put(id, plain);
    return true;
  }

  /// Keeps [plain] — a photo this device just made — as what [ref] names, no
  /// decrypt needed. False for a cleared reference or a file that is no
  /// sound photo.
  bool remember(ProfilePhotoRef ref, Uint8List plain) {
    final id = ref.mediaId;
    if (id == null || !ProfilePhotoCodec.isSound(plain)) return false;
    _put(id, plain);
    return true;
  }

  void _put(String id, Uint8List plain) {
    _bytes.remove(id);
    _bytes[id] = plain;
    while (_bytes.length > maxEntries) {
      _bytes.remove(_bytes.keys.first);
    }
    notifyListeners();
  }

  /// Drops [mediaId]: the reference that named it was replaced or removed.
  void forget(String? mediaId) {
    if (mediaId == null) return;
    final prefix = '$mediaId|';
    _asked.removeWhere((k) => k.startsWith(prefix));
    _refused.removeWhere((k) => k.startsWith(prefix));
    if (_bytes.remove(mediaId) != null) notifyListeners();
  }

  /// Test seam: the decrypted photo [bytes] for [mediaId], as if shown.
  @visibleForTesting
  void putForTest(String mediaId, Uint8List bytes) => _put(mediaId, bytes);
}
