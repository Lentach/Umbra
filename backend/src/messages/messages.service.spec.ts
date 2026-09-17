import { MessagesService } from './messages.service';
import { Repository } from 'typeorm';
import { Message, MessageDeliveryStatus } from './message.entity';
import { getRepositoryToken } from '@nestjs/typeorm';
import { Test } from '@nestjs/testing';
import { MESSAGE_NOT_EXPIRED_SQL } from './message-expiry.util';
import { MediaCleanupService } from '../media/media-cleanup.service';

/** Every MessagesService module needs this since the hard-delete rule. */
const mediaCleanupMock = () => ({
  provide: MediaCleanupService,
  useValue: { deleteMediaFile: jest.fn().mockResolvedValue(undefined) },
});

type UnreadSummaryQueryBuilder = {
  innerJoin: jest.Mock;
  select: jest.Mock;
  addSelect: jest.Mock;
  where: jest.Mock;
  andWhere: jest.Mock;
  groupBy: jest.Mock;
  getRawMany: jest.Mock;
};

describe('MessagesService.findByConversation', () => {
  let service: MessagesService;
  let repo: jest.Mocked<Repository<Message>>;

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        {
          provide: getRepositoryToken(Message),
          useValue: { find: jest.fn().mockResolvedValue([]) },
        },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
    repo = module.get(getRepositoryToken(Message));
  });

  it('uses DB-level skip and take when no hiddenByUserId', async () => {
    await service.findByConversation(1, 20, 40);

    expect(repo.find).toHaveBeenCalledWith(
      expect.objectContaining({ take: 20, skip: 40 }),
    );
  });

  it('filters hidden rows and applies client-side offset/limit slicing (oldest-first)', async () => {
    // repo.find is mocked, so it returns rows in the order we supply: newest-first
    // (DESC), mirroring the real query. The service filters rows hidden for the
    // user, then slices(offset, offset+limit) and reverses to oldest-first.
    const rows = [
      { id: 10, hiddenByUserIds: null, createdAt: new Date() },
      { id: 9, hiddenByUserIds: '99', createdAt: new Date() },
      { id: 8, hiddenByUserIds: null, createdAt: new Date() },
      { id: 7, hiddenByUserIds: null, createdAt: new Date() },
      { id: 6, hiddenByUserIds: '1,99,2', createdAt: new Date() },
      { id: 5, hiddenByUserIds: null, createdAt: new Date() },
    ] as unknown as Message[];
    repo.find.mockResolvedValue(rows);

    // limit=2, offset=1, hiddenByUserId=99
    const result = await service.findByConversation(1, 2, 1, 99);

    // With hiddenByUserId, skip=0 and take=fetchLimit (2*3+1+50=57)
    expect(repo.find).toHaveBeenCalledWith(
      expect.objectContaining({ skip: 0, take: 57 }),
    );
    // Hidden rows (9, 6) removed → [10, 8, 7, 5]; slice(1,3) → [8, 7];
    // reverse() → oldest-first [7, 8].
    expect(result.map((m) => m.id)).toEqual([7, 8]);
    expect(result.map((m) => m.id)).not.toContain(9);
    expect(result.map((m) => m.id)).not.toContain(6);
  });
});

describe('MessagesService.getUnreadSummaryForUser', () => {
  let service: MessagesService;
  let qb: UnreadSummaryQueryBuilder;

  beforeEach(async () => {
    qb = {
      innerJoin: jest.fn().mockReturnThis(),
      select: jest.fn().mockReturnThis(),
      addSelect: jest.fn().mockReturnThis(),
      where: jest.fn().mockReturnThis(),
      andWhere: jest.fn().mockReturnThis(),
      groupBy: jest.fn().mockReturnThis(),
      getRawMany: jest.fn().mockResolvedValue([
        { conversationId: '10', count: '3' },
        { conversationId: '20', count: '5' },
      ]),
    };
    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        {
          provide: getRepositoryToken(Message),
          useValue: {
            find: jest.fn().mockResolvedValue([]),
            createQueryBuilder: jest.fn().mockReturnValue(qb),
          },
        },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
  });

  it('returns correct unreadTotal, unreadConversationIds, and per-conv counts', async () => {
    const result = await service.getUnreadSummaryForUser(42);

    expect(result.unreadTotal).toBe(8);
    expect(result.unreadConversationIds).toEqual(
      expect.arrayContaining([10, 20]),
    );
    expect(result.unreadConversationIds).toHaveLength(2);
    expect(result.countByConversationId.get(10)).toBe(3);
    expect(result.countByConversationId.get(20)).toBe(5);
  });

  it('returns zeros when no unread messages', async () => {
    qb.getRawMany.mockResolvedValue([]);

    const result = await service.getUnreadSummaryForUser(99);

    expect(result.unreadTotal).toBe(0);
    expect(result.unreadConversationIds).toHaveLength(0);
    expect(result.countByConversationId.size).toBe(0);
  });

  it('applies unread query filters before grouping by conversation', async () => {
    await service.getUnreadSummaryForUser(42);

    expect(qb.innerJoin).toHaveBeenCalledWith('m.sender', 's');
    expect(qb.innerJoin).toHaveBeenCalledWith('m.conversation', 'c');
    expect(qb.where).toHaveBeenCalledWith(
      '(c.user_one_id = :userId OR c.user_two_id = :userId)',
      { userId: 42 },
    );
    expect(qb.andWhere).toHaveBeenCalledWith('s.id != :userId', { userId: 42 });
    expect(qb.andWhere).toHaveBeenCalledWith('m."deliveryStatus" != :status', {
      status: MessageDeliveryStatus.READ,
    });
    expect(qb.andWhere).toHaveBeenCalledWith(
      MESSAGE_NOT_EXPIRED_SQL,
      expect.objectContaining({ now: expect.any(Date) }),
    );
    expect(qb.andWhere).toHaveBeenCalledWith(
      expect.stringContaining('"hiddenByUserIds"'),
      { uid: 42 },
    );
    expect(qb.andWhere).toHaveBeenCalledWith(
      expect.stringContaining('NOT LIKE'),
      { uid: 42 },
    );
    expect(qb.groupBy).toHaveBeenCalledWith('m.conversation_id');
  });
});

describe('MessagesService.applyEdit', () => {
  let service: MessagesService;
  let repo: jest.Mocked<Repository<Message>>;
  let messageUpdate: jest.Mock;
  let envelopeQb: {
    insert: jest.Mock;
    into: jest.Mock;
    values: jest.Mock;
    orUpdate: jest.Mock;
    execute: jest.Mock;
  };

  beforeEach(async () => {
    messageUpdate = jest.fn().mockResolvedValue({ affected: 1 });
    envelopeQb = {
      insert: jest.fn().mockReturnThis(),
      into: jest.fn().mockReturnThis(),
      values: jest.fn().mockReturnThis(),
      orUpdate: jest.fn().mockReturnThis(),
      execute: jest.fn().mockResolvedValue({}),
    };
    const manager: Record<string, unknown> = {
      getRepository: jest.fn((entity: unknown) =>
        entity === Message
          ? { update: messageUpdate }
          : { createQueryBuilder: jest.fn(() => envelopeQb) },
      ),
    };
    // The real manager hands the callback ITSELF, so the row update and the
    // envelope upsert share one transaction.
    manager.transaction = jest.fn(
      (cb: (m: unknown) => Promise<unknown>) => cb(manager) as Promise<unknown>,
    );

    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        {
          provide: getRepositoryToken(Message),
          useValue: {
            findOne: jest.fn(),
            manager,
          },
        },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
    repo = module.get(getRepositoryToken(Message));
  });

  it('returns null and writes nothing when caller is not the sender', async () => {
    repo.findOne.mockResolvedValue({
      id: 5,
      sender: { id: 99 },
      content: '[encrypted]',
      encryptedContent: 'old',
    } as unknown as Message);

    const result = await service.applyEdit(5, 1, {
      encryptedContent: 'new',
      content: '[encrypted]',
    });

    expect(result).toBeNull();
    expect(messageUpdate).not.toHaveBeenCalled();
    expect(envelopeQb.execute).not.toHaveBeenCalled();
  });

  it('returns null when the message does not exist', async () => {
    repo.findOne.mockResolvedValue(null);

    const result = await service.applyEdit(5, 1, { encryptedContent: 'new' });

    expect(result).toBeNull();
    expect(messageUpdate).not.toHaveBeenCalled();
  });

  it('updates content, editedAt and originDeviceId through a COLUMN-SCOPED update', async () => {
    repo.findOne.mockResolvedValue({
      id: 5,
      sender: { id: 1 },
      content: 'old plaintext',
      encryptedContent: 'old-cipher',
      editedAt: null,
    } as unknown as Message);

    const before = Date.now();
    const result = await service.applyEdit(5, 1, {
      encryptedContent: 'new-cipher',
      content: '[encrypted]',
      originDeviceId: 3,
    });

    expect(messageUpdate).toHaveBeenCalledTimes(1);
    const [criteria, patch] = messageUpdate.mock.calls[0] as [
      Record<string, unknown>,
      Record<string, unknown>,
    ];
    expect(criteria).toEqual({ id: 5 });
    expect(patch.content).toBe('[encrypted]');
    expect(patch.encryptedContent).toBe('new-cipher');
    expect(patch.originDeviceId).toBe(3);
    // A full-entity save would carry deliveryStatus and the expiry stamps back
    // to whatever they held when this method read the row.
    expect(Object.keys(patch).sort()).toEqual([
      'content',
      'editedAt',
      'encryptedContent',
      'originDeviceId',
    ]);
    expect(result!.editedAt).toBeInstanceOf(Date);
    expect(result!.editedAt!.getTime()).toBeGreaterThanOrEqual(before);
    expect(result!.originDeviceId).toBe(3);
  });

  it('leaves the legacy column ALONE when encryptedContent is omitted (new-model row)', async () => {
    repo.findOne.mockResolvedValue({
      id: 5,
      sender: { id: 1 },
      content: '[encrypted]',
      encryptedContent: null,
      editedAt: null,
    } as unknown as Message);

    await service.applyEdit(5, 1, {
      content: '[encrypted]',
      originDeviceId: 2,
      envelopes: [{ userId: 7, deviceId: 1, ciphertext: 'c1' }],
    });

    const [, patch] = messageUpdate.mock.calls[0] as [
      unknown,
      Record<string, unknown>,
    ];
    expect('encryptedContent' in patch).toBe(false);
  });

  it('clears encryptedContent when explicitly passed null', async () => {
    repo.findOne.mockResolvedValue({
      id: 5,
      sender: { id: 1 },
      content: '[encrypted]',
      encryptedContent: 'old-cipher',
      editedAt: null,
    } as unknown as Message);

    const result = await service.applyEdit(5, 1, { encryptedContent: null });

    const [, patch] = messageUpdate.mock.calls[0] as [
      unknown,
      Record<string, unknown>,
    ];
    // explicit null (!== undefined) → field is set to null, not skipped
    expect(patch.encryptedContent).toBeNull();
    expect(result!.encryptedContent).toBeNull();
  });

  it('UPSERTs the named envelopes CONTENT-ONLY, so an existing deliveredAt survives (F8)', async () => {
    repo.findOne.mockResolvedValue({
      id: 5,
      sender: { id: 1 },
      content: '[encrypted]',
      encryptedContent: null,
    } as unknown as Message);

    await service.applyEdit(5, 1, {
      content: '[encrypted]',
      originDeviceId: 1,
      envelopes: [
        { userId: 7, deviceId: 1, ciphertext: 'c-peer-1' },
        { userId: 7, deviceId: 4, ciphertext: 'c-peer-4' },
        { userId: 1, deviceId: 2, ciphertext: 'c-self-2' },
      ],
    });

    expect(envelopeQb.execute).toHaveBeenCalledTimes(1);
    expect(envelopeQb.values).toHaveBeenCalledWith([
      {
        messageId: 5,
        recipientUserId: 7,
        recipientDeviceId: 1,
        ciphertext: 'c-peer-1',
        deliveredAt: null,
        readAt: null,
      },
      {
        messageId: 5,
        recipientUserId: 7,
        recipientDeviceId: 4,
        ciphertext: 'c-peer-4',
        deliveredAt: null,
        readAt: null,
      },
      {
        messageId: 5,
        recipientUserId: 1,
        recipientDeviceId: 2,
        ciphertext: 'c-self-2',
        deliveredAt: null,
        readAt: null,
      },
    ]);
    // THE ticket's core assertion: the conflict clause overwrites `ciphertext`
    // and NOTHING else. This is load-bearing precisely BECAUSE `values()` above
    // passes `deliveredAt: null` — listing the column here (or using save())
    // would push that null over a delivered envelope's real stamp and regress
    // the §4 projection.
    //
    // Scope, per spec §12 (xxxviii): the surviving column that MATTERS is
    // `deliveredAt`. `readAt` is never written by any code path — `stampEnvelope`'s
    // sole call site passes 'deliveredAt', and `markConversationRead` drives the
    // message ROW without touching the envelope — so claiming this test protects
    // `readAt` would be claiming an always-NULL column trivially survives.
    expect(envelopeQb.orUpdate).toHaveBeenCalledWith(
      ['ciphertext'],
      ['messageId', 'recipientUserId', 'recipientDeviceId'],
    );
  });

  it('touches no envelope repository when the edit carries no envelopes', async () => {
    repo.findOne.mockResolvedValue({
      id: 5,
      sender: { id: 1 },
      content: '[encrypted]',
      encryptedContent: 'legacy',
    } as unknown as Message);

    await service.applyEdit(5, 1, { encryptedContent: 'new', content: '[encrypted]' });

    expect(messageUpdate).toHaveBeenCalledTimes(1);
    expect(envelopeQb.execute).not.toHaveBeenCalled();
  });
});

/**
 * The lost-ack reconcile is only exactly-once if the lookup is SENDER-SCOPED
 * (Phase 1, spec §5.4). A send token is unique per sender, not globally, so a
 * query that dropped the sender clause would let one account's retry reconcile
 * onto ANOTHER account's row — re-acking a stranger's message and leaking its
 * id and conversation back to the wrong client. Nothing pinned the clause.
 */
describe('MessagesService.findBySendToken', () => {
  it('scopes the lookup to the SENDER, not the token alone', async () => {
    const repo = { findOne: jest.fn().mockResolvedValue(null) };
    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        { provide: getRepositoryToken(Message), useValue: repo },
        mediaCleanupMock(),
      ],
    }).compile();
    const service = module.get(MessagesService);

    await service.findBySendToken(42, 'tok-abcdefgh');

    expect(repo.findOne).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { sender: { id: 42 }, sendToken: 'tok-abcdefgh' },
      }),
    );
  });
});

/**
 * The WRITE half of envelope-stamp survival (spec §12 (xxxviii)).
 *
 * `applyEdit`'s content-only conflict clause is what stops an EDIT from zeroing
 * a stamp; this is what stops a second DELIVERY from moving one. Nothing pinned
 * either property of `stampEnvelope` before — it was mocked out everywhere it
 * was used — even though the columns are unreadable over the wire, so a
 * regression here would be invisible until a per-device delivery feature
 * eventually reads them.
 */
describe('MessagesService.stampEnvelope', () => {
  type UpdateBuilder = {
    update: jest.Mock;
    set: jest.Mock;
    where: jest.Mock;
    execute: jest.Mock;
  };
  let builder: UpdateBuilder;
  let service: MessagesService;

  beforeEach(async () => {
    builder = {
      update: jest.fn().mockReturnThis(),
      set: jest.fn().mockReturnThis(),
      where: jest.fn().mockReturnThis(),
      execute: jest.fn().mockResolvedValue({ affected: 1 }),
    };
    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        {
          provide: getRepositoryToken(Message),
          useValue: {
            manager: {
              getRepository: jest.fn(() => ({
                createQueryBuilder: jest.fn(() => builder),
              })),
            },
          },
        },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
  });

  /** The `set` payload, with the SQL-function values resolved to strings. */
  function assignedColumns(): Record<string, string> {
    const [patch] = builder.set.mock.calls[0] as [
      Record<string, () => string>,
    ];
    return Object.fromEntries(
      Object.entries(patch).map(([column, value]) => [column, value()]),
    );
  }

  it('assigns ONLY the named column, so stamping delivery cannot touch readAt', async () => {
    await service.stampEnvelope(5, 7, 2, 'deliveredAt');

    expect(assignedColumns()).toEqual({ deliveredAt: 'now()' });
  });

  it('is WRITE-ONCE: an already-stamped envelope is excluded by the predicate', async () => {
    await service.stampEnvelope(5, 7, 2, 'deliveredAt');

    const [predicate] = builder.where.mock.calls[0] as [string];
    // This is the survival property expressible without a database: a second
    // `messageDelivered` — a reconnect, or a second socket of the same device —
    // must not move an existing stamp forward, so the first delivery time is
    // the durable one.
    expect(predicate).toContain('"deliveredAt" IS NULL');
  });

  it('is scoped to exactly one (message, recipient, device) — no cross-device bleed', async () => {
    await service.stampEnvelope(5, 7, 2, 'deliveredAt');

    const [predicate, params] = builder.where.mock.calls[0] as [
      string,
      Record<string, number>,
    ];
    expect(predicate).toContain('"messageId" = :messageId');
    expect(predicate).toContain('"recipientUserId" = :recipientUserId');
    expect(predicate).toContain('"recipientDeviceId" = :recipientDeviceId');
    expect(params).toEqual({
      messageId: 5,
      recipientUserId: 7,
      recipientDeviceId: 2,
    });
  });
});

describe('MessagesService.findServedMessageIds', () => {
  const DAY_MS = 86400 * 1000;

  type ServedQueryBuilder = {
    innerJoin: jest.Mock;
    select: jest.Mock;
    addSelect: jest.Mock;
    where: jest.Mock;
    andWhere: jest.Mock;
    getRawMany: jest.Mock;
  };

  let service: MessagesService;
  let qb: ServedQueryBuilder;
  let createQueryBuilder: jest.Mock;

  /** Every predicate the built query carries, in one flat list. */
  const predicates = (): string[] =>
    [
      ...(qb.where.mock.calls as unknown[][]),
      ...(qb.andWhere.mock.calls as unknown[][]),
    ].map((c) => String(c[0]));

  beforeEach(async () => {
    qb = {
      innerJoin: jest.fn().mockReturnThis(),
      select: jest.fn().mockReturnThis(),
      addSelect: jest.fn().mockReturnThis(),
      where: jest.fn().mockReturnThis(),
      andWhere: jest.fn().mockReturnThis(),
      getRawMany: jest.fn().mockResolvedValue([]),
    };
    createQueryBuilder = jest.fn(() => qb);
    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        {
          provide: getRepositoryToken(Message),
          useValue: { createQueryBuilder },
        },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
  });

  it('reports a message the caller SENT as still served', async () => {
    // The regression this guards: the unread-count queries in this same
    // service all carry `s.id != :userId`. Copying that here would report the
    // user's entire outgoing history as gone and the client would destroy it.
    qb.getRawMany.mockResolvedValue([
      {
        id: 7,
        hiddenByUserIds: null,
        expiresAt: null,
        disappearAfterSeconds: null,
        createdAt: new Date(),
      },
    ]);

    expect(await service.findServedMessageIds([7], 1)).toEqual([7]);
    expect(predicates().join(' ')).not.toMatch(/sender|s\.id|deliveryStatus/);
  });

  it('scopes to conversations the caller participates in', async () => {
    await service.findServedMessageIds([7], 42);

    expect(qb.innerJoin).toHaveBeenCalledWith('m.conversation', 'c');
    expect(qb.andWhere).toHaveBeenCalledWith(
      '(c.user_one_id = :userId OR c.user_two_id = :userId)',
      { userId: 42 },
    );
  });

  it('drops rows the caller hid with "delete for me"', async () => {
    qb.getRawMany.mockResolvedValue([
      {
        id: 1,
        hiddenByUserIds: '5,42,7',
        expiresAt: null,
        disappearAfterSeconds: null,
        createdAt: new Date(),
      },
      {
        id: 2,
        hiddenByUserIds: '5,7',
        expiresAt: null,
        disappearAfterSeconds: null,
        createdAt: new Date(),
      },
      {
        id: 3,
        hiddenByUserIds: null,
        expiresAt: null,
        disappearAfterSeconds: null,
        createdAt: new Date(),
      },
    ]);

    expect(await service.findServedMessageIds([1, 2, 3], 42)).toEqual([2, 3]);
  });

  it('drops expired rows but keeps a disappearing message still inside its unread window', async () => {
    const now = Date.now();
    qb.getRawMany.mockResolvedValue([
      // Deadline already passed.
      {
        id: 1,
        hiddenByUserIds: null,
        expiresAt: new Date(now - 1000),
        disappearAfterSeconds: 60,
        createdAt: new Date(now - 5000),
      },
      // Read-mode, never read, sent two days ago → past the 1-day unread cap.
      {
        id: 2,
        hiddenByUserIds: null,
        expiresAt: null,
        disappearAfterSeconds: 60,
        createdAt: new Date(now - 2 * DAY_MS),
      },
      // Read-mode, never read, sent a minute ago → still live despite the
      // 60-second timer: the clock only starts when the recipient reads.
      {
        id: 3,
        hiddenByUserIds: null,
        expiresAt: null,
        disappearAfterSeconds: 60,
        createdAt: new Date(now - 60 * 1000),
      },
      // Deadline in the future.
      {
        id: 4,
        hiddenByUserIds: null,
        expiresAt: new Date(now + DAY_MS),
        disappearAfterSeconds: null,
        createdAt: new Date(now - 5000),
      },
    ]);

    expect(await service.findServedMessageIds([1, 2, 3, 4], 42)).toEqual([
      3, 4,
    ]);
  });

  it('never queries for an empty or non-positive id set', async () => {
    expect(await service.findServedMessageIds([], 42)).toEqual([]);
    expect(await service.findServedMessageIds([0, -3, 1.5, NaN], 42)).toEqual(
      [],
    );
    expect(createQueryBuilder).not.toHaveBeenCalled();
  });

  it('de-duplicates the requested ids', async () => {
    await service.findServedMessageIds([4, 4, 9, 4], 42);

    expect(qb.where).toHaveBeenCalledWith('m.id IN (:...ids)', { ids: [4, 9] });
  });
});

describe('MessagesService.hideMessageForUser', () => {
  let service: MessagesService;
  let repo: {
    findOne: jest.Mock;
    query: jest.Mock<Promise<unknown>, [string, unknown[]]>;
    delete: jest.Mock;
  };
  let mediaCleanup: { deleteMediaFile: jest.Mock };

  const conv = (a: number, b: number) => ({
    id: 10,
    userOne: { id: a },
    userTwo: { id: b },
  });

  /** repo.query() returns the [rows, rowCount] tuple for UPDATE…RETURNING. */
  const returning = (hiddenByUserIds: string | null) => [
    [{ hiddenByUserIds }],
    1,
  ];

  beforeEach(async () => {
    repo = {
      findOne: jest.fn(),
      query: jest
        .fn<Promise<unknown>, [string, unknown[]]>()
        .mockResolvedValue(returning('1')),
      delete: jest.fn().mockResolvedValue({ affected: 1 }),
    };
    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        { provide: getRepositoryToken(Message), useValue: repo },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
    mediaCleanup = module.get(MediaCleanupService);
  });

  it('NEVER deletes when only one participant hid the row', async () => {
    // THE guard of this feature: the other participant still reads the
    // message. Weakening every() to some(), or hardcoding a count, must turn
    // this red.
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: null,
      mediaUrl: 'https://example.com/media/msgs/a.bin',
      conversation: conv(1, 2),
    });
    repo.query.mockResolvedValue(returning('1'));

    expect(await service.hideMessageForUser(7, 1)).toBe(true);

    expect(repo.delete).not.toHaveBeenCalled();
    expect(mediaCleanup.deleteMediaFile).not.toHaveBeenCalled();
  });

  it('hard-deletes once EVERY participant hid, media then replies then row', async () => {
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: '1',
      mediaUrl: 'https://example.com/media/msgs/a.bin',
      conversation: conv(1, 2),
    });
    repo.query
      .mockResolvedValueOnce(returning('1,2')) // hidden append
      .mockResolvedValueOnce([[], 0]); // reply detach

    expect(await service.hideMessageForUser(7, 2)).toBe(true);

    expect(mediaCleanup.deleteMediaFile).toHaveBeenCalledWith(
      'https://example.com/media/msgs/a.bin',
    );
    expect(repo.delete).toHaveBeenCalledWith({ id: 7 });
    // Reply pointers detach (self-FK has no ON DELETE) and media unlinks
    // BEFORE the row goes away.
    const detachCall = repo.query.mock.calls.find((c) =>
      c[0].includes('reply_to_message_id'),
    );
    expect(detachCall).toBeDefined();
    expect(detachCall![0]).toContain('SET reply_to_message_id = NULL');
    const deleteOrder = repo.delete.mock.invocationCallOrder[0];
    const detachOrder =
      repo.query.mock.invocationCallOrder[repo.query.mock.calls.length - 1];
    // Full pinned order: media unlink → reply detach → row delete.
    expect(
      mediaCleanup.deleteMediaFile.mock.invocationCallOrder[0],
    ).toBeLessThan(detachOrder);
    expect(detachOrder).toBeLessThan(deleteOrder);
  });

  it('appends via a single atomic UPDATE with quoted "hiddenByUserIds"', async () => {
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: null,
      mediaUrl: null,
      conversation: conv(1, 2),
    });

    await service.hideMessageForUser(7, 1);

    const [sql, params] = repo.query.mock.calls[0];
    expect(sql).toContain('"hiddenByUserIds"');
    expect(sql).toContain('RETURNING');
    expect(params).toEqual([7, '1']);
  });

  it('skips media unlink when the row has none', async () => {
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: '2',
      mediaUrl: null,
      conversation: conv(1, 2),
    });
    repo.query
      .mockResolvedValueOnce(returning('2,1'))
      .mockResolvedValueOnce([[], 0]);

    await service.hideMessageForUser(7, 1);

    expect(mediaCleanup.deleteMediaFile).not.toHaveBeenCalled();
    expect(repo.delete).toHaveBeenCalledWith({ id: 7 });
  });

  it('is idempotent for an already-hidden user and still heals a fully-hidden legacy row', async () => {
    // Pre-fix data: both participants hid before the rule shipped. A repeat
    // call must not re-append (no UPDATE on hiddenByUserIds) but MUST
    // hard-delete.
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: '1,2',
      mediaUrl: null,
      conversation: conv(1, 2),
    });
    repo.query.mockResolvedValue([[], 0]); // only the reply detach runs

    expect(await service.hideMessageForUser(7, 1)).toBe(true);

    const appendCalls = repo.query.mock.calls.filter((c: unknown[]) =>
      String(c[0]).includes('"hiddenByUserIds"'),
    );
    expect(appendCalls).toHaveLength(0);
    expect(repo.delete).toHaveBeenCalledWith({ id: 7 });
  });

  it('returns false when the message is gone', async () => {
    repo.findOne.mockResolvedValue(null);

    expect(await service.hideMessageForUser(7, 1)).toBe(false);
    expect(repo.query).not.toHaveBeenCalled();
    expect(repo.delete).not.toHaveBeenCalled();
  });

  it('returns false when the row vanishes between read and append', async () => {
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: null,
      mediaUrl: null,
      conversation: conv(1, 2),
    });
    repo.query.mockResolvedValue([[], 0]); // UPDATE matched nothing

    expect(await service.hideMessageForUser(7, 1)).toBe(false);
    expect(repo.delete).not.toHaveBeenCalled();
  });

  it('never deletes when the conversation relation is missing (fail closed)', async () => {
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: '2',
      mediaUrl: null,
      conversation: null,
    });
    repo.query.mockResolvedValue(returning('2,1'));

    expect(await service.hideMessageForUser(7, 1)).toBe(true);
    expect(repo.delete).not.toHaveBeenCalled();
  });

  it('uses the actual participant set — a self-conversation deletes after its single hide', async () => {
    // Guards against hardcoding "2 participants": the set is derived from
    // the conversation relation, deduplicated.
    repo.findOne.mockResolvedValue({
      id: 7,
      hiddenByUserIds: null,
      mediaUrl: null,
      conversation: conv(5, 5),
    });
    repo.query
      .mockResolvedValueOnce(returning('5'))
      .mockResolvedValueOnce([[], 0]);

    expect(await service.hideMessageForUser(7, 5)).toBe(true);
    expect(repo.delete).toHaveBeenCalledWith({ id: 7 });
  });
});

describe('MessagesService.deleteById', () => {
  let service: MessagesService;
  let repo: {
    findOne: jest.Mock;
    query: jest.Mock<Promise<unknown>, [string, unknown[]]>;
    remove: jest.Mock;
  };

  beforeEach(async () => {
    repo = {
      findOne: jest.fn(),
      query: jest
        .fn<Promise<unknown>, [string, unknown[]]>()
        .mockResolvedValue([[], 0]),
      remove: jest.fn().mockImplementation((m) => Promise.resolve(m)),
    };
    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        { provide: getRepositoryToken(Message), useValue: repo },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
  });

  it('detaches replies BEFORE removing the row (self-FK has no ON DELETE)', async () => {
    repo.findOne.mockResolvedValue({
      id: 9,
      sender: { id: 1 },
      conversation: { id: 10 },
    });

    expect(await service.deleteById(9, 1)).not.toBeNull();

    const [sql, params] = repo.query.mock.calls[0];
    expect(sql).toContain('SET reply_to_message_id = NULL');
    expect(params).toEqual([9]);
    expect(repo.query.mock.invocationCallOrder[0]).toBeLessThan(
      repo.remove.mock.invocationCallOrder[0],
    );
  });

  it('does not touch replies when the caller is not the sender', async () => {
    repo.findOne.mockResolvedValue({
      id: 9,
      sender: { id: 99 },
      conversation: { id: 10 },
    });

    expect(await service.deleteById(9, 1)).toBeNull();
    expect(repo.query).not.toHaveBeenCalled();
    expect(repo.remove).not.toHaveBeenCalled();
  });
});

describe('MessagesService reactions (BE-152/BE-201 atomicity)', () => {
  let service: MessagesService;
  let store: string | null;
  let manager: { query: jest.Mock; findOne: jest.Mock };
  let repo: { manager: { transaction: jest.Mock } };

  beforeEach(async () => {
    store = null;
    // Stateful single-row store so a re-read inside the locked transaction sees
    // the prior writer's UPDATE. Postgres shapes matter: SELECT returns plain
    // rows, UPDATE returns [rows, rowCount].
    manager = {
      query: jest.fn((sql: string, params: unknown[]) => {
        if (/FOR UPDATE/.test(sql)) {
          return Promise.resolve([{ reactions: store }]);
        }
        store = params[1] as string;
        return Promise.resolve([[], 1]);
      }),
      findOne: jest.fn(() =>
        Promise.resolve({ id: 42, reactions: store } as unknown as Message),
      ),
    };
    repo = { manager: { transaction: jest.fn((cb: any) => cb(manager)) } };

    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        { provide: getRepositoryToken(Message), useValue: repo },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
  });

  it('locks the row with SELECT ... FOR UPDATE inside a transaction', async () => {
    await service.addOrUpdateReaction(42, 1, '👍');
    expect(repo.manager.transaction).toHaveBeenCalled();
    const selectCall = manager.query.mock.calls.find(([sql]) =>
      /FOR UPDATE/.test(sql as string),
    );
    expect(selectCall).toBeDefined();
    expect(selectCall![1]).toEqual([42]);
  });

  it('returns null and issues no UPDATE when the message is missing', async () => {
    manager.query.mockImplementation((sql: string) =>
      /FOR UPDATE/.test(sql) ? Promise.resolve([]) : Promise.resolve([[], 0]),
    );
    const result = await service.addOrUpdateReaction(99, 1, '👍');
    expect(result).toBeNull();
    const updateCall = manager.query.mock.calls.find(([sql]) =>
      /UPDATE public\.messages/.test(sql as string),
    );
    expect(updateCall).toBeUndefined();
  });

  it('two concurrent add-reactions both survive (no lost update)', async () => {
    // Each call re-reads inside its own locked transaction, so the second sees
    // the first's write. The old findOne+save (no lock) dropped one reaction.
    await service.addOrUpdateReaction(42, 1, '👍');
    await service.addOrUpdateReaction(42, 2, '❤️');
    expect(JSON.parse(store as string)).toEqual({ '👍': [1], '❤️': [2] });
  });

  it('concurrent add then remove resolves without a ghost reaction', async () => {
    await service.addOrUpdateReaction(42, 1, '👍');
    await service.removeReaction(42, 1);
    expect(JSON.parse(store as string)).toEqual({});
  });

  it('removes the user from a LEGACY plaintext key too', async () => {
    // The reaction-token compat window: an un-updated client stored the plain
    // emoji, and the updated client that toggles it off knows only its own
    // blinded token. An exact-key delete left the chip lit forever.
    store = JSON.stringify({ '👍': [1, 2] });
    await service.removeReaction(42, 1);
    expect(JSON.parse(store)).toEqual({ '👍': [2] });
  });

  it('removes the user from a token key without being told which', async () => {
    const token = 'AAAAAAAAAAAAAAAAAAAAAA';
    store = JSON.stringify({ [token]: [1] });
    await service.removeReaction(42, 1);
    expect(JSON.parse(store)).toEqual({});
  });

  it('degrades corrupt stored reactions instead of throwing', async () => {
    store = '{corrupt';
    await service.addOrUpdateReaction(42, 1, '👍');
    expect(JSON.parse(store as string)).toEqual({ '👍': [1] });
  });
});

describe('MessagesService.create envelope fan-out (spec §5.2 + §12 (v))', () => {
  /** The transactional manager the service asks for per-entity repositories. */
  type TxManager = { getRepository: jest.Mock };
  type MessageRepoMock = {
    create: jest.Mock;
    save: jest.Mock;
    findOne: jest.Mock;
    manager: { transaction: jest.Mock };
  };

  let service: MessagesService;
  let repo: MessageRepoMock;
  let messageRepo: { save: jest.Mock };
  let envelopeRepo: { insert: jest.Mock };

  beforeEach(async () => {
    messageRepo = {
      save: jest.fn((msg: object) => Promise.resolve({ ...msg, id: 500 })),
    };
    envelopeRepo = { insert: jest.fn().mockResolvedValue(undefined) };
    const manager: TxManager = {
      // The transactional manager hands out per-entity repositories; keying on
      // the entity name keeps the assertion independent of import identity.
      getRepository: jest.fn((entity: { name: string }) =>
        entity.name === 'Message' ? messageRepo : envelopeRepo,
      ),
    };
    repo = {
      create: jest.fn((fields: object) => fields),
      save: jest.fn(),
      findOne: jest.fn(),
      manager: {
        transaction: jest.fn((run: (m: TxManager) => Promise<unknown>) =>
          run(manager),
        ),
      },
    };

    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        { provide: getRepositoryToken(Message), useValue: repo },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
  });

  const sender = { id: 1 } as never;
  const conversation = { id: 10 } as never;

  it('writes the row and every envelope inside ONE transaction', async () => {
    const message = await service.create('[encrypted]', sender, conversation, {
      envelopes: [
        { userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' },
        { userId: 2, deviceId: 2, ciphertext: '3:for-bob-2' },
      ],
    });

    expect(repo.manager.transaction).toHaveBeenCalledTimes(1);
    // The non-transactional save must NOT be the writer for a fan-out: a
    // half-written send would leave a device unable to ever read the message.
    expect(repo.save).not.toHaveBeenCalled();
    expect(messageRepo.save).toHaveBeenCalledTimes(1);
    expect(envelopeRepo.insert).toHaveBeenCalledWith([
      {
        messageId: 500,
        recipientUserId: 2,
        recipientDeviceId: 1,
        ciphertext: '3:for-bob-1',
        deliveredAt: null,
        readAt: null,
      },
      {
        messageId: 500,
        recipientUserId: 2,
        recipientDeviceId: 2,
        ciphertext: '3:for-bob-2',
        deliveredAt: null,
        readAt: null,
      },
    ]);
    expect(message.id).toBe(500);
  });

  it('keeps the original single save when there are no envelopes', async () => {
    repo.save.mockResolvedValue({ id: 501 });

    await service.create('hello', sender, conversation, {});

    expect(repo.manager.transaction).not.toHaveBeenCalled();
    expect(repo.save).toHaveBeenCalledTimes(1);
    expect(envelopeRepo.insert).not.toHaveBeenCalled();
  });
});

describe('MessagesService.updateDeliveryStatus projection (falsification 19)', () => {
  type UpdateBuilder = {
    update: jest.Mock;
    set: jest.Mock;
    where: jest.Mock;
    execute: jest.Mock;
  };

  let service: MessagesService;
  let repo: {
    findOne: jest.Mock;
    save: jest.Mock;
    createQueryBuilder: jest.Mock;
  };
  let builder: UpdateBuilder;

  beforeEach(async () => {
    builder = {
      update: jest.fn().mockReturnThis(),
      set: jest.fn().mockReturnThis(),
      where: jest.fn().mockReturnThis(),
      execute: jest.fn().mockResolvedValue({ affected: 1 }),
    };
    repo = {
      findOne: jest.fn().mockResolvedValue({
        id: 100,
        deliveryStatus: MessageDeliveryStatus.SENT,
        expiresAt: null,
        disappearAfterSeconds: 300,
        sender: { id: 1 },
        conversation: { id: 10 },
      }),
      save: jest.fn(),
      createQueryBuilder: jest.fn(() => builder),
    };

    const module = await Test.createTestingModule({
      providers: [
        MessagesService,
        { provide: getRepositoryToken(Message), useValue: repo },
        mediaCleanupMock(),
      ],
    }).compile();
    service = module.get(MessagesService);
  });

  it('writes ONLY deliveryStatus, via a scoped UPDATE and never a full-entity save', async () => {
    await service.updateDeliveryStatus(100, MessageDeliveryStatus.DELIVERED);

    // A full-entity save would rewrite every column from a possibly stale
    // in-memory copy and could silently revert a concurrent write.
    expect(repo.save).not.toHaveBeenCalled();
    expect(builder.set).toHaveBeenCalledWith({
      deliveryStatus: MessageDeliveryStatus.DELIVERED,
    });
    // Nothing about expiry or the disappearing TTL is touched (rider F9, I9).
    const written = builder.set.mock.calls[0][0] as Record<string, unknown>;
    expect(written).not.toHaveProperty('expiresAt');
    expect(written).not.toHaveProperty('disappearAfterSeconds');
    expect(builder.execute).toHaveBeenCalledTimes(1);
  });

  it('keeps the monotonic guard in the WHERE so a race cannot regress the status', async () => {
    await service.updateDeliveryStatus(100, MessageDeliveryStatus.READ);

    const [clause, params] = builder.where.mock.calls[0] as [
      string,
      Record<string, unknown>,
    ];
    expect(clause).toContain('"deliveryStatus" IN');
    expect(params.messageId).toBe(100);
    // READ may only overwrite the strictly lower statuses.
    expect(params.lowerStatuses).toEqual(
      expect.arrayContaining([
        MessageDeliveryStatus.SENT,
        MessageDeliveryStatus.DELIVERED,
      ]),
    );
    expect(params.lowerStatuses).not.toContain(MessageDeliveryStatus.READ);
  });

  it('issues no UPDATE at all when the status would not advance', async () => {
    repo.findOne.mockResolvedValue({
      id: 100,
      deliveryStatus: MessageDeliveryStatus.READ,
      sender: { id: 1 },
      conversation: { id: 10 },
    });

    await service.updateDeliveryStatus(100, MessageDeliveryStatus.DELIVERED);

    expect(repo.createQueryBuilder).not.toHaveBeenCalled();
    expect(repo.save).not.toHaveBeenCalled();
  });
});
