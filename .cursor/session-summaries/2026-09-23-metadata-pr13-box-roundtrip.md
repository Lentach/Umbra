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
- Suites: flutter 2349 passed / 14 skipped (verifier OK). Dart infos 3163 held, 0 errors/warnings. Shared harness 46 passed / 16 skipped (+2 gated).
- CI: `ea0eae45` 7/7; `2536cb88` 7/7, including `E2E isolated probes` running the box step.
- Mutants, run by a throwaway runner (outside the repo); every file restored and sha256-checked, `git status` clean:
  - B1 (box tracker ignores X-Real-IP): KILLED — the other address was refused.
  - B2 (ack deletes nothing): KILLED — the row was still stored.
  - C1 (tracker = `socket.id`): same-connection check PASSED; the fresh-connection check KILLED it.
  - H1 (row check blind to bytea): KILLED at the bytea control.
  - F1a (account Manager put in the io cache, box without forceNew): KILLED — Alice's box engine == Bob's account engine.
  - F1b (the same, WITH forceNew): PASSES, so forceNew is the defence.
  - F1 (forceNew dropped from BOTH sockets): INVALID — both accounts end up on one socket and `setUpAll` times out.
- dart2js signing, retried after `flutter test --platform chrome` hung at `loading` for 14+ min. This time: `dart compile js` of a throwaway entrypoint, run in the managed Chromium 153 (the `verify-session-lock-probe.mjs` pattern).
  - CORRECT: the public key a seed derives and all 4 server-produced vectors match.
  - SLOW: 256 signatures take 1970–2374 ms at `-O4` (≈ 8–9 ms each) and 2678–2867 ms at `-O2`. The Dart VM does the same in 187–248 ms. One 256-queue subscribe chunk blocks the web UI for about 2 s.
- Real Web Push notifier, driven once. The managed Chromium subscribed to Web Push with the dev VAPID key and got a real `fcm.googleapis.com` endpoint. With the real `BoxClient` (throwaway test):
  - challenge → `challenged`; the code arrived through FCM into the service worker;
  - a wrong code → refused; the pushed code → `active`;
  - a send while nobody was subscribed → a `{type:'new_message'}` wake-up 2.8 s later;
  - deleteQueue → ok.
- NOT verified: FCM (Android) notifiers (the dev stack has no `FIREBASE_SERVICE_ACCOUNT`), nginx `/box/`, prod.

## Notes for next session
- Next: gate G4, which needs the owner's OK. At the gate:
  - nginx `location /box/` with `X-Real-IP` (VM);
  - rebuild LATEST as the newest-5 union during the gate rebase. It stays master's verbatim copy until then (owner's pick), so there is no entry this session.
- Before PR3.1 resubscribes on web: `sign()` costs ≈ 8–9 ms under dart2js, so `BoxClient._subscribeChunks` must not sign 256 in one go on the UI thread. Options: yield between signatures, a worker, or WebCrypto Ed25519. This is a PR3.1 design call.
- Owner-owed:
  - the 16 MiB box per-file cap;
  - an OK for `deleteQueue` → `auth_failed` meaning "gone";
  - I2b, the push-token overlap in release N.
- Traps → `docs/agents/traps.md` (2 lines, this file).
