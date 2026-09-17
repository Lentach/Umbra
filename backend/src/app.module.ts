import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { ThrottlerModule } from '@nestjs/throttler';
import { ScheduleModule } from '@nestjs/schedule';
import { AuthModule } from './auth/auth.module';
import { MediaModule } from './media/media.module';
import { UsersModule } from './users/users.module';
import { ChatModule } from './chat/chat.module';
import { ConversationsModule } from './conversations/conversations.module';
import { MessagesModule } from './messages/messages.module';
import { FriendsModule } from './friends/friends.module';
import { BlockedModule } from './blocked/blocked.module';
import { FcmTokensModule } from './fcm-tokens/fcm-tokens.module';
import { KeyBundlesModule } from './key-bundles/key-bundles.module';
import { PushNotificationsModule } from './push-notifications/push-notifications.module';
import { User } from './users/user.entity';
import { Conversation } from './conversations/conversation.entity';
import { Message } from './messages/message.entity';
import { FriendRequest } from './friends/friend-request.entity';
import { BlockedUser } from './blocked/blocked-user.entity';
import { FcmToken } from './fcm-tokens/fcm-token.entity';
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
import { WebPushSubscription } from './web-push-subscriptions/web-push-subscription.entity';
import { WebPushSubscriptionsModule } from './web-push-subscriptions/web-push-subscriptions.module';
import { RefreshToken } from './auth/refresh-token.entity';
import { APP_GUARD } from '@nestjs/core';
import { HttpThrottlerGuard } from './common/http-throttler.guard';

import { ConversationNotificationPreference } from './conversation-notification-preferences/conversation-notification-preference.entity';
import { ConversationNotificationPreferencesModule } from './conversation-notification-preferences/conversation-notification-preferences.module';
import { ProfilePhoto } from './users/profile-photo.entity';
import { Device } from './key-bundles/device.entity';
import { AccountAuthorization } from './key-bundles/account-authorization.entity';
import { MessageEnvelope } from './messages/message-envelope.entity';
import { ReactionKey } from './reaction-keys/reaction-key.entity';
@Module({
  imports: [
    // Load and validate environment variables
    ConfigModule.forRoot({
      validate,
      isGlobal: true,
      envFilePath: ['.env.local', '.env'],
    }),
    // Schedule cron jobs for message expiration
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
          Conversation,
          Message,
          FriendRequest,
          BlockedUser,
          FcmToken,
          WebPushSubscription,
          RefreshToken,
          Device,
          AccountAuthorization,
          MessageEnvelope,
          KeyBundle,
          OneTimePreKey,
          IdentityChangeAudit,
          IdentityResetRequest,
          RecoveryKey,
          SecretNote,
          ConversationNotificationPreference,
          ProfilePhoto,
          ReactionKey,
        ],
        synchronize: process.env.NODE_ENV !== 'production',
      }),
    }),
    MediaModule,
    AuthModule,
    UsersModule,
    ConversationsModule,
    MessagesModule,
    FriendsModule,
    BlockedModule,
    FcmTokensModule,
    WebPushSubscriptionsModule,
    KeyBundlesModule,
    PushNotificationsModule,
    ChatModule,
    ConversationNotificationPreferencesModule,
    SecretNotesModule,
    HealthModule,
    VersionModule,
  ],
  providers: [
    // Activates HTTP @Throttle limits with per-client-IP tracking (behind nginx);
    // skips WS (gateway uses WsThrottlerGuard). See common/http-throttler.guard.ts.
    { provide: APP_GUARD, useClass: HttpThrottlerGuard },
  ],
})
export class AppModule {}
