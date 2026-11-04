import { Test, TestingModule } from '@nestjs/testing';
import { Socket } from 'socket.io';
import { ChatDeviceListService } from './chat-device-list.service';
import { DeviceListService } from '../../key-bundles/device-list.service';

/**
 * WHO MAY READ AN ACCOUNT'S DEVICE ROSTER (spec §12 amendment (xliii), as
 * narrowed by Phase 4 step 5).
 *
 * `getDeviceList` once served whatever `userId` the payload named, which made
 * it a device-count, platform and timeline oracle over every account on the
 * instance; amendment (xliii) then limited it to friends and conversation
 * partners. Both entitlements read the friend and conversation rows, which are
 * gone, so the server now answers ONLY the caller's own id. A friend's list
 * comes over the box or from the `searchUsers` handle lookup.
 *
 * These tests pin the one way in and, just as importantly, the way OUT: a
 * refusal must stay SILENT, because answering at all would confirm whether an
 * account exists.
 */
describe('ChatDeviceListService.handleGetDeviceList (own roster only)', () => {
  const REQUESTER = 7;
  const TARGET = 9;

  let service: ChatDeviceListService;
  let getAuthorization: jest.Mock;
  let pendingReplacementVersion: jest.Mock;
  let emit: jest.Mock;
  let client: Partial<Socket>;

  /** The stored row the handler projects. */
  const authorizationRow = {
    dakPub: 'dak',
    enrollmentSig: 'sig',
    enrollmentCreatedAt: new Date(1_700_000_000_000),
    listVersion: 3,
    listSignature: 'list-sig',
    listCanonical: 'canonical-bytes',
  };

  /** The same row as it appears ON THE WIRE: the date becomes signed ms. */
  const authorizationProjection = {
    ...authorizationRow,
    enrollmentCreatedAt: authorizationRow.enrollmentCreatedAt.getTime(),
  };

  beforeEach(async () => {
    getAuthorization = jest.fn().mockResolvedValue(authorizationRow);
    // The ordinary account owes no replacement enrollment, so the (xlv)
    // clause 2 guard stands aside and these tests exercise the own-id rule.
    pendingReplacementVersion = jest.fn().mockResolvedValue(null);
    emit = jest.fn();
    client = { data: { user: { id: REQUESTER } }, emit };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ChatDeviceListService,
        {
          provide: DeviceListService,
          useValue: { getAuthorization, pendingReplacementVersion },
        },
      ],
    }).compile();
    service = module.get(ChatDeviceListService);
  });

  const get = (userId: number) =>
    service.handleGetDeviceList(client as Socket, { userId });

  it('serves YOUR OWN roster, always', async () => {
    await get(REQUESTER);

    // Discloses nothing the caller does not already hold, and the I7 own-skew
    // re-fetch depends on it.
    expect(emit).toHaveBeenCalledWith(
      'deviceList',
      expect.objectContaining({ userId: REQUESTER }),
    );
  });

  it('answers ANY other account with silence, and reads nothing', async () => {
    await get(TARGET);

    // Silence is fail-closed on the client (I5: an unanswered fetch means
    // "cannot verify", never "no devices"), and answering would itself
    // confirm whether the account exists.
    expect(emit).not.toHaveBeenCalled();
    expect(getAuthorization).not.toHaveBeenCalled();
    expect(pendingReplacementVersion).not.toHaveBeenCalled();
  });

  it('refuses an unauthenticated socket without touching the database', async () => {
    client = { data: {}, emit };

    await get(REQUESTER);

    expect(emit).not.toHaveBeenCalled();
    expect(getAuthorization).not.toHaveBeenCalled();
  });

  it('echoes the stored listCanonical verbatim', async () => {
    // Falsification 23: the bytes are re-verified bit-for-bit by the peer.
    await get(REQUESTER);

    expect(emit).toHaveBeenCalledWith('deviceList', {
      userId: REQUESTER,
      authorization: {
        dakPub: 'dak',
        enrollmentSig: 'sig',
        enrollmentCreatedAt: 1_700_000_000_000,
        listVersion: 3,
        listSignature: 'list-sig',
        listCanonical: 'canonical-bytes',
      },
    });
  });

  // --- (xlv) clause 2: an un-enrolled account must still be ADDRESSABLE ----
  // `authorization: null` is not merely "no row" on the wire — the client
  // answers it by synthesizing the single device 1 a non-enrolled account is
  // supposed to have. A completed §6.2 reset breaks that construction.

  it('REFUSES an un-enrolled account whose live devices exclude device 1', async () => {
    getAuthorization.mockResolvedValue(null);
    pendingReplacementVersion.mockResolvedValue(1);

    await get(REQUESTER);

    // Silence, not `authorization: null` — answering would tell every peer to
    // encrypt to device 1, which this account no longer has, and the loss is
    // silent and permanent in both directions.
    expect(emit).not.toHaveBeenCalled();
  });

  it('still answers an ordinary un-enrolled account, which really IS device 1', async () => {
    getAuthorization.mockResolvedValue(null);
    pendingReplacementVersion.mockResolvedValue(null);

    await get(REQUESTER);

    // The guard must not turn every single-device account into a refusal.
    expect(emit).toHaveBeenCalledWith('deviceList', {
      userId: REQUESTER,
      authorization: null,
    });
  });

  it('still answers an account with NO live device at all', async () => {
    getAuthorization.mockResolvedValue(null);
    pendingReplacementVersion.mockResolvedValue(null);

    await get(REQUESTER);

    // Offline, mid-provisioning or deleted — not this defect, and silently
    // refusing it would be a new failure mode invented by the guard.
    expect(emit).toHaveBeenCalledWith('deviceList', {
      userId: REQUESTER,
      authorization: null,
    });
  });

  // --- (l): the same refusal must cover the ENROLLED shape --------------
  // A §6.2 teardown deliberately LEAVES the enrollment row ((xxix)) and only
  // stamps `devices.revokedAt`, so `listCanonical` still names the pre-reset
  // devices as live. The peer's pinned anchor VERIFIES that dead roster, since
  // the enrollment was signed by the very key it pinned.

  it('REFUSES an ENROLLED account that owes a replacement enrollment', async () => {
    // The default beforeEach row is present; only the owed replacement differs.
    pendingReplacementVersion.mockResolvedValue(4);

    await get(REQUESTER);

    // Before (l) the `!row` conjunct skipped the guard here and served the
    // orphaned roster, and the sender was shown a SUCCESSFUL send while the
    // recipient never learned the message existed.
    expect(emit).not.toHaveBeenCalled();
  });

  it('serves an enrolled account that owes nothing, so the guard is not a blanket refusal', async () => {
    pendingReplacementVersion.mockResolvedValue(null);

    await get(REQUESTER);

    expect(emit).toHaveBeenCalledWith(
      'deviceList',
      expect.objectContaining({ userId: REQUESTER }),
    );
  });

  // --- getDeviceLists: the same own-id rule, applied to each user of a batch --
  // The batch verb may never become a way around the per-user rule above.
  describe('getDeviceLists (batch)', () => {
    const getMany = (data: unknown) =>
      service.handleGetDeviceLists(client as Socket, data);

    it('serves only the caller out of a batch and stays silent on the rest', async () => {
      await getMany({ userIds: [TARGET, REQUESTER, 11] });

      expect(emit.mock.calls).toEqual([
        [
          'deviceList',
          { userId: REQUESTER, authorization: authorizationProjection },
        ],
      ]);
      expect(getAuthorization).not.toHaveBeenCalledWith(TARGET);
      expect(getAuthorization).not.toHaveBeenCalledWith(11);
    });

    it('stays silent for the caller who owes a replacement enrollment', async () => {
      pendingReplacementVersion.mockResolvedValue(4);

      await getMany({ userIds: [REQUESTER, TARGET] });

      expect(emit).not.toHaveBeenCalled();
    });

    it('does not throw when the own roster fails to load', async () => {
      getAuthorization.mockRejectedValue(new Error('db down'));

      await expect(
        getMany({ userIds: [REQUESTER, TARGET] }),
      ).resolves.toBeUndefined();

      expect(emit).not.toHaveBeenCalled();
    });

    it('accepts a full batch of 256 users', async () => {
      const userIds = [
        REQUESTER,
        ...Array.from({ length: 255 }, (_, i) => i + 100),
      ];

      await getMany({ userIds });

      expect(emit.mock.calls).toEqual([
        [
          'deviceList',
          { userId: REQUESTER, authorization: authorizationProjection },
        ],
      ]);
    });

    it.each([
      ['a user named twice', { userIds: [TARGET, REQUESTER, TARGET] }],
      [
        'more than 256 users',
        { userIds: Array.from({ length: 257 }, (_, i) => i + 100) },
      ],
      ['no users', { userIds: [] }],
      ['user id 0', { userIds: [REQUESTER, 0] }],
      ['a user id above 2^31-1', { userIds: [2147483648] }],
      ['a fractional user id', { userIds: [9.5] }],
      ['a user id as a string', { userIds: ['9'] }],
      ['userIds that is not an array', { userIds: TARGET }],
      ['no payload', null],
    ])(
      'refuses a batch with %s whole, in silence, touching nothing',
      async (_label, data) => {
        await getMany(data);

        expect(emit).not.toHaveBeenCalled();
        expect(getAuthorization).not.toHaveBeenCalled();
      },
    );

    it('accepts the largest user id, 2^31-1', async () => {
      client = { data: { user: { id: 2147483647 } }, emit };

      await getMany({ userIds: [2147483647] });

      expect(emit).toHaveBeenCalledWith(
        'deviceList',
        expect.objectContaining({ userId: 2147483647 }),
      );
    });
  });
});
