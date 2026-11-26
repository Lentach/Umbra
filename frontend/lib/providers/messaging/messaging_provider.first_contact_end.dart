part of '../messaging_provider.dart';

// Extension methods on MessagingProvider's own state: notifyListeners() is legitimate here.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// The end of a friendship made over the box, out of
/// [MessagingFirstContact] (E15j, decision 113): our own end of one, a
/// `goodbye` read, and the goodbye to every friend when the account is
/// deleted.
extension MessagingFirstContactEnd on MessagingProvider {
  // ---------- The end of a friendship (E15j) ----------

  /// Ends the friendship made over the box with [userId] — or, for a
  /// [block], any request pending over the box with it: our siblings are
  /// told FIRST, then a `goodbye` goes to each of its devices this device
  /// holds an address for (best effort), then our queues for it are deleted
  /// and the record goes or stays `blocked`. Throws [StateError] — nothing
  /// ended, nothing sent to the peer — when a sibling's copy did not go: a
  /// sibling that never hears of it would keep writing into queues the
  /// peer deletes (review). The chat and its history are the caller's
  /// (`FriendsProvider` removes them right after, while the chat row still
  /// names the peer).
  Future<void> endBoxFriendship(int userId, {required bool block}) async {
    final link = boxFirstContact;
    final friends = boxFriends;
    final outbox = boxOutbox;
    final record = friends?.contactOf(userId);
    if (link == null || !(record?.onBoxRoute ?? false)) return;
    if (!await _relayToAllSiblings(
      jsonEncode(E2eEnvelope.buildGoodbye(sentTo: userId, block: block)),
      peer: userId,
    )) {
      throw StateError('box end of $userId: a sibling was not told');
    }
    if (record!.state == ContactState.friend && outbox != null) {
      final goodbye = jsonEncode(E2eEnvelope.buildGoodbye());
      for (final MapEntry(key: device, value: to)
          in outbox.addressesFor(userId).entries) {
        final frame = await encryptForFriend(userId, device, goodbye);
        // No message in a goodbye: quiet, no wake (decision 91).
        final sent =
            frame != null &&
            await outbox.deliver(
                  to,
                  frame.encode(),
                  mode: BoxSendMode.quiet,
                ) ==
                BoxSendOutcome.taken;
        if (!sent) {
          _firstContactLog('BOX_GOODBYE_NOT_SENT', userId, {'device': device});
        }
      }
    }
    await link.endBoxFriendship(userId, block: block);
    _afterBoxFriendshipEnded(userId);
  }

  /// A `goodbye` read from [userId] — a friend the box carries, whoever made
  /// the friendship (decision 107) — or a sibling's copy of ours: the same
  /// local end, with no goodbye sent.
  Future<bool> _takeGoodbye(int userId, {required bool block}) async {
    final link = boxFirstContact;
    if (link == null) return false;
    if (!(link.firstContact.contactOf(userId)?.onBoxRoute ?? false)) {
      // This device holds no route for that account: a goodbye cannot reach
      // it without a queue, so one that did is not from a friend of ours.
      _firstContactLog('BOX_GOODBYE_IGNORED', userId);
      return true;
    }
    await link.endBoxFriendship(userId, block: block);
    // The chat goes, and its history with it, while its row still names the
    // peer: a list refresh first would drop the row and leave the history
    // on disk for a later friendship to show again (review).
    onBoxFriendshipEnded?.call(userId);
    _afterBoxFriendshipEnded(userId);
    return true;
  }

  /// The lists re-read the store; the chat list is left to the removal
  /// above (or the caller's), never refreshed first.
  void _afterBoxFriendshipEnded(int userId) {
    _firstContactLog('BOX_FRIENDSHIP_ENDED', userId);
    _clearCalmHold(userId);
    onBoxContactsChanged?.call();
    notifyListeners();
  }

  // ---------- The end of an account (decision 113, E114h, E114i) ----------

  /// The account is being deleted (`AuthProvider.deleteAccount`'s
  /// `beforeDelete`, which runs once the password is known good): a `goodbye`
  /// goes to every device of every friend the box covers
  /// ([BoxOutbox.coveredPeers]) — its side ends the friendship as for an
  /// unfriend, so nobody keeps writing into queues that are about to die — and
  /// THEN every queue this device holds is deleted from the box
  /// ([BoxFirstContactLink.retireAccountQueues]). Friends are told at the same
  /// time, one friend's devices one after the other.
  ///
  /// The goodbye is [endBoxFriendship]'s own: the friend's copy, no `sentTo`,
  /// quiet so it wakes nobody (decision 91). None of its other steps apply —
  /// our siblings are NOT told (the account is ending, they lose their
  /// session at the delete), no record is removed (the app tears itself down
  /// right after) and nobody has to answer.
  ///
  /// Best effort inside [budget] and it never throws: a box that is down, a
  /// friend that cannot be reached or a build that ignores a goodbye never
  /// hold the delete (E114i). The budget is a real [Timer], cancelled the
  /// moment the work is over — a `Future.any` against a `Future.delayed`
  /// leaves the loser live for the whole budget. When it runs out first this
  /// returns anyway and the work goes on in the background. The durable log
  /// gets `BOX_ACCOUNT_GOODBYE {told, missed, ms}`: the friend devices the
  /// box took a goodbye for, those it did not, and the time spent, as of the
  /// moment this returns.
  Future<void> goodbyeToBoxFriends({
    Duration budget = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    var told = 0;
    var missed = 0;

    Future<void> work() async {
      try {
        final outbox = boxOutbox;
        if (outbox != null) {
          final goodbye = jsonEncode(E2eEnvelope.buildGoodbye());
          Future<void> tell(int userId) async {
            for (final MapEntry(key: device, value: to)
                in outbox.addressesFor(userId).entries) {
              var sent = false;
              try {
                final frame = await encryptForFriend(userId, device, goodbye);
                sent =
                    frame != null &&
                    await outbox.deliver(
                          to,
                          frame.encode(),
                          mode: BoxSendMode.quiet,
                        ) ==
                        BoxSendOutcome.taken;
              } on Object {
                // A device that cannot be told now is a miss, nothing more.
              }
              if (sent) {
                told++;
              } else {
                missed++;
                _firstContactLog('BOX_GOODBYE_NOT_SENT', userId, {
                  'device': device,
                });
              }
            }
          }

          await Future.wait([
            for (final userId in outbox.coveredPeers().toList()) tell(userId),
          ]);
        }
        await boxFirstContact?.retireAccountQueues();
      } on Object catch (e) {
        _e2eFlowLog('BOX_ACCOUNT_GOODBYE_FAILED', {
          'error': e.runtimeType.toString(),
        });
      }
    }

    final over = Completer<void>();
    void finish() {
      if (!over.isCompleted) over.complete();
    }

    final timer = Timer(budget, finish);
    unawaited(work().whenComplete(finish));
    await over.future;
    timer.cancel();
    E2ePersistentDiag.record('BOX_ACCOUNT_GOODBYE', {
      'told': told,
      'missed': missed,
      'ms': watch.elapsedMilliseconds,
    });
  }
}
