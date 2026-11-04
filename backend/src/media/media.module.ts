import { Global, Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { LocalStorageService } from './local-storage.service';
import { MediaController } from './media.controller';

@Global()
@Module({
  imports: [ConfigModule],
  controllers: [MediaController],
  providers: [LocalStorageService],
  exports: [LocalStorageService],
})
export class MediaModule {}
