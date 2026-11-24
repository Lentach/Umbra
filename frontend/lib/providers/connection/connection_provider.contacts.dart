part of '../connection_provider.dart';

// Extension methods on ConnectionProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The contact store under a live session: open, re-open, the backup's
/// settle and the chat list's retry.
extension ConnectionContacts on ConnectionProvider {
  /// Opens the contact store for [userId], diagnosing and surviving a
  /// refusal: the session goes on with empty lists, and [contactStoreFailed]
  /// puts the reason above the chat list. Retried on every connect (a locked
  /// web vault opens after the unlock) and by [retryContactStore]; the
  /// durable diag is written once per distinct stage so reconnect churn
  /// cannot flood the 80-entry ring.
  Future<void> _openContactStore(int userId) async {
    final store = _contactStore;
    if (store == null) return;
    final before = _contactStoreUnavailable;
    try {
      await store.open(userId);
      _contactStoreUnavailable = null;
    } on ContactStoreUnavailable catch (e) {
      if (e.stage != _contactStoreUnavailable) {
        E2ePersistentDiag.record('CONTACT_STORE_UNAVAILABLE', {
          'stage': e.stage,
        });
      }
      _contactStoreUnavailable = e.stage;
    }
    if (_contactStoreUnavailable != before) notifyListeners();
  }

  /// Re-opens a contact store that is closed under a live session — a web
  /// vault unlocked after a re-lock or a locked boot, or a store that would
  /// not open ([retryContactStore]) — and lets everything that found it
  /// closed read it again. An open store is left alone: Android never
  /// revokes (wrapping is web-only), so an unlock there does no re-read.
  Future<void> _reopenContactStore() async {
    final uid = _currentUserId;
    final store = _contactStore;
    if (uid == null || store == null || store.isOpen) return;
    await _openContactStore(uid);
    if (!store.isOpen) return;
    _friendsProvider?.onContactsChanged();
    _conversationsProvider?.hydrateFromStore();
    // A vault that booted locked left the box without a request queue.
    _box?.storeOpened();
    _refreshBoxDeviceLists();
    // The connect skipped 4c on the closed store: without this the backup's
    // pending restore stays latched and nothing uploads until a reconnect.
    _settleContactBackup(_connectGeneration);
  }

  /// 4c's tail, once the store is open: apply the backup's pending restore
  /// (upgrade-only), then publish what the store holds. Until the restore is
  /// applied the backup refuses every upload, so a store opened after the
  /// connect (a retry, a web unlock) must run this too.
  void _settleContactBackup(int generation) {
    final backup = _contactBackup;
    if (backup == null) return;
    unawaited(
      backup.ready.then((_) async {
        if (_connectGeneration != generation) return;
        if (await backup.applyRestore() > 0) {
          if (_connectGeneration != generation) return;
          _friendsProvider?.onContactsChanged();
          _conversationsProvider?.hydrateFromStore();
        }
        if (_connectGeneration != generation) return;
        await backup.flushPending();
      }),
    );
  }

  /// The contact store would not open this session for a reason other than
  /// a locked web vault (which the passcode gate already covers): on Android
  /// that is the encrypted store failing closed (hardening plan A3), and the
  /// lists are empty until it opens.
  bool get contactStoreFailed =>
      _contactStoreUnavailable != null && _contactStoreUnavailable != 'locked';

  /// The chat list's "try again" for [contactStoreFailed]. The E2E init of
  /// this connect (run at `socketReady`) read the same store, so it
  /// failed with it and is run again once the store is open. Before
  /// `socketReady` nothing is re-run: that event starts the init itself, and
  /// one earlier would emit before the server finished authenticating. A tap while a
  /// retry runs joins it: a second open overtaking the first would clear
  /// the failure while the store is still closed.
  Future<void> retryContactStore() =>
      _contactStoreRetry ??= _retryContactStore().whenComplete(
        () => _contactStoreRetry = null,
      );

  Future<void> _retryContactStore() async {
    await _reopenContactStore();
    final encryption = _encryptionProvider;
    if (_contactStore?.isOpen != true ||
        !_accountReady ||
        encryption == null ||
        encryption.isE2EReady) {
      return;
    }
    await encryption.retryE2EInit();
  }
}
