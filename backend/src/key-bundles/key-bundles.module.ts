import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { AccountAuthorization } from './account-authorization.entity';
import { Device } from './device.entity';
import { KeyBundle } from './key-bundle.entity';
import { OneTimePreKey } from './one-time-pre-key.entity';
import { IdentityChangeAudit } from './identity-change-audit.entity';
import { IdentityResetRequest } from './identity-reset-request.entity';
import { RecoveryKey } from './recovery-key.entity';
import { DevicesService } from './devices.service';
import { KeyBundlesService } from './key-bundles.service';
import { IdentityResetService } from './identity-reset.service';
import { IdentityRetentionService } from './identity-retention.service';
import { DeviceListService } from './device-list.service';
import { ProvisioningStagesService } from './provisioning-stages.service';
import { ResetRosterService } from './reset-roster.service';
import { RefreshTokensModule } from '../refresh-tokens/refresh-tokens.module';

@Module({
  imports: [
    // Every new entity MUST be here AND in the app.module DataSource list:
    // missing the second throws EntityMetadataNotFoundError at runtime while
    // every mocked unit test stays green (cost Phase 0a a live debug session).
    TypeOrmModule.forFeature([
      AccountAuthorization,
      Device,
      KeyBundle,
      OneTimePreKey,
      IdentityChangeAudit,
      IdentityResetRequest,
      RecoveryKey,
    ]),
    // The §6.2 roster teardown re-issues the recovering device's session
    // (amendment (xxviii)). RefreshTokensModule carries no dependency back
    // here, so this stays acyclic.
    RefreshTokensModule,
  ],
  providers: [
    DevicesService,
    KeyBundlesService,
    IdentityResetService,
    DeviceListService,
    ProvisioningStagesService,
    ResetRosterService,
    IdentityRetentionService,
  ],
  exports: [
    DevicesService,
    KeyBundlesService,
    IdentityResetService,
    DeviceListService,
    ProvisioningStagesService,
    ResetRosterService,
  ],
})
export class KeyBundlesModule {}
