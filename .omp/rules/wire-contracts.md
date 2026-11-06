---
description: Use when touching the client⇄server wire — chat.gateway.ts, any @SubscribeMessage or socket.on( handler, DTOs under backend/src/**/dto, socket_service.dart, connection_provider.dart, messaging_provider.dart, message envelopes, key bundles, device lists, provisioning/revocation/reset ceremonies, or /auth/recover.
condition: ".*"
scope: "tool:edit(backend/src/chat/**), tool:write(backend/src/chat/**), tool:edit(backend/src/**/dto/**), tool:write(backend/src/**/dto/**), tool:edit(backend/src/key-bundles/**), tool:write(backend/src/key-bundles/**), tool:edit(backend/src/auth/**), tool:write(backend/src/auth/**), tool:edit(frontend/lib/services/socket_service.dart), tool:write(frontend/lib/services/socket_service.dart), tool:edit(frontend/lib/providers/connection_provider.dart), tool:write(frontend/lib/providers/connection_provider.dart), tool:edit(frontend/lib/providers/messaging_provider.dart), tool:write(frontend/lib/providers/messaging_provider.dart)"
---

# Wire contracts

Read **`docs/contracts/wire.md`** before the first edit in any file above. It is the verbatim former root `CLAUDE.md` §7: envelope shape, `socketReady`/`serverTime` clock law, delete/edit semantics, `rate_limited` answers, takeover alarm, registration lock, reset ceremony + REBIND order, per-device keys, device-material guard, provisioning, fan-out, revocation gates, roster teardown, live-primary login, accept-side gate.

Adding a new event/endpoint/column: root `CLAUDE.md` §8, then append the contract to `docs/contracts/wire.md` in the same commit. Spec of record for multi-device: `docs/design/multi-device.md` §12.
