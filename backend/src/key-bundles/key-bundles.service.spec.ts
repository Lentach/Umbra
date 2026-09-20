import { Logger } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { generateKeyPair, sign } from 'curve25519-js';
import { KeyBundlesService, KeyBundleData } from './key-bundles.service';
import { KeyBundle } from './key-bundle.entity';
import { OneTimePreKey } from './one-time-pre-key.entity';
import { IdentityChangeAudit } from './identity-change-audit.entity';
import { AccountAuthorization } from './account-authorization.entity';
import { IdentityResetService } from './identity-reset.service';
import { buildIdentityChangeMessage } from './identity-signature.util';

describe('KeyBundlesService', () => {
  let service: KeyBundlesService;
  let keyBundleRepo: Record<string, jest.Mock>;
  let otpRepo: Record<string, jest.Mock>;
  let auditRepo: Record<string, jest.Mock>;
  let authorizationRepo: Record<string, jest.Mock>;
  let identityResetService: Record<string, jest.Mock>;
  // Chainable query-builder mock for the stale-OTP purge in upsertKeyBundle.
  let purgeBuilder: {
    delete: jest.Mock;
    where: jest.Mock;
    andWhere: jest.Mock;
    execute: jest.Mock;
  };

  const mockKeyBundleData: KeyBundleData = {
    registrationId: 12345,
    identityPublicKey: 'base64-identity-key',
    signedPreKeyId: 1,
    signedPreKeyPublic: 'base64-signed-pre-key',
    signedPreKeySignature: 'base64-signature',
  };

  beforeEach(async () => {
    purgeBuilder = {
      delete: jest.fn().mockReturnThis(),
      where: jest.fn().mockReturnThis(),
      andWhere: jest.fn().mockReturnThis(),
      execute: jest.fn().mockResolvedValue({ affected: 0 }),
    };

    keyBundleRepo = {
      findOne: jest.fn(),
      create: jest.fn(),
      save: jest.fn(),
      delete: jest.fn(),
      upsert: jest.fn(),
      // An authorized identity change drops every OTHER device's bundle.
      createQueryBuilder: jest.fn(() => purgeBuilder),
    };

    otpRepo = {
      findOne: jest.fn(),
      create: jest.fn(),
      save: jest.fn(),
      upsert: jest.fn(),
      delete: jest.fn(),
      count: jest.fn(),
      query: jest.fn().mockResolvedValue([[], 0]),
      createQueryBuilder: jest.fn(() => purgeBuilder),
    };

    auditRepo = {
      insert: jest.fn().mockResolvedValue({ identifiers: [{ id: 1 }] }),
    };

    // Default: NOT enrolled, so §6.1's signature path stays available. Every
    // pre-(liv) test models a single-device Phase 0b account, which is exactly
    // this shape; the (liv) tests opt into enrollment explicitly.
    authorizationRepo = {
      findOne: jest.fn().mockResolvedValue(null),
    };

    // Default: no completed reset ceremony exists, so an unsigned identity
    // replacement is refused. Tests that model a LEGITIMATE replacement opt in
    // explicitly, which keeps the locked case the default everywhere.
    identityResetService = {
      consumeCompletedReset: jest.fn().mockResolvedValue(false),
      getStatusForUser: jest.fn().mockResolvedValue(null),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        KeyBundlesService,
        { provide: getRepositoryToken(KeyBundle), useValue: keyBundleRepo },
        { provide: getRepositoryToken(OneTimePreKey), useValue: otpRepo },
        {
          provide: getRepositoryToken(IdentityChangeAudit),
          useValue: auditRepo,
        },
        {
          provide: getRepositoryToken(AccountAuthorization),
          useValue: authorizationRepo,
        },
        {
          provide: IdentityResetService,
          useValue: identityResetService,
        },
      ],
    }).compile();

    service = module.get<KeyBundlesService>(KeyBundlesService);
    jest.clearAllMocks();
  });

  describe('hasKeyBundle', () => {
    it.each([
      [{ id: 1 }, true],
      [null, false],
    ])(
      'returns %s existence without touching one-time pre-keys',
      async (bundle, expected) => {
        keyBundleRepo.findOne.mockResolvedValue(bundle);

        await expect(service.hasKeyBundle(1)).resolves.toBe(expected);

        // Per device: a device with no bundle of its own has published
        // nothing, whatever its siblings did.
        expect(keyBundleRepo.findOne).toHaveBeenCalledWith({
          where: { userId: 1, deviceId: 1 },
        });
        expect(otpRepo.query).not.toHaveBeenCalled();
      },
    );
  });

  describe('upsertKeyBundle', () => {
    it('upserts the key bundle atomically (insert-or-update)', async () => {
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });

      await service.upsertKeyBundle(1, mockKeyBundleData);

      // (userId, deviceId): the old account-wide conflict target made a
      // second device's upload overwrite the first device's bundle.
      expect(keyBundleRepo.upsert).toHaveBeenCalledWith(
        { userId: 1, deviceId: 1, ...mockKeyBundleData },
        {
          conflictPaths: ['userId', 'deviceId'],
          skipUpdateIfNoValuesChanged: true,
        },
      );
      expect(keyBundleRepo.save).not.toHaveBeenCalled();
    });

    it('warns, writes a durable audit row, and reports the churn when an upload replaces an existing identity', async () => {
      const oldIdentity = 'old-identity-public-key-material';
      const newIdentity = 'new-identity-public-key-material';
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 9,
        ...mockKeyBundleData,
        identityPublicKey: oldIdentity,
      });
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });
      // Authorized by a completed reset ceremony (§6.2) — the legitimate path
      // for someone who lost their device keys.
      identityResetService.consumeCompletedReset.mockResolvedValue(true);
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);

      const result = await service.upsertKeyBundle(9, {
        ...mockKeyBundleData,
        identityPublicKey: newIdentity,
      });

      expect(warnSpy).toHaveBeenCalledTimes(1);
      expect(warnSpy).toHaveBeenCalledWith(
        // `via` names the authorization: a RESET is the moment the §6.2 roster
        // teardown runs, a signature is a plain rotation (amendment (xxviii)).
        '[identity-churn] deviceId=1 via=reset oldIdentityPrefix=old-identity newIdentityPrefix=new-identity',
      );
      // Phase 0a: the churn is durable — a full audit row, not just a log line.
      expect(auditRepo.insert).toHaveBeenCalledTimes(1);
      expect(auditRepo.insert).toHaveBeenCalledWith({
        userId: 9,
        previousIdentityPublicKey: oldIdentity,
        newIdentityPublicKey: newIdentity,
      });
      expect(result).toEqual({
        identityChanged: true,
        authorizedBy: 'reset',
        previousIdentityPublicKey: oldIdentity,
      });
      warnSpy.mockRestore();
    });

    it('an audit-row insert failure never fails the upload (loud log, upload acked)', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 9,
        ...mockKeyBundleData,
        identityPublicKey: 'old-identity',
      });
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });
      identityResetService.consumeCompletedReset.mockResolvedValue(true);
      auditRepo.insert.mockRejectedValue(new Error('db down'));
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);
      const errorSpy = jest
        .spyOn(Logger.prototype, 'error')
        .mockImplementation(() => undefined);

      const result = await service.upsertKeyBundle(9, {
        ...mockKeyBundleData,
        identityPublicKey: 'new-identity',
      });

      expect(result.identityChanged).toBe(true);
      expect(errorSpy).toHaveBeenCalled();
      warnSpy.mockRestore();
      errorSpy.mockRestore();
    });

    it('does not warn or audit when an upload retains the existing identity', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 10,
        ...mockKeyBundleData,
      });
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);

      await service.upsertKeyBundle(10, mockKeyBundleData);

      expect(warnSpy).not.toHaveBeenCalled();
      // Same-identity re-upload (the normal every-connect path) stays silent.
      expect(auditRepo.insert).not.toHaveBeenCalled();
      warnSpy.mockRestore();
    });

    it('does not audit a first-time bundle upload (no prior identity)', async () => {
      keyBundleRepo.findOne.mockResolvedValue(null);
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });

      const result = await service.upsertKeyBundle(7, mockKeyBundleData);

      expect(auditRepo.insert).not.toHaveBeenCalled();
      expect(result).toEqual({
        identityChanged: false,
        // Nothing was replaced, so nothing authorized anything.
        authorizedBy: null,
        previousIdentityPublicKey: null,
      });
    });

    // LANDMINE 2 (T4 rider, coherence F7). A linked device publishes its OWN
    // bundle under the account's SHARED identity key. If the churn branch
    // compared anything but the identity, provisioning a second device would
    // fire a takeover alarm at the user and purge device 1's key material.
    it('a second device uploading under the SHARED account identity is not churn', async () => {
      // Where-aware: the (lxiv) guard reads THIS device's row separately from
      // the account-first row, and a naive single-value mock would hand the
      // guard device 1's row for a device-2 lookup and refuse a legit link.
      const deviceOneRow = { userId: 11, deviceId: 1, ...mockKeyBundleData };
      keyBundleRepo.findOne.mockImplementation(
        ({ where }: { where: { userId: number; deviceId?: number } }) =>
          Promise.resolve(
            where.deviceId == null || where.deviceId === 1
              ? deviceOneRow
              : null,
          ),
      );
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);

      // Same identityPublicKey, different device, its own registrationId.
      const result = await service.upsertKeyBundle(
        11,
        { ...mockKeyBundleData, registrationId: 13585 },
        undefined,
        2,
      );

      expect(result.identityChanged).toBe(false);
      expect(warnSpy).not.toHaveBeenCalled();
      expect(auditRepo.insert).not.toHaveBeenCalled();
      // Device 1's bundle and OTPs must survive untouched.
      expect(keyBundleRepo.delete).not.toHaveBeenCalled();
      expect(keyBundleRepo.upsert).toHaveBeenCalledWith(
        expect.objectContaining({ userId: 11, deviceId: 2 }),
        {
          conflictPaths: ['userId', 'deviceId'],
          skipUpdateIfNoValuesChanged: true,
        },
      );
      warnSpy.mockRestore();
    });

    // Amendment (lxiv) clause 1 — GATE2-REVOKED-DEVICE-RELOGIN-CLOBBER.
    // Identity and registrationId are minted together, once, in every mint
    // path, so "same identity, different registrationId, same row" can only be
    // a DIFFERENT physical install writing into a namespace it does not own —
    // the revoked-laptop-signs-back-in shape, whose mixed served bundle makes
    // peers' first messages permanently undecryptable by every device.
    describe('device material conflict ((lxiv) clause 1)', () => {
      it('refuses a same-identity upload whose registrationId differs from the stored row', async () => {
        keyBundleRepo.findOne.mockResolvedValue({
          userId: 12,
          deviceId: 1,
          ...mockKeyBundleData,
        });

        await expect(
          service.upsertKeyBundle(12, {
            ...mockKeyBundleData,
            registrationId: 99999,
          }),
        ).rejects.toThrow('device_material_conflict');

        // Refused BEFORE any write: no clobber, no OTP purge, no audit.
        expect(keyBundleRepo.upsert).not.toHaveBeenCalled();
        expect(purgeBuilder.execute).not.toHaveBeenCalled();
        expect(auditRepo.insert).not.toHaveBeenCalled();
      });

      it('positive control: a fresh device row is judged by ITS OWN (absent) row, not the account-first row', async () => {
        const deviceOneRow = { userId: 12, deviceId: 1, ...mockKeyBundleData };
        keyBundleRepo.findOne.mockImplementation(
          ({ where }: { where: { userId: number; deviceId?: number } }) =>
            Promise.resolve(
              where.deviceId == null || where.deviceId === 1
                ? deviceOneRow
                : null,
            ),
        );
        keyBundleRepo.upsert.mockResolvedValue({ raw: [] });

        // Same shared identity, its own registrationId, no row for device 3
        // yet: a legitimate first upload from a freshly linked device.
        const result = await service.upsertKeyBundle(
          12,
          { ...mockKeyBundleData, registrationId: 777 },
          undefined,
          3,
        );

        expect(result.identityChanged).toBe(false);
        expect(keyBundleRepo.upsert).toHaveBeenCalledWith(
          expect.objectContaining({ userId: 12, deviceId: 3 }),
          {
            conflictPaths: ['userId', 'deviceId'],
            skipUpdateIfNoValuesChanged: true,
          },
        );
      });

      it('positive control: an authorized identity change on the same row is not a material conflict', async () => {
        // The consented-regeneration shape: new identity AND new
        // registrationId minted together. The (liv)/§6.1 machinery owns this
        // path; the (lxiv) guard must not fire on it.
        keyBundleRepo.findOne.mockResolvedValue({
          userId: 12,
          deviceId: 1,
          ...mockKeyBundleData,
        });
        keyBundleRepo.upsert.mockResolvedValue({ raw: [] });
        identityResetService.consumeCompletedReset.mockResolvedValue(true);

        const result = await service.upsertKeyBundle(12, {
          ...mockKeyBundleData,
          identityPublicKey: 'regenerated-identity',
          registrationId: 55555,
        });

        expect(result.identityChanged).toBe(true);
        expect(keyBundleRepo.upsert).toHaveBeenCalled();
      });
    });

    it('purges unused OTPs from superseded identity epochs (durable stale-OTP fix)', async () => {
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });

      await service.upsertKeyBundle(42, mockKeyBundleData);

      // A DELETE scoped to this user, unused rows, whose identity is NULL or
      // different from the newly-uploaded identity — never the current epoch.
      expect(otpRepo.createQueryBuilder).toHaveBeenCalledTimes(1);
      expect(purgeBuilder.delete).toHaveBeenCalledTimes(1);
      expect(purgeBuilder.where).toHaveBeenCalledWith('"userId" = :userId', {
        userId: 42,
      });
      const andWhereCalls = purgeBuilder.andWhere.mock.calls.map((c) => c[0]);
      expect(andWhereCalls).toContain('used = false');
      expect(andWhereCalls).toContain(
        '("identityPublicKey" IS NULL OR "identityPublicKey" != :identity)',
      );
      // The identity bound to the purge is the NEW bundle identity.
      const identityCall = purgeBuilder.andWhere.mock.calls.find(
        (c) => c[1] && 'identity' in c[1],
      );
      expect(identityCall?.[1]).toEqual({
        identity: mockKeyBundleData.identityPublicKey,
      });
      expect(purgeBuilder.execute).toHaveBeenCalledTimes(1);
    });
  });

  // Registration lock (multi-device spec §6.1). Before 0b, ANY upload with a
  // valid session could replace the stored identity key — which is what
  // silently redirects every future conversation to different keys. These pin
  // the refusal and both authorized paths.
  describe('registration lock (§6.1)', () => {
    const STORED = 'BdYgkTwp7ZAWQHWKYxQtsMQZxtVQEtVs1Fo63JM3EKJQ';
    const REPLACEMENT = 'BV/AuiEQx2o3p6cfoebDWHomEc5VTzNsyNNcuYxf3BVF';
    // Real client-produced proof: STORED signs REPLACEMENT ‖ 4242 ‖ NONCE.
    const NONCE = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw=';
    const SIGNATURE =
      '+eSga6vQusMMR5gjRe2rk/XQspEwDVXBmFmGy/1iH2P8kBGS+xQ+vE+xTbnzF+3m878LvYXbIooBi4sAmes7hA==';
    const SIGNED_USER_ID = 4242;

    beforeEach(() => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: SIGNED_USER_ID,
        ...mockKeyBundleData,
        identityPublicKey: STORED,
      });
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });
    });

    it('refuses an unauthorized identity replacement on an ENROLLED account and writes NOTHING', async () => {
      // (lxxiii): the lock is armed by enrollment. The un-enrolled twin of
      // this test lives in the (lxxiii) block below and is ACCEPTED there.
      authorizationRepo.findOne.mockResolvedValue({ userId: SIGNED_USER_ID });
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);

      await expect(
        service.upsertKeyBundle(SIGNED_USER_ID, {
          ...mockKeyBundleData,
          identityPublicKey: REPLACEMENT,
        }),
      ).rejects.toThrow('identity_locked');

      // No bundle written, no OTP epoch purged, no audit row, no alarm state:
      // a refused attempt must leave the account byte-identical.
      expect(keyBundleRepo.upsert).not.toHaveBeenCalled();
      expect(purgeBuilder.execute).not.toHaveBeenCalled();
      expect(auditRepo.insert).not.toHaveBeenCalled();
      expect(warnSpy).toHaveBeenCalledWith(
        expect.stringContaining('[identity-lock] REFUSED'),
      );
      warnSpy.mockRestore();
    });

    it('accepts a replacement proven by the previous identity key', async () => {
      const result = await service.upsertKeyBundle(
        SIGNED_USER_ID,
        { ...mockKeyBundleData, identityPublicKey: REPLACEMENT },
        { signature: SIGNATURE, nonce: NONCE },
      );

      expect(result.identityChanged).toBe(true);
      expect(keyBundleRepo.upsert).toHaveBeenCalledTimes(1);
      // A valid signature must NOT burn a reset ceremony.
      expect(identityResetService.consumeCompletedReset).not.toHaveBeenCalled();
    });

    it('a signature for a different account does not authenticate — the change is admitted as unlocked, never as signature', async () => {
      // Pre-(lxxiii) this was an identity_locked refusal. The un-enrolled
      // account is now admitted regardless, so what the wrong-account proof
      // must NOT buy is the 'signature' attribution.
      const result = await service.upsertKeyBundle(
        SIGNED_USER_ID + 1,
        { ...mockKeyBundleData, identityPublicKey: REPLACEMENT },
        { signature: SIGNATURE, nonce: NONCE },
      );
      expect(result.authorizedBy).toBe('unlocked');
    });

    it('a mismatched nonce does not authenticate — unlocked, never signature', async () => {
      const result = await service.upsertKeyBundle(
        SIGNED_USER_ID,
        { ...mockKeyBundleData, identityPublicKey: REPLACEMENT },
        {
          signature: SIGNATURE,
          nonce: Buffer.alloc(32, 1).toString('base64'),
        },
      );
      expect(result.authorizedBy).toBe('unlocked');
    });

    it('falls back to a completed reset ceremony when the signature is unusable', async () => {
      identityResetService.consumeCompletedReset.mockResolvedValue(true);

      const result = await service.upsertKeyBundle(
        SIGNED_USER_ID,
        { ...mockKeyBundleData, identityPublicKey: REPLACEMENT },
        { signature: 'not-a-signature', nonce: NONCE },
      );

      expect(result.identityChanged).toBe(true);
      expect(identityResetService.consumeCompletedReset).toHaveBeenCalledWith(
        SIGNED_USER_ID,
      );
    });

    it('never consults the ceremony for a same-identity re-upload', async () => {
      await service.upsertKeyBundle(SIGNED_USER_ID, {
        ...mockKeyBundleData,
        identityPublicKey: STORED,
      });

      expect(identityResetService.consumeCompletedReset).not.toHaveBeenCalled();
      expect(keyBundleRepo.upsert).toHaveBeenCalledTimes(1);
    });

    it('never consults the ceremony for a first-ever upload', async () => {
      keyBundleRepo.findOne.mockResolvedValue(null);

      await service.upsertKeyBundle(SIGNED_USER_ID, mockKeyBundleData);

      expect(identityResetService.consumeCompletedReset).not.toHaveBeenCalled();
      expect(keyBundleRepo.upsert).toHaveBeenCalledTimes(1);
    });

    // Amendment (liv), finding F1. The §5.1 link blob ships ikPriv to every
    // linked device, so on an ENROLLED account "holds the old identity key" no
    // longer means "is the primary" and the signature path must close.
    describe('(liv) an ENROLLED account loses the signature path', () => {
      beforeEach(() => {
        authorizationRepo.findOne.mockResolvedValue({ userId: SIGNED_USER_ID });
      });

      it('REFUSES a validly signed identity change and writes NOTHING', async () => {
        const warnSpy = jest
          .spyOn(Logger.prototype, 'warn')
          .mockImplementation(() => undefined);

        // Byte-identical to the proof the non-enrolled test accepts above —
        // the ONLY difference is that the account is enrolled.
        await expect(
          service.upsertKeyBundle(
            SIGNED_USER_ID,
            { ...mockKeyBundleData, identityPublicKey: REPLACEMENT },
            { signature: SIGNATURE, nonce: NONCE },
          ),
        ).rejects.toThrow('identity_locked');

        expect(keyBundleRepo.upsert).not.toHaveBeenCalled();
        expect(purgeBuilder.execute).not.toHaveBeenCalled();
        expect(auditRepo.insert).not.toHaveBeenCalled();
        expect(warnSpy).toHaveBeenCalledWith(
          expect.stringContaining('(liv) signature path REFUSED'),
        );
        warnSpy.mockRestore();
      });

      it('still admits the §6.2 ceremony, which is now the ONLY way', async () => {
        identityResetService.consumeCompletedReset.mockResolvedValue(true);

        const result = await service.upsertKeyBundle(
          SIGNED_USER_ID,
          { ...mockKeyBundleData, identityPublicKey: REPLACEMENT },
          { signature: SIGNATURE, nonce: NONCE },
        );

        // The gate must not have made an enrolled account unrecoverable: a
        // completed ceremony authorizes, and it is what gets spent.
        expect(result.identityChanged).toBe(true);
        expect(result.authorizedBy).toBe('reset');
        expect(identityResetService.consumeCompletedReset).toHaveBeenCalledWith(
          SIGNED_USER_ID,
        );
      });

      it('leaves a same-identity re-upload untouched (the every-connect path)', async () => {
        // Enrollment must not disturb the normal reconnect, which carries no
        // proof and changes nothing.
        await service.upsertKeyBundle(SIGNED_USER_ID, {
          ...mockKeyBundleData,
          identityPublicKey: STORED,
        });

        expect(keyBundleRepo.upsert).toHaveBeenCalledTimes(1);
        expect(
          identityResetService.consumeCompletedReset,
        ).not.toHaveBeenCalled();
      });

      it('POSITIVE CONTROL: the same proof is accepted when NOT enrolled', async () => {
        authorizationRepo.findOne.mockResolvedValue(null);

        const result = await service.upsertKeyBundle(
          SIGNED_USER_ID,
          { ...mockKeyBundleData, identityPublicKey: REPLACEMENT },
          { signature: SIGNATURE, nonce: NONCE },
        );

        // Phase 0b is unchanged: one device, one holder of ikPriv.
        expect(result.authorizedBy).toBe('signature');
        expect(
          identityResetService.consumeCompletedReset,
        ).not.toHaveBeenCalled();
      });
    });

    // Amendment (lxxiii) clause 1: the registration lock is OPT-IN — enabling
    // linking (the account_authorizations row) is what arms it. Un-enrolled,
    // an identity replacement with credentials alone is admitted as
    // 'unlocked', and it is LOUD: same churn warn, same audit row, so §6.0's
    // alarm fan-out fires unchanged.
    describe('(lxxiii) the lock is opt-in — un-enrolled replacement is unlocked', () => {
      it('admits a proof-less replacement on an UN-ENROLLED account as unlocked, loudly, with the audit row', async () => {
        const warnSpy = jest
          .spyOn(Logger.prototype, 'warn')
          .mockImplementation(() => undefined);

        const result = await service.upsertKeyBundle(SIGNED_USER_ID, {
          ...mockKeyBundleData,
          identityPublicKey: REPLACEMENT,
        });

        expect(result.identityChanged).toBe(true);
        expect(result.authorizedBy).toBe('unlocked');
        expect(result.previousIdentityPublicKey).toBe(STORED);
        expect(keyBundleRepo.upsert).toHaveBeenCalledTimes(1);
        // The SAME audit/notify path as a signature/reset churn: the durable
        // §6.0 audit row is written, which is what makes the takeover LOUD.
        expect(auditRepo.insert).toHaveBeenCalledWith({
          userId: SIGNED_USER_ID,
          previousIdentityPublicKey: STORED,
          newIdentityPublicKey: REPLACEMENT,
        });
        expect(warnSpy).toHaveBeenCalledWith(
          expect.stringContaining('via=unlocked'),
        );
        // Never refused: no [identity-lock] REFUSED line for this shape.
        expect(warnSpy).not.toHaveBeenCalledWith(
          expect.stringContaining('[identity-lock] REFUSED'),
        );
        warnSpy.mockRestore();
      });

      it('a completed reset still wins over unlocked (it must be SPENT, and it tears the roster down)', async () => {
        identityResetService.consumeCompletedReset.mockResolvedValue(true);

        const result = await service.upsertKeyBundle(SIGNED_USER_ID, {
          ...mockKeyBundleData,
          identityPublicKey: REPLACEMENT,
        });

        // 'unlocked' must never mask a ceremony: the gateway keys the §6.2
        // roster teardown on authorizedBy === 'reset'.
        expect(result.authorizedBy).toBe('reset');
      });
    });
  });

  // Amendment (lxxviii) clause 2: a phrase-restored install re-uploads the
  // account's UNCHANGED identity with a proof signed by that very key. Keys
  // are generated here (deterministic seeds) because the proof must verify
  // under the STORED key — a canned vector could not also produce the
  // wrong-key twin.
  describe('(lxxviii) identity restore proof', () => {
    const USER_ID = 4242;
    const ownKeys = generateKeyPair(
      Uint8Array.from({ length: 32 }, (_, i) => i + 1),
    );
    const foreignKeys = generateKeyPair(
      Uint8Array.from({ length: 32 }, (_, i) => i + 101),
    );
    const STORED_IDENTITY = Buffer.concat([
      Buffer.from([0x05]),
      Buffer.from(ownKeys.public),
    ]).toString('base64');
    const NONCE = Buffer.alloc(32, 7).toString('base64');
    const message = Uint8Array.from(
      buildIdentityChangeMessage(
        Buffer.from(STORED_IDENTITY, 'base64'),
        USER_ID,
        Buffer.from(NONCE, 'base64'),
      ),
    );
    const VALID_PROOF = Buffer.from(
      sign(ownKeys.private, message, undefined),
    ).toString('base64');
    // F7's forgery: the same message signed by a key that is NOT the account's.
    const FOREIGN_PROOF = Buffer.from(
      sign(foreignKeys.private, message, undefined),
    ).toString('base64');

    beforeEach(() => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: USER_ID,
        deviceId: 1,
        ...mockKeyBundleData,
        identityPublicKey: STORED_IDENTITY,
      });
      keyBundleRepo.upsert.mockResolvedValue({ raw: [] });
    });

    it('a proof under the STORED key authorizes as restore — no audit row, no churn', async () => {
      const result = await service.upsertKeyBundle(
        USER_ID,
        { ...mockKeyBundleData, identityPublicKey: STORED_IDENTITY },
        { restoreSignature: VALID_PROOF, nonce: NONCE },
        1,
      );

      expect(result.identityChanged).toBe(false);
      expect(result.authorizedBy).toBe('restore');
      expect(keyBundleRepo.upsert).toHaveBeenCalledTimes(1);
      // The identity did NOT change: no §6.0 audit row, no ceremony spent.
      expect(auditRepo.insert).not.toHaveBeenCalled();
      expect(identityResetService.consumeCompletedReset).not.toHaveBeenCalled();
    });

    // Falsification F7: a proof verified with the wrong key must be REFUSED,
    // with nothing written — never degraded to a plain re-upload, because the
    // gateway keys the roster teardown on this verdict.
    it('F7: a proof signed by a DIFFERENT key is refused and NOTHING is written', async () => {
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);

      await expect(
        service.upsertKeyBundle(
          USER_ID,
          { ...mockKeyBundleData, identityPublicKey: STORED_IDENTITY },
          { restoreSignature: FOREIGN_PROOF, nonce: NONCE },
          1,
        ),
      ).rejects.toThrow('restore_refused');

      expect(keyBundleRepo.upsert).not.toHaveBeenCalled();
      expect(purgeBuilder.execute).not.toHaveBeenCalled();
      expect(auditRepo.insert).not.toHaveBeenCalled();
      expect(warnSpy).toHaveBeenCalledWith(
        expect.stringContaining('[identity-restore] REFUSED'),
      );
      warnSpy.mockRestore();
    });

    it('a stray restore field on an identity CHANGE is ignored — the normal lock adjudicates', async () => {
      const foreignIdentity = Buffer.concat([
        Buffer.from([0x05]),
        Buffer.from(foreignKeys.public),
      ]).toString('base64');

      // Un-enrolled default + no ceremony: the change is admitted 'unlocked'.
      // What the restore field must NOT buy is the 'restore' attribution.
      const result = await service.upsertKeyBundle(
        USER_ID,
        { ...mockKeyBundleData, identityPublicKey: foreignIdentity },
        { restoreSignature: VALID_PROOF, nonce: NONCE },
        1,
      );

      expect(result.identityChanged).toBe(true);
      expect(result.authorizedBy).toBe('unlocked');
    });

    it('the plain same-identity re-upload (no proof) stays unauthorized', async () => {
      const result = await service.upsertKeyBundle(
        USER_ID,
        { ...mockKeyBundleData, identityPublicKey: STORED_IDENTITY },
        undefined,
        1,
      );

      expect(result.identityChanged).toBe(false);
      expect(result.authorizedBy).toBeNull();
    });
  });

  describe('uploadOneTimePreKeys', () => {
    const keys = [
      { keyId: 0, publicKey: 'pk-0' },
      { keyId: 1, publicKey: 'pk-1' },
    ];

    it('upserts on (userId,deviceId,keyId) and tags rows with the explicit identity', async () => {
      // The tag must match what the account actually publishes — see the
      // refusal test below for why an unpublished tag is not key material the
      // account can ever serve.
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'epoch-2-identity',
      });
      otpRepo.upsert.mockResolvedValue({ raw: [] });

      await service.uploadOneTimePreKeys(5, keys, 'epoch-2-identity');

      // Account-scoped lookup: every device shares one IK (§3), so the lowest
      // device's row IS the account identity.
      expect(keyBundleRepo.findOne).toHaveBeenCalledWith({
        where: { userId: 5 },
        order: { deviceId: 'ASC' },
      });
      expect(otpRepo.save).not.toHaveBeenCalled();
      expect(otpRepo.upsert).toHaveBeenCalledWith(
        [
          {
            userId: 5,
            deviceId: 1,
            keyId: 0,
            publicKey: 'pk-0',
            identityPublicKey: 'epoch-2-identity',
            used: false,
          },
          {
            userId: 5,
            deviceId: 1,
            keyId: 1,
            publicKey: 'pk-1',
            identityPublicKey: 'epoch-2-identity',
            used: false,
          },
        ],
        // keyId slots belong to a DEVICE: two devices may both hold keyId 0,
        // and neither upload may overwrite the other's private half.
        { conflictPaths: ['userId', 'deviceId', 'keyId'] },
      );
    });

    // Proven live 2026-08-18: the lock refused a session's identity and the
    // very same session still deposited 20 OTPs into the account's device-1
    // slots, overwriting the legitimate device's keyId 0..19 and stamping them
    // with the REFUSED identity. Those rows are unservable (the fetch filter
    // pins the published identity) but the victim's pool is emptied until a
    // peer fetch triggers preKeysLow. Publishing an identity is locked, so
    // depositing key material under one must be too (§5.1).
    it('refuses one-time pre-keys tagged with an identity an ENROLLED account has not published', async () => {
      // (lxxiii): the refusal is armed by enrollment, like the bundle site.
      authorizationRepo.findOne.mockResolvedValue({ userId: 5 });
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'published-identity',
      });

      await expect(
        service.uploadOneTimePreKeys(5, keys, 'refused-identity'),
      ).rejects.toMatchObject({ message: 'identity_locked' });

      // Nothing written and nothing destroyed: the legitimate pool survives.
      expect(otpRepo.upsert).not.toHaveBeenCalled();
      expect(otpRepo.delete).not.toHaveBeenCalled();
      expect(otpRepo.createQueryBuilder).not.toHaveBeenCalled();
    });

    it('(lxxiii) accepts an UN-ENROLLED remint OTP batch under an unpublished identity', async () => {
      // The client emits bundle + OTPs back to back and the keys can land
      // first: refusing here would strand the un-enrolled remint without its
      // OTP batch — the (lxiv) pool-loss shape for no gain.
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'published-identity',
      });
      otpRepo.upsert.mockResolvedValue({ raw: [] });

      await service.uploadOneTimePreKeys(5, keys, 'reminted-identity');

      expect(otpRepo.upsert).toHaveBeenCalledTimes(1);
    });

    it('accepts a first upload that races its own key bundle (nothing published yet)', async () => {
      // The client emits uploadKeyBundle and uploadOneTimePreKeys back to back
      // and socket.io does not await handlers, so the OTP upload can win. With
      // no published identity there is no victim, and refusing here would
      // break every fresh registration.
      keyBundleRepo.findOne.mockResolvedValue(null);
      otpRepo.upsert.mockResolvedValue({ raw: [] });

      await service.uploadOneTimePreKeys(5, keys, 'epoch-1-identity');

      expect(otpRepo.upsert).toHaveBeenCalledTimes(1);
    });

    it('accepts an in-flight authorized rotation whose bundle upsert has not landed yet', async () => {
      // Same race, one step later in an account's life: a completed ceremony
      // authorizes exactly one replacement, and the new epoch's OTPs may reach
      // the server before the new bundle commits. Refusing here would strip
      // the pool of the ONE flow that exists to rescue a user who lost their
      // keys — the reset-completion path.
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'old-identity',
      });
      identityResetService.getStatusForUser.mockResolvedValue({
        status: 'completed',
        deadlineAt: new Date(),
        shortened: false,
      });
      otpRepo.upsert.mockResolvedValue({ raw: [] });

      await service.uploadOneTimePreKeys(5, keys, 'new-identity');

      expect(otpRepo.upsert).toHaveBeenCalledTimes(1);
      // Reading the grant must never spend it — the bundle upload does that.
      expect(identityResetService.consumeCompletedReset).not.toHaveBeenCalled();
    });

    it('still refuses an ENROLLED unpublished tag while a ceremony is merely PENDING', async () => {
      // A pending ceremony is an alarm, not an authorization: the countdown
      // exists precisely so the owner can cancel it.
      authorizationRepo.findOne.mockResolvedValue({ userId: 5 });
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'published-identity',
      });
      identityResetService.getStatusForUser.mockResolvedValue({
        status: 'pending',
        deadlineAt: new Date(),
        shortened: false,
      });

      await expect(
        service.uploadOneTimePreKeys(5, keys, 'refused-identity'),
      ).rejects.toMatchObject({ message: 'identity_locked' });

      expect(otpRepo.upsert).not.toHaveBeenCalled();
    });

    // Amendment (lxiv) clause 1, OTP half: the bundle guard alone does not
    // close the mixed-halves loss — a foreign install sharing the account
    // identity (a revoked linked device whose login resolved onto the
    // primary's id) could still deposit ITS OTPs into the owner's pool via
    // preKeysLow, and a peer fetch would mix owner signedPreKey + foreign OTP.
    it('refuses one-time pre-keys whose registrationId does not match the device row ((lxiv))', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'published-identity',
        registrationId: 12345,
      });

      await expect(
        service.uploadOneTimePreKeys(5, keys, 'published-identity', 1, 99999),
      ).rejects.toMatchObject({ message: 'device_material_conflict' });

      expect(otpRepo.upsert).not.toHaveBeenCalled();
    });

    it('positive control: a matching registrationId install proof passes ((lxiv))', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'published-identity',
        registrationId: 12345,
      });
      otpRepo.upsert.mockResolvedValue({ raw: [] });

      await service.uploadOneTimePreKeys(
        5,
        keys,
        'published-identity',
        1,
        12345,
      );

      expect(otpRepo.upsert).toHaveBeenCalledTimes(1);
    });

    it('positive control: an absent registrationId (pre-(lxiv) client) is accepted', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        deviceId: 1,
        identityPublicKey: 'published-identity',
        registrationId: 12345,
      });
      otpRepo.upsert.mockResolvedValue({ raw: [] });

      await service.uploadOneTimePreKeys(5, keys, 'published-identity');

      expect(otpRepo.upsert).toHaveBeenCalledTimes(1);
    });

    it('rejects untagged OTP uploads instead of inferring the current identity epoch', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        ...mockKeyBundleData,
      });

      await expect(service.uploadOneTimePreKeys(5, keys)).rejects.toMatchObject(
        {
          message: 'identity_epoch_required',
        },
      );

      expect(otpRepo.upsert).not.toHaveBeenCalled();
    });

    it('preserves existing valid current-epoch rows when rejecting a legacy upload', async () => {
      // A legacy (untagged) upload must be rejected WITHOUT touching any
      // existing rows: no destructive delete/purge and no upsert may run,
      // so previously-stored current-epoch OTPs survive intact.
      await expect(service.uploadOneTimePreKeys(5, keys)).rejects.toThrow(
        'identity_epoch_required',
      );
      expect(otpRepo.upsert).not.toHaveBeenCalled();
      expect(otpRepo.delete).not.toHaveBeenCalled();
      expect(otpRepo.createQueryBuilder).not.toHaveBeenCalled();
    });
  });

  describe('fetchPreKeyBundle', () => {
    const bundle = { id: 1, userId: 5, ...mockKeyBundleData };

    it('returns null when no key bundle exists', async () => {
      keyBundleRepo.findOne.mockResolvedValue(null);

      const result = await service.fetchPreKeyBundle(99);

      expect(result).toBeNull();
      expect(otpRepo.query).not.toHaveBeenCalled();
    });

    it('claims an OTP filtered by the CURRENT identity epoch ($1 user, $2 identity)', async () => {
      keyBundleRepo.findOne.mockResolvedValue(bundle);
      // Real Postgres shape for UPDATE ... RETURNING: [rows, rowCount].
      otpRepo.query.mockResolvedValue([
        [{ id: 10, keyId: 7, publicKey: 'otp-pk-7' }],
        1,
      ]);

      const result = await service.fetchPreKeyBundle(5);

      expect(result).toEqual({
        registrationId: mockKeyBundleData.registrationId,
        identityPublicKey: mockKeyBundleData.identityPublicKey,
        signedPreKeyId: mockKeyBundleData.signedPreKeyId,
        signedPreKeyPublic: mockKeyBundleData.signedPreKeyPublic,
        signedPreKeySignature: mockKeyBundleData.signedPreKeySignature,
        oneTimePreKeyId: 7,
        oneTimePreKeyPublic: 'otp-pk-7',
      });
      // The load-bearing guard: SQL filters on identityPublicKey and binds the
      // current bundle identity as the second parameter.
      const [sql, params] = otpRepo.query.mock.calls[0];
      expect(sql).toContain('UPDATE one_time_pre_keys');
      expect(sql).toContain('"identityPublicKey" = $2');
      // $3 is the Phase 1 re-key: one device's claim must never consume the
      // keyId slot another device minted.
      expect(sql).toContain('"deviceId" = $3');
      expect(params).toEqual([5, mockKeyBundleData.identityPublicKey, 1]);
    });

    it('returns null OTP fields when the current epoch has no unused pre-keys', async () => {
      keyBundleRepo.findOne.mockResolvedValue(bundle);
      otpRepo.query.mockResolvedValue([[], 0]);

      const result = await service.fetchPreKeyBundle(5);

      expect(result?.oneTimePreKeyId).toBeNull();
      expect(result?.oneTimePreKeyPublic).toBeNull();
      // OTP-less bundle is still valid — X3DH completes without a one-time key.
      expect(result?.identityPublicKey).toBe(
        mockKeyBundleData.identityPublicKey,
      );
    });
  });

  describe('countUnusedPreKeys', () => {
    it('counts only unused OTPs of the CURRENT identity epoch', async () => {
      keyBundleRepo.findOne.mockResolvedValue({
        userId: 5,
        ...mockKeyBundleData,
      });
      otpRepo.count.mockResolvedValue(15);

      const count = await service.countUnusedPreKeys(5);

      expect(count).toBe(15);
      expect(otpRepo.count).toHaveBeenCalledWith({
        where: {
          userId: 5,
          deviceId: 1,
          used: false,
          identityPublicKey: mockKeyBundleData.identityPublicKey,
        },
      });
    });

    it('returns 0 when the user has no key bundle', async () => {
      keyBundleRepo.findOne.mockResolvedValue(null);

      const count = await service.countUnusedPreKeys(5);

      expect(count).toBe(0);
      expect(otpRepo.count).not.toHaveBeenCalled();
    });
  });

  describe('deleteByUserId', () => {
    it('deletes all OTPs and key bundles for the user', async () => {
      otpRepo.delete.mockResolvedValue({ affected: 10 });
      keyBundleRepo.delete.mockResolvedValue({ affected: 1 });

      await service.deleteByUserId(5);

      expect(otpRepo.delete).toHaveBeenCalledWith({ userId: 5 });
      expect(keyBundleRepo.delete).toHaveBeenCalledWith({ userId: 5 });
    });

    it('deletes OTPs before key bundles', async () => {
      const callOrder: string[] = [];
      otpRepo.delete.mockImplementation(async () => {
        callOrder.push('otp');
        return { affected: 0 };
      });
      keyBundleRepo.delete.mockImplementation(async () => {
        callOrder.push('keyBundle');
        return { affected: 0 };
      });

      await service.deleteByUserId(5);

      expect(callOrder).toEqual(['otp', 'keyBundle']);
    });
  });

  describe('purgeDeviceMaterial (§5.5 revocation, falsification 12)', () => {
    it('deletes the bundle and OTPs of EXACTLY one device', async () => {
      keyBundleRepo.delete.mockResolvedValue({ affected: 1 });
      otpRepo.delete.mockResolvedValue({ affected: 40 });

      await service.purgeDeviceMaterial(5, 2);

      // Both scoped by the PAIR: a roster teardown can never reach a
      // surviving device's material, which is what falsification 12 asserts.
      expect(keyBundleRepo.delete).toHaveBeenCalledWith({
        userId: 5,
        deviceId: 2,
      });
      expect(otpRepo.delete).toHaveBeenCalledWith({ userId: 5, deviceId: 2 });
    });

    it('uses the caller transaction when given a manager', async () => {
      const bundleDelete = jest.fn().mockResolvedValue({ affected: 1 });
      const otpDelete = jest.fn().mockResolvedValue({ affected: 1 });
      const manager = {
        getRepository: jest.fn((entity: unknown) =>
          entity === KeyBundle
            ? { delete: bundleDelete }
            : { delete: otpDelete },
        ),
      };

      await service.purgeDeviceMaterial(5, 2, manager as never);

      expect(bundleDelete).toHaveBeenCalledWith({ userId: 5, deviceId: 2 });
      expect(otpDelete).toHaveBeenCalledWith({ userId: 5, deviceId: 2 });
      // The service's own repositories stay untouched, so the delete really
      // joins the revocation transaction instead of running beside it.
      expect(keyBundleRepo.delete).not.toHaveBeenCalled();
      expect(otpRepo.delete).not.toHaveBeenCalled();
    });
  });
});
