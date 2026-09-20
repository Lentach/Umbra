import 'package:flutter/foundation.dart';

/// Did this boot PROVE that local content was destroyed?
///
/// One latch, set only where destruction is a fact rather than an inference.
/// Today that is exactly one place: the native opener recreating the
/// SQLCipher file after secure storage was successfully enumerated and held
/// no DB key (`content_kv_opener_io.dart`). There the old file is ciphertext
/// whose key is provably gone — decrypted history, the contact graph and the
/// Signal identity in the same store all died with it.
///
/// Deliberately NOT fed by "the store is empty" or by an absent boot marker:
/// both are also true of a brand-new install, and a loss screen shown to
/// someone who never had anything is a lie that teaches users to dismiss it.
/// An absent marker on web is the same ambiguity — an evicted origin takes
/// the session tokens with it, so that user arrives at the login screen, not
/// here.
///
/// Process-scoped, never persisted: the screen is a response to THIS boot's
/// event. Persisting it would re-accuse a device that already recovered.
class StorageLoss {
  StorageLoss._();

  /// The latch, as something a widget can LISTEN to.
  ///
  /// A plain static bool read per build is not enough and the reason is
  /// exact: [record] fires while the content store opens, which is strictly
  /// AFTER the surface that shows this has mounted, and a widget that read a
  /// false latch registered no dependency on anything — so nothing would
  /// ever ask it to look again and the screen could never appear.
  static final ValueNotifier<bool> listenable = ValueNotifier<bool>(false);

  static String? _reason;

  /// True from the moment [record] runs until [acknowledge] or process exit.
  static bool get lostThisBoot => listenable.value;

  /// Which check proved it, for the surface's diagnostics line.
  static String? get reason => _reason;

  /// Latches the loss. Idempotent: the FIRST reason is kept, because it is
  /// the one closest to the cause.
  static void record(String reason) {
    if (listenable.value) return;
    _reason = reason;
    listenable.value = true;
  }

  /// The user has seen the screen and chosen (restore, or continue fresh).
  static void acknowledge() {
    listenable.value = false;
  }

  @visibleForTesting
  static void resetForTest() {
    listenable.value = false;
    _reason = null;
  }
}
