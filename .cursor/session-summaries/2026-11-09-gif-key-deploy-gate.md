# Web GIF search restored; deploy-web.ps1 refuses to publish without the Giphy key

**Date:** 2026-11-09 · **Version:** unchanged (0.2.80, web re-published at `d0c3f91a`) · **Tiers deployed:** web

## What was done
- Owner report: "GIFs stopped working" on web. Cause: web 0.2.80 was published with `-VmSshTarget` from `fireplace-hotfix`, which has no `deploy-web.config.ps1`, so `$GiphyApiKey` was empty. `deploy-web.ps1` only warned, my output filter hid the warning, and `GifService._fetch` returns `[]` on an empty key, so the picker showed nothing.
- Evidence: the prod `main.dart.js` lacked the key (grep 0). APKs 0.2.76, 0.2.79 and 0.2.80 all carry it in `libapp.so`, so Android was unaffected. Web 0.2.78/0.2.79 were [INFERENCE] probably deployed the same way; no old bundles are kept on the VM to confirm.
- Re-published web at `d0c3f91a` with the key from the main checkout's config (`PUBLISHED_OK`, bundle served from 09:18Z).
- `deploy-web.ps1` (PR #231 → `4e49f743`):
  - With no key, a build that will publish throws before `flutter clean`.
  - New `Assert-BundleHasGiphyKey` runs on every publish, `-SkipBuild` included.
  - `-SkipPublish` builds may still omit the key.
- `docs/agents/traps.md` trap 77 extended: the `-VmSshTarget` route and the new gate.
- Out-of-repo: none beyond the prod web re-publish. Prod throwaway accounts `gif80a130745` (id 147) and `gif80b131678` (id 148) were created by the drive.

## Key files
- Edited: `deploy-web.ps1`, `docs/agents/traps.md`.
- Read only (load-bearing): `frontend/lib/services/gif_service.dart`, `frontend/lib/config/app_config.dart:7-12`, `frontend/lib/widgets/gif_picker_sheet.dart`, `messaging_provider.send.dart:343` (`sendGif`).

## Verification
- CI: 7/7 success on `4e49f743` (PR #231).
- Before the fix: the prod bundle had no key. After: key present (1 match), Giphy `trending` with the key returned 200, post-deploy smoke 8/8 on `d0c3f91a`.
- Gate smoke (publish target `nobody@127.0.0.1`, nothing published):
  - No key with a build: throws "refusing to build for publish".
  - No key with `-SkipBuild`: throws "refusing to publish".
  - Wrong key with `-SkipBuild`: throws "does not carry".
  - Right key: "Bundle carries the Giphy key.", then stops at the VAPID gate.
- Live drive on prod after the fix: web (fresh tab, `d0c3f91a` bundle) and the release APK 0.2.80 on Pixel_7. Picker trending, search "cat", send, and the received GIF rendering animated all passed on both. No Giphy network failures and no app logcat errors.
- NOT verified: the owner's own device after the reload; iOS PWA.

## Notes for next session
- Next action: unchanged. Get do83rman's diag log (per-launch notifier challenge), watch for 0.2.79/0.2.80 `PROFILE_MIGRATED`, then release B on or after 2026-12-08.
- CSP gap, latent: sending a GIF reports `blob:` violations against `connect-src 'self' https://fonts.gstatic.com https://*.giphy.com` (from `main.dart.js` while drawing the sent bubble). Prod is report-only, so nothing is blocked. Add `blob:` before ever enforcing it.
- `build-android.ps1:109` still warns "will use the embedded fallback key" with an empty key. No fallback exists, so such an APK has no GIF search. Not changed; offered to the owner.
- Throwaway prod accounts to delete if the owner wants: `gif80a130745`, `gif80b131678`, plus those listed in `2026-11-09-coldstart-fix-0280.md`.
- Trap: trap 77 in `docs/agents/traps.md` (`-VmSshTarget` without a config file → no Giphy key; now gated).
