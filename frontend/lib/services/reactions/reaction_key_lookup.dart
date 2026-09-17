/// The answer to "does this device hold `K_react` for that conversation?".
///
/// Three states, not a nullable key, and the reason is destructive: an absence
/// authorises a participant to re-key the conversation at `epoch + 1`, which
/// permanently orphans every chip already written under the old epoch — for
/// BOTH participants' other devices. So "absent" has to mean PROVEN absent and
/// nothing else.
///
/// The state that forced this shape is the locked passcode vault: on web the
/// content store rethrows `ContentStoreUnavailable(locked: true)` instead of
/// falling back (`frontend/docs/e2e-invariants.md`), and the passcode-lock doc
/// records that locked deliberately outranks the "no keys" probe because
/// conflating absent-with-locked already destroyed data once. A device whose
/// key is sitting in a locked vault must wait, never re-key.
///
/// `sealed` so a fourth state cannot be added without every `switch` over this
/// reporting a compile error — the whole point is that no call site gets to
/// treat an unknown verdict as an absence by default.
sealed class ReactionKeyLookup {
  const ReactionKeyLookup();
}

/// This device holds the key for [epoch].
final class ReactionKeyFound extends ReactionKeyLookup {
  const ReactionKeyFound({required this.epoch, required this.keyB64});

  final int epoch;
  final String keyB64;
}

/// The store answered, and there is no record. The ONLY state that may
/// authorise a re-key.
final class ReactionKeyAbsent extends ReactionKeyLookup {
  const ReactionKeyAbsent();
}

/// The store could not answer, or answered something unusable.
///
/// [reason] is diagnostic only (`locked`, `corrupt`, a store stage, or an
/// exception type). Callers must render the unknown-token placeholder and
/// RETRY later; they must never read this as "no key exists".
final class ReactionKeyUnavailable extends ReactionKeyLookup {
  const ReactionKeyUnavailable(this.reason);

  final String reason;
}
