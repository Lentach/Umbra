import { IsBoolean } from 'class-validator';

/**
 * Client reports whether the app is on screen so the server can skip the push
 * for a message the open socket already delivers. Deliberately NOT which
 * conversation is open (metadata privacy PR0.2): a per-chat focus stream would
 * tell the server, live, who reads whom.
 */
export class PushClientStateDto {
  @IsBoolean()
  clientVisible: boolean;
}
