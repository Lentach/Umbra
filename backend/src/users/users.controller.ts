import {
  Controller,
  Post,
  Delete,
  Patch,
  Get,
  Body,
  UseGuards,
  Request,
  UnauthorizedException,
  Logger,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { UsersService } from './users.service';
import {
  ResetPasswordDto,
  DeleteAccountDto,
  VerifyPasswordDto,
  UpdateProfileAboutDto,
} from './dto/user.dto';

@Controller('users')
export class UsersController {
  private readonly logger = new Logger(UsersController.name);

  constructor(private usersService: UsersService) {}

  @Get('me')
  @UseGuards(JwtAuthGuard)
  async getMe(@Request() req) {
    const user = await this.usersService.findProfileById(req.user.id);
    if (!user) throw new UnauthorizedException();
    return {
      id: user.id,
      username: user.username,
      tag: user.tag,
      profilePictureUrl: user.profilePictureUrl ?? null,
      about: user.about ?? null,
      profilePhotos: [...user.profilePhotos]
        .sort(
          (left, right) => left.position - right.position || left.id - right.id,
        )
        .map((photo) => ({
          id: photo.id,
          url: photo.url,
          isPrimary: photo.isPrimary,
          createdAt: photo.createdAt,
        })),
    };
  }

  @Patch('profile-about')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 20, ttl: 60000 } })
  async updateProfileAbout(
    @Body() dto: UpdateProfileAboutDto,
    @Request() req: { user: { id: number } },
  ) {
    const user = await this.usersService.updateProfileAbout(
      req.user.id,
      dto.about ?? null,
    );
    return { about: user.about };
  }

  @Post('reset-password')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 10, ttl: 3600000 } })
  async resetPassword(@Body() dto: ResetPasswordDto, @Request() req) {
    const userId = req.user.id;

    this.logger.debug('Password reset requested');

    await this.usersService.resetPassword(
      userId,
      dto.oldPassword,
      dto.newPassword,
    );

    return { message: 'Password updated successfully' };
  }

  // Password check WITHOUT a session (metadata-privacy decision R76): the client
  // proves a typed password before minting the contact-backup wrap from it.
  // `/auth/login` would issue a session (and, on a linked device, the
  // primary's token). A guessing oracle for a JWT holder: keep the reset budget.
  @Post('verify-password')
  @HttpCode(HttpStatus.OK)
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 10, ttl: 3600000 } })
  async verifyPassword(
    @Body() dto: VerifyPasswordDto,
    @Request() req: { user: { id: number } },
  ): Promise<{ ok: true }> {
    this.logger.debug('Password verification requested');

    await this.usersService.verifyPassword(req.user.id, dto.password);

    return { ok: true };
  }

  @Delete('account')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 5, ttl: 3600000 } })
  async deleteAccount(@Body() dto: DeleteAccountDto, @Request() req) {
    const userId = req.user.id;

    this.logger.debug('Account deletion requested');

    await this.usersService.deleteAccount(userId, dto.password);

    return { message: 'Account deleted successfully' };
  }
}
