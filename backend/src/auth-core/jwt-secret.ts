import { ConfigService } from '@nestjs/config';

/**
 * The server's one long-lived secret: it signs access JWTs and keys the
 * refresh-token rotation chain (`RefreshTokensService.successorOf`). Boot
 * validation (`env.validation.ts`) already requires `JWT_SECRET` (>= 32
 * chars), so there is no fallback: an absent value is a hard error.
 */
export function resolveJwtSecret(configService: ConfigService): string {
  const secret = configService.get<string>('JWT_SECRET');
  if (!secret) {
    throw new Error('JWT_SECRET is not configured');
  }
  return secret;
}
