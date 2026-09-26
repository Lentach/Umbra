import { Test, TestingModule } from '@nestjs/testing';
import { Socket } from 'socket.io';
import { ChatDeviceListService } from './chat-device-list.service';
import { ChatValidationService } from './chat-validation.service';
import { DeviceListService } from '../../key-bundles/device-list.service';
import { ConversationsService } from '../../conversations/conversations.service';

/**
 * WHO MAY READ AN ACCOUNT'S DEVICE ROSTER (spec §12 amendment (xliii)).
 *
 * `getDeviceList` used the requester id only to check that SOMEONE was
 * authenticated, then served whatever `userId` the payload named. That made it
 * a device-count, platform and timeline oracle over every account on the
 * instance: walk the ids and learn how many devices each user runs, on which
 * platforms, when each was added and when any was revoked — precise profiling
 * in an app whose whole premise is metadata minimisation, on a repository
 * public since 2026-08-18.
 *
 * These tests pin the three ways in and, just as importantly, the way OUT: a
 * refusal must stay SILENT, because answering at all would confirm whether an
 * account exists.
 */
describe('ChatDeviceListService.handleGetDeviceList entitlement', () => {
  const REQUESTER = 7;
  const TARGET = 9;

  let service: ChatDeviceListService;
  let getAuthorization: jest.Mock;
  let validateCanMessage: jest.Mock;
  let findByUsers: jest.Mock;
  let pendingReplacementVersion: jest.Mock;
  let emit: jest.Mock;
  let client: Partial<Socket>;

  /** The stored row the handler projects when the caller is entitled. */
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
    // Refuses by default, so every test states its OWN reason for being let in
    // and nothing passes merely because the harness was permissive.
    validateCanMessage = jest.fn().mockResolvedValue({
      valid: false,
      error: 'You can only message friends',
    });
    findByUsers = jest.fn().mockResolvedValue(null);
    // The ordinary account owes no replacement enrollment, so the (xlv)
    // clause 2 guard stands aside and these tests exercise entitlement.
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
        { provide: ChatValidationService, useValue: { validateCanMessage } },
        { provide: ConversationsService, useValue: { findByUsers } },
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
    expect(validateCanMessage).not.toHaveBeenCalled();
  });

  it('serves a peer you may message', async () => {
    validateCanMessage.mockResolvedValue({ valid: true });

    await get(TARGET);

    expect(validateCanMessage).toHaveBeenCalledWith(REQUESTER, TARGET);
    expect(emit).toHaveBeenCalledWith(
      'deviceList',
      expect.objectContaining({
        userId: TARGET,
        authorization: authorizationProjection,
      }),
    );
    // The carve-out is not consulted when the cheap predicate already passed.
    expect(findByUsers).not.toHaveBeenCalled();
  });

  it('REFUSES a stranger, in silence', async () => {
    await get(TARGET);

    // Silence is fail-closed on the client (I5: an unanswered fetch means
    // "cannot verify", never "no devices"), and answering would itself
    // confirm whether the account exists.
    expect(emit).not.toHaveBeenCalled();
    expect(getAuthorization).not.toHaveBeenCalled();
  });

  it('still serves a peer you share a CONVERSATION with, after a block', async () => {
    // The carve-out, and it is required rather than convenient: the accept-side
    // gate needs this list to decrypt, so without it a peer who unfriends or
    // blocks you makes history you ALREADY RECEIVED permanently unreadable.
    validateCanMessage.mockResolvedValue({ valid: false, error: 'blocked' });
    findByUsers.mockResolvedValue({ id: 42 });

    await get(TARGET);

    expect(findByUsers).toHaveBeenCalledWith(REQUESTER, TARGET);
    expect(emit).toHaveBeenCalledWith(
      'deviceList',
      expect.objectContaining({ userId: TARGET }),
    );
  });

  it('refuses an unauthenticated socket without touching the database', async () => {
    client = { data: {}, emit };

    await get(TARGET);

    expect(emit).not.toHaveBeenCalled();
    expect(validateCanMessage).not.toHaveBeenCalled();
    expect(getAuthorization).not.toHaveBeenCalled();
  });

  it('echoes the stored listCanonical verbatim for an entitled caller', async () => {
    // Falsification 23: the bytes are re-verified bit-for-bit by the peer, so
    // the gate must not have changed what an ENTITLED caller receives.
    validateCanMessage.mockResolvedValue({ valid: true });

    await get(TARGET);

    expect(emit).toHaveBeenCalledWith('deviceList', {
      userId: TARGET,
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
    validateCanMessage.mockResolvedValue({ valid: true });
    pendingReplacementVersion.mockResolvedValue(4);

    await get(TARGET);

    // Before (l) the `!row` conjunct skipped the guard here and served the
    // orphaned roster, and the sender was shown a SUCCESSFUL send while the
    // recipient never learned the message existed.
    expect(emit).not.toHaveBeenCalled();
  });

  it('serves an enrolled account that owes nothing, so the guard is not a blanket refusal', async () => {
    validateCanMessage.mockResolvedValue({ valid: true });
    pendingReplacementVersion.mockResolvedValue(null);

    await get(TARGET);

    expect(emit).toHaveBeenCalledWith(
      'deviceList',
      expect.objectContaining({ userId: TARGET }),
    );
  });

  // --- getDeviceLists: the same rules, applied to each user of a batch -------
  // One request covers every friend at connect (item 5, E20a) without spending
  // one `getDeviceList` per friend from the shared fetch bucket. It may never
  // become a way around the per-user rules above.
  describe('getDeviceLists (batch)', () => {
    const STRANGER = 11;
    const OWING = 12;

    const getMany = (data: unknown) =>
      service.handleGetDeviceLists(client as Socket, data);

    it('serves each entitled user of a batch and stays silent on the rest', async () => {
      validateCanMessage.mockImplementation((_from: number, to: number) =>
        Promise.resolve(
          to === TARGET ? { valid: true } : { valid: false, error: 'nope' },
        ),
      );

      await getMany({ userIds: [STRANGER, TARGET] });

      expect(emit.mock.calls).toEqual([
        [
          'deviceList',
          { userId: TARGET, authorization: authorizationProjection },
        ],
      ]);
      expect(getAuthorization).not.toHaveBeenCalledWith(STRANGER);
    });

    it('stays silent for a user who owes a replacement enrollment, serving the rest', async () => {
      validateCanMessage.mockResolvedValue({ valid: true });
      pendingReplacementVersion.mockImplementation((userId: number) =>
        Promise.resolve(userId === OWING ? 4 : null),
      );

      await getMany({ userIds: [OWING, TARGET] });

      expect(emit.mock.calls).toEqual([
        [
          'deviceList',
          { userId: TARGET, authorization: authorizationProjection },
        ],
      ]);
    });

    it('serves the rest when one user of the batch fails to load', async () => {
      validateCanMessage.mockResolvedValue({ valid: true });
      getAuthorization.mockImplementation((userId: number) =>
        userId === STRANGER
          ? Promise.reject(new Error('db down'))
          : Promise.resolve(authorizationRow),
      );

      await getMany({ userIds: [STRANGER, TARGET] });

      expect(emit.mock.calls).toEqual([
        [
          'deviceList',
          { userId: TARGET, authorization: authorizationProjection },
        ],
      ]);
    });

    it('serves a full batch of 256 users', async () => {
      validateCanMessage.mockResolvedValue({ valid: true });
      const userIds = Array.from({ length: 256 }, (_, i) => i + 100);

      await getMany({ userIds });

      const served = (emit.mock.calls as [string, { userId: number }][]).map(
        ([, payload]) => payload.userId,
      );
      expect(served).toEqual(userIds);
    });

    it.each([
      ['a user named twice', { userIds: [TARGET, STRANGER, TARGET] }],
      [
        'more than 256 users',
        { userIds: Array.from({ length: 257 }, (_, i) => i + 100) },
      ],
      ['no users', { userIds: [] }],
      ['user id 0', { userIds: [TARGET, 0] }],
      ['a user id above 2^31-1', { userIds: [2147483648] }],
      ['a fractional user id', { userIds: [9.5] }],
      ['a user id as a string', { userIds: ['9'] }],
      ['userIds that is not an array', { userIds: TARGET }],
      ['no payload', null],
    ])(
      'refuses a batch with %s whole, in silence, touching nothing',
      async (_label, data) => {
        validateCanMessage.mockResolvedValue({ valid: true });

        await getMany(data);

        expect(emit).not.toHaveBeenCalled();
        expect(validateCanMessage).not.toHaveBeenCalled();
        expect(getAuthorization).not.toHaveBeenCalled();
      },
    );

    it('accepts the largest user id, 2^31-1', async () => {
      validateCanMessage.mockResolvedValue({ valid: true });

      await getMany({ userIds: [2147483647] });

      expect(emit).toHaveBeenCalledWith(
        'deviceList',
        expect.objectContaining({ userId: 2147483647 }),
      );
    });
  });
});
