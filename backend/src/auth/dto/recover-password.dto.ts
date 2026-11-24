import {
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import {
  AUTH_SECRET_PATTERN,
  CredentialXor,
} from '../../common/credential-xor';
import {
  PASSWORD_MIN_LENGTH,
  PASSWORD_REGEX,
  PASSWORD_REGEX_MESSAGE,
} from '../../auth-core/password.constants';

/**
 * `POST /auth/recover` — the recovery phrase as a credential (multi-device
 * spec §12 amendment (lxxxii) clause 2). Same identifier grammar as login,
 * same password rules as register. Plan B7: new clients send `authSecret`
 * (HKDF output of the phrase) and never the phrase; `phrase` is the legacy
 * plaintext field of clients up to 0.2.89. Exactly one of the two — and this
 * DTO MUST declare both, because the global ValidationPipe strips fields it
 * does not know.
 */
export class RecoverPasswordDto {
  @IsString()
  @MinLength(3)
  @MaxLength(25)
  @Matches(/^[a-zA-Z0-9_]+(#[0-9]{4})?$/, {
    message: 'Use username or username#tag (e.g. john#0427)',
  })
  identifier: string;

  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(256)
  phrase?: string;

  @CredentialXor('phrase', {
    required: true,
    isValid: (v) => typeof v === 'string' && AUTH_SECRET_PATTERN.test(v),
  })
  authSecret?: string;

  @MinLength(PASSWORD_MIN_LENGTH, {
    message: `Password must be at least ${PASSWORD_MIN_LENGTH} characters long`,
  })
  @MaxLength(128)
  @Matches(PASSWORD_REGEX, { message: PASSWORD_REGEX_MESSAGE })
  newPassword: string;
}
