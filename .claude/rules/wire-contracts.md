---
paths:
  - "backend/src/chat/**"
  - "backend/src/**/dto/**"
  - "backend/src/key-bundles/**"
  - "backend/src/auth/**"
  - "frontend/lib/services/socket_service.dart"
  - "frontend/lib/providers/connection_provider.dart"
  - "frontend/lib/providers/messaging_provider.dart"
---
# Wire contracts

Read **`docs/contracts/wire.md`** before the first edit in any file above. It is the verbatim former root `CLAUDE.md` §7: envelope shape, `socketReady`/`serverTime` clock law, delete/edit semantics, `rate_limited` answers, takeover alarm, registration lock, reset ceremony + REBIND order, per-device keys, device-material guard, provisioning, fan-out, revocation gates, roster teardown, live-primary login, accept-side gate.

Adding a new event/endpoint/column: root `CLAUDE.md` §8, then append the contract to `docs/contracts/wire.md` in the same commit. Spec of record for multi-device: `docs/design/multi-device.md` §12.
