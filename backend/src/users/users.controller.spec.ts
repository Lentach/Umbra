import 'reflect-metadata';
import {
  ExecutionContext,
  BadRequestException,
  HttpStatus,
  INestApplication,
  ValidationPipe,
} from '@nestjs/common';
import { GUARDS_METADATA, HTTP_CODE_METADATA } from '@nestjs/common/constants';
import { Test } from '@nestjs/testing';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { VerifyPasswordDto } from './dto/user.dto';
import { UsersController } from './users.controller';
import { UsersService } from './users.service';

describe('UsersController', () => {
  describe('profile photo routes (decision 138: a photo travels over the box)', () => {
    let app: INestApplication;
    let base: string;
    const usersService = { findProfileById: jest.fn() };

    beforeAll(async () => {
      const moduleRef = await Test.createTestingModule({
        controllers: [UsersController],
        providers: [{ provide: UsersService, useValue: usersService }],
      })
        .overrideGuard(JwtAuthGuard)
        .useValue({
          canActivate: (ctx: ExecutionContext) => {
            ctx.switchToHttp().getRequest().user = { id: 7 };
            return true;
          },
        })
        .compile();
      app = moduleRef.createNestApplication();
      await app.listen(0, '127.0.0.1');
      base = await app.getUrl();
    });

    afterAll(async () => {
      await app.close();
    });

    it.each([
      ['POST', '/users/profile-picture'],
      ['POST', '/users/profile-photos/3/main'],
      ['POST', '/users/profile-photos/order'],
      ['DELETE', '/users/profile-photos/3'],
    ])('%s %s answers 404: an older build cannot change a photo', async (method, path) => {
      const res = await fetch(`${base}${path}`, { method });
      expect(res.status).toBe(404);
    });

    it('GET /users/me still serves the legacy server photo the one-time migration reads', async () => {
      usersService.findProfileById.mockResolvedValue({
        id: 7,
        username: 'alice',
        tag: '1234',
        about: null,
        profilePictureUrl: '/avatars/alice.jpg',
        profilePhotos: [],
      });
      const res = await fetch(`${base}/users/me`);
      expect(res.status).toBe(200);
      expect(await res.json()).toMatchObject({
        id: 7,
        profilePictureUrl: '/avatars/alice.jpg',
      });
    });
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
});
