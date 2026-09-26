import { generateKeyPairSync, randomBytes, sign } from 'crypto';
import {
  ackFields,
  boxSignedMessage,
  verifyBoxSignature,
} from './box-signature';

/** Raw 32-byte Ed25519 public key, as the client sends it. */
function mintKey() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const jwk = publicKey.export({ format: 'jwk' });
  return { privateKey, pub: Buffer.from(jwk.x as string, 'base64url') };
}

describe('box signatures (Ed25519 over the canonical per-verb bytes)', () => {
  it('lays the signed bytes out exactly as the wire contract states', () => {
    const rid = Buffer.alloc(32, 0xaa);
    const id = Buffer.alloc(16, 0xbb);
    // "umbra.box.v1" 0x00 ‖ "ack" 0x00 ‖ u8(len) ‖ sockId ‖ rid ‖ id
    const expected = Buffer.concat([
      Buffer.from('756d6272612e626f782e763100', 'hex'),
      Buffer.from('61636b00', 'hex'),
      Buffer.from([4]),
      Buffer.from('S1ab', 'utf8'),
      rid,
      id,
    ]);
    expect(boxSignedMessage('ack', 'S1ab', ackFields(rid, id))).toEqual(
      expected,
    );
  });

  it('verifies a signature over the same verb, connection and fields', () => {
    const { privateKey, pub } = mintKey();
    const message = boxSignedMessage(
      'ack',
      'sock-A',
      ackFields(randomBytes(32), randomBytes(16)),
    );
    expect(
      verifyBoxSignature(pub, message, sign(null, message, privateKey)),
    ).toBe(true);
  });

  it('refuses the same signature replayed on another connection or verb', () => {
    const { privateKey, pub } = mintKey();
    const fields = ackFields(randomBytes(32), randomBytes(16));
    const sig = sign(
      null,
      boxSignedMessage('ack', 'sock-A', fields),
      privateKey,
    );
    expect(
      verifyBoxSignature(pub, boxSignedMessage('ack', 'sock-B', fields), sig),
    ).toBe(false);
    expect(
      verifyBoxSignature(
        pub,
        boxSignedMessage('deleteQueue', 'sock-A', fields),
        sig,
      ),
    ).toBe(false);
  });

  it('answers false, never throws, for a key that is not a valid Ed25519 point', () => {
    const message = boxSignedMessage('subscribe', 's', randomBytes(32));
    expect(verifyBoxSignature(Buffer.alloc(31), message, randomBytes(64))).toBe(
      false,
    );
    expect(verifyBoxSignature(randomBytes(32), message, randomBytes(64))).toBe(
      false,
    );
  });
});
