import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestExpressApplication } from '@nestjs/platform-express';
import { json, type NextFunction, type Request, type Response } from 'express';
import helmet from 'helmet';
import { AppModule } from './app.module';
import { runMigrations } from './database/migration-runner';

async function bootstrap() {
  // Schema migrations run BEFORE the app exists, every environment. Prod has
  // TypeORM synchronize OFF — this is the only path that changes prod schema.
  // A failure here aborts boot: the container stays unhealthy instead of
  // serving a half-migrated database.
  const migrationLogger = new Logger('Migrations');
  await runMigrations({ log: (m) => migrationLogger.log(m) });

  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    logger:
      process.env.NODE_ENV === 'production'
        ? ['error', 'warn', 'log']
        : ['error', 'warn', 'log', 'debug', 'verbose'],
  });
  const logger = new Logger('Bootstrap');
  const configService = app.get(ConfigService);

  // Behind nginx (sets X-Real-IP); trust the first proxy hop so req.ip reflects the client.
  app.set('trust proxy', 1);

  // Security headers (X-Content-Type-Options, X-Frame-Options, etc.)
  app.use(helmet());

  // Express's default JSON body limit is 100 kb, and it MUST stay that way
  // for every unauthenticated route. Body parsing is express middleware: it
  // runs BEFORE Nest routing, before JwtAuthGuard and before
  // HttpThrottlerGuard. A global 4 mb ceiling would let anyone buffer and
  // JSON.parse 4 mb at POST /auth/login or /note/:token/reveal before a
  // single check ran — a 40x rise in the unauthenticated memory/CPU ceiling
  // on one VPS.
  //
  // The contact-backup PUT (backup/contact-backup.controller.ts) carries an
  // opaque blob capped at 2,000,000 chars by its DTO, so 100 kb would 413
  // exactly the accounts with the largest contact graphs. That ONE path gets
  // the headroom, and it is mounted BEFORE Nest's global parser: body-parser
  // skips a request whose stream is already drained (read.js's
  // `onFinished.isFinished`), so the 100 kb parser behind it is a no-op on a
  // body this one already read.
  //
  // The wrapper name is load-bearing. ExpressAdapter.registerParserMiddleware
  // skips its global parser when a layer whose handler is named `jsonParser`
  // is already on the stack (isMiddlewareApplied), and that is exactly what
  // `json()` returns — mounting it bare here would silently leave every OTHER
  // route with no JSON body at all.
  const backupJson = json({ limit: '4mb' });
  app.use(
    '/backup/contacts',
    function contactBackupJsonParser(
      req: Request,
      res: Response,
      next: NextFunction,
    ) {
      backupJson(req, res, next);
    },
  );

  // ValidationPipe validates DTOs (e.g. checks if email is valid).
  // whitelist: true — strips properties not defined in the DTO (security).
  app.useGlobalPipes(new ValidationPipe({ whitelist: true }));

  // Allow cross-origin requests from the Flutter frontend
  // Use ConfigService for environment-based CORS instead of hardcoded origin
  const allowedOrigins = (
    configService.get('ALLOWED_ORIGINS') || 'http://localhost:3000'
  )
    .split(',')
    .map((o) => o.trim());

  // In development, allow localhost and LAN IPs (e.g. http://192.168.1.11:8080 for phone)
  const corsOrigin =
    process.env.NODE_ENV === 'production'
      ? allowedOrigins
      : (origin, callback) => {
          if (
            !origin ||
            origin.startsWith('http://localhost:') ||
            origin.startsWith('http://127.0.0.1:')
          ) {
            callback(null, true);
          } else if (
            origin.startsWith('http://192.168.') ||
            origin.startsWith('http://10.')
          ) {
            callback(null, true);
          } else if (allowedOrigins.includes(origin)) {
            callback(null, true);
          } else {
            callback(new Error('Not allowed by CORS'));
          }
        };

  app.enableCors({ origin: corsOrigin, credentials: true });

  const port = configService.get('PORT') || 3000;
  await app.listen(port, '0.0.0.0');
  logger.log(`Server running on http://0.0.0.0:${port}`);
}
bootstrap();
