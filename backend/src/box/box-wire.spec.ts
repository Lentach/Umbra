import { randomBytes } from 'crypto';
import {
  parseAck,
  parseCreateQueue,
  parseRegisterNotifier,
  parseSend,
  parseSubscribe,
} from './box-wire';

const b64 = (bytes: number) => randomBytes(bytes).toString('base64url');

describe('box wire parser (strict: exact keys, v:1, canonical fixed-length base64url)', () => {
  it('decodes a well-formed createQueue into raw bytes', () => {
    const authPub = randomBytes(32);
    const sig = randomBytes(64);
    const cmd = parseCreateQueue({
      v: 1,
      kind: 'request',
      authPub: authPub.toString('base64url'),
      sig: sig.toString('base64url'),
    });
    expect(cmd).toEqual({ kind: 'request', authPub, sig });
  });

  it('refuses an unknown key instead of ignoring it (validateDto would keep it)', () => {
    expect(
      parseCreateQueue({
        v: 1,
        kind: 'normal',
        authPub: b64(32),
        sig: b64(64),
        userId: 7,
      }),
    ).toBeNull();
  });

  it('refuses a missing key, another version and an unknown kind', () => {
    expect(
      parseCreateQueue({ v: 1, kind: 'normal', authPub: b64(32) }),
    ).toBeNull();
    expect(
      parseCreateQueue({
        v: 2,
        kind: 'normal',
        authPub: b64(32),
        sig: b64(64),
      }),
    ).toBeNull();
    expect(
      parseCreateQueue({ v: 1, kind: 'group', authPub: b64(32), sig: b64(64) }),
    ).toBeNull();
  });

  it('refuses ids of the wrong length, padded, or in a non-canonical encoding', () => {
    const good = b64(32);
    expect(
      parseAck({ v: 1, rid: b64(31), id: b64(16), sig: b64(64) }),
    ).toBeNull();
    expect(
      parseAck({ v: 1, rid: `${good}=`, id: b64(16), sig: b64(64) }),
    ).toBeNull();
    // 43 chars carry 258 bits for 256: the last char's two spare bits must be 0.
    // Flipping the lowest one decodes to the SAME bytes as `good` under Node's
    // lenient decoder — two spellings of one rid.
    const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    const sibling =
      good.slice(0, 42) + alphabet[alphabet.indexOf(good[42]) ^ 1];
    expect(Buffer.from(sibling, 'base64url')).toEqual(
      Buffer.from(good, 'base64url'),
    );
    expect(
      parseAck({ v: 1, rid: sibling, id: b64(16), sig: b64(64) }),
    ).toBeNull();
    expect(
      parseAck({ v: 1, rid: good, id: b64(16), sig: b64(64) }),
    ).not.toBeNull();
  });

  it('accepts a send blob of exactly 16384 bytes and nothing else', () => {
    const sid = b64(32);
    expect(parseSend({ v: 1, sid, blob: b64(16384) })).not.toBeNull();
    expect(parseSend({ v: 1, sid, blob: b64(16383) })).toBeNull();
    expect(parseSend({ v: 1, sid, blob: b64(16385) })).toBeNull();
  });

  it('bounds subscribe to 1..256 entries, each exactly {rid, sig}', () => {
    const sub = () => ({ rid: b64(32), sig: b64(64) });
    expect(parseSubscribe({ v: 1, subs: [] })).toBeNull();
    expect(
      parseSubscribe({ v: 1, subs: Array.from({ length: 257 }, sub) }),
    ).toBeNull();
    expect(
      parseSubscribe({ v: 1, subs: Array.from({ length: 256 }, sub) })?.subs,
    ).toHaveLength(256);
    expect(
      parseSubscribe({ v: 1, subs: [{ ...sub(), extra: true }] }),
    ).toBeNull();
    // The version belongs to the frame, never to an entry.
    expect(parseSubscribe({ v: 1, subs: [{ ...sub(), v: 1 }] })).toBeNull();
  });

  it('refuses non-object payloads', () => {
    expect(parseSend(null)).toBeNull();
    expect(parseSend([1, 2])).toBeNull();
    expect(parseSend('send')).toBeNull();
  });

  describe('registerNotifier', () => {
    const subscription = (endpoint: string) =>
      JSON.stringify({
        endpoint,
        keys: { p256dh: b64(65), auth: b64(16) },
      });

    it('tells step 1 from step 2 by its exact key set', () => {
      expect(
        parseRegisterNotifier({
          v: 1,
          nid: b64(16),
          platform: 'fcm',
          token: 'fcm-token_1:abc',
          sig: b64(64),
        }),
      ).toMatchObject({ step: 1, platform: 'fcm' });
      expect(
        parseRegisterNotifier({
          v: 1,
          nid: b64(16),
          code: b64(16),
          sig: b64(64),
        }),
      ).toMatchObject({ step: 2 });
      expect(
        parseRegisterNotifier({
          v: 1,
          nid: b64(16),
          code: b64(16),
          platform: 'fcm',
          sig: b64(64),
        }),
      ).toBeNull();
    });

    it('accepts a Web Push subscription only for a known push service over https (the box would POST to it)', () => {
      const step1 = (token: string) =>
        parseRegisterNotifier({
          v: 1,
          nid: b64(16),
          platform: 'webpush',
          token,
          sig: b64(64),
        });
      expect(
        step1(subscription('https://fcm.googleapis.com/fcm/send/abc')),
      ).not.toBeNull();
      expect(
        step1(
          subscription('https://wns2-par02p.notify.windows.com/w/?token=x'),
        ),
      ).not.toBeNull();
      expect(step1(subscription('https://169.254.169.254/latest'))).toBeNull();
      expect(
        step1(subscription('http://fcm.googleapis.com/fcm/send/abc')),
      ).toBeNull();
      expect(
        step1(subscription('https://fcm.googleapis.com.evil.example/x')),
      ).toBeNull();
      expect(
        step1(subscription('https://fcm.googleapis.com:8443/fcm/send/abc')),
      ).toBeNull();
    });

    it('refuses a subscription whose keys carry anything beyond p256dh and auth', () => {
      const step1 = (keys: Record<string, string>) =>
        parseRegisterNotifier({
          v: 1,
          nid: b64(16),
          platform: 'webpush',
          token: JSON.stringify({
            endpoint: 'https://fcm.googleapis.com/fcm/send/abc',
            keys,
          }),
          sig: b64(64),
        });
      const keys = { p256dh: b64(65), auth: b64(16) };
      expect(step1(keys)).not.toBeNull();
      expect(step1({ ...keys, extra: 'x' })).toBeNull();
      expect(step1({ p256dh: keys.p256dh })).toBeNull();
    });

    it('refuses a token over 4096 chars', () => {
      expect(
        parseRegisterNotifier({
          v: 1,
          nid: b64(16),
          platform: 'fcm',
          token: 'a'.repeat(4097),
          sig: b64(64),
        }),
      ).toBeNull();
    });
  });
});
