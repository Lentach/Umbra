# Security policy

## Reporting a vulnerability

Send it by e-mail to **olek292@gmail.com**. Please do not open a public issue or pull request for a vulnerability.

Useful in a report:

- what an attacker can do, and what they need first (a password, a linked device, control of the server, network position);
- the version (`Settings` shows it; the server answers at `/version`) and the platform (Android app or web);
- steps to reproduce, or a proof of concept.

Umbra is maintained by one person. Reports are read and answered as time allows; there is no guaranteed response time and no bug bounty. You will be told when a fix ships, and credited if you want to be.

Please test only against accounts you own. Do not read, change or delete other people's data, and do not degrade the service for others.

## Supported versions

Only the latest release is supported: the server and the web app run one version, and the Android app asks to update to it. Fixes are not back-ported.

## Scope

- The Android app and the web app (`frontend/`).
- The server (`backend/`).
- How Umbra uses its cryptography: first contact, the message box, device lists and device linking, recovery keys, backups.

What Umbra claims to protect, what it does not, and the limits already known are written down in [`docs/security/threat-model.md`](docs/security/threat-model.md) and [`docs/METADATA.md`](docs/METADATA.md). A finding that contradicts either file is in scope; a limit those files already state is known.

## Verifying a release

The Android APK is built by CI from a `v<version>` tag and signed offline. Each GitHub release carries the unsigned build and its SHA-256, and the signed file's SHA-256 is published next to the download. `scripts/verify-apk-signed-matches-unsigned.mjs` checks that the signed file is the CI build plus a signature and nothing else. Builds are not yet reproducible.
