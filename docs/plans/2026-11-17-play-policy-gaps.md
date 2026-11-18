# Google Play policy gaps before a public release (2026-11-17)

**Status:** proposal. No product code yet. OWNER decisions are marked **[OWNER-n]**, in the
`metadata-privacy-decisions.md` S8 sense.
**Context:** Distribution was decided on 2026-11-17: Google Play (public, personal account) plus the
self-hosted APK (`docs/runbooks/android-release.md` "Distribution"). That section lists what is still
open: an in-app report flow, terms accepted at sign-up, a web account-deletion path, the Data safety
form, a reviewer account and the closed test.
**Code wins over docs:** every claim about the code below cites a file and line on master as of this
date. If it drifts, fix this doc.

## Sources (re-read 2026-11-17, not from memory)

- **[UGC]** Play Console Help 9876937, *User Generated Content*:
  https://support.google.com/googleplay/android-developer/answer/9876937
- **[DEL]** Play Console Help 13327111, *Understanding Google Play's app account deletion requirements*:
  https://support.google.com/googleplay/android-developer/answer/13327111
- **[DS]** Play Console Help 10787469, *Provide information for Google Play's Data safety section*:
  https://support.google.com/googleplay/android-developer/answer/10787469

### What the policies actually require (quotes)

- **[UGC]** UGC apps must have moderation that:
  - "Requires users accept the app's terms of use and/or user policy before users can create or upload UGC";
  - "Defines objectionable content and behaviors … and prohibits them in the app's terms of use";
  - "includes providing an in-app system for reporting and blocking objectionable UGC and users, and
    taking action against UGC or users where appropriate. Different UGC experiences may require
    different moderation efforts."
- **[UGC]** Its examples:
  - "UGC features that enable 1:1 user interaction with specific users (for example, direct messaging …)
    must provide an in-app functionality for blocking users."
  - The Key Considerations table also says "Provide a user-friendly, in-app system for reporting
    objectionable content and users."
  - A listed violation: "Apps that continually fail to address user complaints about objectionable content."
- **[DEL]** An app that creates accounts must provide "an in-app path to delete their app accounts and
  associated data; **and** a web link resource where users can request app account deletion".
  - The web resource must "give users a way to request that their data be deleted without sending the
    user back to the app".
  - It may be "an additional link that initiates account deletion, a customer service email or a form
    they can submit a request through".
  - It must "reference the app or developer name" as shown on the store listing, and the deletion path
    must be "prominently featured".
  - Data kept "for legitimate reasons such as security, fraud prevention or regulatory compliance" must
    be disclosed, for example in the privacy policy.
- **[DS]** Disclosure rules:
  - "Collect" means "transmitting data from your app off a user's device".
  - E2E-encrypted data "unreadable by you or anyone other than the sender and recipient … does **not**
    need to be disclosed".
  - Pseudonymous data "that can reasonably be re-associated with a user must be disclosed".
  - Ephemeral processing must be declared in the form but is not shown on the listing.
  - Transfers to a "service provider" that processes data on the developer's behalf are not "sharing".
  - Approximate location "inferred, such as via IP address" belongs under Location, but only if the
    data is *collected* in that sense.

**Reading of [UGC] for Umbra.** Umbra is 1:1 direct messaging between users who added each other by
`username#tag`, with no public content. So blocking is the hard MUST. Reporting is required too: the
general bullet and the Key Considerations table both ask for in-app reporting. Its form can be
"reasonable and consistent with the type of UGC hosted". Shipping without any in-app report entry is
the main rejection risk.

---

## 1. In-app reporting in an E2E app

### What a report must contain to satisfy [UGC]

The policy does not specify the content of a report. It must be:
1. reachable **in the app**, from the user or the chat;
2. about **users and content**;
3. able to lead to **action**, which for Umbra means suspending or deleting the account (terms §
   "Rules", `docs/legal/terms.en.md:66`).

The minimum that makes action possible is:
- the reported account (`username#tag`, or the user id the client already has);
- a category;
- for content, some evidence. The server holds no plaintext (`docs/legal/privacy-policy.en.md:52`), so
  only the reporter can supply it.

### Options

| | (a) Reporter-composed report with selected plaintext (Signal/WhatsApp model) | (b) Handle + category only | (c) Email link (`mailto:`) |
|---|---|---|---|
| UX | "Report" on the profile or chat menu, then a category, then optionally "include the last N messages" (N=5, user can untick each one), with a consent line: *"These messages will be sent to Umbra's moderators unencrypted. The person will not be told."* | "Report" on the profile, then a category | "Report" opens the mail app with a prefilled subject |
| Server learns | reporter account, reported account, category, time, the forwarded plaintext (and media only if we allow it; recommend text only) | reporter account, reported account, category, time | whatever the user writes, plus their email address and provider, outside our infrastructure |
| New metadata | a social-graph edge "A reported B at T", plus plaintext of a conversation **that the reporter voluntarily discloses**. Same legal footing as a screenshot | the edge "A reported B at T" | edge plus an email identity; lives in a mailbox we don't control |
| Storage (proposal) | the existing contact inbox on the VM (`~/fireplace-inbox`, privacy policy row "Contact form keeps the message + optional reply address", `docs/legal/privacy-policy.en.md:22,72`), as a new `kind='report'`. **Not** the backend's dormant `contact_messages` table, which no code uses (`docs/METADATA.md:30`) | same inbox | owner's mailbox |
| Retention (proposal) | deleted 90 days after the report is closed, or 12 months at most (matching the contact form's "at most 12 months", `privacy-policy.en.md:72`); reporter id dropped once closed | same | owner's mailbox policy, unbounded unless he deletes |
| Action possible | yes: evidence plus a verified account | weak: no evidence, so action is either "trust the reporter" or none. Fails "taking action … where appropriate" in practice | yes, but manual, and the account handle may be mistyped |
| Passes [UGC] "in-app system"? | yes | probably (it is in-app), but weak on "content" | risky: arguably not "in-app"; reviewers have rejected mailto-only flows [INFERENCE: no primary source found for a rejection rule] |
| Effort | client: menu entry, category sheet, message picker, consent text, l10n EN/PL. Backend/inbox: authenticated `POST /reports` endpoint (rate-limited, size-capped), inbox schema + admin view. About 2–3 agent-days + device drive | about 1 agent-day | about 2 h |
| E2E posture | unchanged: nothing leaves without an explicit user action, as when the user forwards a screenshot. Must never be automatic or server-triggered | unchanged | unchanged |

**Who the endpoint authenticates.** A report must come from a signed-in account, so a stranger can't
flood it. That means the server links reporter ↔ reported anyway. (b) leaks exactly that edge; (a) adds
the plaintext the reporter chose to disclose.

**Do not send the plaintext through the box.** The box is for user-to-user traffic. A report is
user-to-operator and travels over plain HTTPS (TLS) to our server, where the operator can read it. The
consent text must say so.

### Recommendation

Choose **(a)**, with these constraints:
- text only;
- at most the last 10 messages, each deselectable, and zero is allowed (which makes it (b));
- authenticated and rate-limited (e.g. 5/hour, reusing the `@Throttle` pattern at
  `backend/src/users/users.controller.ts:107`);
- stored in the VM inbox with a 12-month cap;
- the reporter can also block in the same flow (the WhatsApp "Report and block" pattern).

Also add a "report" email line in terms and privacy as the fallback channel. It is already sketched at
`docs/legal/terms.en.md:64`.

The privacy policy needs a new §4 row: "Reports you send: reporter, reported account, category, the
messages you chose to include; to act on abuse; (f) legitimate interest; at most 12 months."

**OWNER questions:**
- **[OWNER-1]** Approve option (a), reporter-selected plaintext, with the consent text above? Or do you
  want (b) handle-and-category only, accepting weaker moderation?
- **[OWNER-2]** Retention for reports: 12 months maximum, with the reporter id dropped when the case is
  closed. Agree?
- **[OWNER-3]** The sink: the VM contact inbox (`~/fireplace-inbox`) as `kind='report'`, or a separate
  table in the main backend DB (which would then be in the nightly backup and R2)?
- **[OWNER-4]** Who moderates, and what is the response promise (for example "we review reports within
  7 days")? The terms promise to tell the user why before suspension (`terms.en.md:66`).
- **[OWNER-5]** May reports include media (photos, voice)? Recommendation: no for v1, text only.

## 2. Blocking: exists, and is enough for the "block" requirement

It exists, and it is local and goes over the box:
- `FriendsProvider.blockUser` → `_end(userId, block: true)` (`frontend/lib/providers/friends_provider.dart:561,570`).
- When the friend has a box route, the peer is sent `goodbye` and the local record turns
  `ContactState.blocked` (`friends_provider.dart:97-99,582,609-615`).
- With no route, the record turns `blocked` locally (`friends_provider.dart:587-598`).
- A block also ends a pending request (`friends_provider.dart:568`).
- The blocked list is `blockedUsers` (`friends_provider.dart:104`). Unblock deletes the record
  (`friends_provider.dart:628-641`).
- The server keeps no friend, request or block row (`friends_provider.dart:16`). The block is carried
  by the encrypted contact backup (`friends_provider.dart:567`), so it survives a reinstall.

**Is it enough?** [UGC] asks 1:1 apps for "in-app functionality for blocking users". This is satisfied.
The blocked person learns only that the friendship ended (`goodbye`), not that it was a block, and the
server learns nothing.

**Gap to check [agent]:** whether a blocked user can re-send a friend request through a new invite
code. This is not a policy blocker. Verify on device while doing the report UI, and offer "Block" next
to "Report".

## 3. Account deletion via a web link

### Today

In-app deletion exists:
- Settings → Delete account → `AuthProvider.deleteAccount` (`frontend/lib/providers/auth_provider.dart:1107-1135`).
- The order is: verify the password; `beforeDelete` sends `goodbye` over the box and retires the queues
  (decision 113); `DELETE /users/account`; logout.
- `DELETE /users/account` is JWT-guarded, takes the password and is throttled 5/h
  (`backend/src/users/users.controller.ts:105-116`), calling `UsersService.deleteAccount`
  (`backend/src/users/users.service.ts:165`). Rows go by FK cascade (`privacy-policy.en.md:21`).

The privacy draft §9 leaves the web path open: "**Without the app:** [OWNER/TODO before Play: a web
page or email address where a user can ask for deletion]" (`docs/legal/privacy-policy.en.md:112`).
It also states that unlinked leftovers expire on their own (`:113`): messages after 30 days, media
after 14 days, queues after 90 idle days (`backend/src/box/box.constants.ts:43,45,49`), and backups
after 14 or about 30 days (`:101`).

### Options

| | (A) Web page: log in with username#tag + password, then delete | (B) Request form (or email), handled by hand |
|---|---|---|
| Satisfies [DEL] | yes ("an additional link that initiates account deletion") | yes ("a customer service email or a form") |
| Identity proof | the password itself, at the server's existing check | hard: the server has no email or phone. The operator can't tell the owner from an impersonator. The only proof is the password, which must not be collected by hand |
| Friends told? (decision 113) | **no**: no device, no box keys, so no `goodbye` | no |
| Effort | a static page under `/delete-account` on the current host (a small HTML form on the nginx-served origin) that calls the existing `POST /auth/login` then `DELETE /users/account`. No new backend endpoint. About 0.5–1 agent-day | page + inbox kind + manual runbook. About 0.5 day, plus ongoing manual work |
| Attack surface | a login form on the web: same endpoints as the app, already throttled | a manual operator action keyed on unverifiable claims |

### Decision 113 and web-only deletion

Decision 113 sends `goodbye` before the delete because only the device holds the box routes. A web
deletion cannot do this. Friends then see the following [INFERENCE from 113's text, "no 'gone' answer
from the box (existence oracle)"]:
- their messages to the deleted account still get box-accepted, sit for up to 30 days and expire;
- the deleted account's queues reap after 90 idle days;
- the friend row stays in their app until they unfriend it.

This is the same outcome as an "uninstall and never come back", and the same as the pre-box friends
decision 113 already accepts ("pre-box friends with no route get nothing"). It leaks nothing new: no
server-side "gone" signal is added.

The page must say: *"Your contacts will not be notified. To tell them, delete from the app instead."*

### Recommendation

Choose **(A)**: a static web page that logs in and deletes with the existing endpoints, warns that
friends won't be told, and points to the in-app path first. Then update the privacy draft §9 line
`:112` to the URL, and add the URL to the Data safety deletion field.

(B) is rejected because the server has no second factor to verify a hand request.

- **[OWNER-6]** Approve the self-service web deletion page (A), with the warning that contacts are not
  notified (the accepted consequence of decision 113)?
- **[OWNER-7]** The URL: `https://<current host>/delete-account` now, moving with the domain decision?

## 4. Terms acceptance at sign-up

**Today:** the register tab of `frontend/lib/screens/auth_screen.dart` (mode switch `:43`, register
call `:214-215`, register-only block `:273-280`) shows no terms. `RegisterDto` takes only username and
password (`backend/src/auth/dto/register.dto.ts:9-22`).

**UI.** [UGC] requires acceptance *before* creating UGC; it does not require a checkbox. Recommendation:
an unchecked checkbox on the register tab, *"I accept the [Terms] and have read the [Privacy Policy]"*,
which gates the Create button.
- A checkbox is unambiguous evidence for a reviewer, and GDPR-safe.
- The "By continuing you accept …" line is the lighter alternative, also accepted in practice
  [INFERENCE].
- Both links open in the external browser.

**URLs.** `https://<current host>/terms` and `/privacy`, served as static pages by the existing nginx
frontend origin, built from `docs/legal/*.md` (EN and PL by locale).
- On Android the host comes from the build-time base URL that is already compiled into every APK
  (`android-release.md:419-421`).
- These pages must go live before Play submission, because the Play listing also needs the privacy
  URL ([DS] "Ensure that you've added a privacy policy").

**Server side.** Options:
- (i) store nothing; the client blocks sign-up until the box is ticked.
- (ii) a `users.termsVersion` varchar (for example `"2026-11"`), set at register (a new `RegisterDto`
  field, optional for old clients) and on re-acceptance after a change.
- Metadata cost of (ii): one low-entropy value per account. It reveals nothing beyond "registered after
  terms version X", which `createdAt` (`backend/src/users/user.entity.ts:40`) already reveals.
- Mixed fleet: 0.2.83–0.2.88 clients don't send it, so it would be null for them.

Recommendation: **(ii)**, nullable, with no timestamp column (`createdAt` and the version suffice). It
also lets the terms' "we will announce changes … 14 days" promise (`terms.en.md:89`) prompt existing
users.

- **[OWNER-8]** Checkbox (recommended) or a "by continuing" line?
- **[OWNER-9]** Store `termsVersion` on the account (recommended, nullable), or store nothing server-side?

## 5. Data safety form: draft answers from the code

Top level ([DS] steps 4–5):
- Collects data: **Yes**.
- All data encrypted in transit: **Yes** (HTTPS/WSS only; the nginx TLS origin is `infra/nginx/fireplace.conf`).
- Users can request deletion: **Yes** (in-app plus the §3 URL).
- No data is **shared**: FCM is a service provider; Giphy is user-initiated after opt-in, which counts
  as a "user-initiated action" exemption under [DS]; link-preview fetches go to the open web.
- Ads: none. Analytics/crash SDKs: none (`privacy-policy.en.md:20,47`).

| Item | Play data type | Collected? | Shared? | Required/optional | Purpose | Deletable | Evidence |
|---|---|---|---|---|---|---|---|
| Username + 4-digit tag | Personal info → User IDs | Yes | No | Required | App functionality, Account management | Yes, account delete | `backend/src/users/user.entity.ts:11-21` (`@Unique(['username','tag'])`); `register.dto.ts:9-15` |
| Password | Not a listed type. It is an authentication credential stored only as a bcrypt hash. Declare under Account management via "User IDs" [INFERENCE: Play has no "password" type] | Yes (hash) | No | Required | Account management, Security | Yes | `backend/src/users/users.service.ts:38` (`bcrypt.hash(password, 10)`); `user.entity.ts` `password` column |
| FCM registration token | Device or other IDs | Yes | No: Google FCM is a service provider | Required for push on Android (optional in practice: the app works without push while foregrounded [INFERENCE]) | App functionality | Yes: deleted with its queue, which the device retires on delete; else 90-day idle reap | `frontend/lib/services/push_box_source.dart:48` (`getToken()`); `backend/src/box/entities/box-notifier.entity.ts:27-29`; `box.constants.ts:49` |
| IP address | Location → Approximate location **only if stored**. Answer: processed **ephemerally** (rate limiting in memory), not stored | Yes, ephemeral (hidden on listing) | No | Required | Security | n/a | `infra/nginx/fireplace.conf:39-40,72,87` (`access_log off`, `error_log … crit`); `privacy-policy.en.md:80-82` |
| Messages, photos, video, voice, files | Messages / Photos / Audio / Files | **Not disclosed**: E2E (Signal protocol); the server holds 16 KiB sealed blocks and media it cannot read ([DS] E2E exemption) | No | — | — | Expire: 30 d messages, 14 d media | `privacy-policy.en.md:52`; `box.constants.ts:43,45`; `backend/src/box/entities/box-media.entity.ts:11,24` |
| Box queues (random ids + key, no account link) | None (opaque, unlinked routing state) [INFERENCE: not "user data" under [DS] since not re-associable to an account by the server; revisit if the owner prefers conservative "Device or other IDs"] | — | No | Required | App functionality | 90-day idle reap; device retires on delete | `backend/src/box/entities/box-queue.entity.ts:29,37-49`; `box.constants.ts:49` |
| Encrypted contact backup | Contacts. The blob is sealed with keys the server does not hold, so the E2E exemption applies (user = sender = recipient) [INFERENCE: recommend **declaring it anyway** as Contacts, collected, encrypted, for conservatism] | Yes (conservative) | No | Required (made automatically) | App functionality | Yes, account delete (cascade) | `backend/src/backup/contact-backup.entity.ts:45`; `friends_provider.dart:567`; `privacy-policy.en.md:70` |
| Devices, public keys, sessions, recovery verifier | Device or other IDs (device ids); keys are not personal data | Yes | No | Required | App functionality, Security | Yes, account delete; sessions after 365 idle days | `backend/src/key-bundles/device.entity.ts:26`; `backend/src/auth/refresh-token.entity.ts:17`; `backend/src/key-bundles/recovery-key.entity.ts:23`; `privacy-policy.en.md:63-65` |
| Reports (after §1 ships) | Messages → Other in-app messages + User IDs | Yes, user-initiated | No | Optional | Security, compliance | 12-month cap | new; §1 |
| Giphy search (opt-in) | none of ours: the device talks to Giphy directly. Declare as optional "App interactions / In-app search history" collected by an SDK? It is an HTTP call, not an SDK [INFERENCE: the user-initiated exemption covers it; confirm wording] | — | User-initiated | Optional, off by default | App functionality | n/a | `privacy-policy.en.md:17,95`; `frontend/lib/config/app_config.dart` |

**Store listing result:** "No data shared with third parties". Data collected: User IDs, Device or
other IDs, and Contacts (if declared conservatively), all encrypted in transit and deletable.

- **[OWNER-10]** Declare the contact backup as "Contacts, collected" (conservative, recommended), or
  rely on the E2E exemption and leave it undeclared?

## 6. Remaining Play blockers

| # | Blocker | Owner | Depends on |
|---|---|---|---|
| 1 | App **name** decision (UMBRA collision, `android-release.md:418-420`) | OWNER | — |
| 2 | Own **domain** (FreeDNS subdomain today) | OWNER | 1 |
| 3 | Play **developer account** (personal), identity verification | OWNER | — |
| 4 | Review and publish **privacy + terms** (`docs/legal/`); fill `[OWNER: contact email]` | OWNER (review) / agent (serve `/terms`, `/privacy`) | 2 or the current host |
| 5 | **In-app report** flow (§1 option a) + inbox sink + privacy row | agent | OWNER-1..5 |
| 6 | **Terms checkbox** at sign-up + `termsVersion` | agent | OWNER-8, 9; item 4 URLs |
| 7 | **Web account-deletion** page + privacy §9 URL | agent | OWNER-6, 7 |
| 8 | **Data safety** form entered in Console from §5 | OWNER (Console) / agent (CSV draft) | OWNER-10, items 5–7 |
| 9 | **Content rating** questionnaire (UGC: users interact, share content) | OWNER | 3 |
| 10 | **Reviewer account** (demo username + password, plus a second account so chat can be shown) in App access | agent creates / OWNER enters | 3 |
| 11 | **Closed test**: 12 testers for 14 consecutive days (Play Console Help 14151465) | OWNER (recruit) | 3, 5–7 shipped |
| 12 | **Play App Signing via PEPK** with `fireplace-release.jks`, never a Google-generated key (`android-release.md:416-417`) | OWNER (Console) / agent (runbook) | 3 |
| 13 | Target audience: adults (not "Families"); age line in terms/privacy §11 matches | OWNER | — |

## Owner questions (verbatim list)

1. **[OWNER-1]** Approve option (a), reporter-selected plaintext, with the consent text above? Or do you
   want (b) handle-and-category only, accepting weaker moderation?
2. **[OWNER-2]** Retention for reports: 12 months maximum, with the reporter id dropped when the case is
   closed. Agree?
3. **[OWNER-3]** The sink: the VM contact inbox (`~/fireplace-inbox`) as `kind='report'`, or a separate
   table in the main backend DB (which would then be in the nightly backup and R2)?
4. **[OWNER-4]** Who moderates, and what is the response promise (for example "we review reports within
   7 days")?
5. **[OWNER-5]** May reports include media (photos, voice)? Recommendation: no for v1, text only.
6. **[OWNER-6]** Approve the self-service web deletion page (A), with the warning that contacts are not
   notified (the accepted consequence of decision 113)?
7. **[OWNER-7]** The URL: `https://<current host>/delete-account` now, moving with the domain decision?
8. **[OWNER-8]** Checkbox (recommended) or a "by continuing" line?
9. **[OWNER-9]** Store `termsVersion` on the account (recommended, nullable), or store nothing server-side?
10. **[OWNER-10]** Declare the contact backup as "Contacts, collected" (conservative, recommended), or
    rely on the E2E exemption and leave it undeclared?
