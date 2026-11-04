import {
  Controller,
  Post,
  Delete,
  Patch,
  Get,
  Body,
  UseGuards,
  Request,
  UseInterceptors,
  UploadedFile,
  BadRequestException,
  UnauthorizedException,
  Logger,
  Param,
  ParseIntPipe,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { Throttle } from '@nestjs/throttler';
import { memoryStorage } from 'multer';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { LocalStorageService } from '../media/local-storage.service';
import { UsersService } from './users.service';
import {
  ResetPasswordDto,
  DeleteAccountDto,
  VerifyPasswordDto,
  UpdateProfileAboutDto,
} from './dto/user.dto';
import { ReorderProfilePhotosDto } from './dto/reorder-profile-photos.dto';
import { validateAvatarMagicBytes } from '../media/magic-bytes.validator';

@Controller('users')
export class UsersController {
  private readonly logger = new Logger(UsersController.name);

  constructor(
    private usersService: UsersService,
    private storageService: LocalStorageService,
  ) {}

  @Post('profile-picture')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 10, ttl: 3600000 } })
  @UseInterceptors(
    FileInterceptor('file', {
      storage: memoryStorage(),
      fileFilter: (req, file, cb) => {
        if (!file.mimetype.match(/^image\/(jpeg|png)$/)) {
          return cb(
            new BadRequestException('Only JPEG and PNG images are allowed'),
            false,
          );
        }
        cb(null, true);
      },
      limits: {
        fileSize: 5 * 1024 * 1024, // 5MB
      },
    }),
  )
  async uploadProfilePicture(
    @UploadedFile() file: Express.Multer.File,
    @Request() req,
  ) {
    if (!file) {
      throw new BadRequestException('No file uploaded');
    }
    validateAvatarMagicBytes(file.buffer);

    const userId = req.user.id;
    if ((await this.usersService.getProfilePhotos(userId)).length >= 3) {
      throw new BadRequestException('A profile can have at most three photos');
    }

    const { secureUrl, publicId } = await this.storageService.uploadAvatar(
      userId,
      file.buffer,
      file.mimetype,
    );

    this.logger.debug('Profile picture uploaded');

    try {
      const photos = await this.usersService.addProfilePhoto(
        userId,
        secureUrl,
        publicId,
      );
      const primaryPhoto = photos.find((photo) => photo.isPrimary);
      return {
        profilePictureUrl: primaryPhoto?.url ?? null,
        profilePhotos: photos.map((photo) => ({
          id: photo.id,
          url: photo.url,
          isPrimary: photo.isPrimary,
          createdAt: photo.createdAt,
        })),
      };
    } catch (error) {
      try {
        await this.storageService.deleteAvatar(publicId);
      } catch (cleanupError) {
        this.logger.warn(
          `uploadProfilePicture: failed to clean up ${publicId}: ${(cleanupError as Error).message}`,
        );
      }
      throw error;
    }
  }

  @Post('profile-photos/:photoId/main')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 20, ttl: 60000 } })
  async setPrimaryProfilePhoto(
    @Param('photoId', ParseIntPipe) photoId: number,
    @Request() req: { user: { id: number } },
  ) {
    const photos = await this.usersService.setPrimaryProfilePhoto(
      req.user.id,
      photoId,
    );
    return {
      profilePhotos: photos.map((photo) => ({
        id: photo.id,
        url: photo.url,
        isPrimary: photo.isPrimary,
        createdAt: photo.createdAt,
      })),
    };
  }

  @Post('profile-photos/order')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 20, ttl: 60000 } })
  async reorderProfilePhotos(
    @Body() dto: ReorderProfilePhotosDto,
    @Request() req: { user: { id: number } },
  ) {
    const photos = await this.usersService.reorderProfilePhotos(
      req.user.id,
      dto.orderedIds,
    );
    return {
      profilePhotos: photos.map((photo) => ({
        id: photo.id,
        url: photo.url,
        isPrimary: photo.isPrimary,
        createdAt: photo.createdAt,
      })),
    };
  }

  @Delete('profile-photos/:photoId')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 20, ttl: 60000 } })
  async deleteProfilePhoto(
    @Param('photoId', ParseIntPipe) photoId: number,
    @Request() req: { user: { id: number } },
  ) {
    const photos = await this.usersService.deleteProfilePhoto(
      req.user.id,
      photoId,
    );
    return {
      profilePhotos: photos.map((photo) => ({
        id: photo.id,
        url: photo.url,
        isPrimary: photo.isPrimary,
        createdAt: photo.createdAt,
      })),
    };
  }

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
