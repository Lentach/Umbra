import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestExpressApplication } from '@nestjs/platform-express';
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

  // Express's default JSON body limit is 100 kb. The contact-backup PUT
  // (backup/contact-backup.controller.ts) carries an opaque blob capped at
  // 2,000,000 chars by its DTO, so the default would 413 exactly the accounts
  // with the largest contact graphs — a failure only heavy users ever see.
  // 4 mb leaves headroom for the base64/JSON envelope around that cap.
  app.useBodyParser('json', { limit: '4mb' });

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
          if (!origin || origin.startsWith('http://localhost:') || origin.startsWith('http://127.0.0.1:')) {
            callback(null, true);
          } else if (origin.startsWith('http://192.168.') || origin.startsWith('http://10.')) {
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
