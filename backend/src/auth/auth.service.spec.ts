import { Test, TestingModule } from '@nestjs/testing';
import { HttpException, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as argon2 from 'argon2';
import { AuthService } from './auth.service';
import {
  LoginBackoffService,
  BACKOFF_FREE_FAILURES,
} from './login-backoff.service';
import { verifyDummyPasswords } from './password-hash';
import { UsersService } from '../users/users.service';
import { RefreshTokensService } from './refresh-tokens.service';
import { User } from '../users/user.entity';
import { DevicesService } from '../key-bundles/devices.service';
import { IdentityResetService } from '../key-bundles/identity-reset.service';

// The login door's timing guard: a real verify would cost 19 MiB per test.
jest.mock('./password-hash', () => ({
  verifyDummyPasswords: jest.fn(() => Promise.resolve()),
  passwordFormatOf: (stored: string) =>
    stored.startsWith('$2') ? 'bcrypt' : 'argon2id',
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
    Pick<RefreshTokensService, 'createToken' | 'redeem' | 'revokeByPlain'>
  >;
  let devicesService: jest.Mocked<
    Pick<DevicesService, 'resolveLoginDeviceId' | 'isRevoked'>
  >;
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
        LoginBackoffService,
        {
          provide: UsersService,
          useValue: {
            create: jest.fn(),
            findByUsername: jest.fn(),
            findByUsernameAndTag: jest.fn(),
            findById: jest.fn(),
            setPassword: jest.fn(() => Promise.resolve(new Date())),
            checkPassword: jest.fn(),
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
            redeem: jest.fn(),
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
            isRevoked: jest.fn(() => Promise.resolve(false)),
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
      usersService.checkPassword.mockResolvedValue(true);
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
      usersService.checkPassword.mockResolvedValue(true);

      const result = await service.login('  testuser # 0427  ', 'ValidPass1');

      expect(usersService.findByUsernameAndTag).toHaveBeenCalledWith(
        'testuser',
        '0427',
      );
      expect(usersService.findByUsername).not.toHaveBeenCalled();
      expect(usersService.checkPassword).toHaveBeenCalledWith(
        mockUser,
        'ValidPass1',
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
      usersService.checkPassword.mockResolvedValue(true);
      devicesService.resolveLoginDeviceId.mockResolvedValue(4);

      await service.login('testuser#0427', 'ValidPass1');

      expect(devicesService.resolveLoginDeviceId).toHaveBeenCalledWith(1);
      expect(refreshTokensService.createToken).toHaveBeenCalledWith(1, 4);
      expect(jwtService.sign).toHaveBeenCalledWith(
        expect.objectContaining({ deviceId: 4 }),
      );
    });

    it('returns the generic failure and still runs a dummy verify for ambiguous bare usernames (no enumeration)', async () => {
      usersService.findByUsername.mockResolvedValue([
        mockUser as User,
        { ...mockUser, id: 2, tag: '9001' } as User,
      ]);
      usersService.checkPassword.mockResolvedValue(false);

      // Must be indistinguishable from any other bad login: same message, and a
      // real verify so the branch is not measurably faster (timing enum).
      await expect(service.login('testuser', 'ValidPass1')).rejects.toThrow(
        new UnauthorizedException('Invalid credentials'),
      );

      expect(usersService.findByUsername).toHaveBeenCalledWith('testuser');
      expect(usersService.findByUsernameAndTag).not.toHaveBeenCalled();
      expect(verifyDummyPasswords).toHaveBeenCalledTimes(1);
      expect(usersService.checkPassword).not.toHaveBeenCalled();
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
      // Not-found path performs a constant-time dummy verify to defeat
      // timing-based user enumeration.
      expect(verifyDummyPasswords).toHaveBeenCalled();
    });

    it('should throw when password invalid', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.checkPassword.mockResolvedValue(false);
      await expect(service.login('testuser', 'WrongPass1')).rejects.toThrow(
        UnauthorizedException,
      );
      await expect(service.login('testuser', 'WrongPass1')).rejects.toThrow(
        'Invalid credentials',
      );
    });

    it('treats an identifier with a "#" but empty tag as no-match via the timing-safe path', async () => {
      // 'user#' splits to ['user', ''] -> the `if (u && t)` guard is false, so
      // user stays null and we must fall through to the dummy verify
      // without ever querying with an empty tag.
      await expect(service.login('user#', 'ValidPass1')).rejects.toThrow(
        new UnauthorizedException('Invalid credentials'),
      );

      expect(usersService.findByUsernameAndTag).not.toHaveBeenCalled();
      expect(usersService.findByUsername).not.toHaveBeenCalled();
      // Constant-time guard still runs a real verify to defeat enumeration.
      expect(verifyDummyPasswords).toHaveBeenCalledTimes(1);
    });
  });

  describe('login backoff (plan D4)', () => {
    const IP_A = '203.0.113.1';
    const IP_B = '203.0.113.2';
    const fail = async (id: string, ip = IP_A) => {
      await service.login(id, 'WrongPass1', ip).catch(() => undefined);
    };
    const lockOut = async (id: string, ip = IP_A) => {
      for (let i = 0; i < BACKOFF_FREE_FAILURES; i++) await fail(id, ip);
    };

    it('refuses the next attempt with 429 rate_limited once the free failures are spent, without checking the password', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.checkPassword.mockResolvedValue(false);
      await lockOut('testuser');
      usersService.checkPassword.mockClear();
      usersService.checkPassword.mockResolvedValue(true); // even the RIGHT password waits

      const err = await service
        .login('testuser', 'ValidPass1', IP_A)
        .catch((e) => e);

      expect(err.getStatus()).toBe(429);
      expect(err.getResponse()).toEqual({
        error: 'rate_limited',
        retryAfterMs: expect.any(Number),
      });
      expect(usersService.checkPassword).not.toHaveBeenCalled();
      expect(jwtService.sign).not.toHaveBeenCalled();
    });

    it("an attacker's lock does not lock the owner out: another address with the right password gets in", async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.checkPassword.mockResolvedValue(false);
      await lockOut('testuser', IP_A);
      expect(
        (
          await service.login('testuser', 'x', IP_A).catch((e) => e)
        ).getStatus(),
      ).toBe(429);

      usersService.checkPassword.mockResolvedValue(true);
      await expect(
        service.login('testuser', 'ValidPass1', IP_B),
      ).resolves.toEqual(
        expect.objectContaining({ access_token: 'mock_jwt_token' }),
      );
    });

    it('10 parallel wrong logins from one address verify at most 5 times', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.checkPassword.mockImplementation(async () => {
        await new Promise((r) => setTimeout(r, 5));
        return false;
      });

      const results = await Promise.allSettled(
        Array.from({ length: 10 }, () =>
          service.login('testuser', 'WrongPass1', IP_A),
        ),
      );

      expect(usersService.checkPassword).toHaveBeenCalledTimes(
        BACKOFF_FREE_FAILURES,
      );
      const refused = results.filter(
        (r) => r.status === 'rejected' && r.reason.getStatus?.() === 429,
      );
      expect(refused).toHaveLength(10 - BACKOFF_FREE_FAILURES);
    });

    it('an unknown identifier backs off the same way as a real account', async () => {
      usersService.findByUsername.mockResolvedValue([]);
      await lockOut('ghost');

      const err = await service
        .login('ghost', 'ValidPass1', IP_A)
        .catch((e) => e);

      expect(err.getStatus()).toBe(429);
      expect(verifyDummyPasswords).toHaveBeenCalledTimes(BACKOFF_FREE_FAILURES);
    });

    it('does not reveal which tags exist: after locking the bare name, a wrong tag answers 429 too, and another name is not locked', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.findByUsernameAndTag.mockImplementation((_u, tag) =>
        Promise.resolve(tag === '0427' ? (mockUser as User) : null),
      );
      usersService.checkPassword.mockResolvedValue(false);
      await lockOut('testuser');

      for (const id of ['testuser#0427', 'testuser#1111']) {
        const err = await service.login(id, 'x', IP_A).catch((e) => e);
        expect(err.getStatus()).toBe(429);
      }
      usersService.findByUsername.mockResolvedValue([]);
      const other = await service.login('bob', 'x', IP_A).catch((e) => e);
      expect(other.getStatus()).toBe(401);
    });

    it('spellings of one unknown name share a key (parsed and trimmed like the lookup)', async () => {
      usersService.findByUsername.mockResolvedValue([]);
      for (let i = 0; i < BACKOFF_FREE_FAILURES; i++) {
        await fail(i % 2 ? '  GHOST ' : 'ghost');
      }
      const err = await service.login('Ghost', 'x', IP_A).catch((e) => e);
      expect(err.getStatus()).toBe(429);
    });

    it('a success before the limit resets the count', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.checkPassword.mockResolvedValue(false);
      for (let i = 0; i < BACKOFF_FREE_FAILURES - 1; i++)
        await fail('testuser');
      usersService.checkPassword.mockResolvedValue(true);
      await service.login('testuser', 'ValidPass1', IP_A);
      usersService.checkPassword.mockResolvedValue(false);
      for (let i = 0; i < BACKOFF_FREE_FAILURES - 1; i++)
        await fail('testuser');

      usersService.checkPassword.mockResolvedValue(true);
      await expect(
        service.login('testuser', 'ValidPass1', IP_A),
      ).resolves.toBeDefined();
    });

    it('a full hash gate (503) is not counted against the caller', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.checkPassword.mockRejectedValue(
        new HttpException({ error: 'busy' }, 503),
      );
      for (let i = 0; i < BACKOFF_FREE_FAILURES * 2; i++)
        await fail('testuser');
      usersService.checkPassword.mockResolvedValue(true);
      await expect(
        service.login('testuser', 'ValidPass1', IP_A),
      ).resolves.toBeDefined();
    });

    it('counts per account: the same name#tag and bare name share one budget, another account has its own', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      usersService.checkPassword.mockResolvedValue(false);
      for (let i = 0; i < BACKOFF_FREE_FAILURES - 1; i++)
        await fail('testuser');
      await fail('testuser#0427');

      const err = await service.login('testuser', 'x', IP_A).catch((e) => e);
      expect(err.getStatus()).toBe(429);

      usersService.findByUsernameAndTag.mockResolvedValue({
        ...mockUser,
        id: 2,
      } as User);
      usersService.checkPassword.mockResolvedValue(true);
      await expect(
        service.login('other#0001', 'ValidPass1', IP_A),
      ).resolves.toBeDefined();
    });

    it("a successful recovery clears the account's backoff for every client", async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.findByUsernameAndTag.mockResolvedValue(mockUser as User);
      usersService.checkPassword.mockResolvedValue(false);
      await lockOut('testuser', IP_A);
      identityResetService.verifyRecoveryPhrase.mockResolvedValue('accepted');
      await service.recoverPassword('testuser#0427', 'a b c', 'NewPass1x');

      usersService.checkPassword.mockResolvedValue(true);
      await expect(
        service.login('testuser', 'NewPass1x', IP_A),
      ).resolves.toBeDefined();
    });
  });

  // Every failed login must cost one bcrypt AND one Argon2 verify (~43 + ~16 ms),
  // or the faster branch tells an attacker which names exist.
  describe('login timing parity', () => {
    it('an unknown name pays both dummies', async () => {
      usersService.findByUsername.mockResolvedValue([]);
      await service.login('ghost', 'x', '203.0.113.1').catch(() => undefined);
      expect(verifyDummyPasswords).toHaveBeenCalledWith('x', [
        'bcrypt',
        'argon2id',
      ]);
    });

    it('a wrong password on a bcrypt row pays the Argon2 dummy on top of the real bcrypt verify', async () => {
      usersService.findByUsername.mockResolvedValue([
        { ...mockUser, password: '$2b$10$legacy' } as User,
      ]);
      usersService.checkPassword.mockResolvedValue(false);
      await service
        .login('testuser', 'x', '203.0.113.1')
        .catch(() => undefined);
      expect(verifyDummyPasswords).toHaveBeenCalledTimes(1);
      expect(verifyDummyPasswords).toHaveBeenCalledWith('x', ['argon2id']);
    });

    it('a wrong password on an Argon2id row pays the bcrypt dummy', async () => {
      usersService.findByUsername.mockResolvedValue([
        { ...mockUser, password: '$argon2id$v=19$m=19456,p=1,t=2$x$y' } as User,
      ]);
      usersService.checkPassword.mockResolvedValue(false);
      await service
        .login('testuser', 'x', '203.0.113.1')
        .catch(() => undefined);
      expect(verifyDummyPasswords).toHaveBeenCalledTimes(1);
      expect(verifyDummyPasswords).toHaveBeenCalledWith('x', ['bcrypt']);
    });

    it('a correct password pays no dummy', async () => {
      usersService.findByUsername.mockResolvedValue([mockUser as User]);
      usersService.checkPassword.mockResolvedValue(true);
      await service.login('testuser', 'ValidPass1', '203.0.113.1');
      expect(verifyDummyPasswords).not.toHaveBeenCalled();
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
      // (F34) Timing parity with a known name — the login door's twin:
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
    it('returns a new access_token and the refresh token the session keeps', async () => {
      refreshTokensService.redeem.mockResolvedValue({
        userId: 1,
        deviceId: 2,
        refreshToken: 'rotated_refresh',
      });
      usersService.findById.mockResolvedValue(mockUser as User);

      const result = await service.refreshWithToken('incoming_refresh', true);

      expect(refreshTokensService.redeem).toHaveBeenCalledWith(
        'incoming_refresh',
        expect.any(Function),
        { rotate: true },
      );
      expect(usersService.findById).toHaveBeenCalledWith(1);
      expect(result).toEqual({
        access_token: 'mock_jwt_token',
        refresh_token: 'rotated_refresh',
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

    it('treats a session predating the device column as device 1, and rotates only when asked', async () => {
      refreshTokensService.redeem.mockResolvedValue({
        userId: 1,
        deviceId: null,
        refreshToken: 'legacy_refresh',
      });
      usersService.findById.mockResolvedValue(mockUser as User);

      await service.refreshWithToken('legacy_refresh');

      expect(refreshTokensService.redeem.mock.calls[0][2]).toEqual({
        rotate: false,
      });

      // Read the recorded call rather than referencing the mocked method
      // again: an unbound method reference is the lint debt this file already
      // carries, and new code should not add to it.
      const signed = jwtService.sign.mock.calls.at(-1)?.[0] as {
        deviceId?: number;
      };
      expect(signed.deviceId).toBe(1);
    });

    // Decision 130 (E130a): the revoked-device answer is the refresh token
    // service's; what the AUTH service owes it is the predicate, reading a
    // session with no device column as device 1 (§8), like every other gate.
    it('hands the refresh token service a revoked-device predicate that reads a NULL device as device 1', async () => {
      refreshTokensService.redeem.mockResolvedValue({
        userId: 1,
        deviceId: 2,
        refreshToken: 'r',
      });
      usersService.findById.mockResolvedValue(mockUser as User);
      devicesService.isRevoked.mockResolvedValueOnce(true);

      await service.refreshWithToken('r');

      const isRevoked = refreshTokensService.redeem.mock.calls[0][1];
      await expect(isRevoked(1, 2)).resolves.toBe(true);
      // Read off the recorded calls, not the method: `unbound-method`.
      expect(devicesService.isRevoked.mock.calls.at(-1)).toEqual([1, 2]);
      await expect(isRevoked(1, null)).resolves.toBe(false);
      expect(devicesService.isRevoked.mock.calls.at(-1)).toEqual([1, 1]);
    });

    it('does not issue a token when the refresh token service refuses the device', async () => {
      refreshTokensService.redeem.mockRejectedValue(
        new UnauthorizedException('Device revoked'),
      );

      await expect(service.refreshWithToken('r')).rejects.toThrow(
        new UnauthorizedException('Device revoked'),
      );
      expect((jwtService.sign as jest.Mock).mock.calls).toHaveLength(0);
    });

    it('throws when user row missing after sliding refresh', async () => {
      refreshTokensService.redeem.mockResolvedValue({
        userId: 99,
        deviceId: 1,
        refreshToken: 'r',
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
