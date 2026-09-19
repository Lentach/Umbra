import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';
import { KeyBundle } from './key-bundle.entity';
import { OneTimePreKey } from './one-time-pre-key.entity';
import { IdentityChangeAudit } from './identity-change-audit.entity';
import { AccountAuthorization } from './account-authorization.entity';
import { IdentityResetService } from './identity-reset.service';
import { verifyIdentityChangeSignature } from './identity-signature.util';

/**
 * The device a request is about. Phase 1: absent means device 1, because a
 * client that has never heard of devices is the account's original one (§8
 * rollout — server first, clients later).
 */
export const DEFAULT_DEVICE_ID = 1;

/**
 * Upper bound on a device number the wire will accept.
 *
 * The account cap is 3 devices (spec §1) and numbers are assigned by the
 * server at provisioning (Phase 2), so anything large is either a bug or an
 * attempt to scatter rows across a huge keyspace. Bounded here rather than in
 * each handler so every entry point inherits it.
 */
export const MAX_DEVICE_ID = 100;

export interface KeyBundleData {
  registrationId: number;
  identityPublicKey: string;
  signedPreKeyId: number;
  signedPreKeyPublic: string;
  signedPreKeySignature: string;
}

export interface OneTimePreKeyData {
  keyId: number;
  publicKey: string;
}

export interface PreKeyBundleResponse {
  registrationId: number;
  identityPublicKey: string;
  signedPreKeyId: number;
  signedPreKeyPublic: string;
  signedPreKeySignature: string;
  oneTimePreKeyId: number | null;
  oneTimePreKeyPublic: string | null;
}

/**
 * How an identity replacement was authorized (§6.1/§6.2), or `null` when it
 * was not. The reset case is load-bearing beyond the audit trail: a COMPLETED
 * RESET is the moment the §6.2 roster teardown runs (spec §12 amendment
 * (xxviii)), and a signed rotation deliberately does NOT tear the roster down
 * — the account still holds its other devices.
 *
 * `'unlocked'` is amendment (lxxiii) clause 1: the account is NOT ENROLLED
 * (no `account_authorizations` row), so the registration lock is not armed
 * and the replacement is admitted with credentials alone — loudly, through
 * the same audit/notification path as the other two, and never tearing any
 * roster down (there is none).
 *
 * `'restore'` is amendment (lxxviii) clause 2: the uploaded identity EQUALS
 * the stored one and the caller proved possession of its private half (an
 * XEdDSA signature under the CURRENT IK, restored from the phrase-sealed
 * backup). Not an identity change at all — no audit row, no §6.0 alarm — but
 * it DOES run the §6.2 roster teardown: the restoring install is a fresh
 * wipe, so every other device is presumed lost.
 */
export type IdentityChangeAuthorization =
  'signature' | 'reset' | 'unlocked' | 'restore' | null;

export interface UpsertKeyBundleResult {
  /** True when the upload REPLACED a stored bundle with a different identity. */
  identityChanged: boolean;
  /** Which authorization admitted it; `null` when nothing was replaced. */
  authorizedBy: IdentityChangeAuthorization;
  /** The superseded identity public key when identityChanged, else null. */
  previousIdentityPublicKey: string | null;
}

/**
 * Proof accompanying an upload that replaces the stored identity key
 * (registration lock, multi-device spec §6.1). Absent for the normal
 * same-identity re-upload and for a first-ever upload.
 */
export interface IdentityChangeProof {
  /** base64 XEdDSA signature by the PREVIOUS identity key. */
  signature?: string;
  /** base64 nonce this socket session was issued, echoed back. */
  nonce?: string;
  /**
   * base64 XEdDSA signature by the CURRENT (stored) identity key over
   * identityPublicKey ‖ userId ‖ nonce — the (lxxviii) restore proof.
   * Considered only when the uploaded identity equals the stored one.
   */
  restoreSignature?: string;
}

/**
 * Thrown when an upload would replace the stored identity key without
 * authorization — neither a signature from the previous identity key nor a
 * completed reset ceremony. Nothing is written when this is thrown.
 */
export class IdentityLockedError extends Error {
  constructor() {
    super('identity_locked');
    this.name = 'IdentityLockedError';
  }
}

/**
 * Thrown when an upload carries a restore proof for the account's UNCHANGED
 * identity that does not verify under the stored identity key (amendment
 * (lxxviii) clause 2). Nothing is written when this is thrown: an invalid
 * proof must not degrade into an ordinary same-identity re-upload, because
 * the gateway runs the roster teardown on the verdict.
 */
export class IdentityRestoreRefusedError extends Error {
  constructor() {
    super('restore_refused');
    this.name = 'IdentityRestoreRefusedError';
  }
}

/**
 * Amendment (lxiv) clause 1: a bundle row's registrationId may not change
 * while its identityPublicKey is unchanged. Identity and registrationId are
 * minted together, once, in every mint path, so this shape can only be a
 * DIFFERENT physical install (e.g. a revoked linked device whose password
 * login resolved onto the primary's device id) writing into a namespace it
 * does not own — the write that mixes X3DH halves and makes peers' first
 * messages permanently undecryptable.
 */
export class DeviceMaterialConflictError extends Error {
  constructor() {
    super('device_material_conflict');
    this.name = 'DeviceMaterialConflictError';
  }
}

@Injectable()
export class KeyBundlesService {
  private readonly logger = new Logger(KeyBundlesService.name);

  constructor(
    @InjectRepository(KeyBundle)
    private readonly keyBundleRepo: Repository<KeyBundle>,
    @InjectRepository(OneTimePreKey)
    private readonly otpRepo: Repository<OneTimePreKey>,
    @InjectRepository(IdentityChangeAudit)
    private readonly identityChangeAuditRepo: Repository<IdentityChangeAudit>,
    // Read-only here, and only to answer "is this account enrolled?" for the
    // (liv) admission gate. KeyBundlesService never writes the enrollment.
    @InjectRepository(AccountAuthorization)
    private readonly authorizationRepo: Repository<AccountAuthorization>,
    private readonly identityResetService: IdentityResetService,
  ) {}

  /**
   * Installs the caller's public key bundle.
   *
   * Registration lock (§6.1): replacing the stored identity key requires
   * authorization, because a bundle replacement is what silently redirects
   * every future conversation to different keys. Two things authorize it:
   * a signature by the PREVIOUS identity key over the new key, the account id
   * and a session nonce, or a completed reset ceremony (§6.2) which is spent
   * here. Without either, nothing is written at all.
   *
   * Same-identity re-uploads (the client's normal every-connect path) and the
   * first-ever upload are unaffected.
   */
  async upsertKeyBundle(
    userId: number,
    data: KeyBundleData,
    proof?: IdentityChangeProof,
    deviceId: number = DEFAULT_DEVICE_ID,
  ): Promise<UpsertKeyBundleResult> {
    // The identity key belongs to the ACCOUNT, not to one device (spec §3:
    // every device of an account shares one IK), so the lock compares against
    // whatever identity the account currently publishes — from any device —
    // while the row written below belongs to THIS device alone.
    //
    // Detection pre-check only; races with concurrent uploads are acceptable
    // (duplicate audit rows under a race are tolerated by design — do NOT
    // serialize the upsert around this).
    const existingBundle = await this.keyBundleRepo.findOne({
      where: { userId },
      order: { deviceId: 'ASC' },
    });
    const identityChanged =
      existingBundle != null &&
      existingBundle.identityPublicKey !== data.identityPublicKey;
    let authorizedBy: IdentityChangeAuthorization = null;
    if (identityChanged) {
      const enrolled = await this.isEnrolled(userId);
      authorizedBy = await this.authorizeIdentityChange(
        userId,
        existingBundle.identityPublicKey,
        data.identityPublicKey,
        enrolled,
        proof,
      );
      if (authorizedBy === null) {
        if (enrolled) {
          // Loud, and deliberately before any write: an unauthorized
          // replacement attempt on an ENROLLED account is exactly the event
          // this lock exists to stop.
          this.logger.warn(
            `[identity-lock] REFUSED unauthorized identity replacement deviceId=${deviceId} storedPrefix=${existingBundle.identityPublicKey.slice(0, 12)} attemptedPrefix=${data.identityPublicKey.slice(0, 12)}`,
          );
          throw new IdentityLockedError();
        }
        // (lxxiii) clause 1: the registration lock is OPT-IN — enabling
        // linking (enrolling a DAK) is what arms it. An un-enrolled account
        // replaces its identity with credentials alone, and the churn stays
        // LOUD: same warn line, same audit row, same §6.0 alarm fan-out.
        authorizedBy = 'unlocked';
      }
      this.logger.warn(
        `[identity-churn] deviceId=${deviceId} via=${authorizedBy} oldIdentityPrefix=${existingBundle.identityPublicKey.slice(0, 12)} newIdentityPrefix=${data.identityPublicKey.slice(0, 12)}`,
      );
    }
    // Amendment (lxxviii) clause 2 — restore proof, valid ONLY when the
    // uploaded identity EQUALS the stored one (an identity CHANGE with a
    // stray restore field was adjudicated above and never reaches here). The
    // proof is the §6.1 byte layout verified under the CURRENT identity key:
    // only the holder of `ikPriv` — restored from the phrase-sealed backup —
    // can produce it. Adjudicated BEFORE any write, and an invalid proof is a
    // refusal rather than a silent downgrade to the plain re-upload path,
    // because the caller's next step (the roster teardown) hangs on this
    // verdict.
    if (
      !identityChanged &&
      existingBundle != null &&
      proof?.restoreSignature &&
      proof?.nonce
    ) {
      const proofValid = verifyIdentityChangeSignature({
        storedIdentityPublicKey: existingBundle.identityPublicKey,
        newIdentityPublicKey: data.identityPublicKey,
        userId,
        nonce: proof.nonce,
        signature: proof.restoreSignature,
      });
      if (!proofValid) {
        this.logger.warn(
          `[identity-restore] REFUSED invalid restore proof deviceId=${deviceId} storedPrefix=${existingBundle.identityPublicKey.slice(0, 12)}`,
        );
        throw new IdentityRestoreRefusedError();
      }
      authorizedBy = 'restore';
      this.logger.log(`[identity-restore] proof verified deviceId=${deviceId}`);
    }
    // (lxiv) clause 1 — refuse a foreign install's write BEFORE any mutation.
    // The account-first row above answers "did the ACCOUNT's identity move";
    // this guard needs THIS device's row: same identity + different
    // registrationId on the same (userId, deviceId) row is another install
    // clobbering the owner's published signedPreKey while the served OTP pool
    // stays the owner's. Identity-changing uploads were adjudicated above and
    // mint a fresh registrationId with the fresh identity, so they never
    // match this predicate.
    const ownRow =
      existingBundle != null && existingBundle.deviceId === deviceId
        ? existingBundle
        : await this.keyBundleRepo.findOne({ where: { userId, deviceId } });
    if (
      ownRow != null &&
      ownRow.identityPublicKey === data.identityPublicKey &&
      ownRow.registrationId !== data.registrationId
    ) {
      this.logger.warn(
        `[device-material-conflict] REFUSED same-identity upload with foreign registrationId deviceId=${deviceId} stored=${ownRow.registrationId} attempted=${data.registrationId}`,
      );
      throw new DeviceMaterialConflictError();
    }
    // Atomic upsert — handles concurrent connections from the same device
    // (e.g. two tabs), and keeps other devices' bundles untouched.
    await this.keyBundleRepo.upsert(
      { userId, deviceId, ...data },
      { conflictPaths: ['userId', 'deviceId'] },
    );
    if (identityChanged) {
      // The account identity moved, so every OTHER device still publishes keys
      // minted under a dead identity. Serving those to a peer would encrypt to
      // a key nobody holds; the device itself re-uploads under the new identity
      // when it next connects (or is re-provisioned).
      await this.purgeSupersededDevices(userId, deviceId);
    }
    // Purge unused OTPs from any SUPERSEDED identity epoch (or untagged legacy
    // rows). Belt-and-suspenders with the fetch identity filter: the filter
    // already refuses to serve them; this reclaims the slots so replenishment
    // refills the current epoch. New clients tag their OTPs with this same
    // identity, so a re-upload in either order survives (their tag matches)
    // while genuinely stale rows are removed. This is the durable fix for the
    // 2026-07-11 stale-OTP bad-MAC wave (see migrations 0003-0005).
    //
    // IDENTITY-EPOCH INVARIANT is enforced at THREE sites that MUST stay in
    // sync: (1) here — purge non-current-epoch unused rows; (2) fetchPreKeyBundle
    // — claim only current-epoch rows; (3) countUnusedPreKeys — count only
    // current-epoch rows. Change the epoch semantics in all three or none.
    //
    // Phase 1 re-keys the partition from `identityPublicKey` to
    // `(identityPublicKey, deviceId)`: purge/claim/count operate strictly
    // inside ONE device's namespace, so this device's upload can never reclaim
    // (or serve) another device's slots. Under the shared account identity the
    // identity half only moves on a reset.
    await this.otpRepo
      .createQueryBuilder()
      .delete()
      .where('"userId" = :userId', { userId })
      .andWhere('"deviceId" = :deviceId', { deviceId })
      .andWhere('used = false')
      .andWhere(
        '("identityPublicKey" IS NULL OR "identityPublicKey" != :identity)',
        { identity: data.identityPublicKey },
      )
      .execute();
    // Phase 0a takeover alarm (spec §6.0): durable audit row for the identity
    // replacement. Written AFTER the upsert so a failed upload never leaves a
    // phantom audit row. An audit-write failure must not fail the upload (that
    // would break E2E setup for the client), but it is loud — the alarm's
    // durability depends on this row.
    if (identityChanged) {
      try {
        await this.identityChangeAuditRepo.insert({
          userId,
          previousIdentityPublicKey: existingBundle.identityPublicKey,
          newIdentityPublicKey: data.identityPublicKey,
        });
      } catch (err) {
        this.logger.error(
          `[identity-churn] audit row insert FAILED`,
          err instanceof Error ? err.stack : String(err),
        );
      }
    }
    this.logger.debug(`Key bundle upserted deviceId=${deviceId}`);
    return {
      identityChanged,
      authorizedBy,
      previousIdentityPublicKey: identityChanged
        ? existingBundle.identityPublicKey
        : null,
    };
  }

  /**
   * Drops every OTHER device's key material after an authorized identity
   * change (§6.2 reset, or a signed rotation).
   *
   * Those devices published keys minted under an identity the account no
   * longer has. Serving such a bundle would tell a peer to encrypt to a key
   * nobody holds — the stale-epoch failure this codebase already paid for,
   * one level up. A surviving device re-uploads under the new identity on its
   * next connect; one that cannot is exactly the device the reset removed.
   */
  private async purgeSupersededDevices(
    userId: number,
    keepDeviceId: number,
  ): Promise<void> {
    const removed = await this.keyBundleRepo
      .createQueryBuilder()
      .delete()
      .where('"userId" = :userId', { userId })
      .andWhere('"deviceId" != :keepDeviceId', { keepDeviceId })
      .execute();
    await this.otpRepo
      .createQueryBuilder()
      .delete()
      .where('"userId" = :userId', { userId })
      .andWhere('"deviceId" != :keepDeviceId', { keepDeviceId })
      .execute();
    if ((removed.affected ?? 0) > 0) {
      this.logger.warn(
        `[identity-churn] dropped ${removed.affected} superseded device bundle(s) keptDeviceId=${keepDeviceId}`,
      );
    }
  }

  /**
   * Drops EXACTLY ONE device's key material — its bundle and its OTPs (spec
   * §5.5: "the revoked device's OTPs are purged"; only that device could
   * complete those handshakes and it is no longer served envelopes).
   *
   * A sibling of {@link purgeSupersededDevices} rather than a widening of it:
   * that one is keyed all-EXCEPT-keep for an identity change, and bending it
   * into "purge exactly this one" would make one method mean two opposite
   * things at two call sites. Both stay narrow.
   *
   * Scoped strictly inside the `(userId, deviceId)` namespace Phase 1 created,
   * which is what makes the §6.2 roster teardown unable to reach a surviving
   * device's material (falsification 12).
   */
  async purgeDeviceMaterial(
    userId: number,
    deviceId: number,
    manager?: EntityManager,
  ): Promise<void> {
    const bundleRepo = manager
      ? manager.getRepository(KeyBundle)
      : this.keyBundleRepo;
    const otpRepo = manager
      ? manager.getRepository(OneTimePreKey)
      : this.otpRepo;
    await bundleRepo.delete({ userId, deviceId });
    await otpRepo.delete({ userId, deviceId });
    this.logger.log(`[devices] purged key material deviceId=${deviceId}`);
  }

  /**
   * Drops ONE device's one-time pre-keys and NOTHING else (amendment
   * (lxxviii) clause 2). After a restore the caller's freshly uploaded bundle
   * is real — the blob carried `ikPriv` and the signed prekey was re-minted —
   * but every OTP row under its device id predates the wipe, so the private
   * halves are gone and serving one would hand a peer an unanswerable X3DH.
   * Deliberately NOT {@link purgeDeviceMaterial}: the bundle row must
   * survive, because the §6.2 teardown MOVES it onto the fresh device id.
   */
  async purgeDeviceOneTimePreKeys(
    userId: number,
    deviceId: number,
  ): Promise<void> {
    const removed = await this.otpRepo.delete({ userId, deviceId });
    this.logger.log(
      `[identity-restore] purged ${removed.affected ?? 0} one-time pre-key(s) deviceId=${deviceId}`,
    );
  }

  /**
   * Decides whether a stored identity key may be replaced (§6.1).
   *
   * Order matters: the signature path is checked first because it is cheap and
   * self-contained, and because consuming a reset ceremony is a side effect
   * that must not happen when a perfectly good signature was supplied.
   *
   * (liv) AN ENROLLED ACCOUNT DOES NOT GET THE SIGNATURE PATH AT ALL. §6.1's
   * signature clause assumed the Phase 0b world where holding `ikPriv` meant
   * being the account's only device. Multi-device deliberately broke that: the
   * §5.1 link blob ships `ikPriv` to EVERY linked device, because a device must
   * sign its own X3DH signed prekey under the account identity. So a
   * compromised linked device could mint a new IK, sign the change with the old
   * one, and take the account identity with no ceremony and no delay — wiping
   * the primary's bundle, which the primary can then never republish (it does
   * not hold the new `ikPriv`). That violates the §2 matrix row "Add/replace a
   * device: L=no" and I2.
   *
   * The gate is here, at ADMISSION, and not on the downstream replacement
   * enrollment: constraining that enrollment would keep list authority with the
   * holder of `dakPriv` while leaving the ACCOUNT IDENTITY — the actual prize —
   * with the attacker. Refusing the identity change makes every later hop
   * unreachable instead.
   *
   * A non-enrolled account is unchanged: one device, one holder of `ikPriv`, so
   * §6.1 still holds there.
   */
  private async authorizeIdentityChange(
    userId: number,
    storedIdentityPublicKey: string,
    newIdentityPublicKey: string,
    enrolled: boolean,
    proof?: IdentityChangeProof,
  ): Promise<IdentityChangeAuthorization> {
    if (enrolled && proof?.signature && proof?.nonce) {
      this.logger.warn(
        `[identity-lock] (liv) signature path REFUSED for an enrolled account — a linked device holds ikPriv, so only a §6.2 ceremony authorizes an identity change`,
      );
    }
    if (!enrolled && proof?.signature && proof?.nonce) {
      const signatureValid = verifyIdentityChangeSignature({
        storedIdentityPublicKey,
        newIdentityPublicKey,
        userId,
        nonce: proof.nonce,
        signature: proof.signature,
      });
      if (signatureValid) return 'signature';
    }
    // No usable signature: only a reset ceremony that already served its full
    // delay can authorize this, and it is spent in the process (single-use).
    return (await this.identityResetService.consumeCompletedReset(userId))
      ? 'reset'
      : null;
  }

  /**
   * Whether the account is ENROLLED — an `account_authorizations` row (the
   * DAK pin, one per account) exists for this userId.
   *
   * Amendment (lxxiii) clause 1 hangs the registration lock off this answer:
   * enrolled means §6.1/§6.2 exactly as before; un-enrolled means the lock is
   * not armed. Also served to the client as `linkingEnabled` on
   * `ownKeyBundleStatus` (clause 2). Existence only — never load the row's
   * key material for a boolean.
   */
  async isEnrolled(userId: number): Promise<boolean> {
    return (
      (await this.authorizationRepo.findOne({
        where: { userId },
        select: { userId: true },
      })) !== null
    );
  }

  /**
   * Read-only existence check for the CALLING DEVICE's public key bundle. This
   * MUST not call fetchPreKeyBundle: fetching atomically consumes a one-time
   * key.
   *
   * Per device on purpose: a device with no bundle of its own has not
   * published anything, whatever its siblings did — and this answer gates key
   * generation on the client (the 0.1.10 invariant).
   */
  async hasKeyBundle(
    userId: number,
    deviceId: number = DEFAULT_DEVICE_ID,
  ): Promise<boolean> {
    return (
      (await this.keyBundleRepo.findOne({ where: { userId, deviceId } })) !==
      null
    );
  }

  /**
   * When this account's identity key was last replaced, or null if never.
   *
   * Read at connect time so a session that was offline when the replacement
   * happened still surfaces it — the durable audit row outlives the live
   * notification, which reaches only sessions connected at that moment.
   */
  async latestIdentityChange(
    userId: number,
  ): Promise<{ at: Date; to: string } | null> {
    const latest = await this.identityChangeAuditRepo.findOne({
      where: { userId },
      order: { createdAt: 'DESC' },
    });
    if (!latest) return null;
    // (lxxx) clause 5: the client needs the key the change ENDED at, not just
    // when it happened. A row whose new key is the caller's own published
    // identity describes something that already landed on the key it holds,
    // so it is not a pending replacement — and a wiped-then-restored install,
    // which has no dismissal watermark left, must not be alarmed by its own
    // history.
    return { at: latest.createdAt, to: latest.newIdentityPublicKey };
  }

  async uploadOneTimePreKeys(
    userId: number,
    keys: OneTimePreKeyData[],
    identityPublicKey?: string,
    deviceId: number = DEFAULT_DEVICE_ID,
    registrationId?: number,
  ): Promise<void> {
    // Untagged OTPs are cryptographic material whose identity epoch cannot be
    // proven. Never infer an epoch from the currently stored bundle: a legacy
    // client can upload an old private half after another device rotated the
    // account identity, creating a false {current identity, stale OTP} pair.
    if (!identityPublicKey) {
      this.logger.warn(
        `Rejected untagged one-time pre-keys reason=identity_epoch_required`,
      );
      throw new Error('identity_epoch_required');
    }

    // The registration lock guards which identity an account PUBLISHES; this
    // guards which identity may deposit key material under it. Without it a
    // session whose bundle the lock just refused still upserts over the
    // legitimate device's keyId slots (proven live 2026-08-18, user 168): the
    // rows are unservable, because `fetchPreKeyBundle` claims only rows tagged
    // with the published identity, but the victim's pool is emptied until a
    // peer fetch triggers `preKeysLow`.
    //
    // Account-scoped comparison (lowest device row) because every device of an
    // account shares one identity key (§3) — a Phase 2 device that has not
    // published its own bundle yet still uploads under the account identity.
    const published = await this.keyBundleRepo.findOne({
      where: { userId },
      order: { deviceId: 'ASC' },
    });
    if (
      published != null &&
      published.identityPublicKey !== identityPublicKey
    ) {
      // Two races are legitimate and must NOT be refused: a first upload whose
      // own bundle has not landed yet (no published row at all, handled above),
      // and an authorized rotation in flight. The enrolled client has stashed
      // its keys until the `keyBundleUploaded` ack since 2026-08-19 (see
      // `ChatKeyExchangeService.handleUploadOneTimePreKeys`), so that race is
      // rare there now, but the branch stays: a COMPLETED, unspent ceremony is
      // the authorization, reading it never spends it (the bundle upload
      // does), and a merely PENDING ceremony authorizes nothing — the countdown
      // exists so the owner can cancel it.
      const reset = await this.identityResetService.getStatusForUser(userId);
      // (lxxiii) clause 1 — the OTP site is exempted for an UN-ENROLLED
      // account too: pre-2026-08-19 clients still emit bundle + OTPs back to
      // back and the keys can land first, so refusing here would strand an
      // un-enrolled remint without its OTP batch — the (lxiv) pool-loss shape
      // for no gain.
      if (reset?.status !== 'completed' && (await this.isEnrolled(userId))) {
        this.logger.warn(
          `[identity-lock] REFUSED one-time pre-keys under an unpublished identity deviceId=${deviceId} publishedPrefix=${published.identityPublicKey.slice(0, 12)} attemptedPrefix=${identityPublicKey.slice(0, 12)}`,
        );
        throw new IdentityLockedError();
      }
    }

    // (lxiv) clause 1, OTP half: the bundle guard alone does not close the
    // mixed-halves loss — a foreign install sharing the account identity could
    // still deposit ITS one-time pre-keys into this device's pool via the
    // `preKeysLow` replenishment path, and a peer fetch would then mix the
    // owner's signedPreKey with the foreigner's OTP. When the caller proves
    // its install (new clients always do), the proof must match the row.
    if (registrationId != null) {
      const ownRow =
        published != null && published.deviceId === deviceId
          ? published
          : await this.keyBundleRepo.findOne({ where: { userId, deviceId } });
      if (
        ownRow != null &&
        ownRow.identityPublicKey === identityPublicKey &&
        ownRow.registrationId !== registrationId
      ) {
        this.logger.warn(
          `[device-material-conflict] REFUSED one-time pre-keys from foreign install deviceId=${deviceId} stored=${ownRow.registrationId} attempted=${registrationId}`,
        );
        throw new DeviceMaterialConflictError();
      }
    }

    // UPSERT on (userId, deviceId, keyId): a regenerated epoch reuses keyId
    // slots 0..N, so refresh this device's existing row rather than piling up
    // duplicates — and never touch the identically-numbered slot of another
    // device, which holds a different private half.
    await this.otpRepo.upsert(
      keys.map((k) => ({
        userId,
        deviceId,
        keyId: k.keyId,
        publicKey: k.publicKey,
        identityPublicKey,
        used: false,
      })),
      { conflictPaths: ['userId', 'deviceId', 'keyId'] },
    );
    this.logger.debug(
      `Uploaded ${keys.length} one-time pre-keys deviceId=${deviceId}`,
    );
  }

  async fetchPreKeyBundle(
    userId: number,
    deviceId: number = DEFAULT_DEVICE_ID,
  ): Promise<PreKeyBundleResponse | null> {
    // No fallback to another device: serving device 1's bundle for a device
    // that never published one would build a session that device cannot
    // decrypt. Absent means absent.
    const bundle = await this.keyBundleRepo.findOne({
      where: { userId, deviceId },
    });
    if (!bundle) return null;

    // Atomic claim: UPDATE ... WHERE id = (SELECT id ... LIMIT 1) RETURNING *
    // Prevents a race where two concurrent calls serve the same OTP.
    //
    // The "identityPublicKey" = $2 filter is the DURABLE fix for the stale-OTP
    // bad-MAC wave (2026-07-11): only claim OTPs minted under the CURRENT
    // identity epoch. A row from a superseded epoch (whose private half the
    // device discarded on regeneration) or an untagged legacy row is never
    // served, so PreKey/X3DH can never build on a dead key. Safe regardless of
    // upload order — the tag, not timing, decides. See the identity-epoch
    // invariant note in upsertKeyBundle; fail-closed pinned by the unit spec.
    //
    // The "deviceId" = $3 half is the Phase 1 re-key: one device's claim must
    // never consume the keyId slot another device minted.
    //
    // Postgres repo.query() returns [rows, rowCount] for UPDATE ... RETURNING
    // (see backend/CLAUDE.md §4) — destructuring the row directly reads the
    // rows ARRAY and silently serves oneTimePreKey* as null while still
    // burning the OTP (used=true). Caught by the test_e2e wire harness.
    const [rows] = (await this.otpRepo.query(
      `UPDATE one_time_pre_keys
         SET used = true
       WHERE id = (
         SELECT id FROM one_time_pre_keys
         WHERE "userId" = $1 AND used = false AND "identityPublicKey" = $2
           AND "deviceId" = $3
         ORDER BY id ASC
         LIMIT 1
       )
       RETURNING id, "keyId", "publicKey"`,
      [userId, bundle.identityPublicKey, deviceId],
    )) as [Array<{ id: number; keyId: number; publicKey: string }>, number];
    const otp = rows[0];

    if (!otp) {
      this.logger.warn(
        `OTP exhausted deviceId=${deviceId}: serving bundle without one-time pre-key`,
      );
    }

    return {
      registrationId: bundle.registrationId,
      identityPublicKey: bundle.identityPublicKey,
      signedPreKeyId: bundle.signedPreKeyId,
      signedPreKeyPublic: bundle.signedPreKeyPublic,
      signedPreKeySignature: bundle.signedPreKeySignature,
      oneTimePreKeyId: otp?.keyId ?? null,
      oneTimePreKeyPublic: otp?.publicKey ?? null,
    };
  }

  async countUnusedPreKeys(
    userId: number,
    deviceId: number = DEFAULT_DEVICE_ID,
  ): Promise<number> {
    // Count only the CURRENT epoch of THIS device — stale rows from a
    // superseded identity are never served, and another device's rows are not
    // this device's to spend, so neither may inflate the count and suppress
    // the preKeysLow replenishment signal.
    const bundle = await this.keyBundleRepo.findOne({
      where: { userId, deviceId },
    });
    if (!bundle) return 0;
    return this.otpRepo.count({
      where: {
        userId,
        deviceId,
        used: false,
        identityPublicKey: bundle.identityPublicKey,
      },
    });
  }

  async deleteByUserId(userId: number): Promise<void> {
    await this.otpRepo.delete({ userId });
    await this.keyBundleRepo.delete({ userId });
    this.logger.log(`Deleted all key data`);
  }
}
