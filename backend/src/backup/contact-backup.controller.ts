import { Body, Controller, Get, Put, Request, UseGuards } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import {
  ContactBackupService,
  ContactBackupView,
} from './contact-backup.service';
import { PutContactBackupDto } from './dto/contact-backup.dto';

/**
 * The account's sealed contact backup (metadata-privacy PR2.4).
 *
 * The account is ALWAYS the authenticated one: the user id comes from the JWT
 * via `req.user.id` and never from the body — a body-supplied `userId` is not
 * on the DTO, so the global whitelisting ValidationPipe strips it before this
 * controller sees it.
 */
@Controller('backup')
export class ContactBackupController {
  constructor(private readonly service: ContactBackupService) {}

  /** 404 when the account has no row: the client mints a salt and PUTs. */
  @UseGuards(JwtAuthGuard)
  @Get('contacts')
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  async getContacts(
    @Request() req: { user: { id: number } },
  ): Promise<ContactBackupView> {
    return this.service.get(req.user.id);
  }

  /** 409 `stale_backup` (with the server's rev) or `salt_mismatch` on refusal. */
  @UseGuards(JwtAuthGuard)
  @Put('contacts')
  // Tracks the client's 5 s upload debounce, not the global ceiling: do not
  // raise it blindly. Every accepted PUT rewrites a 2 MB TOAST column, so a
  // permissive limit buys an authenticated account cheap WAL and dead-tuple
  // churn for nothing.
  @Throttle({ default: { limit: 10, ttl: 60000 } })
  async putContacts(
    @Body() dto: PutContactBackupDto,
    @Request() req: { user: { id: number } },
  ): Promise<{ rev: number; updatedAt: Date }> {
    return this.service.put(req.user.id, dto);
  }
}
