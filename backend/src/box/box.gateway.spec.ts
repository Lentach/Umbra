import { generateKeyPairSync, randomBytes, sign } from 'crypto';
import { BoxDelivery } from './box-delivery.service';
import { boxSignedMessage } from './box-signature';
import { BoxGateway } from './box.gateway';

describe('BoxGateway subscribe racing a disconnect', () => {
  it('a socket that dropped during subscribe never becomes the rid owner, so the next send wakes the device', async () => {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const authPub = Buffer.from(
      publicKey.export({ format: 'jwk' }).x as string,
      'base64url',
    );
    const rid = randomBytes(32);
    const nid = randomBytes(32);
    const client = { id: 'sock1', connected: true, emit: jest.fn() };

    // `markSubscribed` is the awaited step the disconnect lands in.
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
      subs: [
        { rid: rid.toString('base64url'), sig: sig.toString('base64url') },
      ],
    });
    // Let subscribe run up to its await on markSubscribed, then drop the socket.
    await new Promise((resolve) => setImmediate(resolve));
    expect(box.markSubscribed).toHaveBeenCalledTimes(1);
    client.connected = false;
    await gateway.handleDisconnect(client as never);
    finishMarking();
    await expect(subscribing).resolves.toEqual({ ok: true, refused: [] });

    // No owner slot for the dead socket: a stored blob is not "delivered".
    expect(delivery.onEnqueued(rid)).toBe(false);
    expect(delivery.detachSocket(client.id)).toEqual([]);
    await gateway.send({
      v: 1,
      sid: randomBytes(32).toString('base64url'),
      blob: randomBytes(16384).toString('base64url'),
    });
    expect(notifier.schedule).toHaveBeenCalledWith(nid, false);
  });
});
