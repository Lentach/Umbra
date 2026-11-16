# A3: the Android content store fails closed; a red line retries it (0.2.84, merged, not deployed)

**Date:** 2026-11-16 · **Version:** 0.2.83 → 0.2.84 (not deployed) · **Tiers deployed:** none

## What was done
- `content_kv_opener_io.dart`:
  - `openEncryptedContentKv` (was `_open`) records `CONTENT_STORE_UNAVAILABLE{stage}` and throws `ContentStoreUnavailable(stage)`. It no longer returns `PrefsContentKv` (cleartext XML).
  - The diag is recorded once per stage until an open succeeds: every store touch retries, and the first drive wrote 7 entries per launch into the 80-entry ring.
  - `openMemoized` drops a failed open, so the next touch opens again.
- `ConnectionProvider`:
  - `contactStoreFailed` = a stage is set and it is not `locked`.
  - `retryContactStore` runs `_reopenContactStore` (open, hydrate, `storeOpened`, device lists), then `retryE2EInit` once the account socket is ready.
  - `_openContactStore` notifies when the stage changes.
  - The web passcode-unlock hook uses the same `_reopenContactStore`.
- `ConversationsScreen`: a red `AlertLine` (`content-store-failed-alert`, PL/EN `contentStoreFailedLine`) above the other top lines; a tap retries.
- Docs:
  - `frontend/docs/e2e-invariants.md`: the fallback bullet is rewritten, and the false "the loss screen says why" claim is corrected (nothing read `contactStoreUnavailableStage`).
  - Plan row A3 ✅.
  - One Agent-tooling trap.
  - `CLAUDE.md` count 3291.
  - Lint floor 2494 → 2493.
- PR #251, `release: 0.2.84`.
- Out-of-repo:
  - Local stack `dmed` downed with `-v`.
  - The `fireplace-a3` worktree was removed.
  - The Pixel_7 emulator was stopped, with this debug build and its account installed.
  - The owner's phone and the `dzwonek36` emulator were not touched.
  - Throwaway local accounts lived on the downed stack only.

## Key files
- Edited:
  - `frontend/lib/services/encryption/content_kv_opener_io.dart`
  - `frontend/lib/providers/connection_provider.dart`
  - `frontend/lib/screens/conversations_screen.dart`
  - l10n ARB and generated files
  - `frontend/test/providers/contact_store_hydration_test.dart`
- New: `frontend/test/services/encryption/content_kv_opener_io_test.dart`.
- Read only (load-bearing):
  - `encryption_service.dart` `_sharedPrefs` (does not keep a rejected open);
  - `contact_store.dart` `open`;
  - `box_session.dart` `storeOpened`;
  - `encryption_provider.dart` `retryE2EInit`.

## Verification
- CI: success 7/7 on `41680691` (PR #251 head: 6 `ci.yml` + CodeQL; Analyze (actions) too), merged as `1184a07b`.
- Red first:
  - the opener test failed on the old code: `PrefsContentKv` came back, and the memo kept a failed open;
  - the hydration retry test did not compile before the API existed.
- Mutants, reasoned:
  - The fallback revert and the memo that keeps failures were killed, as observed in the red run.
  - `contactStoreFailed` always false and a retry that does not hydrate are killed by the hydration test.
  - Survivors with no test, by choice: dropping the `locked` exclusion (the passcode gate covers that screen) and dropping the notify (wiring, covered by the drive).
- Full Flutter suite: 3291 pass, 14 skip. Analyze: infos only. Dart lint ratchet: PASS, improved 2494 → 2493, floor lowered.
- Drive, local stack: debug APK on Pixel_7 plus a local web release peer.
  - **Store broken:** `files/fp_content.db` was replaced by random bytes (originals moved aside) with the DB key intact.
    - The launch showed the red line and "Brak czatów".
    - The prefs keys were the same 5 as before; there was no plaintext ("awari") in `FlutterSharedPreferences.xml`, and the broken file was left in place.
    - The peer's message sent meanwhile was NOT taken.
  - **Retry:** after restoring the file and tapping the line, the line was gone in about 5.7 s, the contact and history were back, and the message sent during the failure arrived; a new send reached the peer.
  - **Second build:** one `CONTENT_STORE_UNAVAILABLE` per failing launch. Logout works while the store is down; logging in after the restore shows the full history.
  - **Web:** passcode lock, then a message received while locked; the unlock showed the chat and the message, with no red line.
- NOT verified:
  - a release APK;
  - a real Keystore failure (the drive breaks the file, not the Keystore);
  - iOS, which still opens prefs.

## Notes for next session
- Next action: release 0.2.84 on the owner's go (recipe `2026-11-10-release-0282.md`, APK versionCode 20084). Otherwise, plan item A5: plaintext voice-note fallback and video temp-file sweep.
- Owed by the owner: an end date for the step5-archive; store decision, privacy policy and ToS.
- Field rate of the old fallback: unknown and unmeasurable, because diagnostics never leave the device.
- Drive recipe:
  - Break the store: `run-as com.fireplace.app` → `cd files`; move `fp_content.db`, `-wal` and `-shm` aside; write `head -c 8192 /dev/urandom > fp_content.db`.
  - Restore: move the three files back while the app runs, then tap the line.
  - `pm clear` wipes the key too, so it does not reproduce this case.
- Traps: one Agent-tooling line (relative paths in omp tools resolve against the main checkout).
