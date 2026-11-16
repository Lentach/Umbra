import { ConfigService } from '@nestjs/config';

const DEV_JWT_SECRET = 'super-secret-dev-key';

/**
 * The server's one long-lived secret: it signs access JWTs and keys the
 * refresh-token rotation chain (`RefreshTokensService.successorOf`). Dev falls
 * back to a fixed value; production refuses to start without a real one.
 */
export function resolveJwtSecret(configService: ConfigService): string {
  const secret = configService.get<string>('JWT_SECRET') || DEV_JWT_SECRET;
  const isProd = configService.get('NODE_ENV') === 'production';
  if (isProd && secret === DEV_JWT_SECRET) {
    throw new Error(
      'Production requires a strong JWT_SECRET. Do not use the dev fallback.',
    );
  }
  return secret;
}
