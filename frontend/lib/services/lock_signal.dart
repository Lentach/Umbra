/// One tab telling the others of the same origin that the user locked the
/// passcode. [web-only: retire with §7]
///
/// The lock revokes keys held in RAM, and RAM is per tab: without a signal a
/// second tab (or an installed PWA beside a browser tab) keeps its keys and
/// its decrypted rows after the first one was locked. The message carries
/// nothing: no secret, no account, no device id. Hearing it means "run your
/// own lock".
abstract interface class LockSignal {
  /// Tells the other tabs. Never reaches the sender itself.
  void announce();

  /// Stops listening and releases the channel.
  void close();
}

/// Opens the signal; [onPeerLocked] runs when ANOTHER tab announced.
typedef LockSignalOpener = LockSignal Function(void Function() onPeerLocked);
