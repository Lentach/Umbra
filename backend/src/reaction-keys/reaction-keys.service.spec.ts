import { DataSource, EntityManager } from 'typeorm';
import { ReactionKeysService } from './reaction-keys.service';

interface Harness {
  service: ReactionKeysService;
  sql: string[];
  params: unknown[][];
  transaction: jest.Mock;
  dataSourceQuery: jest.Mock;
}

/**
 * The reaction-key store speaks SQL through the DataSource (like every other
 * row-locking write path here), so the harness answers the two reads the
 * decision depends on: the locked conversation row and the epoch's existing
 * uploader.
 */
function harness(
  currentEpoch: number | null,
  owners: Array<{ senderUserId: number; senderDeviceId: number }> = [],
  fetchRows: unknown[] = [],
): Harness {
  const sql: string[] = [];
  const params: unknown[][] = [];
  const manager = {
    query: jest.fn((text: string, args: unknown[] = []) => {
      sql.push(text);
      params.push(args);
      if (/FOR UPDATE/.test(text)) {
        return Promise.resolve(
          currentEpoch === null ? [] : [{ reactionKeyEpoch: currentEpoch }],
        );
      }
      if (/SELECT DISTINCT/.test(text)) return Promise.resolve(owners);
      return Promise.resolve([]);
    }),
  };
  const transaction = jest.fn((run: (m: EntityManager) => Promise<unknown>) =>
    run(manager as unknown as EntityManager),
  );
  const dataSourceQuery = jest.fn((text: string, args: unknown[] = []) => {
    sql.push(text);
    params.push(args);
    return Promise.resolve(fetchRows);
  });
  const service = new ReactionKeysService({
    transaction,
    query: dataSourceQuery,
  } as unknown as DataSource);
  return { service, sql, params, transaction, dataSourceQuery };
}

const inserts = (sql: string[]) =>
  sql.filter((text) => /INSERT INTO/.test(text));
const epochWrites = (sql: string[]) =>
  sql.filter((text) => /UPDATE public.conversations/.test(text));

describe('ReactionKeysService.upload', () => {
  it('publishes a new key at current+1 and advances the epoch in the same transaction', async () => {
    const h = harness(0);

    const result = await h.service.upload(7, 1, { userId: 1, deviceId: 2 }, [
      { userId: 2, deviceId: 1, ciphertext: '3:abc' },
    ]);

    expect(result).toEqual({ accepted: true, epoch: 1 });
    expect(h.transaction).toHaveBeenCalledTimes(1);
    expect(inserts(h.sql)).toHaveLength(1);
    // The epoch pointer and the rows it points at must land together: a
    // half-published rotation would advance the epoch past rows no device has.
    expect(epochWrites(h.sql)).toHaveLength(1);
    expect(h.params[h.params.length - 1]).toEqual([1, 7]);
  });

  it('refuses a stale epoch, reports the epoch it actually holds, and writes nothing', async () => {
    const h = harness(3, [{ senderUserId: 9, senderDeviceId: 1 }]);

    const result = await h.service.upload(7, 2, { userId: 1, deviceId: 1 }, [
      { userId: 2, deviceId: 1, ciphertext: '3:abc' },
    ]);

    expect(result).toEqual({ accepted: false, epoch: 3 });
    expect(inserts(h.sql)).toHaveLength(0);
    expect(epochWrites(h.sql)).toHaveLength(0);
  });

  it('refuses the loser of a race for the same new epoch (R3)', async () => {
    // The winner already advanced the conversation to epoch 1 and owns its
    // rows; the loser's copies are wrapped under a DIFFERENT key, so accepting
    // them would leave one side's tokens permanently undecodable.
    const h = harness(1, [{ senderUserId: 1, senderDeviceId: 1 }]);

    const result = await h.service.upload(7, 1, { userId: 2, deviceId: 1 }, [
      { userId: 1, deviceId: 1, ciphertext: '3:loser' },
    ]);

    expect(result).toEqual({ accepted: false, epoch: 1 });
    expect(inserts(h.sql)).toHaveLength(0);
  });

  it('accepts the SAME uploader topping up the current epoch without advancing it', async () => {
    // The `deviceListChanged` re-upload: the same key, sealed to a device that
    // did not exist when the epoch was created.
    const h = harness(2, [{ senderUserId: 1, senderDeviceId: 1 }]);

    const result = await h.service.upload(7, 2, { userId: 1, deviceId: 1 }, [
      { userId: 2, deviceId: 5, ciphertext: '3:new-device' },
    ]);

    expect(result).toEqual({ accepted: true, epoch: 2 });
    expect(inserts(h.sql)).toHaveLength(1);
    expect(epochWrites(h.sql)).toHaveLength(0);
  });

  it('refuses epoch 0 — the "no key ever" sentinel is not a row epoch', async () => {
    const h = harness(0);

    const result = await h.service.upload(7, 0, { userId: 1, deviceId: 1 }, [
      { userId: 2, deviceId: 1, ciphertext: '3:abc' },
    ]);

    expect(result).toEqual({ accepted: false, epoch: 0 });
    expect(h.transaction).not.toHaveBeenCalled();
  });

  it('writes nothing when the conversation was deleted under the upload', async () => {
    const h = harness(null);

    const result = await h.service.upload(7, 1, { userId: 1, deviceId: 1 }, [
      { userId: 2, deviceId: 1, ciphertext: '3:abc' },
    ]);

    expect(result).toEqual({ accepted: false, epoch: 0 });
    expect(inserts(h.sql)).toHaveLength(0);
  });

  it('seals every envelope under the caller-supplied uploader and epoch', async () => {
    const h = harness(0);

    await h.service.upload(7, 1, { userId: 1, deviceId: 3 }, [
      { userId: 1, deviceId: 4, ciphertext: '3:self' },
      { userId: 2, deviceId: 1, ciphertext: '3:peer' },
    ]);

    // conversationId, epoch, senderUserId, senderDeviceId, then one
    // (userId, deviceId, ciphertext) triple per envelope.
    expect(h.params[h.params.length - 2]).toEqual([
      7,
      1,
      1,
      3,
      1,
      4,
      '3:self',
      2,
      1,
      '3:peer',
    ]);
  });
});

describe('ReactionKeysService.fetchOwn', () => {
  it("asks only for the caller's own (userId, deviceId) row", async () => {
    const h = harness(
      0,
      [],
      [
        {
          epoch: 4,
          senderUserId: 2,
          senderDeviceId: 1,
          ciphertext: '3:mine',
        },
      ],
    );

    const row = await h.service.fetchOwn(7, 1, 3);

    expect(row).toEqual({
      epoch: 4,
      senderUserId: 2,
      senderDeviceId: 1,
      ciphertext: '3:mine',
    });
    expect(h.params[0]).toEqual([7, 1, 3]);
  });

  it('answers the current epoch with a null ciphertext when this device has no copy', async () => {
    const h = harness(
      0,
      [],
      [
        {
          epoch: 2,
          senderUserId: null,
          senderDeviceId: null,
          ciphertext: null,
        },
      ],
    );

    // A device that is merely BEHIND must learn the epoch it is behind on —
    // not an error, and not "there is no key".
    expect(await h.service.fetchOwn(7, 1, 9)).toEqual({
      epoch: 2,
      senderUserId: null,
      senderDeviceId: null,
      ciphertext: null,
    });
  });

  it('returns null for a conversation that does not exist', async () => {
    const h = harness(0, [], []);

    expect(await h.service.fetchOwn(7, 1, 1)).toBeNull();
  });
});
