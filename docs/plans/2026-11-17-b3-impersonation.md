# B3: can a malicious server impersonate a friend?

Status: investigation + red test; no fix implemented. Date 2026-11-17.
Red test: `frontend/test/services/encryption_b3_impersonation_test.dart` (skipped).

## Verdict

**The decrypt half of the chain holds; the wrap-key half is bounded by one
extra precondition.** A party that holds (a) the user's login password and
(b) the server-side contact-backup row can read the friends' queue addresses
and seal frames to them. The friend's device then accepts a first ("PreKey")
message from an identity key the attacker invented, as the user, with no
identity check, and moves the pinned identity to the attacker's key.

The "server" that does this is the identity service operator (or anyone who
can read the plaintext password at `/auth/login` and the backup row). It
does NOT need to break any cipher.

## The chain, link by link

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | Login sends the raw password | TRUE | `frontend/lib/services/api_service.dart:104-110` (`jsonEncode({'identifier', 'password'})` to `/auth/login`); backend hashes it only after receipt (`backend/src/auth/auth.service.ts:58`, `bcrypt.compare`). The server sees the plaintext on every login. |
| 2 | The password unwraps the contact backup | TRUE | `contact_backup.dart:275-303` `deriveWrapKey`: `passcode: secret` for `ContactWrapKind.password`, PBKDF2-style KDF (`kContactBackupKdfIterations`) over the password and a per-account `salt` the server stores and serves. `contact_backup_service.dart:655-665` tries `(ContactWrapKind.password, password)` at login. The server holds the wrapped row AND the salt, so it can run the same KDF offline with the password it just saw. No second secret is involved (the phrase wrap is a *separate* door, not a requirement). |
| 3 | The backup holds friends' queue addresses | TRUE, with a limit | `contact_record.dart:674-691` `toBackupJson` keeps `outbound` (`peerDeviceId`, `sid`, `sealPub`: `contact_record.dart:156-185`) and drops `queues` (own private halves) and `relays`. `outbound` is exactly what a sender needs to write into the friend's normal queue. |
| 4 | Normal-queue frames skip the identity check | TRUE | `_readBox` (`messaging_provider.box.dart:1086-1111`) goes: live-device check (1066) → `preKeyFromNewIdentity` (only a *decision-88 handoff* trigger, for a not-enrolled friend; it does not refuse anything) → `enc.decrypt`. The request/sibling paths call `enc.carriesOwnIdentity(signal)` first (`carriesOwnIdentity` at `messaging_provider.box.dart:645`; the friend REQUEST-queue path uses `friendFrameIdentity` at `messaging_provider.box.dart:251` (`prekey_identity.dart:124-150`, via `friendFrameIdentityOf`, `encryption_service.dart:2991`) plus the `preKeyWouldReplaceSession` gate at `:265-283`); the normal path has no equivalent against the pinned friend identity. |
| 5 | Signal's own store does not catch it | TRUE | `SecureIdentityKeyStore.isTrustedIdentity` (`signal_stores.dart:615-660`) returns `true` for ANY key ("TOFU always wins"), saves it, and for a changed key only stages a candidate + `onIdentityChanged`. It never refuses. |
| 6 | The acknowledgement moves the pin | TRUE by default | `encryption_service.dart:372-393`: with key-change warnings off (the default since (lxxix), `settings_provider.dart:167` is `false`) `_demoteKeyChangeIfMuted` calls `acknowledgePeerIdentity` at once; the test log shows `PEER_IDENTITY_ACKNOWLEDGED anchorAdvanced: true source: pending_candidate`. The anchor is attacker-owned within the same decrypt. With warnings ON the text is still decrypted and returned; only the pin stays on the real key until a human acts. |

### Extra links (what else the server needs)

1. **The backup row's plaintext requires the password at login time or a
   later offline guess.** A server that only stores bcrypt'd passwords but
   logs/observes plaintext at `/auth/login` has it; a database-only leak does
   not (bcrypt'd password, and the KDF salt alone does not open the wrap).
   So B3 is an *active/malicious operator* attack, not a data-at-rest one.
   (Offline guessing of weak passwords against the stored wrap is a separate
   KDF-cost question.)
2. **The user must have a backup row at all** (`ContactBackup` ready).
   Accounts without one are not exposed through this path.
3. **A live origin device.** `_originDeviceIsLive`
   (`messaging_provider.decrypt.dart:72-100`) refuses a revoked/unlisted
   device. The attacker simply names a live id from the user's public signed
   device list (normally device 1): no bar.
4. **The friend's bundle.** Served by the same server to anyone; the red test
   builds the PreKey message from the real public bundle fields.
5. **Sealing to the queue.** The box is anonymous by design: `/box` takes
   unauthenticated sends to a sid (`box_client`, D1). `QueueSeal` (`queue_seal.dart`)
   is ECIES to `sealPub`, which the backup row supplies; no sender
   authentication exists in the outer layer. So **yes, it can seal**.
   `_ownerOf` (`box_inbox.dart:355-375`) then attributes the frame to the
   record's `userId`, and `frame.senderUserId != null` is refused only for
   normal queues (`box_inbox.dart:177`), which the attacker avoids.
6. **A PreKey message to an established session.** libsignal accepts a new
   PreKey message even when a session exists (it archives the old one); this is
   what lets the attacker supersede the real session rather than needing a
   fresh friend.

### What breaks the chain (none fully)

* The friend's OWN device pins `(peer, device)` identity, but only as an
  alarm, never as a gate (`signal_stores.dart:640-656`).
* `preKeyWouldReplaceSession` guards only the sibling path.
* An enrolled friend (`cachedDeviceList.enrolled == true`) does not take the
  decision-88 re-mint path, but the decrypt still runs.

### What the victim sees

* Default settings (warnings off): **nothing in the timeline of the message
  itself.** `PEER_IDENTITY_CHANGED` + `PEER_IDENTITY_ACKNOWLEDGED` fire and a
  muted key-change note is stored (`_peerKeyChangeNotes`) that
  `chat_detail_screen` shows only "for a change that actually was absorbed";
  it is a quiet note, not a block. The forged text is displayed in the
  user's chat. Safety number changes silently (the anchor moved).
* Warnings on: the actionable key-change pill shows, and sends to the user
  fail closed (anchor not advanced), but the forged message is already
  shown.
* The real user is not informed at all: their own device never sees the
  attacker's frames, only later the friend's replies encrypted to the
  attacker's session (they fail to decrypt, appearing as lost messages).

### Evidence run

`flutter test test/services/encryption_b3_impersonation_test.dart` with the skip removed:
both tests fail today.

* `victim.decrypt(user, forgedPreKey)` returns `'new number, send the code here'`.
* After it, `peerTofuIdentityBase64(user)` equals the attacker's identity key,
  not the real one (`PEER_IDENTITY_CHANGED` then `PEER_IDENTITY_ACKNOWLEDGED
  anchorAdvanced: true`).

Not covered by the test (stated, not hidden): the seal/inbox attribution and
the backup unwrap are shown by code reading, not by execution; a full
end-to-end run needs the box server. The test stands at the `EncryptionService`
layer `_readBox` calls; the missing check lives at or above that layer.


## Bigger finding (P1): the recovery phrase reaches the server in plaintext

B3's chain starts from the login password. The recovery phrase is worse,
because it is the secret that seals the **real identity key**:

* Enrolment: `EncryptionProvider.setRecoveryKey` emits `setRecoveryKey` with
  `'phrase': phrase` next to `backup` (`encryption_provider.dart:3035-3041`);
  the gateway passes `dto.phrase` to `identityResetService.setRecoveryKey`
  (`chat-key-exchange.service.ts:733-738`). The server stores a verifier and
  the phrase-SEALED identity backup (`SealedIdentityBackup`), and sees the
  phrase itself in that call.
* Recovery: `ApiService.recoverPassword` posts `'phrase': phrase` to
  `/auth/recover` (`api_service.dart:124-136`).

An operator that logs either call holds the phrase and the sealed identity
backup, so it can open the backup and rebuild the account's REAL identity key
pair. The attacker then speaks as the user with the genuine identity:
**Option A's identity check does not stop it** (the frame carries the pinned
key). It also opens the contact-backup phrase wrap, so the backup is readable
without the password. For phrase-enrolled users this is account takeover by
the operator, not just B3. (Verified by reading the call sites above; not run.)

## Fix options

A real fix needs two layers: (1) stop the operator forging with the
addresses, (2) keep the secrets that unlock identity and backup away from the
server. A alone does (1) for password-only attackers; only layer (2) covers
the phrase.

### Option A: friend-identity check on normal queues

Pair two gates in `_readBox`, exactly as the friend request-queue path does
(`messaging_provider.box.dart:251-283`):

1. `friendFrameIdentity` against the pinned account anchor: `foreign` is
   refused before Signal sees it. NOTE the `noAnchor` window: with no pin yet
   nothing can be judged (the request path hands off and returns), so a friend
   made over the box has a short unprotected window until its first frame
   pins an identity.
2. The `preKeyWouldReplaceSession` + re-key gate (`:265-283`): a REVOKED
   device of the friend still holds the account identity and the queue sid
   and passes check 1. Without this gate it replaces our session; with it the
   frame is answered by our re-key built from the real bundle (decision 37).

What it does not cover: an attacker holding the real identity (phrase leak
above), and the `noAnchor` window.

* **Wire/migration:** client-only. ≤0.2.88 senders' legitimate frames carry the
  pinned identity and pass; old RECEIVERS stay exposed until they update.
* **Legitimate identity change (decision 88 re-mint of a not-enrolled
  friend):** indistinguishable from the attack by the frame alone. Hold the
  frame and stage the candidate; the human acknowledges. A signed
  old-identity proof in the handoff is an optional later addition; old
  senders cannot supply it and fall back to acknowledge.
* **Effort:** M. **Risk:** medium (a friend locked out after reinstall).
* **OWNER-class (S8):** this partly REVERSES the owner's dropped plan row
  B2 ("a new identity key arriving in a message is accepted silently by
  default", dropped 2026-11-16) and amendment (lxxix) (default
  `keyChangeWarnings=false`, auto-acknowledge): for a normal-queue PreKey
  frame under a changed identity, the message would be held until a human
  acts. Conservative default is to hold; the owner must approve overriding
  the earlier drop (what users see). Also touches plan row B1 (dropped
  blocking warning for verified contacts) in spirit.

### Option W1: phrase-only contact-backup wrap

Drop the `password` wrap kind. **Not** server-blind today: the phrase reaches
the server (finding above), so W1 only helps once Option V (below) lands.
Migration: the server DTO is `@IsIn(['password','phrase'])`
(`backend/src/backup/dto/contact-backup.dto.ts:28`) so a new kind needs a
backend release first; and old clients re-upload ONLY the wraps they parsed
(`contact_backup_service.dart` `_tryWraps`/`addWrap`), so an old client
dropping or rewriting the row silently removes an unknown-kind wrap
(dual-wrap rows get truncated by ≤0.2.88). Effort S-M; UX regression
(restore needs the phrase): OWNER.

### Option W2: separate backup secret (keystore + phrase)

Same DTO/old-client-truncation constraints as W1; keystore-only restore is
lost on a new device. Effort M. OWNER (recovery UX).

### Option W3: password-blind login (OPAQUE)

Server never sees the password; the wrap key derives from the export key.
New endpoints, per-account migration, security review. Effort L. Changes the
approved auth design: OWNER ("changes approved design").

### Option V: client-side verifier for the phrase (needed for layer 2)

Make the phrase never leave the device: derive a verifier/auth key from the
phrase client-side (e.g. Argon2id then a domain-separated hash or a signing
key), send only the verifier at enrolment and a proof (challenge-response,
or the derived auth secret) at `/auth/recover`; the identity-backup seal key
is derived from a DIFFERENT branch of the KDF so the verifier does not open
the blob. Migration: the existing `phrase` verifier rows were computed from
the plaintext phrase; ≤0.2.88 clients keep posting the plaintext, so the
server must accept both until adoption is high, and every ALREADY-leaked
phrase stays compromised: users must re-enrol (rotate the phrase). Effort
M-L, security review required. OWNER (recovery flow, rotation prompt).

### Option S: server-blind recovery (OPAQUE / SVR-style)

Rate-limited secret recovery inside an enclave or an OPAQUE-style PAKE so
even the verifier is not offline-guessable. The Signal-grade endpoint; L-XL.
OWNER; likely a new infra dependency.

## Recommendation

1. **Option V first** (phrase never reaches the server) together with
   **Option A** (identity + re-key gate). V closes the larger finding; A
   closes forging with leaked addresses and also protects against revoked
   friend devices.
2. W1/W2 (backup wrap off the password) only after V, since before it the
   phrase wrap is not server-blind either.
3. W3/S are the long-term roadmap.
4. Until then the exposure is: an operator that logs `/auth/login`,
   `setRecoveryKey` or `/auth/recover` can speak as the user, and for
   phrase-enrolled users hold the real identity.

## Red test placement

The provider-level test is the one that turns green with Option A:
`frontend/test/providers/messaging_provider_box_test.dart`, 'B3: a
normal-queue PreKey frame under an identity other than the friend's pinned one
is neither decrypted nor shown' (skipped, drives `consumeBoxEntry` through
`_readBox` with the real identity store and a real attacker PreKey message;
the Signal decrypt is the file's existing fake, so "not decrypted" is
observable). Unskipped it fails today (the fake decrypt is reached and the
message is shown). `test/services/encryption_b3_impersonation_test.dart` remains the
service-layer demonstration (Signal accepts the frame and moves the pin) and
is not expected to flip with the `_readBox` fix.

Owner questions: (1) may a normal-queue PreKey frame under a changed identity
be held even with key-change warnings off (reverses dropped row B2/(lxxix))?
(2) approve Option V and a phrase re-enrolment prompt for existing users?
(3) is requiring the phrase to restore contacts (W1/W2) acceptable?

**Owner answers 2026-11-20:** (1) yes, hold (decision 143); (2) done as 0.2.90 (B7); (3) no, keep the password wrap (decision 144).
