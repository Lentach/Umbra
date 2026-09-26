import {
  DeviceListRejectedError,
  DeviceListService,
} from './device-list.service';
import { DEVICE_LIST_VECTOR as V } from './device-list-signature.vectors';

/**
 * Server-side gate of the DAK-signed device list (Phase 2 T2). Signatures are
 * the REAL Dart-client vectors (see device-list-signature.util.spec.ts) —
 * this spec covers the service's own laws: first-write-wins enrollment (I2),
 * version monotonicity with an atomic CAS (falsification 3), byte-exact
 * storage of the client's base64 (falsification 23), and the published-
 * identity gate. The wire harness proves the same laws over a live socket +
 * Postgres.
 */

interface AuthRepoMock {
  findOne: jest.Mock;
  find: jest.Mock;
  insert: jest.Mock;
  query: jest.Mock;
}

describe('DeviceListService', () => {
  let authRepo: AuthRepoMock;
  let keyBundleRepo: { findOne: jest.Mock; find: jest.Mock };
  let devicesService: { listForUser: jest.Mock; listLiveForUsers: jest.Mock };
  let service: DeviceListService;

  const enrollment = () => ({
    dakPub: V.dakPub,
    enrollmentSig: V.enrollmentSig,
    createdAt: V.createdAtMs,
    listCanonical: V.listCanonical,
    listSignature: V.listSignature,
  });

  const storedRow = () => ({
    userId: V.userId,
    dakPub: V.dakPub,
    enrollmentSig: V.enrollmentSig,
    enrollmentCreatedAt: new Date(V.createdAtMs),
    listVersion: 1,
    listSignature: V.listSignature,
    listCanonical: V.listCanonical,
  });

  beforeEach(() => {
    authRepo = {
      findOne: jest.fn(),
      find: jest.fn().mockResolvedValue([]),
      insert: jest.fn().mockResolvedValue(undefined),
      // repo.query() returns [rows, rowCount] for UPDATE (backend/CLAUDE.md
      // §4) — the mock MUST return the tuple shape or it hides the exact bug
      // class the OTP claim shipped with.
      query: jest.fn().mockResolvedValue([[], 1]),
    };
    keyBundleRepo = {
      findOne: jest
        .fn()
        .mockResolvedValue({ identityPublicKey: V.identityPublicKey }),
      find: jest.fn().mockResolvedValue([]),
    };
    // Only `pendingReplacementVersion` (xlv) consults the roster; the enroll
    // paths under test here never reach it. An account whose live device IS
    // device 1 is the ordinary shape and keeps that method's answer null.
    devicesService = {
      listForUser: jest
        .fn()
        .mockResolvedValue([{ deviceId: 1, revokedAt: null }]),
      listLiveForUsers: jest.fn().mockResolvedValue([]),
    };
    service = new DeviceListService(
      authRepo as never,
      keyBundleRepo as never,
      devicesService as never,
    );
  });

  describe('enroll (first-write-wins, I2)', () => {
    it('verifies both signatures against the PUBLISHED identity and stores the exact base64', async () => {
      await service.enroll(V.userId, enrollment());

      // Account-scoped identity lookup, same as the §6.1 lock.
      expect(keyBundleRepo.findOne).toHaveBeenCalledWith({
        where: { userId: V.userId },
        order: { deviceId: 'ASC' },
      });
      expect(authRepo.insert).toHaveBeenCalledWith({
        userId: V.userId,
        dakPub: V.dakPub,
        enrollmentSig: V.enrollmentSig,
        enrollmentCreatedAt: new Date(V.createdAtMs),
        listVersion: 1,
        listSignature: V.listSignature,
        // BYTE-EXACT: the stored string is the client's base64 verbatim.
        listCanonical: V.listCanonical,
      });
    });

    it('refuses when the account has no published identity', async () => {
      keyBundleRepo.findOne.mockResolvedValue(null);
      await expect(service.enroll(V.userId, enrollment())).rejects.toThrow(
        new DeviceListRejectedError('no_published_identity'),
      );
      expect(authRepo.insert).not.toHaveBeenCalled();
    });

    it('refuses an enrollment signature made by a DIFFERENT identity', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        identityPublicKey: V.lockNewIdentityPublicKey,
      });
      await expect(service.enroll(V.userId, enrollment())).rejects.toThrow(
        new DeviceListRejectedError('invalid_enrollment_signature'),
      );
    });

    it('refuses a second enrollment on the unique violation, loudly, never overwriting', async () => {
      authRepo.insert.mockRejectedValue(
        Object.assign(new Error('duplicate key'), {
          driverError: { code: '23505' },
        }),
      );
      await expect(service.enroll(V.userId, enrollment())).rejects.toThrow(
        new DeviceListRejectedError('already_enrolled'),
      );
    });

    it('propagates a non-constraint insert failure unchanged', async () => {
      authRepo.insert.mockRejectedValue(new Error('connection terminated'));
      await expect(service.enroll(V.userId, enrollment())).rejects.toThrow(
        'connection terminated',
      );
    });

    it('refuses a canonical whose userId is not the caller', async () => {
      // The pinned canonical carries userId 4242; enroll as 17.
      keyBundleRepo.findOne.mockResolvedValue({
        identityPublicKey: V.identityPublicKey,
      });
      await expect(service.enroll(17, enrollment())).rejects.toThrow(
        DeviceListRejectedError,
      );
      expect(authRepo.insert).not.toHaveBeenCalled();
    });

    it('refuses an enrollment list at version > 1', async () => {
      await expect(
        service.enroll(V.userId, {
          ...enrollment(),
          listCanonical: V.v2ListCanonical,
          listSignature: V.v2ListSignature,
        }),
      ).rejects.toThrow(
        new DeviceListRejectedError('enrollment_version_must_be_1'),
      );
    });

    it('refuses a duplicate-key canonical AT PARSE (falsification 23)', async () => {
      const ambiguous = Buffer.from(
        `{"userId":${V.userId},"version":1,"version":1,"devices":[]}`,
        'utf8',
      ).toString('base64');
      await expect(
        service.enroll(V.userId, { ...enrollment(), listCanonical: ambiguous }),
      ).rejects.toThrow(new DeviceListRejectedError('invalid_canonical'));
    });

    it('refuses a non-canonical base64 transport form', async () => {
      // Same bytes, whitespace-broken base64: storing this string would break
      // the byte-exact serve.
      const broken = `${V.listCanonical.slice(0, 10)} ${V.listCanonical.slice(10)}`;
      await expect(
        service.enroll(V.userId, { ...enrollment(), listCanonical: broken }),
      ).rejects.toThrow(new DeviceListRejectedError('invalid_canonical'));
    });

    describe('replacement after an identity change (amendment (xxix))', () => {
      /**
       * A stored record whose enrollment signature no longer verifies under
       * the account's CURRENT published identity — which is exactly what a
       * §6.2 reset leaves behind, since `E` was signed by the replaced IK.
       * Modelled by a stored `dakPub` the signature does not cover.
       */
      const orphanedRow = (listVersion = 1) => ({
        ...storedRow(),
        dakPub: 'orphaned-dak-pub',
        listVersion,
      });

      const replacement = () => ({
        ...enrollment(),
        listCanonical: V.v2ListCanonical,
        listSignature: V.v2ListSignature,
      });

      it('REPLACES the orphaned row and CONTINUES the version, never restarting at 1', async () => {
        authRepo.findOne.mockResolvedValue(orphanedRow(1));

        await service.enroll(V.userId, replacement());

        // Never an insert: the row must survive so listVersion is monotonic
        // across the reset ((f)(iii)).
        expect(authRepo.insert).not.toHaveBeenCalled();
        const [sql, params] = authRepo.query.mock.calls[0] as [
          string,
          unknown[],
        ];
        expect(sql).toContain('UPDATE account_authorizations');
        // CAS on the retired version, so two concurrent replacements
        // serialize instead of regressing it.
        expect(sql).toContain('"listVersion" < $6');
        expect(params).toEqual([
          V.dakPub,
          V.enrollmentSig,
          new Date(V.createdAtMs),
          V.v2ListCanonical,
          V.v2ListSignature,
          2,
          V.userId,
        ]);
      });

      it('still refuses a second enrollment while the stored record VERIFIES', async () => {
        // The exception is narrow: only an orphaned record may be replaced, so
        // a live account keeps first-write-wins (I2).
        authRepo.findOne.mockResolvedValue(storedRow());

        await expect(service.enroll(V.userId, replacement())).rejects.toThrow(
          new DeviceListRejectedError('already_enrolled'),
        );
        expect(authRepo.query).not.toHaveBeenCalled();
      });

      it('refuses a replacement that does not ADVANCE the version', async () => {
        authRepo.findOne.mockResolvedValue(orphanedRow(2));

        await expect(service.enroll(V.userId, replacement())).rejects.toThrow(
          new DeviceListRejectedError('stale_version'),
        );
        expect(authRepo.query).not.toHaveBeenCalled();
      });

      it('refuses when the CAS matched no row (a concurrent replacement won)', async () => {
        authRepo.findOne.mockResolvedValue(orphanedRow(1));
        authRepo.query.mockResolvedValue([[], 0]);

        await expect(service.enroll(V.userId, replacement())).rejects.toThrow(
          new DeviceListRejectedError('stale_version'),
        );
      });

      it('keeps the version-must-be-1 rule for a genuine FIRST enrollment', async () => {
        authRepo.findOne.mockResolvedValue(null);

        await expect(service.enroll(V.userId, replacement())).rejects.toThrow(
          new DeviceListRejectedError('enrollment_version_must_be_1'),
        );
      });
    });
  });

  describe('applySignedListUpdate (monotonic versions, falsification 3)', () => {
    it('accepts a valid v2 signed by the ENROLLED DAK via an atomic CAS', async () => {
      authRepo.findOne.mockResolvedValue(storedRow());
      await expect(
        service.applySignedListUpdate(V.userId, {
          listCanonical: V.v2ListCanonical,
          listSignature: V.v2ListSignature,
        }),
      ).resolves.toBe(2);
      const [sql, params] = authRepo.query.mock.calls[0] as [string, unknown[]];
      expect(sql).toContain('"listVersion" < $3');
      expect(params).toEqual([
        V.v2ListCanonical,
        V.v2ListSignature,
        2,
        V.userId,
      ]);
    });

    it('refuses when the account never enrolled', async () => {
      authRepo.findOne.mockResolvedValue(null);
      await expect(
        service.applySignedListUpdate(V.userId, {
          listCanonical: V.v2ListCanonical,
          listSignature: V.v2ListSignature,
        }),
      ).rejects.toThrow(new DeviceListRejectedError('not_enrolled'));
    });

    it('refuses a replay/rollback: version <= stored (falsification 3)', async () => {
      authRepo.findOne.mockResolvedValue({ ...storedRow(), listVersion: 2 });
      await expect(
        service.applySignedListUpdate(V.userId, {
          listCanonical: V.v2ListCanonical,
          listSignature: V.v2ListSignature,
        }),
      ).rejects.toThrow(new DeviceListRejectedError('stale_version'));
      expect(authRepo.query).not.toHaveBeenCalled();
    });

    it('refuses when the CAS loses a concurrent race (rowCount 0)', async () => {
      authRepo.findOne.mockResolvedValue(storedRow());
      authRepo.query.mockResolvedValue([[], 0]);
      await expect(
        service.applySignedListUpdate(V.userId, {
          listCanonical: V.v2ListCanonical,
          listSignature: V.v2ListSignature,
        }),
      ).rejects.toThrow(new DeviceListRejectedError('stale_version'));
    });

    it('refuses a signature by anything but the enrolled DAK (falsification 2)', async () => {
      // The stored DAK is the identity key here — the vector list signature
      // no longer verifies, exactly like an IK-signed mutation.
      authRepo.findOne.mockResolvedValue({
        ...storedRow(),
        dakPub: V.identityPublicKey,
      });
      await expect(
        service.applySignedListUpdate(V.userId, {
          listCanonical: V.v2ListCanonical,
          listSignature: V.v2ListSignature,
        }),
      ).rejects.toThrow(new DeviceListRejectedError('invalid_list_signature'));
      expect(authRepo.query).not.toHaveBeenCalled();
    });

    it('refuses a cross-construction signature: enrollment sig as list sig (falsification 25)', async () => {
      authRepo.findOne.mockResolvedValue(storedRow());
      await expect(
        service.applySignedListUpdate(V.userId, {
          listCanonical: V.v2ListCanonical,
          listSignature: V.enrollmentSig,
        }),
      ).rejects.toThrow(new DeviceListRejectedError('invalid_list_signature'));
    });
  });

  describe('getAuthorization', () => {
    it('returns the stored row untouched (serve-byte-exact upstream)', async () => {
      const row = storedRow();
      authRepo.findOne.mockResolvedValue(row);
      await expect(service.getAuthorization(V.userId)).resolves.toBe(row);
    });

    it('returns null for a never-enrolled account', async () => {
      authRepo.findOne.mockResolvedValue(null);
      await expect(service.getAuthorization(V.userId)).resolves.toBeNull();
    });
  });

  // The one predicate behind BOTH (xlv) clauses: clause 2 refuses a roster on
  // it, clause 1 re-offers the replacement terms on it. They must never
  // disagree, which is why there is only one.
  describe('pendingReplacementVersion ((xlv))', () => {
    it('owes NOTHING for an ordinary un-enrolled account that really is device 1', async () => {
      authRepo.findOne.mockResolvedValue(null);
      await expect(
        service.pendingReplacementVersion(V.userId),
      ).resolves.toBeNull();
    });

    it('owes a FIRST enrollment when an un-enrolled account has lost device 1', async () => {
      authRepo.findOne.mockResolvedValue(null);
      devicesService.listForUser.mockResolvedValue([
        { deviceId: 1, revokedAt: new Date() },
        { deviceId: 2, revokedAt: null },
      ]);
      // The post-reset never-enrolled shape: peers would synthesize a device 1
      // that no longer exists.
      await expect(service.pendingReplacementVersion(V.userId)).resolves.toBe(
        1,
      );
    });

    it('owes nothing when NO device is live — offline or deleted, not this defect', async () => {
      authRepo.findOne.mockResolvedValue(null);
      devicesService.listForUser.mockResolvedValue([
        { deviceId: 1, revokedAt: new Date() },
      ]);
      await expect(
        service.pendingReplacementVersion(V.userId),
      ).resolves.toBeNull();
    });

    it('owes nothing while the stored enrollment still verifies', async () => {
      authRepo.findOne.mockResolvedValue(storedRow());
      await expect(
        service.pendingReplacementVersion(V.userId),
      ).resolves.toBeNull();
    });

    it('owes stored+1 once an identity change has ORPHANED the row', async () => {
      authRepo.findOne.mockResolvedValue({ ...storedRow(), listVersion: 6 });
      // Only an identity change can orphan an enrollment, and §6.2 is the one
      // that also revokes every device the row names.
      keyBundleRepo.findOne.mockResolvedValue({
        identityPublicKey: V.lockNewIdentityPublicKey,
      });
      await expect(service.pendingReplacementVersion(V.userId)).resolves.toBe(
        7,
      );
    });
  });

  // The friends list asks (xlv) for every friend at once; the batch must answer
  // exactly what `pendingReplacementVersion` answers for each account, in a
  // fixed number of queries however many friends there are.
  describe('pendingReplacementUserIds (batch of (xlv))', () => {
    const ENROLLED = V.userId;
    const ORPHANED = V.userId + 1;
    const LOST_DEVICE_1 = V.userId + 2;
    const ORDINARY = V.userId + 3;
    const NO_BUNDLE = V.userId + 4;
    const NOTHING_LIVE = V.userId + 5;

    it('names exactly the accounts that owe a replacement, in three queries', async () => {
      keyBundleRepo.find.mockResolvedValue([
        // Lowest device first per account, as ordered: its identity decides.
        {
          userId: ENROLLED,
          deviceId: 1,
          identityPublicKey: V.identityPublicKey,
        },
        { userId: ENROLLED, deviceId: 2, identityPublicKey: 'ignored' },
        {
          userId: ORPHANED,
          deviceId: 2,
          identityPublicKey: V.lockNewIdentityPublicKey,
        },
        { userId: LOST_DEVICE_1, deviceId: 1, identityPublicKey: 'ik' },
        { userId: ORDINARY, deviceId: 1, identityPublicKey: 'ik' },
        { userId: NOTHING_LIVE, deviceId: 1, identityPublicKey: 'ik' },
      ]);
      authRepo.find.mockResolvedValue([
        storedRow(),
        { ...storedRow(), userId: ORPHANED, listVersion: 6 },
      ]);
      devicesService.listLiveForUsers.mockResolvedValue([
        { userId: LOST_DEVICE_1, deviceId: 2, revokedAt: null },
        { userId: ORDINARY, deviceId: 1, revokedAt: null },
      ]);

      const owed = await service.pendingReplacementUserIds([
        ENROLLED,
        ORPHANED,
        LOST_DEVICE_1,
        ORDINARY,
        NO_BUNDLE,
        NOTHING_LIVE,
      ]);

      expect(owed).toEqual(new Set([ORPHANED, LOST_DEVICE_1]));
      expect(keyBundleRepo.find).toHaveBeenCalledTimes(1);
      expect(authRepo.find).toHaveBeenCalledTimes(1);
      // The roster matters only to an account with no enrollment row.
      expect(devicesService.listLiveForUsers.mock.calls).toEqual([
        [[LOST_DEVICE_1, ORDINARY, NOTHING_LIVE]],
      ]);
    });

    it('asks nothing for an empty batch', async () => {
      await expect(service.pendingReplacementUserIds([])).resolves.toEqual(
        new Set(),
      );
      expect(keyBundleRepo.find).not.toHaveBeenCalled();
    });
  });
});
