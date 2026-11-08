import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { User } from './user.entity';
import { ProfilePhoto } from './profile-photo.entity';
import { UsersService } from './users.service';
import { UsersController } from './users.controller';
import { KeyBundlesModule } from '../key-bundles/key-bundles.module';
import { RefreshTokensModule } from '../auth/refresh-tokens.module';

@Module({
  imports: [
    TypeOrmModule.forFeature([User, ProfilePhoto]),
    RefreshTokensModule,
    KeyBundlesModule,
  ],
  controllers: [UsersController],
  providers: [UsersService],
  exports: [UsersService],
})
export class UsersModule {}
