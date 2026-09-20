import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsIn,
  IsInt,
  IsNotEmpty,
  IsString,
  Length,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';

/**
 * One wrapped copy of the backup's content key (metadata-privacy PR2.4).
 *
 * `kind` says which secret unwraps it — the account password or the recovery
 * phrase — and `ct` is the wrapped key. The bound is a DoS cap, not crypto
 * validation: the server has no key for `ct` and never parses it.
 */
export class ContactBackupWrapDto {
  @IsIn(['password', 'phrase'])
  kind: 'password' | 'phrase';

  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  ct: string;
}

/**
 * Uploads the account's sealed contact backup.
 *
 * `baseRev` is the rev the client read (0 = "I expect no row"): the server
 * rejects a mismatch instead of writing, so a fresh `blob` can never land
 * next to stale `wraps`. `salt` must equal the stored one — it is minted once
 * and immutable, because every other device derives its key under it.
 */
export class PutContactBackupDto {
  /** Backup format version; 1 is the only one defined. */
  @IsInt()
  @Min(1)
  @Max(1)
  v: number;

  @IsInt()
  @Min(0)
  baseRev: number;

  @IsString()
  @Length(16, 64)
  salt: string;

  /** Content-key label: 22 chars of base64url (a 16-byte id). */
  @IsString()
  @Matches(/^[A-Za-z0-9_-]{22}$/)
  ckId: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(8)
  @ValidateNested({ each: true })
  @Type(() => ContactBackupWrapDto)
  wraps: ContactBackupWrapDto[];

  /** The sealed contact list. ~2 MB ceiling; opaque to the server. */
  @IsString()
  @IsNotEmpty()
  @MaxLength(2_000_000)
  blob: string;
}
