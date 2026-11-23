import { generateKeyPairSync, randomBytes, sign } from 'crypto';
import { BoxDelivery } from './box-delivery.service';
import { boxSignedMessage } from './box-signature';
import { BoxGateway } from './box.gateway';

/**
 * A real `BoxDelivery` behind a real `BoxGateway`, one signed subscribe for
 * one rid whose `markSubscribed` step the test controls.
 */
function subscribeFixture() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const authPub = Buffer.from(
    publicKey.export({ format: 'jwk' }).x as string,
    'base64url',
  );
  const rid = randomBytes(32);
  const nid = randomBytes(32);
  const client = { id: 'sock1', connected: true, emit: jest.fn() };

  // `markSubscribed` is the awaited step a disconnect can land in.
  let finishMarking: () => void = () => undefined;
  const marking = new Promise<void>((resolve) => {
    finishMarking = resolve;
  });
  const box = {
    authKeysByRid: jest
      .fn()
      .mockResolvedValue(new Map([[rid.toString('base64url'), authPub]])),
    markSubscribed: jest.fn().mockReturnValue(marking),
    waitingNids: jest.fn().mockResolvedValue([]),
    enqueue: jest.fn().mockResolvedValue({ result: 'stored', rid, nid }),
    pendingHeads: jest.fn().mockResolvedValue([]),
    blobs: jest.fn().mockResolvedValue(new Map()),
  };
  const notifier = { schedule: jest.fn() };
  const delivery = new BoxDelivery(box as never);
  const gateway = new BoxGateway(box as never, delivery, notifier as never);

  const sig = sign(
    null,
    boxSignedMessage('subscribe', client.id, rid),
    privateKey,
  );
  const subscribing = gateway.subscribe(client as never, {
    v: 1,
    subs: [{ rid: rid.toString('base64url'), sig: sig.toString('base64url') }],
  });
  const send = () =>
    gateway.send({
      v: 1,
      sid: randomBytes(32).toString('base64url'),
      blob: randomBytes(16384).toString('base64url'),
    });
  return {
    rid,
    nid,
    client,
    box,
    notifier,
    delivery,
    gateway,
    subscribing,
    finishMarking,
    send,
    /** Lets subscribe run up to its await on markSubscribed. */
    parked: async () => {
      await new Promise((resolve) => setImmediate(resolve));
      expect(box.markSubscribed).toHaveBeenCalledTimes(1);
    },
  };
}

describe('BoxGateway subscribe racing a disconnect', () => {
  it('control: a socket that stays connected owns the rid, so a send is delivered to it and no wake-up is scheduled for it', async () => {
    const f = subscribeFixture();
    await f.parked();
    f.finishMarking();
    await expect(f.subscribing).resolves.toEqual({ ok: true, refused: [] });

    expect(f.delivery.onEnqueued(f.rid)).toBe(true);
    await f.send();
    expect(f.notifier.schedule).toHaveBeenCalledWith(f.nid, true);
  });

  it('a socket that dropped during subscribe never becomes the rid owner, so the next send wakes the device', async () => {
    const f = subscribeFixture();
    await f.parked();
    f.client.connected = false;
    await f.gateway.handleDisconnect(f.client as never);
    f.finishMarking();
    await expect(f.subscribing).resolves.toEqual({ ok: true, refused: [] });

    // No owner slot for the dead socket: a stored blob is not "delivered".
    expect(f.delivery.onEnqueued(f.rid)).toBe(false);
    expect(f.delivery.detachSocket(f.client.id)).toEqual([]);
    await f.send();
    expect(f.notifier.schedule).toHaveBeenCalledWith(f.nid, false);
  });
});
