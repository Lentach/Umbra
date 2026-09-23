import { Test, TestingModule } from '@nestjs/testing';
import { UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as bcrypt from 'bcrypt';
import * as argon2 from 'argon2';
import { AuthService } from './auth.service';
import { UsersService } from '../users/users.service';
import { RefreshTokensService } from './refresh-tokens.service';
import { User } from '../users/user.entity';
import { DevicesService } from '../key-bundles/devices.service';
import { IdentityResetService } from '../key-bundles/identity-reset.service';

jest.mock('bcrypt', () => ({
  compare: jest.fn(),
  hash: jest.fn((val: string) => Promise.resolve(`hashed_${val}`)),
}));

// The recover door's timing guard: a real verify would cost 19 MiB per test.
jest.mock('argon2', () => ({
  verify: jest.fn(() => Promise.resolve(false)),
}));

describe('AuthService', () => {
  let service: AuthService;
  let usersService: jest.Mocked<UsersService>;
  let jwtService: jest.Mocked<JwtService>;
  let refreshTokensService: jest.Mocked<
    Pick<
      RefreshTokensService,
      'createToken' | 'consumeAndSlide' | 'revokeByPlain'
    >
  >;
  let devicesService: jest.Mocked<Pick<DevicesService, 'resolveLoginDeviceId'>>;
  let identityResetService: jest.Mocked<
    Pick<IdentityResetService, 'verifyRecoveryPhrase'>
  >;

  const mockUser: Partial<User> = {
    id: 1,
    username: 'testuser',
    tag: '0427',
    password: 'hashed_password',
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        AuthService,
        {
          provide: UsersService,
          useValue: {
            create: jest.fn(),
            findByUsername: jest.fn(),
            findByUsernameAndTag: jest.fn(),
            findById: jest.fn(),
            setPassword: jest.fn(() => Promise.resolve(new Date())),
          },
        },
        {
          provide: JwtService,
          useValue: {
            sign: jest.fn(() => 'mock_jwt_token'),
          },
        },
        {
          provide: RefreshTokensService,
          useValue: {
            createToken: jest.fn(() => Promise.resolve('mock_refresh_plain')),
            consumeAndSlide: jest.fn(),
            revokeByPlain: jest.fn(() => Promise.resolve()),
          },
        },
        {
          // A login resolves the account's LIVE PRIMARY (amendment (xxviii)) —
          // device 1 for every single-device account, which is what the login
          // laws below assume.
          provide: DevicesService,
          useValue: {
            resolveLoginDeviceId: jest.fn(() => Promise.resolve(1)),
          },
        },
        {
          provide: IdentityResetService,
          useValue: {
            verifyRecoveryPhrase: jest.fn(),
          },
        },
      ],
    }).compile();

    service = module.get<AuthService>(AuthService);
    usersService = module.get(UsersService);
    jwtService = module.get(JwtService);
    refreshTokensService = module.get(RefreshTokensService);
    devicesService = module.get(DevicesService);
    identityResetService = module.get(IdentityResetService);
    jest.clearAllMocks();
  });

  describe('register', () => {
    it('should create user and return id/username/tag', async () => {
      usersService.create.mockResolvedValue(mockUser as User);
      const result = await service.register('testuser', 'ValidPass1');
      expect(usersService.create).toHaveBeenCalledWith(
        'testuser',
        'ValidPass1',
      );
      expect(result).toEqual({ id: 1, username: 'testuser', tag: '0427' });
    });

    // Password strength validation is enforced at the DTO layer (RegisterDto).
    // See password.spec.ts for those tests.
  });

  describe('login', () => {
    it('should return access_token for valid credentials', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      (bcrypt.compare as jest.Mock).mockResolvedValue(true);
      const result = await service.login('testuser', 'ValidPass1');
      expect(result).toEqual({
        access_token: 'mock_jwt_token',
        refresh_token: 'mock_refresh_plain',
      });
      expect(jwtService.sign).toHaveBeenCalledWith({
        sub: 1,
        username: 'testuser',
        tag: '0427',
        deviceId: 1,
      });
    });

    it('trims username#tag identifiers, signs a JWT, and creates a refresh token for valid credentials', async () => {
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      (bcrypt.compare as jest.Mock).mockResolvedValue(true);

      const result = await service.login('  testuser # 0427  ', 'ValidPass1');

      expect(usersService.findByUsernameAndTag).toHaveBeenCalledWith(
        'testuser',
        '0427',
      );
      expect(usersService.findByUsername).not.toHaveBeenCalled();
      expect(bcrypt.compare).toHaveBeenCalledWith(
        'ValidPass1',
        'hashed_password',
      );
      // Session and token agree on the device from the first login (§4).
      expect(refreshTokensService.createToken).toHaveBeenCalledWith(1, 1);
      expect(jwtService.sign).toHaveBeenCalledWith({
        sub: 1,
        username: 'testuser',
        tag: '0427',
        deviceId: 1,
      });
      expect(result).toEqual({
        access_token: 'mock_jwt_token',
        refresh_token: 'mock_refresh_plain',
      });
    });

    it('logs in as the account LIVE PRIMARY, not a hardcoded device 1', async () => {
      // The lockout this prevents: a §6.2 reset revokes the pre-reset roster
      // and moves the account onto a freshly allocated id (amendment
      // (xxviii)). A login that kept claiming device 1 would mint a token for
      // a REVOKED device, which both §5.5 session gates then refuse — the
      // owner locked out with the correct password and no way back in.
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      (bcrypt.compare as jest.Mock).mockResolvedValue(true);
      devicesService.resolveLoginDeviceId.mockResolvedValue(4);

      await service.login('testuser#0427', 'ValidPass1');

      expect(devicesService.resolveLoginDeviceId).toHaveBeenCalledWith(1);
      expect(refreshTokensService.createToken).toHaveBeenCalledWith(1, 4);
      expect(jwtService.sign).toHaveBeenCalledWith(
        expect.objectContaining({ deviceId: 4 }),
      );
    });

    it('returns the generic failure and still runs a bcrypt compare for ambiguous bare usernames (no enumeration)', async () => {
      usersService.findByUsername.mockResolvedValue([
        mockUser as User,
        { ...mockUser, id: 2, tag: '9001' } as User,
      ]);
      (bcrypt.compare as jest.Mock).mockResolvedValue(false);

      // Must be indistinguishable from any other bad login: same message, and a
      // real bcrypt compare so the branch is not measurably faster (timing enum).
      await expect(service.login('testuser', 'ValidPass1')).rejects.toThrow(
        new UnauthorizedException('Invalid credentials'),
      );

      expect(usersService.findByUsername).toHaveBeenCalledWith('testuser');
      expect(usersService.findByUsernameAndTag).not.toHaveBeenCalled();
      expect(bcrypt.compare).toHaveBeenCalledTimes(1);
      expect(refreshTokensService.createToken).not.toHaveBeenCalled();
      expect(jwtService.sign).not.toHaveBeenCalled();
    });

    it('should throw when user not found', async () => {
      usersService.findByUsername.mockResolvedValue([]);
      await expect(service.login('unknown', 'ValidPass1')).rejects.toThrow(
        UnauthorizedException,
      );
      await expect(service.login('unknown', 'ValidPass1')).rejects.toThrow(
        'Invalid credentials',
      );
      // Not-found path now performs a constant-time dummy bcrypt.compare to
      // defeat timing-based user enumeration.
      expect(bcrypt.compare).toHaveBeenCalled();
    });

    it('should throw when password invalid', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      (bcrypt.compare as jest.Mock).mockResolvedValue(false);
      await expect(service.login('testuser', 'WrongPass1')).rejects.toThrow(
        UnauthorizedException,
      );
      await expect(service.login('testuser', 'WrongPass1')).rejects.toThrow(
        'Invalid credentials',
      );
    });

    it('treats an identifier with a "#" but empty tag as no-match via the timing-safe path', async () => {
      // 'user#' splits to ['user', ''] -> the `if (u && t)` guard is false, so
      // user stays null and we must fall through to the dummy bcrypt.compare
      // without ever querying with an empty tag.
      await expect(service.login('user#', 'ValidPass1')).rejects.toThrow(
        new UnauthorizedException('Invalid credentials'),
      );

      expect(usersService.findByUsernameAndTag).not.toHaveBeenCalled();
      expect(usersService.findByUsername).not.toHaveBeenCalled();
      // Constant-time guard still runs a real compare to defeat enumeration.
      expect(bcrypt.compare).toHaveBeenCalledTimes(1);
    });
  });

  // Amendment (lxxxii) clause 2 — the recovery phrase as a credential.
  describe('recoverPassword', () => {
    const phrase =
      'abandon ability able about above absent absorb abstract absurd abuse access accident';

    it('a correct phrase sets the password and answers with login tokens', async () => {
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      identityResetService.verifyRecoveryPhrase.mockResolvedValue('accepted');

      const result = await service.recoverPassword(
        'testuser#0427',
        phrase,
        'NewPass1x',
      );

      expect(identityResetService.verifyRecoveryPhrase).toHaveBeenCalledWith(
        1,
        phrase,
      );
      expect(usersService.setPassword).toHaveBeenCalledWith(1, 'NewPass1x');
      expect(devicesService.resolveLoginDeviceId).toHaveBeenCalledWith(1);
      expect(result).toEqual({
        access_token: 'mock_jwt_token',
        refresh_token: 'mock_refresh_plain',
      });
    });

    it('signs the token in a LATER second than passwordChangedAt even when the timer fires early, or JwtStrategy rejects it on arrival', async () => {
      // Node timers run on the monotonic clock and may fire ~1 ms before
      // Date.now() crosses the target (CI 917845eb: 1790127135 vs 1790127135).
      // A virtual clock whose timer lands 1 ms short makes that deterministic.
      let virtualMs = 1_790_127_135_400;
      const nowSpy = jest
        .spyOn(Date, 'now')
        .mockImplementation(() => virtualMs);
      const earlyTimer = (resolve: () => void, ms = 0) => {
        virtualMs += ms > 1 ? ms - 1 : ms;
        resolve();
      };
      const timerSpy = jest
        .spyOn(global, 'setTimeout')
        .mockImplementation(earlyTimer as unknown as typeof setTimeout);
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      identityResetService.verifyRecoveryPhrase.mockResolvedValue('accepted');
      let stamp = 0;
      (usersService.setPassword as jest.Mock).mockImplementation(() => {
        stamp = Date.now();
        return Promise.resolve(new Date(stamp));
      });
      let signedAt = 0;
      jwtService.sign.mockImplementation(() => {
        signedAt = Date.now();
        return 'mock_jwt_token';
      });

      try {
        await service.recoverPassword('testuser#0427', phrase, 'NewPass1x');
      } finally {
        timerSpy.mockRestore();
        nowSpy.mockRestore();
      }

      // `iat` is floored to the second and refused when <= the stamp's second.
      expect(Math.floor(signedAt / 1000)).toBeGreaterThan(
        Math.floor(stamp / 1000),
      );
    });

    it('an unknown identifier pays a dummy Argon2 verify and spends no counter', async () => {
      usersService.findByUsername.mockResolvedValue([]);

      await expect(
        service.recoverPassword('nobody', phrase, 'NewPass1x'),
      ).rejects.toThrow(UnauthorizedException);
      // (F34) Timing parity with a known name — the login door's bcrypt twin:
      // "no such user" must cost the same verify as a wrong phrase, or the
      // door enumerates usernames by response time.
      expect(argon2.verify).toHaveBeenCalledTimes(1);
      expect(argon2.verify).toHaveBeenCalledWith(expect.any(String), phrase);
      // ...but no account's failure counter is touched.
      expect(identityResetService.verifyRecoveryPhrase).not.toHaveBeenCalled();
      expect(usersService.setPassword).not.toHaveBeenCalled();
    });

    it('a known identifier does NOT pay the dummy verify on top of the real one', async () => {
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      identityResetService.verifyRecoveryPhrase.mockResolvedValue(
        'invalid_phrase',
      );

      await expect(
        service.recoverPassword('testuser#0427', phrase, 'NewPass1x'),
      ).rejects.toThrow(UnauthorizedException);
      expect(argon2.verify).not.toHaveBeenCalled();
    });

    it('a wrong phrase is refused with the same wording as an unknown name', async () => {
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      identityResetService.verifyRecoveryPhrase.mockResolvedValue(
        'invalid_phrase',
      );

      await expect(
        service.recoverPassword('testuser#0427', 'wrong', 'NewPass1x'),
      ).rejects.toThrow('Invalid credentials');
      expect(usersService.setPassword).not.toHaveBeenCalled();
    });

    it('a lockout answers 423, distinct from a wrong phrase', async () => {
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      identityResetService.verifyRecoveryPhrase.mockResolvedValue('locked');

      await expect(
        service.recoverPassword('testuser#0427', phrase, 'NewPass1x'),
      ).rejects.toMatchObject({ status: 423 });
      expect(usersService.setPassword).not.toHaveBeenCalled();
    });

    it('an ambiguous bare username resolves to nobody', async () => {
      usersService.findByUsername.mockResolvedValue([
        mockUser as User,
        { ...mockUser, id: 2, tag: '9999' } as User,
      ]);

      await expect(
        service.recoverPassword('testuser', phrase, 'NewPass1x'),
      ).rejects.toThrow(UnauthorizedException);
      expect(identityResetService.verifyRecoveryPhrase).not.toHaveBeenCalled();
      expect(argon2.verify).toHaveBeenCalledTimes(1);
    });
  });

  describe('refreshWithToken', () => {
    it('returns new access_token and slid refresh_token when refresh valid', async () => {
      refreshTokensService.consumeAndSlide.mockResolvedValue({
        userId: 1,
        deviceId: 2,
      });
      usersService.findById.mockResolvedValue(mockUser as User);

      const result = await service.refreshWithToken('incoming_refresh');

      expect(refreshTokensService.consumeAndSlide).toHaveBeenCalledWith(
        'incoming_refresh',
      );
      expect(usersService.findById).toHaveBeenCalledWith(1);
      expect(result).toEqual({
        access_token: 'mock_jwt_token',
        refresh_token: 'incoming_refresh',
      });
      // The reissued token keeps naming the SAME device: silently becoming
      // device 1 would hand this session another device's key namespace.
      expect(jwtService.sign).toHaveBeenCalledWith({
        sub: 1,
        username: 'testuser',
        tag: '0427',
        deviceId: 2,
      });
    });

    it('treats a session predating the device column as device 1', async () => {
      refreshTokensService.consumeAndSlide.mockResolvedValue({
        userId: 1,
        deviceId: null,
      });
      usersService.findById.mockResolvedValue(mockUser as User);

      await service.refreshWithToken('legacy_refresh');

      // Read the recorded call rather than referencing the mocked method
      // again: an unbound method reference is the lint debt this file already
      // carries, and new code should not add to it.
      const signed = jwtService.sign.mock.calls.at(-1)?.[0] as {
        deviceId?: number;
      };
      expect(signed.deviceId).toBe(1);
    });

    it('throws when user row missing after sliding refresh', async () => {
      refreshTokensService.consumeAndSlide.mockResolvedValue({
        userId: 99,
        deviceId: 1,
      });
      usersService.findById.mockResolvedValue(null);

      await expect(service.refreshWithToken('r')).rejects.toThrow(
        UnauthorizedException,
      );
    });
  });

  describe('logoutRefreshToken', () => {
    it('forwards the plain token to refreshTokensService.revokeByPlain', async () => {
      await service.logoutRefreshToken('plain-to-revoke');

      expect(refreshTokensService.revokeByPlain).toHaveBeenCalledTimes(1);
      expect(refreshTokensService.revokeByPlain).toHaveBeenCalledWith(
        'plain-to-revoke',
      );
    });
  });
});
