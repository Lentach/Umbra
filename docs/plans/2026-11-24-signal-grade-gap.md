# What still separates Umbra from Signal-grade

**Date:** 2026-11-24 · **Status:** report for the owner, no code. Phase 3 of `2026-11-23-cleanup-program.md`. · **Measured against:** master `32dc6cf0` (prod 0.2.100), before batch 5 merged; batch 5 changed tests, docs and CI only.

`✔` = checked against code or a command on the date above. `[INFERENCE]` = reasoned, not run. Facts about Signal's own libraries are marked `[R§n]`: they come from primary sources (the `signalapp/libsignal` repository at tag `v0.108.6`, signal.org specifications) read on 2026-11-24 and quoted with links in `2026-11-24-libsignal-ffi-research.md`, section n. Nothing here is legal advice; the licence points are questions for a lawyer.

## 0. Summary

Umbra's message content is end-to-end encrypted with the Signal protocol (X3DH + Double Ratchet), and its metadata posture (anonymous box queues) is in one respect stronger than a plain Signal-protocol app. What separates it from "Signal-grade" is not one missing feature. It is five things, in order of how much they matter:

1. **Nobody outside has checked it.** The crypto library is an unaudited port, the app code around it is ~31 000 lines, and there is no single document an auditor could start from (§5).
2. **A user cannot detect a substituted key.** Verification and key-change warnings were dropped by the owner (B1, B2). This is a product decision, but it is the largest gap to Signal's actual security guarantee, so it is restated here (§2.1).
3. **A user cannot check that the app they run is the code in the repo.** No reproducible build, and the web client is served fresh by the server on every load (§4).
4. **No post-quantum protection** (B6, §1).
5. **A short list of known residual weaknesses** that are written down but not closed (§2).

Section 6 lists the decisions only the owner can make.

## 1. B6: official libsignal through FFI, and PQXDH

### 1.1 What runs today ✔

- `libsignal_protocol_dart` `0.8.2+umbra.1`, the MixinNetwork pure-Dart port, vendored in `frontend/third_party/` with two local patches (`session_state.dart:30` deep copy of session state; `session_cipher.dart:178`). There is no PATCHES file; the patches are documented only by their in-code markers and decision row `metadata-privacy-decisions.md:271`.
- About 4 100 lines of hand-written Dart (generated protobuf excluded). Its primitives come from `pointycastle`, `x25519`, `ed25519_edwards`: pure Dart packages whose READMEs make no constant-time or audit claim `[R§7]`.
- Used: X3DH, Double Ratchet, XEdDSA signatures. Not used: sender keys (no groups), sealed sender (the box replaces it), the library's fingerprint module (no match in `frontend/lib`).
- The same Dart code runs on Android and on web. Only storage differs (SQLCipher on native, AES-GCM-sealed IndexedDB/localStorage on web).
- No post-quantum code anywhere.

### 1.2 What "official libsignal" means

- `libsignal` is a Rust library whose products are Java, Swift and TypeScript (Node) libraries. Its README says: "Use outside of Signal is unsupported", and that the JNI, C and Node bridge layers can change without notice `[R§3]`.
- **No Dart binding** exists. A C header (`signal_ffi.h`) exists, with that same no-stability warning `[R§3]`.
- **No browser build.** The repository has no wasm target; the npm package is a native Node addon; a Signal engineer wrote in 2025: "We don't offer a wasm build" `[R§2]`. Whether the protocol crate *could* be compiled to wasm is not settled; nobody tests it.
- **It no longer speaks the protocol Umbra uses.** Classic X3DH was removed in v0.75.0 (2025-06-16): a session needs a Kyber pre-key, and an incoming classic first message is rejected with "X3DH no longer supported" `[R§4]`. The post-quantum ratchet (SPQR, "Triple Ratchet") is mandatory for new sessions since v0.92.0 (2026-04-08) and adds fields to every message `[R§5]`. Our Dart port speaks only the classic version (message version 3).
- **Licence.** libsignal is `AGPL-3.0-only`. The Dart port Umbra vendors **today** is GPL-3.0 (its `LICENSE` is the GPLv3 text; the package does not say "only" or "or later") `[R§1]`. Umbra's public repo has **no LICENSE file** ✔. So the licence question is already open now, before any move (§6, Q5).
- **Audits.** Neither the libsignal repository nor the Dart port's states that it was audited `[R§7]`. The honest comparison is "a maintained Rust implementation used by Signal's own apps, with post-quantum protection" against "a pure-Dart classic port with two local patches", not "audited" against "unaudited".

### 1.3 What the move costs

| Piece | Work | Risk |
|---|---|---|
| Binding | Dart FFI over the Rust library for Android (and iOS later): build Rust for 4 ABIs, 16 KB page alignment (the gate `build-android.ps1` already enforces), write and maintain the Dart wrapper. Either through the official Java binding via a platform channel, or direct `dart:ffi` to the C ABI. | Medium. We would own a binding nobody else maintains. |
| Stores | libsignal calls back into session / pre-key / identity stores. Ours sit behind `ContentKv` and are async; the callback contract must be matched. | Medium. |
| Server | PQXDH needs Kyber pre-keys: one signed last-resort key plus one-time keys per device. New columns, new upload/fetch fields in `key-bundles`, new wire fields (`docs/contracts/wire.md`), a migration, and the one-time pre-key accounting that ENC-21 and B5 just fixed has to be repeated for the Kyber set. | Medium. This is a wire change with a shim window. |
| Existing sessions | Do not plan to migrate them. A record written by the port is a version-3 session with no post-quantum ratchet state, and libsignal has checks that fail exactly that `[R§6]`. Plan: every pair of devices starts a fresh session after the switch. The re-key path exists (decision 37), but E143g (§2.2) is the gate that judges such re-keys on normal queues, so E143g has to be designed first. | High. Prototype this first. |
| Our two patches | Both fix behaviour of the Dart port. They disappear with it; the bug they fixed ("Bad Mac" after a failed trial decrypt) must be re-tested against libsignal. | Low. |

### 1.4 The web client cannot follow, and cannot stay behind either

A browser cannot load an FFI library. And because libsignal rejects the classic protocol (§1.2), **a native client that uses only libsignal cannot exchange a first message with a web client on the Dart port** `[R§4]`. "Native moves, web stays on the old library" does not work by itself. That leaves:

- **W-a. Retire the PWA first, then do B6.** Already the direction (hardening plan §7; decisions 105, 110). Blocked by iOS: with no Apple Developer enrolment, iPhone users have only the PWA. Last count in the repo (2026-10-21): 23 of 24 accounts held a Web Push subscription, 2 an FCM token. Not re-measured.
- **W-b. Native carries both libraries.** libsignal for native-to-native pairs, the Dart port kept inside the native app for any pair that includes a web device. Possible, but it is the worst of both: the old port stays in the audit scope, a second code path decides per peer device which protocol to use (a downgrade point an active server could push on), and a conversation is post-quantum only if no web device is in it.
- **W-c. Compile libsignal to wasm for web and switch both platforms on the same day.** Not offered by Signal and not tested by them `[R§2]`; we would maintain an unsupported build of a crypto library, and it would still be served by our own server (§4.3).
- **W-d. Do not adopt libsignal; add post-quantum protection to the Dart port ourselves.** Keeps web and native on one code base. It means writing new cryptographic protocol code (a KEM handshake) in an unaudited library: the opposite of what B6 is for. Listed only so that it is not rediscovered later.

**Recommendation:** W-a. Do not start B6 while the PWA is a client. If iOS stays on hold for long, B6 stays on hold with it; the useful work in the meantime is §1.5 and §3–§5.

### 1.5 A cheaper first step

B6 is months. Two things give most of the audit value sooner and are not thrown away by B6:
- write `third_party/libsignal_protocol_dart/PATCHES.md` (what was changed, why, the test that proves each patch), and pin the upstream commit the vendored tree came from;
- add known-answer tests that run the port against published test vectors for X3DH and the Double Ratchet (the classic protocol is gone from current libsignal `[R§4]`, so the vectors must come from the specifications or from a libsignal tag before v0.75.0; finding them is the first task). Today nothing proves the port agrees with the reference; they are also the only way to show an auditor that the port implements the classic protocol correctly. (They are not an acceptance test for B6: libsignal no longer speaks the classic protocol.)

## 2. Remaining hardening items

Status of `2026-11-16-security-hardening.md`, re-checked today. That file's rows said "unmerged" for B5, D3, D4, E4 and "unreleased" for C1 although all five shipped in 0.2.89 (release commit `b3e0aaba`), B7 in 0.2.90 and B3 in 0.2.91 ✔ (`gh pr view`, `git log`); the rows were corrected together with this report.

### 2.1 Dropped by the owner: the gap that matters most

- **B1** (safety numbers / QR / a lasting "verified" mark) and **B2** (blocking warning on a changed key) were dropped on 2026-11-16. Today a friend's key change shows one muted timeline line by default.
- What this means in Signal's terms: the protocol protects against a server that only *reads*. Against a server that *acts* (hands out a wrong key bundle at first contact), protection exists only for a user who compares raw hex by hand. Signal's answer to an active server is the safety number a user can compare; libsignal also carries a key-transparency module (`rust/keytrans` in the repository ✔), which this report did not study.
- B3 (0.2.91) closed the worst form of this for *existing* friends: a frame under a non-pinned identity is held until accepted. It does not cover first contact (`noAnchor`: the first frame pins).
- This is not a request to reopen the decision. It is the item an external auditor will name first, so the report says so.

### 2.2 Open, with a known shape

| Item | What is open | Size |
|---|---|---|
| **E143g** | The decision-37 re-key gate is built for sibling and request queues, **not for friends' normal queues**. A *revoked* device of a friend still holds the account identity key, passes the B3 identity gate, and can replace our session. Needs an `awaitingFriendRekeyFrom` window plus the live device-list check, and its own crossing test, because it changes who may replace a session on every normal frame (`metadata-privacy-decisions.md:359`). No test pins it. | Medium, risky |
| **B3 has one layer** | The B3 hold lives only in the provider (`_readBox` → `holdForeignFrame`). The service layer below it does not refuse a first message under a foreign identity from a pinned friend: `isTrustedIdentity` accepts and stages the key, and with key-change warnings off (the default, B2) `_demoteKeyChangeIfMuted` then moves the pin, unless the provider marked the peer as held ✔ (`encryption_service.dart:380-385`, `:593-608`). Any future caller of `EncryptionService.decrypt` that does not pass through the provider gate would accept an impersonator silently. Found in the batch 5 review: the two skipped tests deleted there (EC-9) demonstrated exactly this, and no remaining test pins it. Fix shape: refuse at the service layer too, or a test that fails when a new decrypt caller bypasses the gate. | Small–medium, in the encryption layer |
| **B7 tail** | New phrases never reach the server (0.2.90). The server still accepts a plaintext `phrase` for legacy rows (`chat-key-exchange.service.ts:723`); 7 prod rows were on `phrase_v1` at deploy. Those users stay exposed to an operator who logged the phrase until they re-enrol. Needs: a count today, a prompt to re-enrol, then removal of the legacy branch. | Small |
| **Contact-backup wrap** | The contact backup is wrapped by a key derived from the login password, and login sends that password to the server. A malicious operator can unwrap it and learn queue addresses (W1/W2 declined, decision 144). Stated openly in `docs/METADATA.md:65`. The real fix is a password-blind login (OPAQUE). | Large |
| **D2 tail** | O7 (friend lane) accepted but not built; O6 (blind admission tokens) deferred (decision 145). Until then an attacker with many IPs can still crowd the stranger lane. The alarm and purge exist. | Medium |
| **E1** | Both friends restoring onto new storage lose each other's messages while showing ✓ (decision 124). | Unknown |
| **E2** | A newly linked device sometimes cannot send until every sibling swapped queues; cause not found. | Unknown |
| **E3** | Android shows a message 7–15 s after resume from a 60 s background. | Unknown |
| **E5 tail** | #176 and #178 untriaged. | Small |
| **A3 on iOS** | The iOS opener still falls back to plaintext prefs. Must be fixed before any iOS build ships. | Small, gated on iOS |

### 2.3 Web-only (retire with the PWA)

C4 (link previews through our server with the user's JWT), D7 (CSP is report-only, `security-headers.conf:138`), the C3 tail (CanvasKit fetches fonts from gstatic on every load), B4 on web (refresh tokens do not rotate), web key storage (keys sealed in the origin's own IndexedDB; XSS is out of scope of that design, `web-sig-sealing.md:342`).

### 2.4 Found during this program, still open

`chat-search.service.ts:17-34` duplicate socket-data helpers; UI-23; WEB-16 (unexplained composer state, not reproduced); the 6th account delete per hour per IP fails silently; `messaging_provider.box.dart` is 2 890 lines; `encryption_service.dart` (5 768) and `encryption_provider.dart` (4 052) were out of scope by design. From the batch 5 review: five IPv6 entries in the link-preview `blocked` test list pass even with the URL guard off (the URL regex in `fetchPreview` stops at `[`, so an IPv6-literal URL never reaches the guard: nothing is fetched, and nothing is tested); the `frontend-composer-media` agent rule has two triggers that match no file; seven `expect(emitted, isNot(contains('sendMessage')))` lines in the send test can no longer fail.

## 3. Threat model and invariants

### 3.1 What exists ✔

There is no system-wide threat model. There are five partial ones:
- `docs/design/multi-device.md` §2: actors P (password thief), S (malicious server), L (linked device), Pr (primary); invariants I1–I6+, each with a red-first test. Scoped to multi-device. The file is 3 252 lines.
- `docs/METADATA.md`: what the server sees, honestly listed.
- `docs/proof/e2e-encryption-proof.md` (2026-09-14): claimed / not claimed, with commands. **It predates the box**: its "the server knows who talks to whom" paragraph describes the old path and now understates the product.
- `docs/design/web-sig-sealing.md`, `docs/plans/2026-11-17-d2-box-flood.md`: their own scoped models.
- No `SECURITY.md`, no disclosure address.

### 3.2 Proposed threat model (one page, to be written as `docs/security/threat-model.md`)

| Adversary | Can | Umbra's answer today | Gap |
|---|---|---|---|
| Network observer | See traffic to the server | TLS | Traffic analysis; no padding of timing |
| DB / backup thief | Read every stored row | Ciphertext only; box rows name no account; backups hold no box content (decision 147) | Password hashes (Argon2id), the password-wrapped contact backup |
| Honest-but-curious operator | Read DB, logs, memory | As above; no user ids in logs (CI-gated); box code cannot import account code (CI-gated) | IP ↔ queue correlation at the socket; login password is seen in clear |
| **Malicious operator (active)** | Serve wrong key bundles, wrong device lists, replay, drop, **serve a modified web app** | DAK-signed device lists; B3 hold on changed identity; decision-37 gate on sibling/request queues | First contact (no verification, §2.1); E143g; the web client (§4.3); contact-backup unwrap |
| Password thief | Log in | Linking needs possession + SAS (I3); reset is slow and loud (I4) | Reads the contact backup |
| Revoked device | Still holds the account identity key | Stops receiving at revocation (I6); gate on sibling/request queues | **E143g** on normal queues |
| Device thief (unlocked / rooted) | Read local storage | SQLCipher, sealed caches, passcode | Out of scope beyond the passcode; state it |
| Quantum adversary recording today | Open handshakes later | None | B6 |

### 3.3 Invariants list (to live next to the threat model; each row needs a named test or gate)

1. The server never holds a private key (multi-device I1).
2. Every device-list mutation is signed by the DAK, which exists only on the primary (I2).
3. Linking requires possession: QR + SAS + explicit approve (I3).
4. A box queue row names no account, device, sender or peer; a send is unsigned (`METADATA.md:8`).
5. Nothing under `backend/src/box` reaches `auth/`, `users/` or `chat/` (CI `verify-box-imports.mjs`).
6. No backend log line carries a user identifier (CI `verify-no-user-logs.mjs`).
7. A box send never fetches a pre-key bundle (E38b).
8. A friend's normal-queue PreKey frame under a non-pinned identity is held, never decrypted (decision 143).
9. A PreKey message that would replace a session is read only if this device asked for the re-key: siblings and request queues only (decision 37). **Not yet an invariant for normal queues (E143g).**
10. All content at rest goes through `ContentKv`; Android never falls back to plaintext (A3).
11. A one-time pre-key is served at most once and a re-upload never resets `used` (ENC-21, 0.2.98).
12. The recovery phrase never leaves the device (B7; legacy rows excepted).
13. Attachments carry no EXIF and their true length is inside the ciphertext (A1, A2).
14. The receiver of a message never makes a network request chosen by the sender (C1).

Today rows 5 and 6 are machine-enforced; most others are held by tests scattered over ~60 files. The work is a table mapping each invariant to its test, and a CI check that the named tests exist.

## 4. Reproducible builds and supply chain

### 4.1 What is pinned ✔
Flutter 3.44.6 (one source: `frontend/pubspec.yaml`, read by CI too); `pubspec.lock` and `backend/package-lock.json` committed; Gradle 8.14 by URL; signer verified with `apksigner` at build; the build refuses to package without the release keystore; 16 KB alignment gate; the served APK's SHA-256 is compared with the built one at each release.

### 4.2 What is not ✔
- **No reproducibility check at all.** The APK is built on the owner's Windows PC by `build-android.ps1`. Nobody else can rebuild it and compare, and CI does not try.
- `gradle-wrapper.properties` has no `distributionSha256Sum`; no Gradle dependency lock/verification file.
- GitHub Actions are pinned by tag (`actions/checkout@v7`, `subosito/flutter-action@v2`), not by commit SHA.
- `backend/Dockerfile` uses `node:22-alpine` with no digest.
- No SBOM; the APK checksum is recorded in session notes, not published next to the download.
- **CodeQL default setup scans only `actions`** ✔ (`gh api …/code-scanning/default-setup` → `["actions"]`): the TypeScript backend is not analysed. Turning on `javascript-typescript` is a setting, not a project.
- Dependabot: no open alerts today ✔; it does not watch `scripts/smoke`.

### 4.3 The web client is not verifiable, by nature
A PWA's code is whatever the server sends on the next load. `/version.json` names a commit and two inline scripts are hash-pinned, but nothing lets a user check that `main.dart.js` matches the repo, and the CSP is report-only. Against the malicious-operator adversary the web client offers no protection that the operator cannot remove. This is true of every web E2E client and is the strongest argument for §1.4 W-a.

### 4.4 Path
1. Build the release APK in CI from a tag, in a pinned container, and publish the SHA-256 next to the download and in the GitHub release. Signing stays offline: CI builds unsigned, the owner signs, and the two are compared with the signature left out. The known tool for that comparison, `apksigcopier`, is archived (last commit 2024-10-15) `[R§8]`; plan to use `apksigner` plus a zip-content diff, or own a small script. Flutter gives no promise that two builds are identical: two issues about it are open with no answer from the Flutter team `[R§8]`, so step 2 is real work with an unknown end.
2. Make it reproducible: fix the Flutter-side sources of non-determinism (build paths, timestamps, the `--dart-define` values, native library build ids), then a second CI job rebuilds and compares.
3. Pin actions by SHA, the base image by digest, Gradle by checksum.
4. Play: with Play App Signing, Google re-signs; reproducibility then applies to the self-hosted APK and to the uploaded bundle only.

## 5. External audit readiness

**Not ready.** An audit bought today would spend most of its budget on orientation.

| Needed | State ✔ |
|---|---|
| A protocol document: how Umbra uses X3DH/Double Ratchet, the box, device lists, linking, recovery, backups, in one place | Missing. The content is spread over `multi-device.md` (3 252 lines), `metadata-privacy-decisions.md` (408 dense rows), `wire.md` (152), `e2e-invariants.md`, `METADATA.md` |
| Threat model and invariants | §3: to be written |
| A scoped, readable code base | `encryption_service.dart` 5 768 lines, `encryption_provider.dart` 4 052, `services/encryption/` 6 212, `services/box/` 8 289, `messaging_provider.box.dart` 2 890, vendored library ~4 100: about 31 000 lines in scope. The first two files were deliberately excluded from this cleanup program |
| A stable target | Feature freeze holds; the wire still changes in security fixes |
| `SECURITY.md` + disclosure address | Missing |
| Licence | Missing (§1.2) |
| Proof the crypto port matches the reference | Missing (§1.5) |
| Static analysis on the server code | CodeQL covers workflow files only (§4.2) |
| Known issues list to hand over | This document §2 |

Order that makes an audit worth its money: (1) `SECURITY.md`, licence, CodeQL for TypeScript: days. (2) Threat model + invariants table + protocol document: one to two weeks of writing, no code. (3) Known-answer tests for the port. (4) Decide §1.4. If the answer is "B6 soon", audit *after* B6, otherwise the audit covers a library about to be replaced; if "not soon", audit the protocol *use* (box, device lists, linking, recovery) now and exclude the ratchet internals. (5) Split the two encryption giants only with the audit scope agreed, since that is the "encryption layer redesign" this program was told not to touch.

## 6. Decisions for the owner

- **Q1. PWA and B6 (§1.4):** W-a (retire web first), W-b (native carries both libraries), W-c (wasm) or W-d (extend the port)? Recommended: W-a, with web as linked-only in the interim.
- **Q2. iOS:** W-a is blocked while iPhone users have only the PWA. Is Apple Developer enrolment still on hold?
- **Q3. Verification (§2.1):** B1/B2 stay dropped? If yes, the threat model will say in plain words that an active server is out of scope at first contact.
- **Q4. E143g:** build it now (medium, risky, its own release) or record it as accepted until B6 forces a re-key design anyway?
- **Q5. Licence:** Umbra already ships GPL-3.0 code (the Dart port) with no licence file of its own; libsignal would add AGPL-3.0-only. What licence does Umbra publish under, and does this need a lawyer before the Play listing? (The research note §1 quotes the relevant licence clauses; it draws no conclusion.)
- **Q6. Audit:** protocol-use audit now, or full audit after B6?
- **Q7. Reproducible builds:** start with §4.4 step 1 (CI-built APK + published checksum)?
- **Q8. Small items that need only a yes:** CodeQL for TypeScript; `SECURITY.md` with a contact address (which address?); B7 legacy-row count and re-enrol prompt.

## 7. Parked, not started (cleanup program §7)

- **New app name and own domain:** open. Host is `fireplace.ignorelist.com`; the Play package is `com.fireplace.app`.
- **Play items (decision 146):** in-app reports, `/delete-account` web page, terms checkbox at sign-up. Decided 11-20, **not built** ✔ (no match in `backend/src` or `frontend/lib`).
- **Play Console account:** not created per `docs/runbooks/android-release.md:430`. Closed test needs 12 testers for 14 days (owner recruits).
- **O7 / O6 of plan D2:** O7 accepted, not built; O6 deferred (decision 145).
- **E143g:** §2.2.
- **Release B** (avatar file deletion, with TD-13): due on or after 2026-12-08.
- **Owner-owed from the cleanup batches:** BE-12 confirmation; UI-16 and UI-17; a batch 4b for `messaging_provider.box.dart` and the composer split; TD-07 (tests bound to English UI strings); the two composer comments of TD-15.
