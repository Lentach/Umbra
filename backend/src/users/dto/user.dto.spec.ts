import {
  ArgumentMetadata,
  BadRequestException,
  ValidationPipe,
} from '@nestjs/common';
import { UpdateProfileAboutDto } from './user.dto';

// An About is 80 characters as the user sees them (grapheme clusters), with a
// hard 640 code-point backstop that matches the column's CHECK (migration
// 0032): nothing the DTO lets through can fail the write.
const pipe = new ValidationPipe({ whitelist: true });
const meta: ArgumentMetadata = {
  type: 'body',
  metatype: UpdateProfileAboutDto,
};
const heart = '\u2764\uFE0F';
const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}'; // 7 code points

const messageOf = async (about: unknown): Promise<unknown> => {
  const error: unknown = await pipe
    .transform({ about }, meta)
    .catch((e: unknown) => e);
  return error instanceof BadRequestException
    ? (error.getResponse() as { message: string[] }).message
    : 'accepted';
};

describe('UpdateProfileAboutDto about length (R12-BE-01)', () => {
  it.each([
    ['80 hearts with a variation selector (160 code points)', heart.repeat(80)],
    ['80 family emoji (560 code points)', family.repeat(80)],
    ['80 one-unit characters', 'a'.repeat(80)],
    ['80 astral emoji', '\u{1F600}'.repeat(80)],
  ])('accepts %s', async (_name, about) => {
    const out = (await pipe.transform(
      { about },
      meta,
    )) as UpdateProfileAboutDto;
    expect(out.about).toBe(about);
  });

  it.each([
    ['81 hearts', heart.repeat(81)],
    ['81 family emoji', family.repeat(81)],
    ['81 astral emoji', '\u{1F600}'.repeat(81)],
  ])('refuses %s as too many characters', async (_name, about) => {
    expect(await messageOf(about)).toEqual([
      'about must be at most 80 characters',
    ]);
  });

  it('refuses one letter plus 700 combining marks: the code-point backstop', async () => {
    // One grapheme cluster, 701 code points: the column CHECK would refuse it.
    expect(await messageOf('a' + '\u0301'.repeat(700))).toEqual([
      'about must be at most 640 code points',
    ]);
  });

  it('accepts exactly 640 code points in one cluster, refuses 641', async () => {
    expect(await messageOf('a' + '\u0301'.repeat(639))).toBe('accepted');
    expect(await messageOf('a' + '\u0301'.repeat(640))).not.toBe('accepted');
  });

  it.each([
    ['null', null],
    ['an empty string', ''],
    ['an absent field', undefined],
  ])('still lets %s through to clear the About', async (_name, about) => {
    expect(await messageOf(about)).toBe('accepted');
  });
});
