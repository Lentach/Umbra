import { Type } from 'class-transformer';
import {
  registerDecorator,
  ValidationArguments,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
  MinLength,
  ValidateNested,
} from 'class-validator';
import {
  AUTH_SECRET_PATTERN,
  CredentialXor,
} from '../../common/credential-xor';

/**
 * Starts an account-identity reset ceremony (multi-device spec §6.2).
 *
 * The optional recovery credential shortens the delay (§6.2.1). Plan B7: new
 * clients send `recoveryAuth` (the HKDF-derived authSecret) and NEVER the
 * phrase; `recoveryPhrase` is the legacy plaintext field of clients up to
 * 0.2.89, declared ONLY so it is refused (`invalid_phrase`, nothing verified
 * or counted; plan B7 tail, 0.2.104). At most one
 * of the two. Both are bounded in length so a hostile payload cannot turn the
 * memory-hard verifier into a denial-of-service lever.
 */
export class ResetIdentityRequestDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(256)
  recoveryPhrase?: string;

  @CredentialXor('recoveryPhrase', {
    required: false,
    isValid: (v) => typeof v === 'string' && AUTH_SECRET_PATTERN.test(v),
  })
  recoveryAuth?: string;
}

/**
 * `iterations` follows `version`: a v1 blob is PBKDF2 (client-chosen count in
 * the DoS bounds), a v2 blob's key is an HKDF output with no stretching, so
 * its count is exactly 0.
 */
function IterationsMatchVersion() {
  return (object: object, propertyName: string): void => {
    registerDecorator({
      name: 'iterationsMatchVersion',
      target: object.constructor,
      propertyName,
      validator: {
        validate(value: unknown, args?: ValidationArguments): boolean {
          const version = (args?.object as { version?: unknown }).version;
          if (typeof value !== 'number') return false;
          if (version === 2) return value === 0;
          return value >= 100000 && value <= 2000000;
        },
        defaultMessage(): string {
          return 'iterations must be 0 for version 2, 100000-2000000 for version 1';
        },
      },
    });
  };
}

/**
 * Sealed identity backup riding a phrase enrolment (amendment (lxxviii)
 * clause 1). Opaque to the server: `blob` is base64(iv12 || AES-256-GCM ct)
 * sealed under PBKDF2-HMAC-SHA256(phrase, salt, iterations) (version 1) or
 * under an HKDF-SHA256 output the server never receives (version 2, plan B7).
 * Bounds are DoS caps, not crypto validation — the server cannot open a v2
 * blob, and could open a v1 one only if it had seen the phrase.
 */
export class RecoveryBackupDto {
  /** ≤ 16 KiB of base64 — the identity record is far below this. */
  @IsString()
  @MinLength(1)
  @MaxLength(16384)
  @Matches(/^[A-Za-z0-9+/]+={0,2}$/)
  blob: string;

  /** base64 PBKDF2 salt (a 16-byte salt encodes to 24 chars). */
  @IsString()
  @MinLength(16)
  @MaxLength(64)
  @Matches(/^[A-Za-z0-9+/]+={0,2}$/)
  salt: string;

  @IsInt()
  @Min(0)
  @Max(2000000)
  @IterationsMatchVersion()
  iterations: number;

  /** Blob format version: 1 (PBKDF2 over the phrase) or 2 (HKDF seal key). */
  @IsInt()
  @IsIn([1, 2])
  version: number;
}

/**
 * An `authSecret` enrolment must carry a version-2 backup: a v1 blob is
 * PBKDF2 over the phrase, and storing an `auth_v2` verifier next to it would
 * pair a server-blind verifier with a blob the old KDF could open.
 */
function AuthSecretNeedsV2Backup() {
  return (object: object, propertyName: string): void => {
    registerDecorator({
      name: 'authSecretNeedsV2Backup',
      target: object.constructor,
      propertyName,
      validator: {
        validate(value: unknown, args?: ValidationArguments): boolean {
          if (value == null) return true;
          const backup = (args?.object as { backup?: { version?: unknown } })
            .backup;
          return backup?.version === 2;
        },
        defaultMessage(): string {
          return 'authSecret requires a version 2 backup';
        },
      },
    });
  };
}

/**
 * Enrolls or replaces the account's recovery key (§6.2.1). Plan B7: new
 * clients send `authSecret` (HKDF output; the phrase never leaves the device).
 * `phrase` is the legacy plaintext field of clients up to 0.2.89, declared
 * ONLY so it is refused (failed ack, nothing stored; plan B7 tail, 0.2.104).
 * Exactly one of the two.
 */
export class SetRecoveryKeyDto {
  @IsOptional()
  @IsString()
  @MinLength(8)
  @MaxLength(256)
  phrase?: string;

  @CredentialXor('phrase', {
    required: true,
    isValid: (v) => typeof v === 'string' && AUTH_SECRET_PATTERN.test(v),
  })
  @AuthSecretNeedsV2Backup()
  authSecret?: string;

  /**
   * The sealed identity backup, written with the verifier in one transaction
   * ((lxxviii) clause 1). Optional: an older client enrols the phrase alone
   * and the previously stored backup (if any) is left untouched.
   */
  @IsOptional()
  @ValidateNested()
  @Type(() => RecoveryBackupDto)
  backup?: RecoveryBackupDto;
}
