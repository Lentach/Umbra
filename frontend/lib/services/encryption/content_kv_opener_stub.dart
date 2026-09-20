import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/e2e_persistent_diag.dart';
import '../secure_kv.dart';
import 'content_key_manager.dart';
import 'content_key_wrap.dart';
import 'content_kv.dart';
import 'content_sealer.dart';
import 'sealed_web_content_kv.dart';

Future<ContentKv>? _memo;

/// Test-only: drops the process-wide memo so each test opens fresh.
@visibleForTesting
void debugResetPlatformContentKv() {
  _memo = null;
}

/// Web build of the opener (this file must stay free of `dart:io`): the
/// sealed backend, canary-gated and unblocked 2026-08-03 (`CANARY_OK
/// {ageDays: 5}` on the production device — see
/// `docs/design/web-content-sealing.md`).
///
/// Memoized AS A FUTURE, mirroring the Android opener: concurrent first calls
/// cannot race two stores into existence, and a session that fell back to
/// prefs STAYS on prefs — flip-flopping backends mid-session would split the
/// read view.
Future<ContentKv> openPlatformContentKv() => _memo ??= _open();

/// Mid-session passcode re-lock: the open sealed store forgets its keys AND
/// every decrypted row it is holding ([SealedWebContentKv.revoke]), and the
/// memo is dropped so the next open is decided from scratch — which, while
/// the vault is locked, rethrows `locked` rather than serving a plaintext
/// fallback.
Future<void> revokePlatformContentKv() async {
  final open = _memo;
  _memo = null;
  if (open == null) return;
  try {
    final kv = await open;
    if (kv is SealedWebContentKv) kv.revoke();
  } catch (_) {
    // A store that never opened has nothing to revoke.
  }
}

/// Web twin of the native gate: every backend the opener can hand out here
/// is acceptable. The sealed store wraps `contact_v1_` rows like the message
/// families; the prefs fallback is parity with the `sig_` Signal keys, which
/// already sit in the same localStorage.
bool contactStoreAccepts(ContentKv kv) => true;

Future<ContentKv> _open() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    // SAME instance/options as the Signal keys and the ContentKeyCanary
    // target: the content keys must live and die with the identity, never
    // alone.
    final keys = ContentKeyManager(
      const FlutterSecureStorageKv(
        FlutterSecureStorage(webOptions: WebOptions(dbName: 'FireplaceE2E')),
      ),
      wrap: ContentKeyWrap.instance,
    );
    return await SealedWebContentKv.open(
      prefs: prefs,
      keys: keys,
      sealer: AesGcmContentSealer(),
    );
  } on ContentStoreUnavailable catch (e) {
    if (e.locked) {
      // Phase 2: wrapped keys present, vault locked. Falling back here would
      // write the decrypted-message cache in cleartext while the app is still
      // locked. Rethrow so E2E stays down until the user unlocks, and DO NOT
      // memoize a broken store — `_memo` is cleared so the next attempt (post
      // unlock) opens the sealed backend for real.
      _memo = null;
      E2ePersistentDiag.record('CONTENT_STORE_LOCKED', const {});
      rethrow;
    }
    // Fallback = the pre-sealing behavior, loudly diagnosed. Status quo
    // plaintext with a diag beats a store that pretends to be sealed. The
    // `web-` stage prefix keeps this stream separable from Android's.
    E2ePersistentDiag.record('CONTENT_STORE_FALLBACK', {
      'stage': 'web-${e.stage}',
    });
    return PrefsContentKv.open();
  } catch (_) {
    E2ePersistentDiag.record('CONTENT_STORE_FALLBACK', {'stage': 'web-open'});
    return PrefsContentKv.open();
  }
}
