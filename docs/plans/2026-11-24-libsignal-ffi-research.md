# Moving from the Dart Signal port to official libsignal — Research (2026-11-24)

Date: 2026-11-24. Every claim below comes from a primary source that was read on this date.
Each claim has a URL or a local `path:line`. Nothing is written from memory.
Sentences marked **[INFERENCE]** are conclusions drawn from the quoted lines, not quotes.

Sources examined:

- `signalapp/libsignal` at tag **v0.108.6** = commit `08a4b5ade3ed5d5e48ce8d0bc94e7d2041a3a3b1`
  (tagged 2026-11-24). Short form below: `LS/<path>` means
  `https://github.com/signalapp/libsignal/blob/v0.108.6/<path>`.
- `MixinNetwork/libsignal_protocol_dart` at `master` = commit `9c871c05629e60f23fed6e7cec863c8aaff696d9`
  (2026-06-21), version `0.8.2`.
- The vendored tree on disk. Short form: `VND/<path>` means
  `frontend/third_party/libsignal_protocol_dart/<path>`.
- signal.org/docs specifications (PQXDH revision 3; Double Ratchet revision 4, 2025-11-04; ML-KEM Braid revision 1).
- `obfusk/apksigcopier`, `flutter/flutter` issues, GitHub API.

This note gives no legal advice. Licence questions are marked as questions for a lawyer.

---

## 1. Licence of what Umbra ships today

- `VND/LICENSE:1-2` is the text "GNU GENERAL PUBLIC LICENSE / Version 3, 29 June 2007".
  It is byte-identical (ignoring line endings) to the upstream `LICENSE` at
  https://github.com/MixinNetwork/libsignal_protocol_dart/blob/9c871c05629e60f23fed6e7cec863c8aaff696d9/LICENSE.
- "GPL-3.0-only" or "GPL-3.0-or-later": **the package does not say.** `VND/pubspec.yaml` has no
  licence field. No file under `VND/lib` has a licence header (search for "later version", "SPDX",
  "GNU General" found nothing). The upstream README has no licence line. GitHub reports `GPL-3.0`.
  The words "or any later version" appear only inside the licence text itself (`VND/LICENSE:572`, `:639-640`).
- The licence text covers this case (`VND/LICENSE:574-577`): "If the Program does not specify a
  version number of the GNU General Public License, you may choose any version ever published by
  the Free Software Foundation."
- The Umbra repo root has **no** `LICENSE` or `COPYING` file (directory listing of
  `C:/Users/olek2/Desktop/Fireplace`, 2026-11-24).
- What GPLv3 says about a combined work (`VND/LICENSE:222-226`): "You must license the entire work,
  as a whole, under this License to anyone who comes into possession of a copy. This License will
  therefore apply ... to the whole of the work, and all its parts, regardless of how they are packaged."
- What GPLv3 says about combining with AGPL (`VND/LICENSE:552-560`, section 13): "you have
  permission to link or combine any covered work with a work licensed under version 3 of the GNU
  Affero General Public License into a single combined work, and to convey the resulting work. The
  terms of this License will continue to apply to the part which is the covered work, but the special
  requirements of the GNU Affero General Public License, section 13, concerning interaction through
  a network will apply to the combination as such."
- libsignal is `license = "AGPL-3.0-only"` (`LS/Cargo.toml`, `[workspace.package]`). Its section 13
  (`LS/LICENSE#L540-L559`) says a modified version "must prominently offer all users interacting with
  it remotely through a computer network ... an opportunity to receive the Corresponding Source",
  and gives the matching permission to combine with GPLv3 work.
- Two open issues ask Signal for an App Store exception to the AGPL: 
  https://github.com/signalapp/libsignal/issues/677 (5 comments) and
  https://github.com/signalapp/libsignal/issues/684 (2 comments). **No comment in either issue is
  from a Signal maintainer** (all authors have GitHub association `NONE`).

So for Umbra: Umbra already ships GPLv3 code and has no licence file of its own; what that requires, and what AGPL would add (also for iOS), is a question for a lawyer.

## 2. Browser / WASM

- No wasm target exists in the repository. The full file tree at v0.108.6 (2292 paths) has no path
  containing "wasm". The workspace members in `LS/Cargo.toml` are `rust/bridge/ffi`, `rust/bridge/jni`,
  `rust/bridge/node` and others; none is a wasm crate.
- The Node package is a native add-on. `LS/rust/bridge/node/Cargo.toml#L44`:
  `neon = { workspace = true, features = ["napi-6"] }`, with `crate-type = ["cdylib", "lib"]`.
  `LS/node/package.json` ships `"prebuilds/*/*.node"` and depends on `node-gyp-build`.
  There is no `binding.gyp`; the build is `python3 build_node_bridge.py`, which runs
  `cargo build --target <target> -p libsignal-node` (`LS/node/build_node_bridge.py#L177`).
- The loader `LS/node/ts/NativeLoad.ts` handles only `'darwin'`, `'linux'`, `'win32'`
  (`require('@signalapp/libsignal-client-${platform}')`) and otherwise calls `node-gyp-build`. It
  imports `node:module`. There is no browser path.
- CI build targets found: `x86_64-apple-darwin`, `aarch64-pc-windows-msvc` (`LS/.github/workflows/npm.yml#L36-L39`),
  `i686-unknown-linux-gnu`, `aarch64-linux-android,armv7-linux-androideabi`, `aarch64-apple-ios-sim`
  (`LS/.github/workflows/build_and_test.yml#L239`, `#L436`, `#L729`). No `wasm32`.
- Statements by `jrose-signal` (GitHub shows association `CONTRIBUTOR`; the account name and the
  answers show a Signal employee):
  - 2025-10-20: "We don't offer a wasm build, and we don't use Kyber768 for our flavor of PQXDH."
    https://github.com/signalapp/libsignal/issues/634#issuecomment-3422994240
  - 2023-12-07, on plain JS in a web client: "You can try, but it's not a supported configuration.
    In particular, you'll have to write your own bridging layer that uses Wasm bindings instead of Neon."
    https://github.com/signalapp/libsignal/issues/542#issuecomment-1845926376
  - 2021-09-01: "I think supporting a full wasm bridge would qualify as too much of a maintenance
    burden to land in the main repository." He suggests instead: "Writing a manual wasm-friendly Rust
    wrapper library for the operations you care about, depending again on libsignal-protocol rather
    than libsignal-bridge." https://github.com/signalapp/libsignal/issues/350#issuecomment-910632258
  - 2024-09-04: approaches that reuse the bridge or the C API "are much more difficult now that we
    have `boring` as a dependency, and possibly other C libraries in the indirect dependency tree
    that won't just accept a wasm target. (1) and (2) are still plausible."
    https://github.com/signalapp/libsignal/issues/350#issuecomment-2329577894

So for Umbra: official libsignal cannot run in the browser as shipped; a web client needs either a self-made wasm wrapper around the Rust `libsignal-protocol` crate (unsupported) or a different library.

## 3. Dart

- There is no Dart or Flutter binding in the repository. The tree at v0.108.6 has no `.dart` file,
  no `pubspec.yaml`, and no path containing "flutter".
- Maintainer answer to "Do you plan to add dart language support?" (2021-05-10): "No current plans.
  The supported languages are those used by Signal's official client apps, so it's unlikely we'll
  add any more in the repository itself unless those apps start using a new language."
  https://github.com/signalapp/libsignal/issues/294#issuecomment-836961324
- A C header exists: `LS/swift/Sources/SignalFfi/signal_ffi.h` (8162 lines). Line 3 says
  "AUTOGENERATED! Do not modify!". It declares for example `signal_pre_key_bundle_new` (L6575)
  and `signal_process_prekey_bundle` (L6717). The Rust side is the crate `rust/bridge/ffi`.
- Stability, `LS/README.md#L19-L25`: "Use outside of Signal is unsupported. In particular, the
  products of this repository are the Java, Swift, and TypeScript libraries that wrap the underlying
  Rust implementations. All APIs and implementations are subject to change without notice, as are
  the JNI, C, and Node add-on "bridge" layers. However, backwards-incompatible changes to the Java,
  Swift, TypeScript, and non-bridge Rust APIs will be reflected in the version number on a
  best-effort basis".
- On the C API (issue #350 comment above): "we don't treat the C API as a product, just a means to
  an end for the Swift API, and so there's been no effort put into making it a proper friendly abstraction."
- A user comment in issue #684 mentions third-party `libsignal_dart` bindings. This note did not
  examine that project.

So for Umbra: a Dart FFI binding to `signal_ffi.h` is possible but Umbra would own it, and the C layer can change in any release without a version signal.

## 4. PQXDH in libsignal today

- A Kyber pre-key is **required** to build a session. `PreKeyBundle::new` takes
  `kyber_pre_key_id: KyberPreKeyId, kyber_pre_key_public: kem::PublicKey, kyber_pre_key_signature: Vec<u8>`
  as plain (not `Option`) arguments (`LS/rust/protocol/src/state/bundle.rs#L137-L146`), and the
  builder fails with "kyber_pre_key_id is required" (`#L106-L114`).
- Incoming X3DH PreKey messages are **rejected**. `LS/rust/protocol/src/session.rs#L136-L143`:
  `if message.message_version() == CIPHERTEXT_MESSAGE_PRE_KYBER_VERSION { ... return Err(SignalProtocolError::InvalidMessage(CiphertextMessageType::PreKey, "X3DH no longer supported".to_owned())); }`.
  The constants are `CIPHERTEXT_MESSAGE_CURRENT_VERSION: u8 = 4` and
  `CIPHERTEXT_MESSAGE_PRE_KYBER_VERSION: u8 = 3` (`LS/rust/protocol/src/protocol.rs#L19-L21`).
  A version-4 PreKey message without Kyber data fails with "Kyber pre key must be present for this
  session version" (`protocol.rs#L481-L486`).
- When it was dropped (release notes text read from `RELEASE_NOTES.md` at each commit):
  - **v0.73.0** (released 2025-05-20), commit
    https://github.com/signalapp/libsignal/commit/0e1ec3909b66dac768a47a7ae270bc6c5fb3d549 :
    "Support for starting sessions with pre-quantum X3DH has been removed from Swift, Java, and
    TypeScript. PQXDH will be required going forward."
  - **v0.75.0** (released 2025-06-16), commits
    https://github.com/signalapp/libsignal/commit/69bb363840a3355b0d47027e99e7b317ec362bf9 and
    https://github.com/signalapp/libsignal/commit/2879220e93197adbfbf04d19c788b2bdea15d92a :
    "X3DH handling has been removed from libsignal; X3DH PreKey messages will now be rejected as invalid."
- Which KEM: `LS/rust/protocol/src/kem.rs#L201-L219`. `Kyber1024` (type byte `0x08`) is always
  compiled in. `MLKEM1024` (`0x0A`) is behind `#[cfg(feature = "mlkem1024")]`. That feature is
  declared `mlkem1024 = []` and is not a default feature (`LS/rust/protocol/Cargo.toml#L56`).
  A GitHub code search for "mlkem1024" in `Cargo.toml` files finds only `rust/protocol` and
  `rust/attest`, so no bridge crate turns it on. **[INFERENCE]** The shipped Java/Swift/Node builds
  use Kyber1024 pre-keys, not ML-KEM-1024.
- The PQXDH spec names the example parameter "pqkem as CRYSTALS-KYBER-1024"
  (https://signal.org/docs/specifications/pqxdh/ , Revision 3, last updated 2024-01-23).
- The vendored Dart port has no KEM: a search for "kyber", "pqxdh", "kem" in `VND/lib/**/*.dart`
  finds no file. Its message version is `currentVersion = 3`
  (`VND/lib/src/protocol/ciphertext_message.dart:4`).

So for Umbra: a native client on libsignal v0.75.0 or later cannot start a session with, or accept a first message from, a web client on the Dart port; both platforms must change together.

## 5. Post-quantum ratchet (SPQR, "Triple Ratchet")

- libsignal ships it. `LS/Cargo.toml#L110`:
  `spqr = { git = "https://github.com/signalapp/SparsePostQuantumRatchet.git", tag = "v1.7.0" }`.
  `LS/rust/protocol/src/triple_ratchet.rs#L6`: "The Triple Ratchet: Double Ratchet + SPQR combined into a single ...".
- Since when: **v0.74.0** (released 2025-06-04), "Integrate post-quantum ratchet in opt-in mode."
  https://github.com/signalapp/libsignal/commit/b7b8040e3a19830d558000792fdf85126a3a9f14
- Mandatory for new sessions since **v0.92.0** (released 2026-04-08): "Force use of SPQR v1 for all
  newly initiated sessions." https://github.com/signalapp/libsignal/commit/cf9a7445c6e801e25b7d85ed41967133a089f4a3 .
  In source: `min_version: spqr::Version::V1, // Require that all clients speak SPQR`
  (`LS/rust/protocol/src/ratchet.rs#L87`, same at `#L150`).
- Wire format changed. `SignalMessage` has a new field `optional bytes pq_ratchet = 5;`
  (`LS/rust/protocol/src/proto/wire.proto#L15`). The session record has `bytes pq_ratchet_state = 15;`
  (`LS/rust/protocol/src/proto/storage.proto#L66`).
- Spec: "The Double Ratchet Algorithm", Revision 4, 2025-11-04,
  https://signal.org/docs/specifications/doubleratchet/ . Section 5 is "The Sparse Post-Quantum
  Ratchet". Section 6 is "The Triple Ratchet: combining Secure Messaging protocols for hybrid
  security" and says: "Triple Ratchet messages use a composite header containing: ec_header:
  Standard Double Ratchet header (dh, pn, n); scka_header: SCKA message data and metadata (msg, n)".
  The key-agreement part is specified in https://signal.org/docs/specifications/mlkembraid/
  (Revision 1, last updated 2025-09-26).

So for Umbra: "moving to libsignal" today means moving to PQXDH plus the Triple Ratchet; there is no setting in v0.108.6 to start a classic Double Ratchet session.

## 6. Wire and record compatibility with the Dart port

Port side: generated files `VND/lib/src/state/whisper_text_protocol.pb.dart` and
`local_storage_protocol.pb.dart` (line numbers below). libsignal side: `wire.proto` and `storage.proto` at v0.108.6.

| Message | Port fields (number: name) | libsignal difference |
|---|---|---|
| `SignalMessage` | 1 ratchetKey, 2 counter, 3 previousCounter, 4 ciphertext (`:48-68`) | same 1-4; **added** 5 `pq_ratchet`, 6 `addresses` (`wire.proto#L10-L17`) |
| `PreKeySignalMessage` | 1 preKeyId, 2 baseKey, 3 identityKey, 4 message, 5 registrationId, 6 signedPreKeyId (`:210-244`) | same 1-6; **added** 7 `kyber_pre_key_id`, 8 `kyber_ciphertext` (`wire.proto#L19-L28`) |
| `SessionStructure` | 1 sessionVersion, 2 localIdentityPublic, 3 remoteIdentityPublic, 4 rootKey, 5 previousCounter, 6 senderChain, 7 receiverChains, 8 pendingKeyExchange, 9 pendingPreKey, 10 remoteRegistrationId, 11 localRegistrationId, 12 needsRefresh, 13 aliceBaseKey (`:877-961`) | same 1-7, 9-11, 13; **removed** 8 (not declared) and 12 (`reserved 12; // no longer used`); **added** 14 `pending_kyber_pre_key`, 15 `pq_ratchet_state`, 16 `origin` (`storage.proto#L47-L77`) |
| `Chain.MessageKey` | 1 index, 2 cipherKey, 3 macKey, 4 iv (`:159-179`) | same 1-4; **added** 5 `seed` (`storage.proto#L22-L30`) |
| `PendingPreKey` | 1 preKeyId, 2 baseKey, 3 signedPreKeyId (`:702-716`) | same 1-3; **added** 4 `timestamp` (`storage.proto#L35-L40`) |
| `RecordStructure` | 1 currentSession, 2 previousSessions as repeated `SessionStructure` (`:1212-1219`) | 1 same; 2 is `repeated bytes` holding a serialized `SessionStructure`; **added** 3 `tahini` (`storage.proto#L95-L105`) |

No field was renumbered. Other differences: the port still has `KeyExchangeMessage`
(`whisper_text_protocol.pb.dart:365`), which libsignal's `wire.proto` does not have. `SenderKeyMessage`
field 1 is `id` (uint32) in the port (`:584`) and `distribution_uuid` (bytes) in libsignal
(`wire.proto#L31`); this matters only for group sender keys.

- (a) On the wire, classic X3DH + Double Ratchet: **no, and section 4 settles it regardless of the
  field tables.** libsignal rejects a version-3 PreKey message ("X3DH no longer supported") and
  cannot build a session from a bundle without a Kyber pre-key. The port only speaks version 3.
- (b) Loading a port-written session record: the field numbers overlap, so the definitions alone
  do not forbid parsing **[INFERENCE]**. But such a record has `session_version = 3` and an empty
  `pq_ratchet_state`. libsignal has checks for exactly this: a session "established with X3DH"
  fails `EstablishedWithPqxdh`, and an empty `pq_ratchet_state` fails `Spqr`
  (`LS/rust/protocol/src/state/session.rs#L122-L134`, `#L303-L312`). Whether the callers always
  request those checks was not traced; see NOT SETTLED.

So for Umbra: plan for fresh sessions on every device after the switch; do not plan to migrate stored session records.

## 7. What the Dart port lacks versus libsignal

- libsignal crypto dependencies: `curve25519-dalek = "5.0"`, `x25519-dalek = "3.0"`, `subtle = "2.6"`,
  `libcrux-ml-kem = "0.0.10"` (`LS/Cargo.toml#L146`, `#L255`, `#L230`, `#L176`), used by
  `LS/rust/core/Cargo.toml#L20-L29` and `LS/rust/protocol/Cargo.toml#L38-L46`. Other parts of the
  workspace use Signal's BoringSSL fork (`LS/Cargo.toml#L109`).
- Constant-time code that is visible in libsignal source: MAC check `our_mac.ct_eq(their_mac)`
  (`LS/rust/protocol/src/protocol.rs#L172`); KEM key compare "A constant-time comparison as long as
  the two keys have a matching type." (`LS/rust/protocol/src/kem.rs#L403-L412`). The libsignal
  README makes no general constant-time claim (no match for "constant" in `LS/README.md`).
- Port dependencies (`VND/pubspec.yaml`): `x25519: ^0.1.1`, `ed25519_edwards: ^0.3.1`,
  `pointycastle: ^4.0.0`, `crypto: ^3.0.6`, `adaptive_number`, `protobuf`. These are pure Dart packages.
- The port's MAC check is `if (Digest(ourMac) != Digest(theirMac))`
  (`VND/lib/src/protocol/signal_message.dart:117`). `package:crypto` 3.0.7 documents that
  comparison: "This should be used instead of manual comparisons to avoid leaking information via
  timing." (pub cache `crypto-3.0.7/lib/src/digest.dart:14-19`). So this one check is not a gap.
- The READMEs of `x25519` 0.1.1 and `ed25519_edwards` 0.3.1 (pub cache) contain none of the words
  "audit", "constant", "timing", "secur". They make no constant-time claim.
- The port has no KEM, no PQXDH and no post-quantum ratchet (section 4 search; `currentVersion = 3`).
- Audits. **Nothing is stated in either repository.**
  - libsignal: no match for "audit" in `README.md`, `SECURITY.md`, `RELEASE.md`. The only tree path
    containing "audit" is `.cargo/audit.toml` (configuration for a dependency checker). `LS/SECURITY.md`
    only gives the address security@signal.org.
  - Dart port: no match for "audit" or "secur" in the upstream README or in `VND/README.md`.
    The upstream tree has no `SECURITY.md`.
  - The SPQR repository README has a section titled "Formal Verification"
    (https://github.com/signalapp/SparsePostQuantumRatchet/blob/v1.7.0/README.md). That is not an audit claim.

So for Umbra: the facts that can be cited are "post-quantum protocol and maintained Rust crypto crates versus a pure-Dart classic port"; "audited" cannot be cited for either side from these repositories.

## 8. Reproducible-build tooling

- `apksigcopier` does what the report says. README
  (https://github.com/obfusk/apksigcopier/blob/master/README.md): it "enables using an android APK
  signature as a build input (by copying it from a signed APK to an unsigned one) ... It can also be
  used to verify that two APKs with different signatures are otherwise identical." Operations:
  "copy", "extract", "patch", "compare". Example: `apksigcopier compare --unsigned foo.apk foo-unsigned.apk`.
  "The `compare` command also requires `apksigner`."
- Maintenance: the repository is **archived** (`archived: true` from
  `gh api repos/obfusk/apksigcopier`). Last commit 2024-10-15
  (https://github.com/obfusk/apksigcopier/commit/3546ac613de67d8328eb8ee73d09d00636e71845, "setup.py:
  support py 3.13"). Last push 2025-01-11. Latest release v1.1.1, 2023-02-08. The README contains
  no deprecation notice and names no successor.
- Flutter: the Android deployment page and the obfuscation page on docs.flutter.dev (sources
  `flutter/website` `sites/docs/src/content/deployment/android.md` and `obfuscate.md`, branch `main`)
  contain neither "reproducib" nor "deterministic". Open issues exist without any comment from a
  Flutter member: "Flutter apks have embeded paths which makes it hard to be reproducible"
  (https://github.com/flutter/flutter/issues/140558, open, P3) and "Encourage reproducible builds"
  (https://github.com/flutter/flutter/issues/17464, open since 2018, P2).

So for Umbra: `apksigcopier compare` is the right kind of tool but it is archived and unmaintained, and Flutter gives no promise that two APK builds are identical; the report should say both.

## NOT SETTLED

- **GPL-3.0-only or GPL-3.0-or-later** for the Dart port. The package states no version choice
  (section 1). Looked at: `VND/LICENSE`, `VND/pubspec.yaml`, all of `VND/lib`, upstream README and LICENSE.
- **Any licence conclusion** (GPLv3 app + AGPL libsignal, app stores, the web client served from
  Umbra's server). Only the licence texts are quoted. Signal has not answered issues #677 and #684.
- **Can libsignal still use an already-stored version-3 session?** The rejection in section 4 is
  for PreKey messages (new sessions). `session_management.rs#L807-L808` only checks that message and
  session versions match. The callers of the usability flags were not traced.
- **Does `libsignal-protocol` compile to `wasm32` today?** The maintainer said in 2021 "it probably
  nearly works already" and in 2024 that options (1) and (2) "are still plausible". No CI job tests
  it. Not tried here (no builds).
- **Is `jrose-signal` formally a maintainer?** GitHub reports association `CONTRIBUTOR`, not `MEMBER`.
- **Which KEM the Signal apps upload as pre-keys in production.** Only the library default
  (Kyber1024) is shown. The ML-KEM variant used inside SPQR was not read.
- **Third-party audits** of either library that are published outside the two repositories. Not
  searched (out of scope: primary repositories only).
- **A maintained successor to `apksigcopier`**, and any official Flutter statement on reproducible
  Android builds. None found in the sources above.
