import 'reflect-metadata';
import {
  BadRequestException,
  HttpStatus,
  ValidationPipe,
} from '@nestjs/common';
import { GUARDS_METADATA, HTTP_CODE_METADATA } from '@nestjs/common/constants';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { VerifyPasswordDto } from './dto/user.dto';
import { UsersController } from './users.controller';

describe('UsersController', () => {
  const usersService = {
    getProfilePhotos: jest.fn(),
    addProfilePhoto: jest.fn(),
    reorderProfilePhotos: jest.fn(),
  };
  const storageService = {
    uploadAvatar: jest.fn(),
    deleteAvatar: jest.fn(),
  };
  const controller = new UsersController(
    usersService as any,
    storageService as any,
    {} as any,
    {} as any,
  );

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('deletes a newly uploaded asset when profile-photo persistence fails', async () => {
    usersService.getProfilePhotos.mockResolvedValue([]);
    storageService.uploadAvatar.mockResolvedValue({
      secureUrl: '/avatars/new-photo.jpg',
      publicId: 'avatars/new-photo.jpg',
    });
    usersService.addProfilePhoto.mockRejectedValue(
      new BadRequestException('A profile can have at most three photos'),
    );
    storageService.deleteAvatar.mockResolvedValue(undefined);

    await expect(
      controller.uploadProfilePicture(
        {
          buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
          mimetype: 'image/png',
        } as Express.Multer.File,
        { user: { id: 7 } },
      ),
    ).rejects.toThrow('A profile can have at most three photos');

    expect(storageService.deleteAvatar).toHaveBeenCalledWith(
      'avatars/new-photo.jpg',
    );
  });
  it('rejects before uploading when the gallery already holds three photos', async () => {
    usersService.getProfilePhotos.mockResolvedValue([
      { id: 1 },
      { id: 2 },
      { id: 3 },
    ]);

    await expect(
      controller.uploadProfilePicture(
        {
          buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
          mimetype: 'image/png',
        } as Express.Multer.File,
        { user: { id: 7 } },
      ),
    ).rejects.toThrow('A profile can have at most three photos');

    // The pre-check must short-circuit before any asset is uploaded, so a
    // full gallery never orphans a freshly uploaded file.
    expect(storageService.uploadAvatar).not.toHaveBeenCalled();
  });
  it('throttles the fcm-token endpoints at the same 30/15min limit as the web-push siblings', () => {
    // @Throttle metadata lives on the route handler under THROTTLER:<key><name>.
    const limit = (fn: unknown) =>
      Reflect.getMetadata('THROTTLER:LIMITdefault', fn as object);
    const ttl = (fn: unknown) =>
      Reflect.getMetadata('THROTTLER:TTLdefault', fn as object);

    // Concrete sibling limit: 30 requests per 15 minutes.
    expect(limit(controller.registerFcmToken)).toBe(30);
    expect(ttl(controller.registerFcmToken)).toBe(900000);
    expect(limit(controller.removeFcmToken)).toBe(30);
    expect(ttl(controller.removeFcmToken)).toBe(900000);

    // Parity with the web-push siblings (guards against future drift).
    expect(limit(controller.registerFcmToken)).toBe(
      limit(controller.registerWebPushSubscription),
    );
    expect(ttl(controller.removeFcmToken)).toBe(
      ttl(controller.removeWebPushSubscription),
    );
  });

  describe('POST /users/verify-password', () => {
    // Metadata hangs off the prototype function; read it via the descriptor.
    const handler = (): object => {
      const value: unknown = Object.getOwnPropertyDescriptor(
        UsersController.prototype,
        'verifyPassword',
      )?.value;
      if (typeof value !== 'function') throw new Error('no verifyPassword');
      return value;
    };

    it('is JWT-guarded, answers 200 and keeps the reset-password budget', () => {
      // A password oracle for any JWT holder: unguarded or loosely throttled it
      // is a free online guessing endpoint; a 201 breaks the client's check.
      const guards: unknown = Reflect.getMetadata(GUARDS_METADATA, handler());
      expect(guards).toContain(JwtAuthGuard);
      expect(Reflect.getMetadata(HTTP_CODE_METADATA, handler())).toBe(
        HttpStatus.OK,
      );
      expect(Reflect.getMetadata('THROTTLER:LIMITdefault', handler())).toBe(10);
      expect(Reflect.getMetadata('THROTTLER:TTLdefault', handler())).toBe(
        3600000,
      );
    });

    it.each([{ password: '' }, {}, { password: 'x'.repeat(129) }])(
      'rejects the body %j before the service runs',
      async (body) => {
        await expect(
          new ValidationPipe({ whitelist: true }).transform(body, {
            type: 'body',
            metatype: VerifyPasswordDto,
          }),
        ).rejects.toThrow(BadRequestException);
      },
    );
  });

  it('forwards the requested photo order and returns the fresh primary-first list', async () => {
    const createdAt = new Date('2026-07-16T00:00:00.000Z');
    usersService.reorderProfilePhotos.mockResolvedValue([
      {
        id: 3,
        url: '/avatars/three.jpg',
        isPrimary: true,
        position: 0,
        createdAt,
      },
      {
        id: 1,
        url: '/avatars/one.jpg',
        isPrimary: false,
        position: 1,
        createdAt,
      },
    ]);

    await expect(
      controller.reorderProfilePhotos(
        { orderedIds: [3, 1] },
        { user: { id: 7 } },
      ),
    ).resolves.toEqual({
      profilePhotos: [
        {
          id: 3,
          url: '/avatars/three.jpg',
          isPrimary: true,
          createdAt,
        },
        {
          id: 1,
          url: '/avatars/one.jpg',
          isPrimary: false,
          createdAt,
        },
      ],
    });
    expect(usersService.reorderProfilePhotos).toHaveBeenCalledWith(7, [3, 1]);
  });
});
