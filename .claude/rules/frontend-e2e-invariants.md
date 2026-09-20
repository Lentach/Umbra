---
paths:
  - "frontend/lib/services/encryption/**"
  - "frontend/lib/services/backup/**"
  - "frontend/lib/services/contacts/**"
  - "frontend/lib/services/encryption_service.dart"
  - "frontend/lib/services/device_list/**"
  - "frontend/lib/services/device_link/**"
  - "frontend/lib/services/recovery_phrase.dart"
  - "frontend/lib/services/content_key_canary.dart"
  - "frontend/lib/services/e2e_lock_revoker.dart"
  - "frontend/lib/providers/encryption_provider.dart"
  - "frontend/lib/screens/device_link_gate_screen.dart"
  - "frontend/lib/screens/recovery_key_screen.dart"
---
# Frontend E2E and local-storage invariants

Read **`frontend/docs/e2e-invariants.md`** before the first edit (verbatim former `frontend/CLAUDE.md` §5). Server stores ciphertext only; device private keys never leave the device; storage names (`FireplaceE2E`, `fireplace-*`) are addresses of live user data and are NEVER renamed.
