import { Module } from '@nestjs/common';
import { ChatGateway } from './chat.gateway';
import { WsThrottlerGuard } from './guards/ws-throttler.guard';
import { ChatMessageService } from './services/chat-message.service';
import { ChatFriendRequestService } from './services/chat-friend-request.service';
import { ChatConversationService } from './services/chat-conversation.service';
import { ChatKeyExchangeService } from './services/chat-key-exchange.service';
import { ChatPresenceService } from './services/chat-presence.service';
import { ChatBlockService } from './services/chat-block.service';
import { ChatSearchService } from './services/chat-search.service';
import { ChatReactionService } from './services/chat-reaction.service';
import { ChatReactionKeyService } from './services/chat-reaction-key.service';
import { ChatDeviceListService } from './services/chat-device-list.service';
import { ChatProvisioningService } from './services/chat-provisioning.service';
import { ChatDeviceRevocationService } from './services/chat-device-revocation.service';
import { ChatLinkPreviewService } from './services/chat-link-preview.service';
import { ChatValidationModule } from './chat-validation.module';
import { LinkPreviewModule } from './services/link-preview.module';
import { AuthModule } from '../auth/auth.module';
import { UsersModule } from '../users/users.module';
import { ConversationsModule } from '../conversations/conversations.module';
import { MessagesModule } from '../messages/messages.module';
import { FriendsModule } from '../friends/friends.module';
import { BlockedModule } from '../blocked/blocked.module';
import { KeyBundlesModule } from '../key-bundles/key-bundles.module';
import { PushNotificationsModule } from '../push-notifications/push-notifications.module';
import { FcmTokensModule } from '../fcm-tokens/fcm-tokens.module';
import { WebPushSubscriptionsModule } from '../web-push-subscriptions/web-push-subscriptions.module';
import { ConversationNotificationPreferencesModule } from '../conversation-notification-preferences/conversation-notification-preferences.module';
import { ReactionKeysModule } from '../reaction-keys/reaction-keys.module';

@Module({
  imports: [
    AuthModule,
    UsersModule,
    ConversationsModule,
    MessagesModule,
    FriendsModule,
    BlockedModule,
    ChatValidationModule,
    KeyBundlesModule,
    LinkPreviewModule,
    PushNotificationsModule,
    // Revocation tears down the revoked device's push rows itself (§5.5);
    // PushNotificationsModule does not re-export these two, so the chat
    // module imports them directly.
    FcmTokensModule,
    WebPushSubscriptionsModule,
    ConversationNotificationPreferencesModule,
    ReactionKeysModule,
  ],
  providers: [
    ChatGateway,
    ChatMessageService,
    ChatFriendRequestService,
    ChatConversationService,
    ChatKeyExchangeService,
    ChatPresenceService,
    ChatBlockService,
    ChatSearchService,
    ChatReactionService,
    ChatReactionKeyService,
    ChatDeviceListService,
    ChatProvisioningService,
    ChatDeviceRevocationService,
    ChatLinkPreviewService,
    WsThrottlerGuard,
  ],
})
export class ChatModule {}
