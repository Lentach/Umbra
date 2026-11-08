part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The newest of [refs] (highest counter), or null for none. Library-level
/// so the first-contact extension reads it too (an extension cannot see
/// another's statics).
ProfilePhotoRef? _newestPhoto(Iterable<ProfilePhotoRef?> refs) {
  ProfilePhotoRef? best;
  for (final ref in refs) {
    if (ref != null && (best == null || ref.rev > best.rev)) best = ref;
  }
  return best;
}

/// Profile photos over the box (decision 138, release A): the SENDING and
/// READING half. The files, references and downloads are `ProfilePhotos`;
/// this is what knows the friends' and siblings' queues.
///
/// * A change of the own photo — and the first launch of the build that
///   moves the server photo, and a photo whose upload is 7 days old — is
///   one quiet `{t: 'profile', av}` frame to every live device of every
///   friend this device holds an address for and to every live sibling
///   (the fan-out of `announceOwnList`, E50d). A frame is sealed only to a
///   device this device already has a session with and that is not paused
///   (decision 38, E93a): a photo is never worth a pre-key fetch, and a
///   device not reached is owed the frame until a connect finds it taken.
/// * A friend's frame replaces its photo only with a higher counter, only
///   for a FRIEND (never a request: decision 53), and its file is fetched
///   at once. A sibling's frame is the account's own newest photo.
extension MessagingProfile on MessagingProvider {
  // ---------- Change (the user card) ----------

  /// Makes [picked] — the bytes of whatever image the user chose — this
  /// account's photo: scaled to ≤256×256 JPEG, encrypted, uploaded once, and
  /// told to every friend and sibling. [ProfilePhotoOutcome.done] once the
  /// reference is committed; the frames then go on their own.
  Future<ProfilePhotoOutcome> setOwnProfilePhoto(Uint8List picked) async {
    final photos = profilePhotos;
    if (photos == null) return ProfilePhotoOutcome.noRoute;
    final jpeg = await profilePhotoScaler(picked);
    if (jpeg == null) return ProfilePhotoOutcome.unreadable;
    final outcome = await photos.setOwn(jpeg);
    if (outcome == ProfilePhotoOutcome.done) unawaited(_announceOwnPhoto());
    return outcome;
  }

  /// Removes the photo: a cleared reference to every friend and sibling.
  Future<ProfilePhotoOutcome> removeOwnProfilePhoto() async {
    final photos = profilePhotos;
    if (photos == null) return ProfilePhotoOutcome.noRoute;
    final outcome = await photos.clearOwn();
    if (outcome == ProfilePhotoOutcome.done) unawaited(_announceOwnPhoto());
    return outcome;
  }

  // ---------- Connect: migration, the weekly upload, frames still owed ----------

  /// One pass per box (re)connect, cheap when there is nothing to do:
  ///  1. the one-time MIGRATION — an account with a server photo and no
  ///     end-to-end reference downloads it, runs the change path once, and
  ///     stops (a failed download is tried again; an account with none, or
  ///     a file that is gone, is settled);
  ///  2. the WEEKLY upload — a photo made more than 7 days ago is made
  ///     again (the box keeps a file 14, D8) and announced;
  ///  3. the frames a change still owes;
  ///  4. the files of references held with no copy here.
  /// At most one runs at a time; a request that lands meanwhile — the next
  /// friend's session came up, the box published — asks for one more pass.
  /// A migration whose download failed is not asked again within a minute,
  /// however often the box reconnects.
  Future<void> syncOwnPhoto() async {
    final photos = profilePhotos;
    final enc = _encryptionProvider;
    if (photos == null || enc == null || !enc.isE2EReady || _isDisposed) return;
    if (_syncingProfile) {
      _profileSyncAgain = true;
      return;
    }
    _syncingProfile = true;
    try {
      do {
        _profileSyncAgain = false;
        await _syncOwnPhotoOnce(photos);
      } while (_profileSyncAgain && !_isDisposed);
    } on Object catch (e) {
      _e2eFlowLog('PROFILE_SYNC_FAILED', {'error': e.runtimeType.toString()});
    } finally {
      _syncingProfile = false;
    }
  }

  Future<void> _syncOwnPhotoOnce(ProfilePhotos photos) async {
    if (photos.own == null && !photos.migrated) {
      await _migrateLegacyPhoto(photos);
    } else if (!photos.migrated) {
      await photos.markMigrated();
    }
    final refreshed = await photos.refreshIfDue();
    if (refreshed != null) {
      _e2eFlowLog('PROFILE_PHOTO_REFRESHED', {'outcome': refreshed.name});
    }
    if (photos.ownPending) await _announceOwnPhoto();
    if (!_profileFilesChecked) {
      _profileFilesChecked = true;
      unawaited(photos.fetchMissing());
    }
  }

  /// How long a failed server-photo download waits before it is asked again.
  static const Duration _profileMigrateRetry = Duration(minutes: 1);

  Future<void> _migrateLegacyPhoto(ProfilePhotos photos) async {
    final fetch = legacyOwnPhoto;
    if (fetch == null) return;
    final tried = _profileMigrateTriedAt;
    final now = clock.now();
    if (tried != null && now.difference(tried) < _profileMigrateRetry) return;
    _profileMigrateTriedAt = now;
    final Uint8List? file;
    try {
      file = await fetch();
    } on Object catch (e) {
      // A transient failure: nothing is decided, the next pass asks again.
      _e2eFlowLog('PROFILE_MIGRATE_FETCH_FAILED', {
        'error': e.runtimeType.toString(),
      });
      return;
    }
    // No server photo, or a file the server no longer holds: settled.
    if (file == null) {
      await photos.markMigrated();
      return;
    }
    final jpeg = await profilePhotoScaler(file);
    if (jpeg == null) {
      // The server holds bytes that are no image: asking again changes
      // nothing.
      await photos.markMigrated();
      return;
    }
    final outcome = await photos.setOwn(jpeg);
    _e2eFlowLog('PROFILE_MIGRATED', {'outcome': outcome.name});
  }

  /// A request or an accept is about to carry the own profile: a photo whose
  /// upload is older than 7 days is made again first (decision 138), so the
  /// `av` it carries names a file the box still holds. Never fails the
  /// caller; when it cannot refresh the old reference rides.
  Future<void> _refreshOwnPhotoIfStale() async {
    final photos = profilePhotos;
    if (photos == null) return;
    try {
      if (await photos.refreshIfDue() == ProfilePhotoOutcome.done) {
        unawaited(_announceOwnPhoto());
      }
    } on Object {
      // The old reference rides.
    }
  }

  // ---------- Announce ----------

  /// Sends the own reference to every friend device and sibling that has not
  /// taken it yet, and clears the debt once every live one has. One pass at
  /// a time: a change that lands meanwhile asks for another.
  Future<void> _announceOwnPhoto() async {
    if (_announcingProfile) {
      _profileAnnounceAgain = true;
      return;
    }
    _announcingProfile = true;
    try {
      do {
        _profileAnnounceAgain = false;
        await _announceOwnPhotoOnce();
      } while (_profileAnnounceAgain && !_isDisposed);
    } on Object catch (e) {
      _e2eFlowLog('PROFILE_ANNOUNCE_FAILED', {
        'error': e.runtimeType.toString(),
      });
    } finally {
      _announcingProfile = false;
    }
  }

  /// A reference nobody could be told of for this long is let go: a cleared
  /// one has no weekly upload to supersede it, and a device that has not
  /// read its queue in two weeks learns the photo from the next re-send.
  static const Duration _profileOwedFor = Duration(days: 14);

  Future<void> _announceOwnPhotoOnce() async {
    final photos = profilePhotos;
    final ref = photos?.own;
    if (photos == null || ref == null || !photos.ownPending) return;
    final made = ref.uploadedAt;
    if (made != null && DateTime.now().difference(made) > _profileOwedFor) {
      await photos.markAnnounced(ref);
      return;
    }
    final json = jsonEncode(E2eEnvelope.buildProfile(ref));
    if (await _fanOutProfile(json, ref.rev)) await photos.markAnnounced(ref);
  }

  /// [json] to every live sibling and every live device of every friend with
  /// a box address, quiet. True when every one of them took it (or took it
  /// earlier in this process); false leaves the debt for the next connect.
  Future<bool> _fanOutProfile(String json, int rev) async {
    final outbox = boxOutbox;
    final enc = _encryptionProvider;
    final own = _currentUserId;
    if (outbox == null || enc == null || own == null || !enc.isE2EReady) {
      return false;
    }
    var all = true;

    // Our own other devices: the account's newest photo, one copy each.
    final mine = await ownLiveDevices();
    if (mine == null) {
      all = false;
    } else {
      final addresses = outbox.siblingAddresses();
      for (final device in mine.live) {
        if (device == mine.self) continue;
        final to = addresses[device];
        if (to == null) {
          all = false;
          continue;
        }
        if (!await _sendProfileFrame(
          enc: enc,
          outbox: outbox,
          user: own,
          to: to,
          rev: rev,
          seal: () => encryptForOwnDevice(device, json),
        )) {
          all = false;
        }
      }
    }

    // Every friend with a route, on the lists this connect verified: a frame
    // never times a lookup (decision 21).
    for (final peer in outbox.coveredPeers().toList()) {
      if (_isDisposed) return false;
      final live = enc.cachedDeviceList(peer)?.liveDeviceIds.toSet();
      if (live == null) {
        all = false;
        continue;
      }
      for (final MapEntry(key: device, value: to)
          in outbox.addressesFor(peer).entries) {
        // A device the verified list does not name live is no one to tell.
        if (!live.contains(device)) continue;
        if (!await _sendProfileFrame(
          enc: enc,
          outbox: outbox,
          user: peer,
          to: to,
          rev: rev,
          seal: () => encryptForFriend(peer, device, json),
        )) {
          all = false;
        }
      }
    }
    _e2eFlowLog('PROFILE_ANNOUNCED', {'rev': rev, 'all': all});
    return all;
  }

  /// One profile frame to [to] (device of [user]). True when this device's
  /// box took it, now or earlier in this process.
  Future<bool> _sendProfileFrame({
    required EncryptionProvider enc,
    required BoxOutbox outbox,
    required int user,
    required ContactOutbound to,
    required int rev,
    required Future<BoxFrame?> Function() seal,
  }) async {
    final device = to.peerDeviceId;
    final key = '$user:$device:$rev';
    if (_profileSent.contains(key)) return true;
    void skipped(String why) =>
        _e2eFlowLog('PROFILE_FRAME_SKIPPED', {'why': why});
    try {
      // Never builds a session (E38b) and never seals to a full queue
      // (E93a): a device that is not ready is owed the frame, not probed.
      if (!await _hasUsableBoxSession(enc, user, device)) {
        skipped('no_session');
        return false;
      }
      if (_boxPaused.isPaused(user, device)) {
        skipped('paused');
        return false;
      }
      final frame = await seal();
      if (frame == null || frame.signal.length > BoxFrame.maxSignalBytes) {
        skipped('seal');
        return false;
      }
      final outcome = await outbox.deliver(
        to,
        frame.encode(),
        mode: BoxSendMode.quiet,
      );
      _noteBoxAnswer(user, device, outcome);
      if (outcome != BoxSendOutcome.taken) return false;
      _profileSent.add(key);
      return true;
    } on Object catch (e) {
      skipped(e.runtimeType.toString());
      return false;
    }
  }

  // ---------- Read ----------

  /// Friend [senderId]'s `profile` frame. Always finished: a frame that is
  /// not sound, or from an account that is no friend, is dropped; one that
  /// does not supersede the held reference changes nothing.
  Future<bool> _takeFriendProfile(int senderId, String plaintext) async {
    final parsed = E2eEnvelope.parseProfile(plaintext);
    if (parsed == null) {
      _e2eFlowLog('BOX_ENVELOPE_UNREADABLE', {'t': E2eEnvelope.typeProfile});
      return true;
    }
    final photos = profilePhotos;
    if (photos == null) return false;
    if (boxFriends?.contactOf(senderId)?.state != ContactState.friend) {
      _e2eFlowLog('BOX_PROFILE_REFUSED', {'peer': senderId, 'why': 'no_friend'});
      return true;
    }
    if (await photos.takeFriend(senderId, parsed.avatar)) {
      _e2eFlowLog('BOX_PROFILE_TAKEN', {
        'peer': senderId,
        'rev': parsed.avatar.rev,
      });
      _afterProfileChange();
    }
    return true;
  }

  /// A sibling's `profile` frame: the account's own newest photo (only ever
  /// read from our self-queue; the caller checks).
  Future<bool> _takeOwnProfile(String plaintext) async {
    final parsed = E2eEnvelope.parseProfile(plaintext);
    if (parsed == null) {
      _e2eFlowLog('BOX_SIBLING_UNREADABLE', {'t': E2eEnvelope.typeProfile});
      return true;
    }
    final photos = profilePhotos;
    if (photos == null) return false;
    if (await photos.takeSibling(parsed.avatar, madeAt: parsed.madeAt)) {
      _e2eFlowLog('BOX_PROFILE_OWN_TAKEN', {'rev': parsed.avatar.rev});
      notifyListeners();
    }
    return true;
  }

  /// A friend's photo moved: the lists and the chat rows read the record
  /// again.
  void _afterProfileChange() {
    onBoxContactsChanged?.call();
    _conversationsProvider?.refreshChats();
    notifyListeners();
  }
}
