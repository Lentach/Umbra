import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ReactionKey } from './reaction-key.entity';
import { ReactionKeysService } from './reaction-keys.service';

@Module({
  // The entity is registered so `synchronize` builds the table in dev/CI;
  // production truth is migration 0018. The service itself speaks SQL through
  // the DataSource, like the other row-locking write paths.
  imports: [TypeOrmModule.forFeature([ReactionKey])],
  providers: [ReactionKeysService],
  exports: [ReactionKeysService],
})
export class ReactionKeysModule {}
