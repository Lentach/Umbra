<!--
DRAFT, NOT PUBLISHED. Owner review pending (decision 2026-11-17: the agent drafts, the owner reviews; no lawyer for now).
Fields marked [OWNER: …] are facts only the owner can supply. The Polish text (privacy-policy.pl.md) must say the same thing.
Every factual claim below is traced to code or a tracked doc; keep this table in step when either changes.

| Claim | Source |
|---|---|
| Stored tables, purposes, retention | docs/METADATA.md "What the server stores" |
| Sessions: hashes only, 365-day sliding expiry, rotation | backend/src/auth/refresh-tokens.service.ts (REFRESH_TOKEN_TTL_DAYS) |
| Blobs 30 d, queues 90 idle days, media 14 d | docs/METADATA.md "Retention and logging" |
| Contact backup: padded, 4 KiB buckets, password-derived wrap (plan B3 residual) | docs/METADATA.md "Contact backup" |
| nginx access log off, error log at crit | /etc/nginx/sites-enabled/fireplace (infra/nginx/fireplace.conf) |
| App logs carry no account ids/usernames; 10 MB x 3 rotation | scripts/verify-no-user-logs.mjs; docker-compose.prod.yml logging |
| Backups: 14 d on the VM, Cloudflare R2 (~32 d lifecycle), GPG-encrypted | backup-db.sh; docs/METADATA.md; VM crontab (fireplace-r2) |
| Server in Warsaw (OVH) | .omp/rules/production-vm-deploy.md |
| FCM payload {type:'new_message'}; Web Push encrypted | docs/METADATA.md "Push providers" |
| Giphy only after opt-in | docs/METADATA.md (C2, decision 141) |
| Link previews: sender's device fetches; receiver loads image from the site (C1); web asks the server (C4) | frontend/lib/services/link_preview_service.dart; backend/src/link-preview |
| Web only: Roboto from Google's font server | docs/METADATA.md (C3 note) |
| No analytics/crash/ads SDKs | frontend/pubspec.yaml (firebase_core + firebase_messaging only) |
| Account deletion: device tells friends + retires its queues, server deletes the account rows (FK cascade) | frontend/lib/providers/auth_provider.dart deleteAccount; backend/src/users |
| Contact form keeps the message + optional reply address | ~/fireplace-inbox/src/db.ts (VM) |
| Android 7+ (minSdk 24) | frontend/android/app/build.gradle.kts |
-->

# Umbra Privacy Policy

**Effective from:** [OWNER: date of publication]

Umbra is a messenger built so that the people who run it cannot read your messages. This policy explains what the Umbra server stores, what it can and cannot see, who else is involved, and what you can do about it.

## 1. Who runs Umbra

Umbra is run by a private individual, not a company:

- **[OWNER: full name]**, [OWNER: address]
- Email: **[OWNER: contact email]**

That person is the data controller under the EU General Data Protection Regulation (GDPR) for the personal data described below.

## 2. The short version

- Your messages, photos, voice notes, files, reactions and read receipts are **end-to-end encrypted** (Signal Protocol). Only the devices of the people in the conversation can read them. We cannot.
- We do **not** ask for your phone number, email address or real name. An account is a username and a password.
- The server does not know who you talk to. Messages pass through anonymous delivery queues that name no account and no sender.
- Your contact list, chats and blocks live **on your devices**, not on our server.
- There are **no ads, no analytics, no tracking and no crash-reporting services**, and we sell nothing.
- Some things are unavoidable: the server sees your IP address while you are connected, and Google wakes your phone when a message arrives. Both are explained below.

## 3. What the server cannot see

- **Message content.** Everything you send is encrypted on your device before it leaves, inside fixed-size 16 KiB blocks, so the server cannot even see how long a message is.
- **Who sends to whom.** A message is dropped into an anonymous queue. The queue is not linked to any account, and sending does not identify the sender.
- **Your contacts, chats and blocks.** These are stored only on your devices.
- **Whether you read a message.** Read and delivery receipts travel inside the encryption.
- **Your profile photo.** It travels encrypted, like a message.

## 4. What the server stores, and why

| What | Why | Legal basis (GDPR art. 6(1)) | How long |
|---|---|---|---|
| **Account:** username, a random 4-digit tag, a one-way hash of your password, when the account was created and when the password last changed | To let you sign in and be found by your username#tag | (b) contract | Until you delete the account |
| **Devices and public keys:** which devices your account has (when each was added or removed), their public encryption keys and the signed list of your devices | So your contacts' devices can encrypt to yours | (b) contract | Until you delete the account |
| **Login sessions:** one record per signed-in device, holding only fingerprints (hashes) of its current login token. Each refresh moves the record's expiry date, so it shows when the device was last active, to about a day | To keep you signed in, and to end the session if an old token is reused | (b) contract; (f) security | Until you sign out, remove the device, or 365 days without use; or until you delete the account |
| **Recovery data:** a verifier of a value your device derives from your recovery phrase (the phrase itself never leaves your device; a key set by an older app version, up to 0.2.89, stored a verifier of the phrase itself until you replace it) and records of identity resets | So you can recover your account | (b) contract | Until you delete the account |
| **Delivery queues:** random identifiers and a key, linked to no account | To deliver messages | (b) contract | Until your device deletes the queue, or after 90 days without use |
| **Undelivered messages:** encrypted 16 KiB blocks | To hold a message until the recipient's device collects it | (b) contract | Deleted as soon as it is collected, otherwise after 30 days |
| **Attachments:** encrypted files, padded to standard sizes so the server sees only a size band | To deliver photos, voice notes, videos and files | (b) contract | 14 days |
| **Push tokens:** your phone's Firebase Cloud Messaging token, or your browser's Web Push subscription | To wake your device when a message arrives | (b) contract | Deleted with the queue it belongs to |
| **Encrypted contact backup:** one encrypted file per account | So your contact list survives losing a device | (b) contract | Until you delete the account |
| **One-time secret notes:** encrypted text with an expiry, without any link to who created it | To deliver the note | (b) contract | Deleted when read or when it expires |
| **Messages you send us through the contact form:** your message and, if you give one, a reply address | To answer you | (f) legitimate interest in answering | At most 12 months |

About the **contact backup**: its content is encrypted with a key the server never receives, and it is padded so that its size (rounded up to 4 KiB) does not reveal how many contacts you have. The server learns only that a backup exists, its rounded size and when it last changed. One limit you should know: the backup key is protected by your password, and your password is sent to the server when you sign in. Someone running a modified server could therefore, in principle, open the backup. Your messages are not affected by this.

Old **profile photos** that were stored on the server before version 0.2.79 are kept only until about 8 December 2026 and then deleted.

## 5. IP addresses and logs

- Every connection shows the server your **IP address** and the time. We use it only while the request is handled, for example to limit how many requests one address can make (anti-abuse). It is not stored with your account.
- Our web server's **access log is switched off**: it does not record who visited which page. Its error log records only critical server faults.
- The application's own logs never contain usernames or account numbers (this is checked automatically before every release). They are overwritten after a few megabytes.
- Someone with access to the server could still try to match the time one person sends with the time another receives. Hiding that would require an anonymity network such as Tor, which Umbra does not use.

Legal basis: art. 6(1)(f), our legitimate interest in keeping the service secure and working.

## 6. Who else is involved

We do not sell or share your data. These services are involved in running Umbra:

- **OVH** (hosting): the Umbra server runs on an OVH server in Warsaw, Poland. OVH processes data on our behalf.
- **Cloudflare (R2 storage)**: stores copies of our nightly backups. Backups are encrypted on our server **before** they are uploaded, and Cloudflare does not have the key. Cloudflare is a US company; the transfer relies on [OWNER: verify — Cloudflare's EU–US Data Privacy Framework certification and/or Standard Contractual Clauses].
- **Google (Firebase Cloud Messaging)**, Android app only: when a message arrives for your phone, Google delivers a wake-up signal that contains nothing but "new message". Google sees your phone's push token and that it was woken, not who wrote to you or what they wrote.
- **Web Push services** (Google, Mozilla, Apple or Microsoft, depending on your browser), web version only: same role as above; the payload is encrypted.
- **Giphy**, only if you switch on GIF search: Giphy then sees your GIF searches, the previews you load, the GIF you pick and your IP address. A GIF you send travels encrypted; the person who receives it never contacts Giphy. GIF search is off by default.
- **Websites you link to**: when you send a link, your device fetches the page to build a preview, so that website sees your IP address. The person who receives the preview currently loads its image directly from that website too (we are changing this). In the web version, the preview page is fetched by our server instead of your browser.
- **Google Fonts**, web version only: the web version downloads a standard font (Roboto) from Google's font server when it loads. The Android app contains all its fonts and downloads none.

## 7. Backups

Every night the server makes an encrypted backup of its database and the encrypted attachments. Backups are kept **14 days** on our server and about **30 days** in Cloudflare R2, and then deleted. Data you delete, including a deleted account, can therefore survive in a backup for up to that long. Backups contain only what is described in section 4; your messages are not in them in readable form.

## 8. What stays on your device

Your messages, contacts, chat history and private encryption keys are stored on your devices. In the Android app, keys are kept in the Android Keystore and messages in an encrypted database. In the web version, keys are stored in the browser's local storage, where anyone with access to your browser profile could read them; for this reason we recommend the Android app.

If you lose all your devices and your recovery phrase, nobody, including us, can restore your messages.

## 9. Deleting your account

- **In the app:** Settings → Delete account. Your device first tells your contacts and removes its delivery queues, then the server deletes your account, devices, keys, sessions, recovery data and contact backup.
- **Without the app:** [OWNER/TODO before Play: a web page or email address where a user can ask for deletion].
- Encrypted leftovers that are linked to no account expire on their own: undelivered messages after 30 days, attachments after 14 days, unused queues after 90 days. Backups are deleted as described in section 7.

## 10. Your rights

Under the GDPR you have the right to access your data, to have it corrected or deleted, to restrict or object to its processing, to receive it in a portable form, and to withdraw any consent you gave (for example, by switching GIF search off). Write to **[OWNER: contact email]**; we answer within one month.

Please note that we cannot give you your messages, because we never have them in readable form. The app can export your chat history to a file that you control.

You can complain to the Polish data protection authority: **Prezes Urzędu Ochrony Danych Osobowych**, ul. Stawki 2, 00-193 Warszawa, uodo.gov.pl, or to the authority in your own EU country.

## 11. Age

Umbra is for people aged **16 or over**.

## 12. Security

Messages are end-to-end encrypted with the Signal Protocol. Connections to the server use HTTPS. Passwords are stored only as one-way hashes. Login tokens are stored only as hashes and are replaced on every refresh in the Android app. Backups are encrypted before they leave the server.

## 13. Changes

If we change this policy, we will publish the new version here and tell you in the app before it takes effect.

## 14. Contact

**[OWNER: full name]**, [OWNER: address], **[OWNER: contact email]**
