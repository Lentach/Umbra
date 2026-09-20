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
  RegisterFcmTokenDto,
  RemoveFcmTokenDto,
  UpdateProfileAboutDto,
  RegisterWebPushSubscriptionDto,
  RemoveWebPushSubscriptionDto,
} from './dto/user.dto';
import { ReorderProfilePhotosDto } from './dto/reorder-profile-photos.dto';
import { FcmTokensService } from '../fcm-tokens/fcm-tokens.service';
import { WebPushSubscriptionsService } from '../web-push-subscriptions/web-push-subscriptions.service';
import { validateAvatarMagicBytes } from '../media/magic-bytes.validator';

@Controller('users')
export class UsersController {
  private readonly logger = new Logger(UsersController.name);

  constructor(
    private usersService: UsersService,
    private storageService: LocalStorageService,
    private fcmTokensService: FcmTokensService,
    private webPushSubscriptionsService: WebPushSubscriptionsService,
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

  @Delete('account')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 5, ttl: 3600000 } })
  async deleteAccount(@Body() dto: DeleteAccountDto, @Request() req) {
    const userId = req.user.id;

    this.logger.debug('Account deletion requested');

    await this.usersService.deleteAccount(userId, dto.password);

    return { message: 'Account deleted successfully' };
  }

  @Post('fcm-token')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  async registerFcmToken(
    @Body() dto: RegisterFcmTokenDto,
    // `deviceId` always present since the §5.5 gate landed in JwtStrategy.
    @Request() req: { user: { id: number; deviceId: number } },
  ) {
    const userId = req.user.id;
    // Which device owns this endpoint (spec §12 amendment (xxiv)) — without
    // it a §5.5 revocation cannot stop pushing to the revoked device.
    await this.fcmTokensService.upsert(
      userId,
      dto.token,
      dto.platform,
      req.user.deviceId,
    );
    return { message: 'FCM token registered' };
  }

  @Delete('fcm-token')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  async removeFcmToken(@Body() dto: RemoveFcmTokenDto, @Request() req) {
    await this.fcmTokensService.removeByTokenForUser(req.user.id, dto.token);
    return { message: 'FCM token removed' };
  }

  @Post('web-push-subscription')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  async registerWebPushSubscription(
    @Body() dto: RegisterWebPushSubscriptionDto,
    @Request() req: { user: { id: number; deviceId: number } },
  ) {
    const userId = req.user.id;
    await this.webPushSubscriptionsService.upsert({
      userId,
      // See the FCM note above (amendment (xxiv)).
      deviceId: req.user.deviceId,
      endpoint: dto.endpoint,
      p256dh: dto.keys.p256dh,
      auth: dto.keys.auth,
      userAgent: dto.userAgent ?? null,
      expirationTime: dto.expirationTime ?? null,
    });
    return { message: 'Web push subscription registered' };
  }

  @Delete('web-push-subscription')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  async removeWebPushSubscription(
    @Body() dto: RemoveWebPushSubscriptionDto,
    @Request() req,
  ) {
    await this.webPushSubscriptionsService.removeByEndpointForUser(
      req.user.id,
      dto.endpoint,
    );
    return { message: 'Web push subscription removed' };
  }
}
