# Vendored `libsignal_protocol_dart`: origin, patches, proof

This directory is Umbra's copy of the MixinNetwork pure-Dart port of the classic
Signal protocol (X3DH + Double Ratchet). `frontend/pubspec.yaml` points at it
through `dependency_overrides`. This file records where it came from, every
line that differs from upstream, and which test proves what.

## 1. Origin

| | |
|---|---|
| Package | `libsignal_protocol_dart` 0.8.2, vendored 2026-09-27; still the latest release on pub.dev on 2026-11-24 |
| Archive | `https://pub.dev/api/archives/libsignal_protocol_dart-0.8.2.tar.gz` |
| Archive SHA-256 | `3ed4455f09c7299934a6b9ca0028daff87940d446142056e1ec25997de0e41bf` (equals `archive_sha256` in the pub.dev API) |
| Upstream repository | `https://github.com/MixinNetwork/libsignal_protocol_dart` |
| Upstream commit | `9f093cfb38cc3bc2397bd4758c05d85e8d2ef4f2` ("bump version to 0.8.2", 2026-06-20). Its `lib/` is identical to the archive's. Upstream has no `v0.8.2` tag; tags stop at `v0.7.3`. |
| Licence | GPL-3.0 (`LICENSE`, unchanged) |

Checked on 2026-11-24 by comparing git blob hashes: of the 98 files taken from
upstream, 95 are byte-identical to the archive. The three that differ are the two
patched files below and `pubspec.yaml`.

To repeat the check: unpack the archive, then for each committed file compare
`git rev-parse HEAD:<path>` with
`git -c core.autocrlf=false hash-object --no-filters <archive file>`.

## 2. What differs from upstream

### 2.1 Not copied

`test/`, `example/`, `protobuf/` (the `.proto` sources), `CHANGELOG.md`,
`analysis_options.yaml`. No file under `lib/` was left out or added.

### 2.2 `pubspec.yaml`

`version: 0.8.2+umbra.1`, `publish_to: none`, and `dev_dependencies` removed
(there is no test directory here). Runtime dependencies are unchanged.

### 2.3 Code patches

Both are marked `UMBRA PATCH (0.8.2+umbra.1)` in the source. Both fix the trial
decrypt in `SessionCipher._decrypt`: a message sealed under an older session
state is read by trying the current state, then each archived one.

| # | File | Upstream | Here | Why |
|---|---|---|---|---|
| 1 | `lib/src/state/session_state.dart`, `SessionState.fromSessionState` | `_sessionStructure = copy.structure;` (shares the protobuf) | a real copy: `SessionStructure.fromBuffer(copy.structure.writeToBuffer())` | The failed try on the current state advanced the real current state's chains, so the next message on it failed `Bad Mac`. |
| 2 | `lib/src/session_cipher.dart`, `SessionCipher._decrypt` | `previousStates.remove(promotedState);` (removes the copy, which was never in the list) | `previousStates.remove(archived);` (removes the archived original) | A stale snapshot of the promoted state, with its message key unused, stayed in the archive. |

**Proof.** `frontend/test/services/encryption/libsignal_trial_decrypt_test.dart`
(one test, one assertion per patch). Checked on 2026-11-24 by undoing each
patch separately: without patch 1 the test fails at the "Patch 1" expectation,
without patch 2 at the "Patch 2" expectation.

Upstream `master` (`9c871c05`, 2026-06-21) still has both original lines.

## 3. Agreement with the reference implementation

`frontend/test/services/encryption/libsignal_known_answer_test.dart` runs this
port against known answers.

**Source of the vectors.** The X3DH and Double Ratchet specifications
(`signal.org/docs/specifications/`) contain no test vectors. Current libsignal
removed the classic protocol in v0.75.0. The vectors are therefore those of the
reference implementation's own unit tests: `signalapp/libsignal-protocol-java`,
commit `fde96d22004f32a391554e4991e4e1f0a14c2d50`, directory
`tests/src/test/java/org/whispersystems/libsignal/`. The hex strings in the
Dart test were compared by script with the byte arrays in the Java files.

| Java test | What it pins | Result |
|---|---|---|
| `kdf/HKDFTest`: `testVectorV3`, `testVectorLongV3`, `testVectorV2` | HKDF output. The first is RFC 5869 test case 1. | equal |
| `ratchet/ChainKeyTest`: V2, V3 | symmetric ratchet step: message key, MAC key, next chain key, counters | equal |
| `ratchet/RatchetingSessionTest`: `testRatchetingSessionAsBob` | session setup from an X3DH key set, receiving side: first chain key | equal |
| `ecc/Curve25519Test`: `testAgreement` | X25519 shared secret | equal |
| `ecc/Curve25519Test`: `testSignature` | signature verification; each of 64 one-bit changes is rejected | equal |
| `ratchet/RootKeyTest`: `testRootKeyDerivationV2` | DH ratchet step: next root key, next chain key | equal **with the reference's agreement plugged in** (below) |
| `ratchet/RatchetingSessionTest`: `testRatchetingSessionAsAlice` | session setup, initiating side: first receiving chain key | equal **with the reference's agreement plugged in** (below) |

### 3.1 One difference: private-key clamping

The last two Java tests use private keys that are not clamped (RFC 7748 §5:
low three bits and the top bit cleared, bit 254 set). The Java vectors equal
X25519 computed with the scalar exactly as given. This port's X25519
(`package:x25519` 0.1.1) clamps the scalar on every call, so with its own
agreement the two tests give other values.

- The known-answer test therefore runs those two cases through
  `Curve.agreementCalculator` with an unclamped ladder, which shows the port's
  key derivation around the agreement matches the reference.
- A third test pins the difference itself: the port's agreement on an
  unclamped key equals the agreement on its clamped form.
- Keys this port generates are clamped at creation (`Curve.generateKeyPair`,
  `generateKeyPairFromPrivate`), and for a clamped key both give the same
  result. `testAgreement` uses clamped keys and matches without help.
- Upstream's own port of `RootKeyTest` has these two assertions commented out
  with a `TODO` (`test/ratchet/root_key_test.dart` in the archive).
- Umbra rebuilds a private key from stored bytes in three places:
  `encryption_service.dart` (`adoptProvisionedIdentity`),
  `device_authority_engine.dart` (`restoreDak`), `queue_seal.dart` (`sealPriv`).
  All three re-load keys this port generated (`sealPriv` is minted by
  `QueueSeal.mintKeyPair` → `Curve.generateKeyPair`); nothing in `frontend/lib`
  sets `Curve.keyPairGenerator`.
- Consequence today: none between Umbra clients, which all run this port. It
  matters for any move to another library: a stored key that is not clamped
  would give different secrets there unless that library also clamps on use.
  Not checked for libsignal.

### 3.2 Not covered

- No known answer for a complete message: the wire format, the AES-CBC
  encryption and the MAC of `SignalMessage` / `PreKeySignalMessage` are covered
  only by round trips inside this port. The reference publishes no such vector.
- Session setup with a one-time pre-key (both Java tests leave it absent).
- The DH ratchet step under the v3 KDF (the Java test uses v2 only).
- Signature creation (the Java test checks verification only; signing is
  randomised).
- Sender keys (groups), fingerprints, device-consistency codes: outside X3DH
  and the Double Ratchet.

## 4. Updating this package

0.8.2 and upstream `master` still carry both bugs. Before dropping the override or taking a new
upstream version: carry both patches, re-run the two tests named above, and
repeat the blob comparison of §1 against the new archive.
