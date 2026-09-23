# The box has a Flutter client (PR1.2, dark); PR1.1 review items closed; media budget is 1 GiB/day

**Date:** 2026-09-23 · **Version:** unchanged · **Tiers deployed:** none

## What was done
- `0de8b935` PR1.1 review items:
  - `box-wire.ts parseWebPushSubscription`: `keys` must be exactly `{p256dh, auth}`.
  - `box-wire.spec`: a subscribe ENTRY carrying `v` is refused.
  - `box.int-spec` round trip: after the ack, a second send arrives and the acked id never does.
  - `scripts/verify-box-imports.mjs` resolves bare specifiers from `baseUrl` (`from 'src/users/…'` compiles under nodenext), plus a self-test row.
- `a7a80e80` owner's number: `BOX_MEDIA_DAILY_BUDGET_BYTES` 256 MiB → **1 GiB** per normal queue per UTC day, charged at the rung size. `mediaBytesToday` stays `integer`; 2 GiB+ needs it widened.
- `ac48857d` PR1.2, `frontend/lib/services/box/`, all dark:
  - `box_wire`: signed bytes, canonical b64, `BoxResult`.
  - `box_signer`: `BoxSigner` over `ed25519_edwards`, promoted from transitive.
  - `box_client`: `BoxSocket` seam + `IoBoxSocket`, plus its own `ChatReconnectManager(requiresToken: false)`; the class gained that flag.
  - `queue_seal`: X25519 → HKDF → AES-GCM, exactly 16384 B.
  - `queue_keys`: create → store → subscribe; not stored → deleted again.
  - `ContactQueue` gained `nid`.
- The owed PR2.2 rule: `FriendsProvider._unlisted` keeps a swept record that holds `queues`/`outbound` as `ContactState.former`. `_storeConversationsList` never removed records, so it needed nothing.

## Key files
- New:
  - `frontend/lib/services/box/{box_wire,box_signer,box_client,queue_seal,queue_keys}.dart`;
  - `frontend/test/services/box/*_test.dart` (4 files) and `frontend/test/support/box_fakes.dart` (socket double + pointycastle GCM).
- Edited:
  - `chat_reconnect_manager.dart`, `friends_provider.dart`, `contact_record.dart`, `pubspec.yaml/.lock` (dependency kind only);
  - `box-wire.ts`, `box.constants.ts`, the box specs, `verify-box-imports.mjs`;
  - `CLAUDE.md` counts, `wire.md` (budget, client, seal format), `e2e-invariants.md` (`former`).
- Read only: `socket_io_client` 3.1.6 `socket.dart` (ack shape, `sendBuffer`, dispose fires `disconnect`), `ed25519_edwards` 0.3.1, `x25519` 0.1.1, libsignal `curve.dart`.

## Verification
- Backend:
  - red first: the extra-keys row accepted `{p256dh, auth, extra}` before the fix;
  - the checker's new self-test row FAILED on the relative-only resolver; a fake tree printed `box/leak.ts -> users/user.entity.ts`;
  - jest 1182/68, test:int 23/23 (twice, before and after the budget change), ESLint 870 held, knip, no-user-logs, I1 OK.
- Backend mutants: entry-`v` stripped → killed; the gateway calling `onAcked` BEFORE `box.ack` → killed (the acked blob was pushed again).
- Frontend: flutter 2318 → **2349** passed / 14 skipped (+30 box, +1 sweep); Dart infos 3163 held, 0 errors/warnings.
- 14 frontend mutants, 13 killed:
  - emit while connecting; pending not failed on drop; `requiresToken` default; one frame for 300 rids; ready before chunks;
  - deleteQueue auth_failed; sid in the URL; verb separator; KDF without sealPub; open letting low-order throw;
  - store refusal ignored; `inbound()` skips former; sweep removes queue holders.
  - The survivor (no re-encode compare) was dead code: Dart's decoder refuses spare bits (probed). Removed; the test stays.
- Signed bytes AND signatures equal vectors that the server's `dist/box/box-signature.js` + node `crypto.sign` produced.
- Live, the real `IoBoxSocket` vs dev `/box`, 16/16:
  - createQueue twice → same address; subscribe; sealed send → msg → open → ack;
  - close/connect → backlog after the resubscribe; media 201/200/404;
  - deleteQueue twice → gone; a deleted rid is refused.
- Dev CORS preflight with `box-sid` → 204, header reflected.
- CI 7/7 on `0de8b935` and `a7a80e80`; `ac48857d` was in progress when this was written.
- NOT verified: `ed25519_edwards` under dart2js (web speed/correctness), a live transport DROP (only close/connect), a real push notifier, the PR3.1 wiring (none exists).

## Notes for next session
- Next: PR1.3 (`test_e2e/support/box_client.dart` + `box_roundtrip_test.dart`, `task_plan.md` PR1.2/PR1.3), then gate G4. PR1.3 can reuse `BoxClient` rather than a raw `io.io` copy — decide there.
- Owner-owed: OK `deleteQueue` → `auth_failed` (G3 §1 said `ok`); I2b push-token overlap in release N; **the per-file cap drops to 16 MiB of CIPHERTEXT on the box** (top rung, `box.constants.ts:58`) vs 20 MiB plaintext today (`media_crypto_service.dart:19`, server 21 MiB `media.controller.ts:38`) until the 32 MiB rung + nginx `client_max_body_size` land (Phase 5) — accept the gap, or pull that rung forward. The budget is DECIDED: 1 GiB/day.
- `LATEST.md` still master's verbatim (owner's pick): no entry for this session; rebuild as the newest-5 union at the gate rebase.
- Traps → `docs/agents/traps.md` (6 lines + 1 owner-owed, this file).
