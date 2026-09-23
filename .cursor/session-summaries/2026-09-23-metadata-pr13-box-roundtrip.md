# The box is proven end to end: PR1.3 drives the real BoxClient beside two logged-in accounts (opt-in, isolated CI stack)

**Date:** 2026-09-23 · **Version:** unchanged · **Tiers deployed:** none (branch `feat/metadata-privacy`, draft PR #184)

## What was done
- `ea0eae45` docs: new owner-owed item. The box's largest file is 16 MiB of ciphertext (its top size step), vs 20 MiB of plaintext on today's path. Recorded in the PR1.2 summary and in `traps.md`.
- `2536cb88` PR1.3: new `frontend/test_e2e/box_roundtrip_test.dart`, gated on `--dart-define=BOX_PROBE=true`. It uses the REAL `BoxClient` over the production `IoBoxSocket`; the plan's raw `io.io` support copy was not built.
  - Round trip: createQueue → sid handed over in-test → send while the owner is away → subscribe delivers → ack deletes it at rest (`e2eSql`) → a fresh connection gets only what came after → deleteQueue.
  - Checks: 4 distinct engine.io ids (2 box sockets + 2 account sockets). No box row the round trip wrote carries either account.
  - Throttle test: one address spends its createQueue bucket; another address proceeds.
- `IoBoxSocket` (`box_client.dart`) gained two `@visibleForTesting` seams: `.withHeaders(url, headers)`, standing in for the proxy's X-Real-IP, and `engineId`.
- Opt-in because the shared `e2e-wire` run already spends all 10 registrations/h (1+2+2+1+2+2). New step in `e2e-isolated-probes` with the passed-count guard; that stack's budget goes from 6 to 8 of 10.
- Docs:
  - root `CLAUDE.md`: harness count and the isolated-probes list (the encryption proof was missing from it);
  - `wire.md`: the box suite line.
- `11027e3a`: two independent reviewers both judged it "correct" and raised 4 findings; all applied.
  - A fresh connection from the throttled address must be refused too.
  - The row check now reads bytea columns (UTF-8 hex of username/token), with a `convert_to()` control row.
  - Dropped the dead `box_notifiers` read and the always-true acked-id comparison.

- Box signing no longer freezes the web UI (owner picked "built-in browser crypto + fallback"). `BoxSigner.sign` is now async and the platform `boxSigner` is selected by conditional import:
  - web: `WebCryptoBoxSigner` (`box_signer_web.dart`, PKCS#8 import, one cached key per queue); if the first import fails (no Ed25519, or no `crypto.subtle` in an insecure context) the session falls back to pure Dart;
  - elsewhere, and as that fallback: `Ed25519BoxSigner(yields: true)`. It signs one at a time, each after one event-loop turn, so a Dart timer or frame that arrives mid-burst waits at most one signature.
  - `BoxClient` signs a subscribe chunk with `Future.wait`, then builds the frame. If the socket changed while it was signing, the call answers `disconnected` and nothing is sent.

## Key files
- New: `frontend/test_e2e/box_roundtrip_test.dart`.
- Edited:
  - `frontend/lib/services/box/box_client.dart` (`IoBoxSocket`)
  - `.github/workflows/ci.yml`
  - `CLAUDE.md`
  - `docs/contracts/wire.md`
- Read only (load-bearing):
  - `socket_io_client-3.1.6/lib/socket_io_client.dart` `_lookup`
  - `backend/src/box/box-throttler.guard.ts`
  - `backend/src/box/box.service.ts`
  - `test_e2e/support/e2e_test_client.dart`

## Verification
- Probe on the dev stack: 2/2 at `2536cb88`, 2/2 again after the review fixes.
- Suites at `11027e3a`: flutter 2349 passed / 14 skipped (verifier OK). Dart infos 3163 held, 0 errors/warnings. Shared harness 46 passed / 16 skipped (+2 gated).
- CI: `ea0eae45` 7/7; `2536cb88` 7/7, including `E2E isolated probes` running the box step.
- Mutants (throwaway runner, files restored + sha256-checked): B1 X-Real-IP ignored, B2 ack deletes nothing, C1 tracker = `socket.id`, H1 row check blind to bytea, F1a box joins the account Manager — all KILLED; F1b (same, forceNew kept) passes; F1 (forceNew off BOTH sockets) invalid. Detail: `.planning/metadata-privacy/findings.md` §2026-09-23 PR1.3.
- dart2js signing (`dart compile js` page in Chromium 153; `flutter test --platform chrome` hung 14+ min): correct — 4/4 server vectors; ≈ 8–9 ms/signature at `-O4` vs < 1 ms on the VM.
- Real Web Push notifier, driven once (managed Chromium, real `fcm.googleapis.com` endpoint, dev VAPID, real `BoxClient`): challenge → code pushed into the service worker → wrong code refused, pushed code `active` → a send while unsubscribed woke it 2.8 s later → deleteQueue ok.
- Freeze fix, dart2js `-O4` page in Chromium 153 (Long Tasks, rAF gaps, a mid-burst timer), 256 signatures started as `BoxClient` starts them:
  - before: one 2571 ms long task, frame gap 2567 ms;
  - WebCrypto: 40 ms cold, 21 ms warm, 0 long tasks, frame gap ≤ 38 ms;
  - fallback (insecure origin, no `crypto.subtle`): 3.1 s wall, 0 long tasks, frame gap ≤ 13 ms, a timer set mid-burst 9–10 ms late (first cut `1167a6fa`, all turns queued at once: that timer ~2.5 s late; `findings.md`);
  - all three: vectors 4/4.
- Freeze fix, tests and suites: mutants Y1 (stub stops yielding), Y2 (signer ignores `yields`), P1 (yields queued in parallel again) and R1 (no re-check after signing) all KILLED by the 2 new tests. Box probe 2/2 on the dev stack, flutter 2351 passed / 14 skipped, Dart infos 3163 held.
- NOT verified: FCM (Android) notifiers (the dev stack has no `FIREBASE_SERVICE_ACCOUNT`), nginx `/box/`, prod.

## Notes for next session
- Next: gate G4, which needs the owner's OK. At the gate:
  - nginx `location /box/` with `X-Real-IP` (VM);
  - rebuild LATEST as the newest-5 union during the gate rebase. It stays master's verbatim copy until then (owner's pick), so there is no entry this session.
- Residue of the freeze fix:
  - old or insecure-context browsers still wait ~3 s after a reconnect before the box is `ready`, without freezing;
  - `WebCryptoBoxSigner` keeps one imported key per queue key it has signed with, and nothing prunes it on `deleteQueue` (session memory only).
- Owner-owed:
  - the 16 MiB box per-file cap;
  - an OK for `deleteQueue` → `auth_failed` meaning "gone";
  - I2b, the push-token overlap in release N.
- Traps → `docs/agents/traps.md` (5 lines, this file).
