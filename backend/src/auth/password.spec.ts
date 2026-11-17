import { BadRequestException } from '@nestjs/common';
import { validateDto } from '../chat/utils/dto.validator';
import { RegisterDto } from './dto/register.dto';
import { ResetPasswordDto } from '../users/dto/user.dto';
import { PASSWORD_MIN_LENGTH, PASSWORD_REGEX_MESSAGE } from './password.constants';

// Shared cases run against both DTOs that enforce the password policy
const VALID_PASSWORDS = [
  'ValidPass1',
  'A1bbbbbbb',
  `${'x'.repeat(PASSWORD_MIN_LENGTH - 2)}A1`,   // exactly min length
  'Hello1!@#$%^&*()',                             // special chars allowed
  'CorrectHorse1Battery',                         // long passphrase
];

const INVALID_PASSWORDS: Array<[string, string]> = [
  ['Short1',          `at least ${PASSWORD_MIN_LENGTH} characters`],
  ['alllowercase1',   PASSWORD_REGEX_MESSAGE],
  ['ALLUPPERCASE1',   PASSWORD_REGEX_MESSAGE],
  ['NoNumbersHere',   PASSWORD_REGEX_MESSAGE],
  ['',                `at least ${PASSWORD_MIN_LENGTH} characters`],
];

// Toggling exactly one character class must flip validity. Unlike the shared
// generic PASSWORD_REGEX_MESSAGE (which cannot say *which* class failed), these
// prove each requirement is independently enforced: if e.g. the digit rule were
// dropped from PASSWORD_REGEX, the missing-digit password would be accepted and
// the toThrow below would fail.
const CLASS_TOGGLE_CASES: Array<[string, string, string]> = [
  ['digit',     'NoNumbersHere',  'NoNumbersHere1'],
  ['uppercase', 'alllowercase1',  'Alllowercase1'],
  ['lowercase', 'ALLUPPERCASE1',  'ALLUPPERCASe1'],
];

// Helper: build a valid RegisterDto payload
function registerPayload(password: string) {
  return { username: 'testuser', password };
}

// Helper: build a valid ResetPasswordDto payload
function resetPayload(newPassword: string) {
  return { oldPassword: 'OldValid1', newPassword };
}

// --- RegisterDto ---

describe('RegisterDto — password validation', () => {
  it.each(VALID_PASSWORDS)('should accept valid password: %s', (pw) => {
    expect(() => validateDto(RegisterDto, registerPayload(pw))).not.toThrow();
  });

  it.each(INVALID_PASSWORDS)(
    'should reject "%s" (%s)',
    (pw, expectedPattern) => {
      expect(() => validateDto(RegisterDto, registerPayload(pw))).toThrow(
        BadRequestException,
      );
      expect(() => validateDto(RegisterDto, registerPayload(pw))).toThrow(
        expectedPattern,
      );
    },
  );

  it.each(CLASS_TOGGLE_CASES)(
    'enforces the %s requirement independently (rejected without it, accepted with it)',
    (_label, rejected, accepted) => {
      // Missing only this class -> rejected with the policy message.
      expect(() => validateDto(RegisterDto, registerPayload(rejected))).toThrow(
        PASSWORD_REGEX_MESSAGE,
      );
      // Adding only this class satisfies the whole policy -> accepted.
      expect(() =>
        validateDto(RegisterDto, registerPayload(accepted)),
      ).not.toThrow();
    },
  );

  it('should accept passwords with special characters (#^() etc.)', () => {
    expect(() =>
      validateDto(RegisterDto, registerPayload('Hello1#^&*()!')),
    ).not.toThrow();
  });
});

// --- ResetPasswordDto ---

describe('ResetPasswordDto — newPassword validation', () => {
  it.each(VALID_PASSWORDS)(
    'should accept valid newPassword: %s',
    (pw) => {
      expect(() => validateDto(ResetPasswordDto, resetPayload(pw))).not.toThrow();
    },
  );

  it.each(INVALID_PASSWORDS)(
    'should reject newPassword "%s" (%s)',
    (pw, expectedPattern) => {
      expect(() => validateDto(ResetPasswordDto, resetPayload(pw))).toThrow(
        BadRequestException,
      );
      expect(() => validateDto(ResetPasswordDto, resetPayload(pw))).toThrow(
        expectedPattern,
      );
    },
  );

  it('should not validate strength of oldPassword (any non-empty string)', () => {
    // oldPassword just needs to be non-empty — no strength check
    expect(() =>
      validateDto(ResetPasswordDto, {
        oldPassword: 'weak',
        newPassword: 'StrongNew1',
      }),
    ).not.toThrow();
  });

  it('should reject empty oldPassword', () => {
    expect(() =>
      validateDto(ResetPasswordDto, { oldPassword: '', newPassword: 'StrongNew1' }),
    ).toThrow(BadRequestException);
  });
});

// --- Cross-check: both DTOs use the same rules ---

describe('Password policy consistency — RegisterDto vs ResetPasswordDto', () => {
  it('a password accepted by RegisterDto should also be accepted by ResetPasswordDto', () => {
    const pw = 'CrossTest1!';
    expect(() => validateDto(RegisterDto, registerPayload(pw))).not.toThrow();
    expect(() => validateDto(ResetPasswordDto, resetPayload(pw))).not.toThrow();
  });

  it('a password rejected by RegisterDto should also be rejected by ResetPasswordDto', () => {
    const pw = 'alllowercase1';
    expect(() => validateDto(RegisterDto, registerPayload(pw))).toThrow(BadRequestException);
    expect(() => validateDto(ResetPasswordDto, resetPayload(pw))).toThrow(BadRequestException);
  });
});
