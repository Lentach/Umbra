import { Module } from '@nestjs/common';
import { ChatGateway } from './chat.gateway';
import { WsThrottlerGuard } from './guards/ws-throttler.guard';
import { ChatKeyExchangeService } from './services/chat-key-exchange.service';
import { ChatPresenceService } from './services/chat-presence.service';
import { ChatSearchService } from './services/chat-search.service';
import { ChatDeviceListService } from './services/chat-device-list.service';
import { ChatProvisioningService } from './services/chat-provisioning.service';
import { ChatDeviceRevocationService } from './services/chat-device-revocation.service';
import { AuthModule } from '../auth/auth.module';
import { UsersModule } from '../users/users.module';
import { KeyBundlesModule } from '../key-bundles/key-bundles.module';

@Module({
  imports: [AuthModule, UsersModule, KeyBundlesModule],
  providers: [
    ChatGateway,
    ChatKeyExchangeService,
    ChatPresenceService,
    ChatSearchService,
    ChatDeviceListService,
    ChatProvisioningService,
    ChatDeviceRevocationService,
    WsThrottlerGuard,
  ],
})
export class ChatModule {}
