import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ConditionalModule, ConfigModule, ConfigService } from '@nestjs/config';
import { ThrottlerModule } from '@nestjs/throttler';
import { ScheduleModule } from '@nestjs/schedule';
import { AuthModule } from './auth/auth.module';
import { MediaModule } from './media/media.module';
import { UsersModule } from './users/users.module';
import { ChatModule } from './chat/chat.module';
import { LinkPreviewModule } from './link-preview/link-preview.module';
import { KeyBundlesModule } from './key-bundles/key-bundles.module';
import { User } from './users/user.entity';
import { KeyBundle } from './key-bundles/key-bundle.entity';
import { OneTimePreKey } from './key-bundles/one-time-pre-key.entity';
import { IdentityChangeAudit } from './key-bundles/identity-change-audit.entity';
import { IdentityResetRequest } from './key-bundles/identity-reset-request.entity';
import { RecoveryKey } from './key-bundles/recovery-key.entity';
import { SecretNote } from './secret-notes/secret-note.entity';
import { SecretNotesModule } from './secret-notes/secret-notes.module';
import { validate } from './config/env.validation';
import { HealthModule } from './health/health.module';
import { VersionModule } from './version/version.module';
import { RefreshToken } from './auth/refresh-token.entity';
import { APP_GUARD } from '@nestjs/core';
import { HttpThrottlerGuard } from './common/http-throttler.guard';

import { ProfilePhoto } from './users/profile-photo.entity';
import { Device } from './key-bundles/device.entity';
import { AccountAuthorization } from './key-bundles/account-authorization.entity';
import { ContactBackup } from './backup/contact-backup.entity';
import { BackupModule } from './backup/backup.module';
import { BoxModule, BOX_ENTITIES } from './box/box.module';
@Module({
  imports: [
    // Load and validate environment variables
    ConfigModule.forRoot({
      validate,
      isGlobal: true,
      envFilePath: ['.env.local', '.env'],
    }),
    // Schedule cron jobs (secret-note expiry, identity reset, box reaper)
    ScheduleModule.forRoot(),
    // Rate limiting: 100 requests per 15 minutes globally
    ThrottlerModule.forRoot([
      {
        ttl: 900000, // 15 minutes in milliseconds
        limit: 100,
      },
    ]),
    // TypeORM auto-creates tables (synchronize: true).
    // synchronize is automatically disabled when NODE_ENV=production.
    TypeOrmModule.forRootAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        type: 'postgres',
        host: configService.get('DB_HOST'),
        port: configService.get('DB_PORT'),
        username: configService.get('DB_USER'),
        password: configService.get('DB_PASS'),
        database: configService.get('DB_NAME'),
        entities: [
          User,
          RefreshToken,
          Device,
          AccountAuthorization,
          KeyBundle,
          OneTimePreKey,
          IdentityChangeAudit,
          IdentityResetRequest,
          RecoveryKey,
          SecretNote,
          ProfilePhoto,
          ContactBackup,
          ...BOX_ENTITIES,
        ],
        synchronize: process.env.NODE_ENV !== 'production',
      }),
    }),
    MediaModule,
    AuthModule,
    UsersModule,
    KeyBundlesModule,
    BackupModule,
    ChatModule,
    LinkPreviewModule,
    SecretNotesModule,
    HealthModule,
    VersionModule,
    // Shares ChatGateway's engine.io server; both pass the same options
    // (`common/socket-cors.ts`), so module order does not matter.
    // Registered ONLY when BOX_ENABLED=true. Anyone can mint a queue, so the
    // box is safe to expose only with its global ceiling (decision 30) and
    // per-socket rid cap (item 9) in place; prod still pins it off until the
    // owner turns it on after G5 (G4 review, 2026-09-23). The dev compose,
    // and so CI's e2e stacks, set it.
    ConditionalModule.registerWhen(
      BoxModule,
      (env: NodeJS.ProcessEnv) => env.BOX_ENABLED === 'true',
    ),
  ],
  providers: [
    // Activates HTTP @Throttle limits with per-client-IP tracking (behind nginx);
    // skips WS (gateway uses WsThrottlerGuard). See common/http-throttler.guard.ts.
    { provide: APP_GUARD, useClass: HttpThrottlerGuard },
  ],
})
export class AppModule {}
