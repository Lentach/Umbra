import { HttpException, NotFoundException } from '@nestjs/common';
import { createHash, randomBytes } from 'crypto';
import type { Request } from 'express';
import { BOX_LIMITS, BOX_THROTTLE_TTL_MS } from './box.constants';
import { BoxMediaController } from './box-media.controller';
import type { BoxMediaStore } from './box-media.store';
import type { BoxService } from './box.service';

const b64 = (b: Buffer): string => b.toString('base64url');
const sha = (b: Buffer): Buffer => createHash('sha256').update(b).digest();

/** One stored medium, and the calls the route makes, in order. */
function setup(deleteHash: Buffer | null) {
  const id = randomBytes(32);
  const calls: string[] = [];
  const rows = new Map<string, { path: string; deleteHash: Buffer | null }>([
    [b64(id), { path: 'f.bin', deleteHash }],
  ]);
  const box = {
    mediaForDelete: jest.fn((key: Buffer) =>
      Promise.resolve(rows.get(b64(key)) ?? null),
    ),
    deleteMedia: jest.fn((ids: Buffer[]) => {
      calls.push(`row:${ids.map(b64).join()}`);
      for (const key of ids) rows.delete(b64(key));
      return Promise.resolve();
    }),
  };
  const store = {
    remove: jest.fn((path: string) => {
      calls.push(`file:${path}`);
      return Promise.resolve();
    }),
  };
  const controller = new BoxMediaController(
    box as unknown as BoxService,
    store as unknown as BoxMediaStore,
  );
  const del = (mediaId: string, secret?: string): Promise<void> =>
    controller.remove(mediaId, {
      headers: secret === undefined ? {} : { 'box-delete-secret': secret },
    } as unknown as Request);
  return { id, calls, rows, del };
}

describe('DELETE /box/media/:id (plan D3)', () => {
  it('removes the file, then the row, for the right secret', async () => {
    const secret = randomBytes(32);
    const { id, calls, rows, del } = setup(sha(secret));

    await expect(del(b64(id), b64(secret))).resolves.toBeUndefined();

    expect(calls).toEqual(['file:f.bin', `row:${b64(id)}`]);
    expect(rows.size).toBe(0);
  });

  it.each([
    ['a wrong secret', () => b64(randomBytes(32))],
    ['no secret', () => undefined],
    ['a malformed secret', () => 'not-base64url!'],
    ['a short secret', () => b64(randomBytes(31))],
    // The hash itself is not the capability: knowing it (a DB leak) deletes nothing.
    ['the stored hash', (hash: Buffer) => b64(hash)],
  ])('deletes nothing for %s, answering 404', async (_label, presented) => {
    const secret = randomBytes(32);
    const hash = sha(secret);
    const { id, calls, rows, del } = setup(hash);

    await expect(del(b64(id), presented(hash))).rejects.toBeInstanceOf(
      NotFoundException,
    );

    expect(calls).toEqual([]);
    expect(rows.size).toBe(1);
  });

  it('never deletes an upload that carried no hash (pre-D3 clients)', async () => {
    const { id, calls, rows, del } = setup(null);

    await expect(del(b64(id), b64(randomBytes(32)))).rejects.toBeInstanceOf(
      NotFoundException,
    );

    expect(calls).toEqual([]);
    expect(rows.size).toBe(1);
  });

  it('answers an unknown id exactly as a wrong secret (no existence oracle)', async () => {
    const secret = randomBytes(32);
    const { id, del } = setup(sha(secret));
    const wrong = await del(b64(id), b64(randomBytes(32))).catch(
      (e: HttpException) => [e.getStatus(), e.getResponse()],
    );
    const unknown = await del(b64(randomBytes(32)), b64(secret)).catch(
      (e: HttpException) => [e.getStatus(), e.getResponse()],
    );

    expect(unknown).toEqual(wrong);
    expect(wrong).toEqual([404, expect.anything()]);
  });

  it('is throttled per box tracker like the other media routes', () => {
    // @Throttle metadata lives on the route handler under THROTTLER:<key><name>.
    const handler = Object.getOwnPropertyDescriptor(
      BoxMediaController.prototype,
      'remove',
    )?.value as object;
    const download = Object.getOwnPropertyDescriptor(
      BoxMediaController.prototype,
      'download',
    )?.value as object;

    expect(Reflect.getMetadata('THROTTLER:LIMITdefault', handler)).toBe(
      BOX_LIMITS.mediaDelete,
    );
    expect(Reflect.getMetadata('THROTTLER:TTLdefault', handler)).toBe(
      BOX_THROTTLE_TTL_MS,
    );
    // The same /64-widened tracker as download, never Nest's default IP.
    expect(Reflect.getMetadata('THROTTLER:TRACKERdefault', handler)).toBe(
      Reflect.getMetadata('THROTTLER:TRACKERdefault', download),
    );
    expect(
      Reflect.getMetadata('THROTTLER:TRACKERdefault', handler),
    ).toBeInstanceOf(Function);
  });
});
