import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ContactBackup } from './contact-backup.entity';
import { ContactBackupController } from './contact-backup.controller';
import { ContactBackupService } from './contact-backup.service';

@Module({
  imports: [TypeOrmModule.forFeature([ContactBackup])],
  providers: [ContactBackupService],
  controllers: [ContactBackupController],
})
export class BackupModule {}
