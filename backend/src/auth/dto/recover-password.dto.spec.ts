import { ArgumentMetadata, ValidationPipe } from '@nestjs/common';
import { RecoverPasswordDto } from './recover-password.dto';

// main.ts runs the global pipe with whitelist: true, which STRIPS any field
// the DTO does not declare. A new credential field that is missing here would
// vanish silently and every recovery would answer "no credential".
const pipe = new ValidationPipe({ whitelist: true });
const meta: ArgumentMetadata = { type: 'body', metatype: RecoverPasswordDto };
const authSecret = Buffer.alloc(32, 1).toString('base64');
const base = { identifier: 'alice#0427', newPassword: 'NewPass1x' };

describe('RecoverPasswordDto (plan B7)', () => {
  it('keeps authSecret through the whitelisting pipe', async () => {
    const out = (await pipe.transform(
      { ...base, authSecret },
      meta,
    )) as RecoverPasswordDto;
    expect(out.authSecret).toBe(authSecret);
    expect(out.phrase).toBeUndefined();
  });

  it('still accepts the legacy plaintext phrase of clients up to 0.2.89', async () => {
    const out = (await pipe.transform(
      { ...base, phrase: 'abandon ability able' },
      meta,
    )) as RecoverPasswordDto;
    expect(out.phrase).toBe('abandon ability able');
  });

  it.each([
    ['neither credential', {}],
    ['both credentials', { authSecret, phrase: 'abandon ability able' }],
    ['a malformed authSecret', { authSecret: 'AAAA' }],
  ])('refuses %s', async (_name, extra) => {
    await expect(pipe.transform({ ...base, ...extra }, meta)).rejects.toThrow();
  });
});
