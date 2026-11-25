import { Logger, UnauthorizedException } from '@nestjs/common';
import * as argon2 from 'argon2';
import { Server, Socket } from 'socket.io';
import { AuthController } from '../auth/auth.controller';
import { AuthService } from '../auth/auth.service';
import { RecoverPasswordDto } from '../auth/dto/recover-password.dto';
import { LoginBackoffService } from '../auth/login-backoff.service';
import { ChatKeyExchangeService } from '../chat/services/chat-key-exchange.service';
import {
  IdentityResetService,
  RECOVERY_MIN_AGE_MS,
  TIMING_SAFE_DUMMY_VERIFIER,
} from './identity-reset.service';

// Plan B7 tail (0.2.104): the server refuses a plaintext recovery phrase at
// all three doors. These tests wire the REAL handlers to the REAL
// IdentityResetService and replace only argon2, so "the phrase reached the
// hasher" is observable. The stand-in verifier accepts exactly the string it
// was made from: every row below would ACCEPT the phrase if anything asked.
const verifierOf = (value: string) => `verifier-of:${value}`;
jest.mock('argon2', () => ({
  argon2id: 2,
  hash: jest.fn((value: string) => Promise.resolve(`verifier-of:${value}`)),
  verify: jest.fn((hash: string, value: string) =>
    Promise.resolve(hash === `verifier-of:${value}`),
  ),
}));

const phrase =
  'abandon ability able about above absent absorb abstract absurd abuse access accident';
const v2Backup = {
  blob: 'c2VhbGVkLWJsb2I=',
  salt: 'c2FsdC1zaXh0ZWVuLWI=',
  iterations: 0,
  version: 2,
};

describe('a plaintext recovery phrase is refused at every door (plan B7)', () => {
  let recoveryRepo: Record<string, jest.Mock>;
  let resetRepo: Record<string, jest.Mock>;
  let counterUpdate: jest.Mock;
  let setPassword: jest.Mock;
  let client: { data: unknown; emit: jest.Mock };
  let roomEmit: jest.Mock;
  let server: Server;
  let keyExchange: ChatKeyExchangeService;
  let controller: AuthController;
  let logSpies: jest.SpyInstance[];

  /** A row old enough to buy the shortcut, whose verifier matches `phrase`. */
  const row = (verifierKind: 'phrase_v1' | 'auth_v2') => ({
    id: 3,
    userId: 1,
    verifierHash: verifierOf(phrase),
    verifierKind,
    usedAt: null,
    failedAttempts: 0,
    lockedUntil: null,
    createdAt: new Date(Date.now() - RECOVERY_MIN_AGE_MS - 60_000),
  });

  beforeEach(() => {
    jest.clearAllMocks();
    counterUpdate = jest.fn().mockResolvedValue({ affected: 1, raw: [] });
    const builder: Record<string, jest.Mock> = {
      execute: counterUpdate,
      getOne: jest.fn().mockResolvedValue(null),
    };
    for (const step of [
      'update',
      'set',
      'where',
      'andWhere',
      'innerJoin',
      'orderBy',
      'returning',
    ]) {
      builder[step] = jest.fn(() => builder);
    }
    recoveryRepo = {
      findOne: jest.fn().mockResolvedValue(row('phrase_v1')),
      insert: jest.fn().mockResolvedValue({}),
      update: jest.fn().mockResolvedValue({ affected: 1 }),
      createQueryBuilder: jest.fn(() => builder),
    };
    resetRepo = {
      findOne: jest.fn().mockResolvedValue(null),
      insert: jest.fn().mockResolvedValue({}),
      createQueryBuilder: jest.fn(() => builder),
    };
    const manager = {
      getRepository: jest.fn((entity: { name: string }) =>
        entity.name === 'RecoveryKey' ? recoveryRepo : resetRepo,
      ),
    };
    const identityReset = new IdentityResetService(
      resetRepo as never,
      recoveryRepo as never,
      // Enrolled, so the ceremony is not refused for an unrelated reason.
      { findOne: jest.fn().mockResolvedValue({ userId: 1 }) } as never,
      {
        transaction: jest.fn((cb: (m: unknown) => unknown) => cb(manager)),
      } as never,
    );

    keyExchange = new ChatKeyExchangeService(
      {} as never,
      identityReset,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
    );
    client = { data: { user: { id: 1 } }, emit: jest.fn() };
    roomEmit = jest.fn();
    server = { to: jest.fn(() => ({ emit: roomEmit })) } as unknown as Server;

    // A stamp in the past, so an (unwanted) success would not wait a second.
    setPassword = jest.fn().mockResolvedValue(new Date(Date.now() - 5000));
    controller = new AuthController(
      new AuthService(
        {
          findByUsernameAndTag: jest
            .fn()
            .mockResolvedValue({ id: 1, username: 'alice', tag: '0427' }),
          setPassword,
        } as never,
        { sign: jest.fn(() => 'jwt') } as never,
        { createToken: jest.fn().mockResolvedValue('refresh') } as never,
        { resolveLoginDeviceId: jest.fn().mockResolvedValue(1) } as never,
        identityReset,
        new LoginBackoffService(),
      ),
    );

    logSpies = (['log', 'warn', 'error', 'debug', 'verbose'] as const).map(
      (level) =>
        jest.spyOn(Logger.prototype, level).mockImplementation(() => undefined),
    );
  });

  afterEach(() => logSpies.forEach((spy) => spy.mockRestore()));

  /** Every string handed to argon2, as the value to hash or to verify. */
  const argon2Inputs = (): unknown[] => [
    ...(argon2.hash as jest.Mock).mock.calls.map((call: unknown[]) => call[0]),
    ...(argon2.verify as jest.Mock).mock.calls.map(
      (call: unknown[]) => call[1],
    ),
  ];
  const logged = (): string =>
    JSON.stringify(logSpies.flatMap((spy) => spy.mock.calls as unknown[]));
  const expectNothingWritten = () => {
    expect(recoveryRepo.insert).not.toHaveBeenCalled();
    expect(recoveryRepo.update).not.toHaveBeenCalled();
    // The failure counter and the lockout are one SQL UPDATE.
    expect(counterUpdate).not.toHaveBeenCalled();
    expect(resetRepo.insert).not.toHaveBeenCalled();
  };

  it.each([
    ['no row', null, { phrase }],
    ['a legacy row', row('phrase_v1'), { phrase }],
    ['an auth_v2 row', row('auth_v2'), { phrase }],
    ['a version-2 backup attached', null, { phrase, backup: v2Backup }],
  ])(
    'setRecoveryKey: a plaintext phrase is not hashed and not stored (%s)',
    async (_name, existing, payload) => {
      recoveryRepo.findOne.mockResolvedValue(existing);

      await keyExchange.handleSetRecoveryKey(
        client as unknown as Socket,
        payload,
        server,
      );

      expect(client.emit.mock.calls).toEqual([
        ['recoveryKeySet', { success: false }],
      ]);
      expect(argon2Inputs()).toEqual([]);
      expectNothingWritten();
      // Nothing changed, so no session is told a key was enrolled.
      expect(roomEmit).not.toHaveBeenCalled();
      expect(logged()).not.toContain(phrase);
    },
  );

  it('resetIdentityRequest: the phrase a legacy row would accept answers invalid_phrase, starts nothing and spends no attempt', async () => {
    await keyExchange.handleResetIdentityRequest(
      client as unknown as Socket,
      { recoveryPhrase: phrase },
      server,
    );

    expect(client.emit.mock.calls).toEqual([
      [
        'identityResetStatus',
        expect.objectContaining({
          status: 'invalid_phrase',
          shortened: false,
          phraseTooNew: false,
        }),
      ],
    ]);
    expect(argon2Inputs()).toEqual([]);
    expectNothingWritten();
    expect(roomEmit).not.toHaveBeenCalled();
    expect(logged()).not.toContain(phrase);
  });

  it('POST /auth/recover: the phrase a legacy row would accept answers 401 like a wrong phrase, on a dummy verify of a constant', async () => {
    const attempt = controller.recover({
      identifier: 'alice#0427',
      phrase,
      newPassword: 'NewPass1x',
    } as RecoverPasswordDto);

    await expect(attempt).rejects.toThrow(UnauthorizedException);
    await expect(attempt).rejects.toThrow('Invalid credentials');
    // One verify, so the refusal costs what a wrong phrase costs — against
    // the dummy verifier and never over the phrase.
    expect((argon2.verify as jest.Mock).mock.calls).toEqual([
      [TIMING_SAFE_DUMMY_VERIFIER, expect.any(String)],
    ]);
    expect(argon2Inputs()).not.toContain(phrase);
    expectNothingWritten();
    expect(setPassword).not.toHaveBeenCalled();
    expect(logged()).not.toContain(phrase);
  });
});
