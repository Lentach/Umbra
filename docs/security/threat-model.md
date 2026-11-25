# Umbra threat model

What Umbra protects, against whom, and what it does not. Checked against the
code on 2026-11-24 (version 0.2.103). Where this page and the code disagree,
the code is right and this page is the bug.

Related: what the server stores and learns is in [`docs/METADATA.md`](../METADATA.md);
the decisions behind it are in `docs/plans/metadata-privacy-decisions.md`; open
hardening work is in `docs/plans/2026-11-24-signal-grade-gap.md`.

## 1. What is protected

- **Message content and attachments.** Encrypted on the sending device with the
  classic Signal protocol (X3DH + Double Ratchet, a vendored pure-Dart port:
  `frontend/third_party/libsignal_protocol_dart/PATCHES.md`). For messages the
  server stores only sealed blobs. There is no post-quantum protection. Account
  data the server holds in readable form is listed in `docs/METADATA.md`.
- **Who sends to whom.** Messages travel through queues whose rows hold random
  ids and one auth key, nothing that names an account, sender or peer. One
  exception: a device's request queue is tied to its account, by design. What
  the server can still work out is in item 4 below.
- **Keys.** Private keys never reach the server in the clear. A user who sets
  a recovery phrase stores a copy on the server sealed by that phrase (§3). On
  Android the keys sit in the Android Keystore, and messages and contacts in
  an encrypted (SQLCipher) database. If that database fails to open, the app
  runs without it and never writes content in plaintext.

## 2. Out of scope, in plain words

These are decisions, not oversights. The table in §4 refers to them as
"item 1" to "item 6".

1. **A server that lies at first contact.** When you add someone, your device
   takes that person's identity key from the server and trusts the first key it
   sees. A malicious operator could hand you its own key and sit between you
   and your contact from the first message on. **Umbra does not protect you
   against this.** It has no safety numbers, no QR verification and no lasting
   "verified" mark (hardening items B1 and B2, dropped by the owner on
   2026-11-16, confirmed 2026-11-24). What exists: the contact's card shows a
   key fingerprint that two people can compare over another channel; nothing
   prompts them to, and nothing remembers that they did.
   After first contact a changed identity key is noticed: on a friend's
   normal queue its first message is held and not shown, a contact request
   under it is dropped, and you cannot send to that friend, until you accept
   the new key. Accepting is one tap that nothing checks, and a friend who
   really reset their account looks the same as an attacker.
2. **A friend's revoked device replacing your session (E143g).** A device that
   was removed from a friend's account still holds that account's identity
   key. If it also knows the address of one of your queues for that friend, it
   can, by the design record, send a session-opening message that passes the
   identity check and replaces your session with that friend's device. The
   gate that prevents this exists for your own other devices and for contact
   requests, not for friends' normal queues. No test demonstrates the attack
   or pins its absence. Accepted by the owner on 2026-11-24 until the move to
   another protocol library forces a new re-key design.
3. **The web app's code.** The browser checks with Umbra's server on every
   load, so an operator can serve modified code to one user. Web keys are
   sealed, but without the app passcode the key that unseals them is in the
   same browser storage: anything that can read that storage reads the keys.
   The content security policy for the app is report-only. The web app is to
   be retired; until then, treat it as weaker than the Android app.
4. **Traffic analysis and what the server can work out.** The server sees an
   IP address and a time for every connection, and which queues one connection
   reads. It sees when one account looks up another's username (for example
   when you add someone). It can group one device's queues through their
   shared push token: how many contacts that device has and when each one
   writes, though not whose device it is. Messages are fixed-size blobs and
   media is padded to fixed steps; timing is not hidden. No anonymity network.
5. **An unlocked or rooted device.** Local protection ends at the device's own
   lock. On Android the app passcode is a screen lock only.
6. **A recording adversary with a future quantum computer.**

## 3. Limits that are not decisions

- **An account that never linked a second device has no reset delay.** With
  the password alone, someone can publish a new identity for that account at
  once. Linking a device is what arms the lock. The account's own devices see
  the change when they next connect; friends' apps treat the new key as in
  item 1.
- **Recovery phrase set on an app up to 0.2.89.** Those versions sent the
  phrase to the server each time it was set or used. Since 0.2.104 the server
  refuses such a phrase and never stores or verifies one. An operator who
  kept it earlier can open that
  account's recovery backup (the account's identity key and the key that
  signs its device list) and the phrase lock of its contact backup. The
  account is safe only after it sets a new phrase on a current app. Phrases
  set since 0.2.90 never leave the device.
- **Nobody can check that the Android app they install was built from this
  repository.** It is built on the owner's PC; there is no reproducible build.
- **The protocol library has had no external audit.** What is and is not
  proven about it: `PATCHES.md`, named in §1.
- A photo or video loses its camera metadata before encryption. A file sent as
  a document, a GIF, a HEIC photo or a WebM video keeps its metadata. The true
  size of every attachment is hidden inside the ciphertext.
- A received message never makes your device fetch an address the sender
  chose. On the web app, the sender's link preview is fetched by Umbra's
  server, which then sees that address and which account asked for it.

## 4. Adversaries

| Adversary | Can do | What stops it | What does not |
|---|---|---|---|
| Network observer | See traffic to the server | TLS | Traffic analysis (item 4) |
| Thief of the database | Read every stored row | Messages and media are ciphertext; queue rows name no account | Password hashes (Argon2id; older bcrypt hashes are upgraded at the next login); the contact backup, which is locked by a key derived from the password |
| Thief of a backup | Read a nightly backup file | Backups are encrypted with a passphrase, and leave out waiting messages and media (queue rows and push registrations are included) | With the passphrase: everything the database thief gets, plus the server's secrets, including the key that signs login tokens |
| Operator who only reads | Read database, logs, memory | As for the database thief. Log strings carry no account id or username (a mechanical scan in CI; device ids are logged). Queue code cannot import account code (CI) | Sees the login password inside TLS, so can unlock that user's contact backup and learn their queue addresses. Item 4 |
| **Operator who acts** | Serve wrong keys or device lists, replay, drop, serve a modified web app; everything a password thief can do | Device lists are signed by a key the server does not hold, and peers check the chain. A changed identity key is held until accepted (item 1). A session-replacing message is read only when asked for, on sibling and request queues | First contact (item 1). E143g (item 2). The web app (item 3). An account with a pre-0.2.90 recovery phrase: the operator may hold its signing key (§3) |
| Password thief | Log in | Linking a device also needs a code exchanged with the primary device, the same short code on both screens, and an approve tap on the primary. On an account that has linked a device, an identity reset waits 6 hours (1 hour with a recovery phrase enrolled at least 6 hours earlier) and is announced to the account's connected devices | An account that never linked a device (§3). Can read the contact backup. Devices that are offline learn of a pending reset only when they next connect; contacts are not told by the server |
| Revoked device | Still holds the account identity key, and a friend's old queue address until that friend's device rotates it (the retired queue is deleted about 30 days later) | Each remaining device sends friends a signed updated list; a friend that processes it stops addressing the revoked device and rotates its queue | A friend that missed the announcement keeps sending to it until corrected. E143g (item 2) |
| Device thief | Read local storage | Android: Keystore-held keys, encrypted database, sealed caches | An unlocked or rooted device (item 5). There is no iOS app; an iOS build today would fall back to plaintext app storage |
| Recording adversary with a later quantum computer | Open recorded handshakes | Nothing | Item 6 |

## 5. Reporting a problem

No security contact address is published yet.
