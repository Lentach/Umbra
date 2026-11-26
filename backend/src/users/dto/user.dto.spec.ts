import {
  ArgumentMetadata,
  BadRequestException,
  ValidationPipe,
} from '@nestjs/common';
import { UpdateProfileAboutDto } from './user.dto';

// `users.about` is varchar(80) and Postgres counts code points, so the DTO
// must count the same way: anything it lets through has to fit the column.
const pipe = new ValidationPipe({ whitelist: true });
const meta: ArgumentMetadata = {
  type: 'body',
  metatype: UpdateProfileAboutDto,
};

describe('UpdateProfileAboutDto about length (R12-BE-01)', () => {
  it('refuses 80 hearts with a variation selector (160 code points)', async () => {
    const error: unknown = await pipe
      .transform({ about: '\u2764\uFE0F'.repeat(80) }, meta)
      .catch((e: unknown) => e);
    expect(error).toBeInstanceOf(BadRequestException);
    expect((error as BadRequestException).getResponse()).toMatchObject({
      message: ['about must be at most 80 characters'],
    });
  });

  it.each([
    ['80 one-unit characters', 'a'.repeat(80)],
    [
      '80 astral emoji (one code point, two UTF-16 units each)',
      '\u{1F600}'.repeat(80),
    ],
  ])('accepts %s', async (_name, about) => {
    const out = (await pipe.transform(
      { about },
      meta,
    )) as UpdateProfileAboutDto;
    expect(out.about).toBe(about);
  });

  it('refuses 81 astral emoji', async () => {
    await expect(
      pipe.transform({ about: '\u{1F600}'.repeat(81) }, meta),
    ).rejects.toThrow(BadRequestException);
  });
});
