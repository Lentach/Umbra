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
 * phrase — and `ct` is the wrapped key. The bounds are a DoS cap and a shape
 * cap, not crypto validation: the server has no key for `ct` and never parses
 * it. The charset is standard base64 with padding, which is what the client's
 * `base64Encode` emits (frontend contact_backup.dart `wrap`).
 */
export class ContactBackupWrapDto {
  @IsIn(['password', 'phrase'])
  kind: 'password' | 'phrase';

  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  @Matches(/^[A-Za-z0-9+/]+={0,2}$/)
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

  /**
   * Opaque KDF salt label, echoed back verbatim. Charset-pinned for parity
   * with every other opaque field here (G2 review T1): the client always
   * sends `base64Encode(16 bytes)`, so without it an account could park 64
   * arbitrary bytes — control characters included — in its own row.
   */
  @IsString()
  @Length(16, 64)
  @Matches(/^[A-Za-z0-9+/]+={0,2}$/)
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

  /**
   * The sealed contact list. ~2 MB ceiling; opaque to the server.
   *
   * Standard base64 with padding — what the client's `base64Encode` emits
   * (frontend contact_backup.dart `sealPayload`). The charset is what keeps
   * this from being a general-purpose 2 MB/account key-value store: an
   * arbitrary byte string is not a sealed contact list.
   */
  @IsString()
  @IsNotEmpty()
  @MaxLength(2_000_000)
  @Matches(/^[A-Za-z0-9+/]+={0,2}$/)
  blob: string;
}
