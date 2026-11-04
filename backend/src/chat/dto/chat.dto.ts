import { IsString, Matches } from 'class-validator';

export class SearchUsersDto {
  @IsString()
  @Matches(/^[a-zA-Z0-9_]{3,20}#[0-9]{4}$/, {
    message: 'Enter username#tag (e.g. username#1234)',
  })
  handle: string; // username#tag, e.g. ziomek1#1234
}

/**
 * The ONE canonical unpadded base64url spelling of 32 bytes: 43 chars, the
 * last one carrying two zero spare bits (the box's id convention, wire.md
 * "Box"). A second spelling of the same bytes would let one queue be served
 * under two strings.
 */
const CANONICAL_B64URL_32 = /^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/;

/** A device publishes its box request queue (metadata-privacy PR3.2). */
export class SetRequestQueueDto {
  @IsString()
  @Matches(CANONICAL_B64URL_32)
  sid: string;

  @IsString()
  @Matches(CANONICAL_B64URL_32)
  sealPub: string;
}
