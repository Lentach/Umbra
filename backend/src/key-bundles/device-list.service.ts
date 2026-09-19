import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { EntityManager, Repository } from 'typeorm';
import { AccountAuthorization } from './account-authorization.entity';
import { KeyBundle } from './key-bundle.entity';
import { DevicesService } from './devices.service';
import {
  CanonicalDeviceListError,
  parseCanonicalDeviceList,
} from './device-list-canonical.util';
import {
  verifyDeviceListSignature,
  verifyEnrollmentSignature,
} from './device-list-signature.util';

/** Postgres unique-violation SQLSTATE — the first-write-wins signal. */
const PG_UNIQUE_VIOLATION = '23505';

/**
 * TypeORM surfaces the Postgres SQLSTATE either directly or under
 * `driverError` depending on the failing call — same dual shape
 * `conversations.service.ts` handles. Runtime-narrowed, no shape assertions.
 */
function isUniqueViolation(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  if ('code' in error && error.code === PG_UNIQUE_VIOLATION) return true;
  if ('driverError' in error) {
    const driverError: unknown = error.driverError;
    return (
      typeof driverError === 'object' &&
      driverError !== null &&
      'code' in driverError &&
      driverError.code === PG_UNIQUE_VIOLATION
    );
  }
  return false;
}

export type DeviceListRejection =
  | 'no_published_identity'
  | 'invalid_enrollment_signature'
  | 'invalid_canonical'
  | 'canonical_user_mismatch'
  | 'enrollment_version_must_be_1'
  | 'invalid_list_signature'
  | 'already_enrolled'
  | 'not_enrolled'
  | 'stale_version';

/**
 * Thrown for every refused enrollment/mutation. Nothing is written when this
 * is thrown — a refusal never leaves partial state.
 */
export class DeviceListRejectedError extends Error {
  constructor(public readonly code: DeviceListRejection) {
    super(code);
    this.name = 'DeviceListRejectedError';
  }
}

export interface EnrollmentInput {
  /** base64, 33 bytes. */
  dakPub: string;
  /** base64, 64 bytes — sig_IK over the "fp-enroll-v1\0" construction. */
  enrollmentSig: string;
  /** Integer milliseconds since epoch, exactly as signed. */
  createdAt: number;
  /** Opaque base64 canonical bytes of the v1 list. */
  listCanonical: string;
  /** base64, 64 bytes — sig_DAK over the "fp-list-v1\0" construction. */
  listSignature: string;
}

export interface ListUpdateInput {
  listCanonical: string;
  listSignature: string;
}

/**
 * The DAK-signed device list (Phase 2 T2, spec §3/§5.2 + §12 amendments
 * (d)/(g)).
 *
 * The server STORES and SERVES the enrollment + list but can mint none of it
 * (I1/I2): every write is gated on signatures only the client-side keys can
 * produce, and `listCanonical` is stored byte-exact as the opaque base64 the
 * client signed (§3 transport rule — falsification 23). Peers verify the full
 * chain themselves (I7); the checks here are the server-side liveness gate,
 * not the trust anchor.
 */
@Injectable()
export class DeviceListService {
  private readonly logger = new Logger(DeviceListService.name);

  constructor(
    @InjectRepository(AccountAuthorization)
    private readonly authorizationRepo: Repository<AccountAuthorization>,
    @InjectRepository(KeyBundle)
    private readonly keyBundleRepo: Repository<KeyBundle>,
    private readonly devicesService: DevicesService,
  ) {}

  /**
   * Does this account owe a REPLACEMENT enrollment, and at what version
   * (amendment (xlv))? Null when it does not.
   *
   * One predicate, two consumers, deliberately: the roster guard of clause 2
   * and the retry offer of clause 1 must never disagree about whether an
   * account is addressable, or the server would refuse to serve a list while
   * telling nobody how to repair it.
   *
   * Two ways a completed §6.2 reset leaves an account un-addressable, and
   * they need different tests because ONLY the second leaves a row behind:
   *
   *  - Never enrolled. No row, so peers synthesize the single device 1 a
   *    non-enrolled account has by construction — which the teardown revoked.
   *    Its replacement is a FIRST enrollment, so version 1. An account with
   *    no live device at all is offline or deleted, not this defect.
   *  - Previously enrolled. The row survives ((xxix)) but its enrollment
   *    record no longer verifies under the account's CURRENT published
   *    identity, and ONLY an identity change can orphan it. Its replacement
   *    must advance past the surviving version.
   */
  async pendingReplacementVersion(userId: number): Promise<number | null> {
    const published = await this.keyBundleRepo.findOne({
      where: { userId },
      order: { deviceId: 'ASC' },
    });
    if (!published) return null;

    const stored = await this.authorizationRepo.findOne({ where: { userId } });
    if (!stored) {
      const live = (await this.devicesService.listForUser(userId)).filter(
        (d) => d.revokedAt == null,
      );
      const addressable = live.length === 0 || live.some((d) => d.deviceId === 1);
      return addressable ? null : 1;
    }

    const stillValid = verifyEnrollmentSignature({
      identityPublicKey: published.identityPublicKey,
      userId,
      dakPub: stored.dakPub,
      createdAtMs: stored.enrollmentCreatedAt.getTime(),
      signature: stored.enrollmentSig,
    });
    return stillValid ? null : stored.listVersion + 1;
  }

  /**
   * Validates the canonical base64 transport form and the bytes behind it.
   * Returns the decoded bytes; the STRING is what gets stored, so it must
   * round-trip to the same bytes (a non-canonical base64 form would break the
   * byte-exact serve).
   */
  private decodeCanonical(listCanonical: string): Buffer {
    let canonical: Buffer;
    try {
      canonical = Buffer.from(listCanonical, 'base64');
      if (canonical.toString('base64') !== listCanonical) {
        throw new CanonicalDeviceListError('non-canonical base64');
      }
      parseCanonicalDeviceList(canonical);
    } catch (error) {
      if (error instanceof CanonicalDeviceListError) {
        this.logger.warn(
          `[device-list] canonical rejected at parse: ${error.reason}`,
        );
        throw new DeviceListRejectedError('invalid_canonical');
      }
      throw error;
    }
    return canonical;
  }

  /**
   * Enrolls the account's device authorization: pins the DAK via the
   * IK-signed record E plus the DAK-signed v1 list, FIRST-WRITE-WINS (I2 —
   * the authority is born once and changes only via rotation §6.3 or reset
   * §6.2, neither of which is T2). A second enrollment is refused loudly,
   * never overwritten.
   */
  async enroll(userId: number, input: EnrollmentInput): Promise<void> {
    // The account's PUBLISHED identity — the same account-scoped lookup the
    // §6.1 lock uses (every device shares one IK, spec §3).
    const published = await this.keyBundleRepo.findOne({
      where: { userId },
      order: { deviceId: 'ASC' },
    });
    if (!published) {
      throw new DeviceListRejectedError('no_published_identity');
    }

    if (
      !verifyEnrollmentSignature({
        identityPublicKey: published.identityPublicKey,
        userId,
        dakPub: input.dakPub,
        createdAtMs: input.createdAt,
        signature: input.enrollmentSig,
      })
    ) {
      this.logger.warn(
        `[device-list] REFUSED enrollment with invalid E signature`,
      );
      throw new DeviceListRejectedError('invalid_enrollment_signature');
    }

    const canonical = this.decodeCanonical(input.listCanonical);
    const list = parseCanonicalDeviceList(canonical);
    if (list.userId !== userId) {
      throw new DeviceListRejectedError('canonical_user_mismatch');
    }
    // Read the stored record before the version rule, because which rule
    // applies depends on whether this is a FIRST enrollment or the (xxix)
    // replacement of an orphaned one.
    const stored = await this.authorizationRepo.findOne({ where: { userId } });
    if (!stored && list.version !== 1) {
      // A first enrollment IS version 1 by definition; later versions arrive
      // via signed mutations.
      throw new DeviceListRejectedError('enrollment_version_must_be_1');
    }

    if (
      !verifyDeviceListSignature({
        dakPub: input.dakPub,
        canonical,
        signature: input.listSignature,
      })
    ) {
      this.logger.warn(
        `[device-list] REFUSED enrollment with invalid list signature`,
      );
      throw new DeviceListRejectedError('invalid_list_signature');
    }

    // First-write-wins (I2), with ONE admitted exception: an enrollment whose
    // STORED record no longer verifies under the account's CURRENT published
    // identity is orphaned, and only an identity change can orphan it (§6.2
    // reset — spec §12 amendment (xxix)). Replacing it keeps `listVersion`
    // MONOTONIC, which is why the row is replaced and never dropped: dropping
    // it would restart versions at 1 and make the account read as
    // not-enrolled, which the (xix) rollback pin correctly refuses.
    if (stored) {
      const storedStillValid = verifyEnrollmentSignature({
        identityPublicKey: published.identityPublicKey,
        userId,
        dakPub: stored.dakPub,
        createdAtMs: stored.enrollmentCreatedAt.getTime(),
        signature: stored.enrollmentSig,
      });
      if (storedStillValid) {
        this.logger.warn(
          `[device-list] REFUSED second enrollment (first-write-wins)`,
        );
        throw new DeviceListRejectedError('already_enrolled');
      }
      if (list.version <= stored.listVersion) {
        this.logger.warn(
          `[device-list] REFUSED replacement enrollment at a non-advancing version version=${list.version} stored=${stored.listVersion}`,
        );
        throw new DeviceListRejectedError('stale_version');
      }
      // CAS on the retired version: two concurrent replacements serialize and
      // the loser is refused rather than silently regressing the version.
      // repo.query() returns [rows, rowCount] for UPDATE (backend/CLAUDE.md §4).
      const [, rowCount] = await this.authorizationRepo.query<
        [unknown[], number]
      >(
        `UPDATE account_authorizations
            SET "dakPub" = $1, "enrollmentSig" = $2, "enrollmentCreatedAt" = $3,
                "listCanonical" = $4, "listSignature" = $5, "listVersion" = $6,
                "updatedAt" = now()
          WHERE "userId" = $7 AND "listVersion" < $6`,
        [
          input.dakPub,
          input.enrollmentSig,
          new Date(input.createdAt),
          input.listCanonical,
          input.listSignature,
          list.version,
          userId,
        ],
      );
      if (rowCount !== 1) {
        throw new DeviceListRejectedError('stale_version');
      }
      this.logger.warn(
        `[device-list] REPLACED orphaned enrollment after an identity change version=${list.version}`,
      );
      return;
    }

    try {
      // Plain INSERT: the userId PRIMARY KEY makes first-write-wins atomic —
      // a concurrent duplicate loses on the constraint, never overwrites.
      await this.authorizationRepo.insert({
        userId,
        dakPub: input.dakPub,
        enrollmentSig: input.enrollmentSig,
        enrollmentCreatedAt: new Date(input.createdAt),
        listVersion: 1,
        listSignature: input.listSignature,
        listCanonical: input.listCanonical,
      });
    } catch (error) {
      if (isUniqueViolation(error)) {
        this.logger.warn(
          `[device-list] REFUSED second enrollment (first-write-wins)`,
        );
        throw new DeviceListRejectedError('already_enrolled');
      }
      throw error;
    }
    this.logger.log(`[device-list] enrolled version=1`);
  }

  /**
   * Applies a DAK-signed list mutation: parse-clean canonical, signature by
   * the ENROLLED DAK (an IK-signed mutation dies here by construction —
   * falsification 2), and strictly increasing version (rollback/replay is
   * falsification 3's loud refusal). T3's provisioning commit and T6's
   * revocation route their list writes through this same gate.
   *
   * `manager` (optional) makes the write participate in a caller-owned
   * transaction — the T3 provisioning commit writes the devices row and this
   * mutation atomically (§5.1 two-phase commit). Default behavior without it
   * is unchanged.
   *
   * Returns the accepted version.
   */
  async applySignedListUpdate(
    userId: number,
    input: ListUpdateInput,
    manager?: EntityManager,
  ): Promise<number> {
    const repo = manager
      ? manager.getRepository(AccountAuthorization)
      : this.authorizationRepo;
    const stored = await repo.findOne({ where: { userId } });
    if (!stored) {
      throw new DeviceListRejectedError('not_enrolled');
    }

    const canonical = this.decodeCanonical(input.listCanonical);
    const list = parseCanonicalDeviceList(canonical);
    if (list.userId !== userId) {
      throw new DeviceListRejectedError('canonical_user_mismatch');
    }

    if (
      !verifyDeviceListSignature({
        dakPub: stored.dakPub,
        canonical,
        signature: input.listSignature,
      })
    ) {
      this.logger.warn(
        `[device-list] REFUSED mutation with invalid list signature version=${list.version}`,
      );
      throw new DeviceListRejectedError('invalid_list_signature');
    }

    if (list.version <= stored.listVersion) {
      this.logger.warn(
        `[device-list] REFUSED stale/rollback mutation version=${list.version} stored=${stored.listVersion}`,
      );
      throw new DeviceListRejectedError('stale_version');
    }

    // Atomic compare-and-set: the WHERE re-checks monotonicity so two
    // concurrent valid updates commit in some serial order and the loser is
    // refused instead of silently regressing the version.
    // repo.query() returns [rows, rowCount] for UPDATE (backend/CLAUDE.md §4).
    const [, rowCount] = await repo.query<[unknown[], number]>(
      `UPDATE account_authorizations
         SET "listCanonical" = $1, "listSignature" = $2, "listVersion" = $3,
             "updatedAt" = now()
       WHERE "userId" = $4 AND "listVersion" < $3`,
      [input.listCanonical, input.listSignature, list.version, userId],
    );
    if (rowCount !== 1) {
      this.logger.warn(
        `[device-list] REFUSED concurrent stale mutation version=${list.version}`,
      );
      throw new DeviceListRejectedError('stale_version');
    }
    this.logger.log(`[device-list] updated version=${list.version}`);
    return list.version;
  }

  /**
   * The stored enrollment + current signed list, or null when the account
   * never enrolled. Served to ANY authenticated caller: peers need the full
   * record to run the I7 chain themselves.
   */
  async getAuthorization(userId: number): Promise<AccountAuthorization | null> {
    return this.authorizationRepo.findOne({ where: { userId } });
  }
}
