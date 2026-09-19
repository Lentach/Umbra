import { Logger } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import * as argon2 from 'argon2';
import {
  CANCEL_COOLDOWN_MS,
  COMPLETED_GRANT_TTL_MS,
  IdentityResetService,
  RECOVERY_ARGON2_OPTIONS,
  RECOVERY_MAX_FAILED_ATTEMPTS,
  RESET_DELAY_MS,
  RESET_DELAY_RECOVERY_MS,
  RECOVERY_MIN_AGE_MS,
} from './identity-reset.service';
import { AccountAuthorization } from './account-authorization.entity';
import { IdentityResetRequest } from './identity-reset-request.entity';
import { RecoveryKey } from './recovery-key.entity';

interface BuilderMock {
  update: jest.Mock;
  set: jest.Mock;
  where: jest.Mock;
  andWhere: jest.Mock;
  innerJoin: jest.Mock;
  orderBy: jest.Mock;
  returning: jest.Mock;
  execute: jest.Mock;
  getOne: jest.Mock;
}

/** A query-builder call: SQL fragment plus optional bound parameters. */
type QueryCall = [string, Record<string, unknown>?];

/**
 * Chainable stand-in covering both shapes the service builds: SELECT chains
 * ending in getOne(), and UPDATE chains ending in execute().
 */
function makeBuilder(result: {
  affected?: number;
  raw?: unknown;
  one?: unknown;
}): BuilderMock {
  const builder = {
    update: jest.fn(),
    set: jest.fn(),
    where: jest.fn(),
    andWhere: jest.fn(),
    innerJoin: jest.fn(),
    orderBy: jest.fn(),
    returning: jest.fn(),
    execute: jest.fn().mockResolvedValue({
      affected: result.affected ?? 0,
      raw: result.raw ?? [],
    }),
    getOne: jest.fn().mockResolvedValue(result.one ?? null),
  };
  builder.update.mockReturnValue(builder);
  builder.set.mockReturnValue(builder);
  builder.where.mockReturnValue(builder);
  builder.andWhere.mockReturnValue(builder);
  builder.innerJoin.mockReturnValue(builder);
  builder.orderBy.mockReturnValue(builder);
  builder.returning.mockReturnValue(builder);
  return builder;
}

/** Bound parameters of the first call that binds `key`, if any. */
function boundParams(
  mock: jest.Mock,
  key: string,
): Record<string, unknown> | undefined {
  const calls = mock.mock.calls as QueryCall[];
  return calls.find((call) => call[1] != null && key in call[1])?.[1];
}

/** Bound parameters of the first call whose params satisfy `predicate`. */
function boundParamsWhere(
  mock: jest.Mock,
  predicate: (params: Record<string, unknown>) => boolean,
): Record<string, unknown> | undefined {
  const calls = mock.mock.calls as QueryCall[];
  return calls.find((call) => call[1] != null && predicate(call[1]))?.[1];
}

/** Every SQL fragment passed to a builder method. */
function sqlFragments(mock: jest.Mock): string[] {
  const calls = mock.mock.calls as QueryCall[];
  return calls.map((call) => String(call[0]));
}

/**
 * SQL produced by an UPDATE ... SET object. Values are either literals or
 * functions returning a raw fragment; only the fragments are of interest.
 */
function setSql(mock: jest.Mock): string {
  const calls = mock.mock.calls as Array<[Record<string, unknown>]>;
  return calls
    .flatMap((call) => Object.values(call[0] ?? {}))
    .map((value) =>
      typeof value === 'function' ? (value as () => string)() : '',
    )
    .join(' ');
}

/** The row object handed to a repository insert/update call. */
function rowArg(mock: jest.Mock, callIndex = 0): Record<string, unknown> {
  const calls = mock.mock.calls as Array<[Record<string, unknown>]>;
  return calls[callIndex][0];
}

describe('IdentityResetService (reset ceremony §6.2 / recovery key §6.2.1)', () => {
  let service: IdentityResetService;
  let resetRepo: Record<string, jest.Mock>;
  let recoveryRepo: Record<string, jest.Mock>;
  let authorizationRepo: Record<string, jest.Mock>;
  let resetBuilder: BuilderMock;
  let recoveryBuilder: BuilderMock;
  let warnSpy: jest.SpyInstance;
  // Errors that escaped the transaction callback — a real transaction ROLLS
  // BACK on each of these, undoing anything it wrote (a spent phrase above
  // all).
  let rolledBack: unknown[];

  beforeEach(async () => {
    rolledBack = [];
    resetBuilder = makeBuilder({ affected: 0 });
    recoveryBuilder = makeBuilder({ affected: 0 });
    resetRepo = {
      findOne: jest.fn().mockResolvedValue(null),
      insert: jest.fn().mockResolvedValue({ identifiers: [{ id: 1 }] }),
      createQueryBuilder: jest.fn(() => resetBuilder),
    };
    recoveryRepo = {
      findOne: jest.fn().mockResolvedValue(null),
      insert: jest.fn().mockResolvedValue({ identifiers: [{ id: 1 }] }),
      update: jest.fn().mockResolvedValue({ affected: 1 }),
      createQueryBuilder: jest.fn(() => recoveryBuilder),
    };
    // ENROLLED by default: the ceremony only exists for enrolled accounts
    // ((lxxiii) opt-in lock), so every test below models one unless it says
    // otherwise.
    authorizationRepo = {
      findOne: jest.fn().mockResolvedValue({ userId: 7 }),
    };

    // The service spends the phrase and creates the row inside ONE
    // transaction; the manager hands back the same mocks.
    const manager = {
      getRepository: jest.fn((entity: unknown) =>
        entity === RecoveryKey ? recoveryRepo : resetRepo,
      ),
    };
    const dataSource = {
      transaction: jest.fn(async (cb: (m: unknown) => unknown) => {
        try {
          return await cb(manager);
        } catch (error) {
          rolledBack.push(error);
          throw error;
        }
      }),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        IdentityResetService,
        {
          provide: getRepositoryToken(IdentityResetRequest),
          useValue: resetRepo,
        },
        { provide: getRepositoryToken(RecoveryKey), useValue: recoveryRepo },
        {
          provide: getRepositoryToken(AccountAuthorization),
          useValue: authorizationRepo,
        },
        { provide: DataSource, useValue: dataSource },
      ],
    }).compile();

    service = module.get(IdentityResetService);
    warnSpy = jest
      .spyOn(Logger.prototype, 'warn')
      .mockImplementation(() => undefined);
  });

  afterEach(() => {
    warnSpy.mockRestore();
    jest.clearAllMocks();
  });

  describe('requestReset', () => {
    it('starts a ceremony with the full delay when nothing is pending', async () => {
      const before = Date.now();
      const result = await service.requestReset(7);

      expect(result.status).toBe('pending');
      expect(result.shortened).toBe(false);
      const deadline = result.deadlineAt?.getTime() ?? 0;
      expect(deadline).toBeGreaterThanOrEqual(before + RESET_DELAY_MS - 5000);
      expect(deadline).toBeLessThanOrEqual(Date.now() + RESET_DELAY_MS + 5000);
      expect(resetRepo.insert).toHaveBeenCalledWith(
        expect.objectContaining({
          userId: 7,
          status: 'pending',
          shortened: false,
        }),
      );
    });

    it('is a no-op returning the existing deadline while one is pending', async () => {
      const deadlineAt = new Date(Date.now() + 1000);
      resetRepo.findOne.mockResolvedValue({
        userId: 7,
        status: 'pending',
        deadlineAt,
        shortened: false,
      });

      const result = await service.requestReset(7);

      expect(result).toEqual({
        status: 'existing',
        deadlineAt,
        shortened: false,
        // No phrase was examined: this request short-circuited on the
        // ceremony that was already running.
        phraseTooNew: false,
      });
      // A repeat request must not restart or extend the clock.
      expect(resetRepo.insert).not.toHaveBeenCalled();
    });

    it('refuses an UN-ENROLLED account outright, before any phrase is spent — the lock is not armed, so there is nothing to reset', async () => {
      // (lxxiii) opt-in lock: with no `account_authorizations` row the §6.1
      // refusal never fires, so a fresh install replaces the identity on
      // credentials alone. A ceremony here could only HARM the account: the
      // completion teardown revokes device 1 and allocates a fresh id while
      // the account stays un-enrolled, so peers keep synthesizing device 1
      // and the recovering device is unaddressable until it re-enrols.
      authorizationRepo.findOne.mockResolvedValue(null);

      const result = await service.requestReset(7, 'a-correct-phrase');

      expect(result).toEqual({
        status: 'not_enrolled',
        deadlineAt: null,
        shortened: false,
        phraseTooNew: false,
      });
      // Nothing written and the phrase untouched: the refusal is a fact about
      // the account, not about the phrase, so it must not count as an attempt.
      expect(resetRepo.insert).not.toHaveBeenCalled();
      expect(recoveryRepo.findOne).not.toHaveBeenCalled();
      expect(recoveryRepo.update).not.toHaveBeenCalled();
      expect(recoveryBuilder.execute).not.toHaveBeenCalled();
    });

    it('still reports an already-pending ceremony on an un-enrolled account (rows from before the rule stay cancellable)', async () => {
      authorizationRepo.findOne.mockResolvedValue(null);
      const deadlineAt = new Date(Date.now() + 1000);
      resetRepo.findOne.mockResolvedValue({
        userId: 7,
        status: 'pending',
        deadlineAt,
        shortened: false,
      });

      const result = await service.requestReset(7);

      expect(result.status).toBe('existing');
      expect(result.deadlineAt).toBe(deadlineAt);
    });

    it('refuses during the cooldown that follows a cancel', async () => {
      resetBuilder.getOne.mockResolvedValue({
        userId: 7,
        status: 'cancelled',
        cancelledAt: new Date(Date.now() - 1000),
      });

      const result = await service.requestReset(7);

      expect(result.status).toBe('cooldown');
      expect(resetRepo.insert).not.toHaveBeenCalled();
    });

    it('logs a warn when the cooldown refuses (the branch used to be silent)', async () => {
      resetBuilder.getOne.mockResolvedValue({
        userId: 7,
        status: 'cancelled',
        cancelledAt: new Date(Date.now() - 1000),
      });

      await service.requestReset(7);

      expect(warnSpy).toHaveBeenCalledWith(
        expect.stringContaining('post-cancel cooldown'),
      );
    });

    it('voids a cooldown armed before the last password change (2026-08-19 carve-out)', async () => {
      // Mocks can only prove the predicate is PRESENT in the query — the
      // behavioural proof lives in the wire suite (start→cancel→cooldown,
      // change password, request→pending). Assert both halves of the SQL:
      // the users join and the passwordChangedAt comparison.
      await service.requestReset(7);

      const joins = resetBuilder.innerJoin.mock.calls as Array<
        [string, string, string]
      >;
      expect(joins).toContainEqual(['users', 'u', 'u.id = r."userId"']);
      const fragments = sqlFragments(resetBuilder.andWhere).join(' ');
      expect(fragments).toContain('u."passwordChangedAt" IS NULL');
      expect(fragments).toContain('r."cancelledAt" > u."passwordChangedAt"');
    });

    it('queries the cooldown window against the documented 24 h bound', async () => {
      await service.requestReset(7);

      const params = boundParams(resetBuilder.andWhere, 'since');
      expect(params).toBeDefined();
      const since = params?.since as Date;
      expect(Date.now() - since.getTime()).toBeGreaterThanOrEqual(
        CANCEL_COOLDOWN_MS - 5000,
      );
    });

    describe('with a recovery phrase', () => {
      const phrase =
        'abandon ability able about above absent absorb abstract absurd abuse access accident';
      let verifierHash: string;

      beforeAll(async () => {
        verifierHash = await argon2.hash(phrase, RECOVERY_ARGON2_OPTIONS);
      });

      // Enrolled long ago by default, so every pre-existing law below keeps
      // describing the same account: a phrase old enough to shorten the
      // window (amendment (xlii)). The age cases are their own tests.
      const enrolled = (overrides: Record<string, unknown> = {}) => ({
        id: 3,
        userId: 7,
        verifierHash,
        usedAt: null,
        failedAttempts: 0,
        lockedUntil: null,
        createdAt: new Date(Date.now() - RECOVERY_MIN_AGE_MS - 60_000),
        ...overrides,
      });

      it('shortens the delay to one hour and spends the phrase', async () => {
        recoveryRepo.findOne.mockResolvedValue(enrolled());

        const result = await service.requestReset(7, phrase);

        expect(result.status).toBe('pending');
        expect(result.shortened).toBe(true);
        // Accepted, so there is nothing to explain away.
        expect(result.phraseTooNew).toBe(false);
        const remaining = (result.deadlineAt?.getTime() ?? 0) - Date.now();
        expect(remaining).toBeLessThanOrEqual(RESET_DELAY_RECOVERY_MS + 5000);
        expect(remaining).toBeGreaterThan(RESET_DELAY_RECOVERY_MS - 5000);
        // Single-use: spent in the same transaction that created the ceremony.
        expect(recoveryRepo.update).toHaveBeenCalledWith(
          { id: 3 },
          expect.objectContaining({ usedAt: expect.any(Date) as unknown }),
        );
        expect(resetRepo.insert).toHaveBeenCalledWith(
          expect.objectContaining({ shortened: true }),
        );
      });

      // Amendment (xlii). The actor is a PASSWORD thief, who can already run
      // the ordinary 72 h ceremony — that is the documented lost-device path.
      // What they must not also get is the SHORTCUT: enrol a phrase of their
      // own and spend it immediately, cutting the owner's cancel window from
      // 72 h to 1 h. A password re-prompt would not stop them; the age does.
      it('a phrase younger than the minimum age does NOT shorten the window', async () => {
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({ createdAt: new Date(Date.now() - 60_000) }),
        );

        const result = await service.requestReset(7, phrase);

        // The ceremony still STARTS — refusing would break the lost-device
        // path §6.2 exists to serve — but at the full delay.
        expect(result.status).toBe('pending');
        expect(result.shortened).toBe(false);
        expect(result.phraseTooNew).toBe(true);
        const remaining = (result.deadlineAt?.getTime() ?? 0) - Date.now();
        expect(remaining).toBeGreaterThan(RESET_DELAY_MS - 5000);
        expect(resetRepo.insert).toHaveBeenCalledWith(
          expect.objectContaining({ shortened: false }),
        );
      });

      it('and leaves that young phrase UNSPENT', async () => {
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({ createdAt: new Date(Date.now() - 60_000) }),
        );

        await service.requestReset(7, phrase);

        // It was the user's own phrase and it verified. Burning it here would
        // cost a legitimate owner their key for nothing; it simply could not
        // buy the shortcut yet.
        expect(recoveryRepo.update).not.toHaveBeenCalled();
      });

      // The UX half of (xlii). The gate is right, but a silent `shortened:
      // false` reads exactly like "no phrase given" — so an owner who typed a
      // correct phrase sees 72 h, assumes a typo, and retypes it until the
      // five-attempt lockout. The answer has to distinguish the two.
      it('reports the age verdict, so a young phrase is distinguishable from no phrase at all', async () => {
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({ createdAt: new Date(Date.now() - 60_000) }),
        );

        const young = await service.requestReset(7, phrase);

        resetRepo.findOne.mockResolvedValue(null);
        resetRepo.insert.mockClear();
        const none = await service.requestReset(7);

        // Identical on every field the pre-(xlii) client could see...
        expect(young.status).toBe(none.status);
        expect(young.shortened).toBe(none.shortened);
        // ...and told apart only by the verdict this amendment adds.
        expect(young.phraseTooNew).toBe(true);
        expect(none.phraseTooNew).toBe(false);
      });

      it('a WRONG phrase still costs an attempt even when it is young', async () => {
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({ createdAt: new Date(Date.now() - 60_000) }),
        );
        recoveryBuilder.execute.mockResolvedValue({
          affected: 1,
          raw: [{ failedAttempts: 1 }],
        });

        const result = await service.requestReset(7, 'not the phrase at all');

        // The age is checked AFTER verification on purpose: otherwise the
        // ordering would turn the age gate into a free oracle for probing
        // whether a phrase is enrolled, without spending an attempt.
        expect(result.status).toBe('invalid_phrase');
        expect(setSql(recoveryBuilder.set)).toContain('"failedAttempts" + 1');
        // A wrong phrase is not a young phrase: the caller must not be told
        // to stop retyping something that genuinely did not match.
        expect(result.phraseTooNew).toBe(false);
      });

      it('rolls the phrase spend back when a concurrent request wins the race', async () => {
        recoveryRepo.findOne.mockResolvedValue(enrolled());
        // The partial unique index refuses the second pending row...
        resetRepo.insert.mockRejectedValue(
          new Error('duplicate key value violates unique constraint'),
        );
        const winnerDeadline = new Date(Date.now() + RESET_DELAY_MS);
        // ...and the winner is read back after the rollback, on this.resetRepo.
        resetRepo.findOne
          .mockResolvedValueOnce(null)
          .mockResolvedValue({ deadlineAt: winnerDeadline, shortened: false });

        const result = await service.requestReset(7, phrase);

        // The loser reports the winner's ceremony, not one of its own.
        expect(result.status).toBe('existing');
        expect(result.deadlineAt).toEqual(winnerDeadline);
        expect(result.shortened).toBe(false);
        // And the transaction was rolled back, so the single-use phrase is NOT
        // spent: committing here would leave the account on the winner's 72 h
        // deadline with nothing left to shorten a retry.
        expect(rolledBack).toHaveLength(1);
      });

      it('refuses a wrong phrase, counts it, and creates no ceremony', async () => {
        recoveryRepo.findOne.mockResolvedValue(enrolled({ failedAttempts: 1 }));
        recoveryBuilder.execute.mockResolvedValue({
          affected: 1,
          raw: [{ failedAttempts: 2 }],
        });

        const result = await service.requestReset(7, 'not the right phrase');

        expect(result.status).toBe('invalid_phrase');
        expect(resetRepo.insert).not.toHaveBeenCalled();
        // Counted by the database, not by a read-modify-write: two failures
        // landing together must not both store the same count.
        expect(setSql(recoveryBuilder.set)).toContain('"failedAttempts" + 1');
        expect(recoveryRepo.update).not.toHaveBeenCalled();
      });

      it('locks out on the attempt whose stored count reaches the limit', async () => {
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({ failedAttempts: RECOVERY_MAX_FAILED_ATTEMPTS - 1 }),
        );
        // The lockout follows the value the UPDATE actually stored, so a
        // concurrent failure that already advanced the counter still locks.
        recoveryBuilder.execute.mockResolvedValue({
          affected: 1,
          raw: [{ failedAttempts: RECOVERY_MAX_FAILED_ATTEMPTS }],
        });

        const result = await service.requestReset(7, 'wrong again');

        expect(result.status).toBe('locked');
        const params = boundParams(recoveryBuilder.where, 'lockedUntil');
        expect(params?.lockedUntil).toBeInstanceOf(Date);
        // The threshold is applied in SQL against the row's own value.
        expect(setSql(recoveryBuilder.set)).toContain(
          `"failedAttempts" + 1 >= ${RECOVERY_MAX_FAILED_ATTEMPTS}`,
        );
      });

      it('refuses while locked, without even checking the phrase', async () => {
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({
            failedAttempts: RECOVERY_MAX_FAILED_ATTEMPTS,
            lockedUntil: new Date(Date.now() + 60_000),
          }),
        );

        const result = await service.requestReset(7, phrase);

        expect(result.status).toBe('locked');
        expect(resetRepo.insert).not.toHaveBeenCalled();
        expect(recoveryRepo.update).not.toHaveBeenCalled();
      });

      it('refuses an already-spent phrase', async () => {
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({ usedAt: new Date() }),
        );

        const result = await service.requestReset(7, phrase);

        expect(result.status).toBe('invalid_phrase');
        expect(resetRepo.insert).not.toHaveBeenCalled();
      });

      it('refuses when no phrase is enrolled at all', async () => {
        recoveryRepo.findOne.mockResolvedValue(null);

        const result = await service.requestReset(7, phrase);

        expect(result.status).toBe('invalid_phrase');
        expect(resetRepo.insert).not.toHaveBeenCalled();
      });

      it('never authorizes anything when the stored verifier is malformed', async () => {
        const errorSpy = jest
          .spyOn(Logger.prototype, 'error')
          .mockImplementation(() => undefined);
        recoveryRepo.findOne.mockResolvedValue(
          enrolled({ verifierHash: 'not-a-phc-string' }),
        );

        const result = await service.requestReset(7, phrase);

        expect(result.status).toBe('invalid_phrase');
        expect(resetRepo.insert).not.toHaveBeenCalled();
        errorSpy.mockRestore();
      });
    });
  });

  // Amendment (lxxxii) clause 2: the phrase as a CREDENTIAL. Same verifier,
  // same counter, same lockout as the §6.2 shortcut — but never spent, and
  // `usedAt` ignored, because the phrase is the seed, not a ticket.
  describe('verifyRecoveryPhrase (the password door)', () => {
    const phrase =
      'abandon ability able about above absent absorb abstract absurd abuse access accident';
    let verifierHash: string;
    beforeAll(async () => {
      verifierHash = await argon2.hash(phrase, RECOVERY_ARGON2_OPTIONS);
    });
    const enrolled = (overrides: Record<string, unknown> = {}) => ({
      id: 3,
      userId: 7,
      verifierHash,
      usedAt: null,
      failedAttempts: 0,
      lockedUntil: null,
      createdAt: new Date(),
      ...overrides,
    });

    it('accepts the phrase without spending it', async () => {
      recoveryRepo.findOne.mockResolvedValue(enrolled());

      await expect(service.verifyRecoveryPhrase(7, phrase)).resolves.toBe(
        'accepted',
      );
      expect(recoveryRepo.update).not.toHaveBeenCalled();
    });

    it('a phrase already spent on the shortcut still opens the door', async () => {
      recoveryRepo.findOne.mockResolvedValue(enrolled({ usedAt: new Date() }));

      await expect(service.verifyRecoveryPhrase(7, phrase)).resolves.toBe(
        'accepted',
      );
    });

    it('a correct phrase after fumbles clears the count and still does not spend', async () => {
      recoveryRepo.findOne.mockResolvedValue(enrolled({ failedAttempts: 4 }));

      await expect(service.verifyRecoveryPhrase(7, phrase)).resolves.toBe(
        'accepted',
      );
      expect(recoveryRepo.update).toHaveBeenCalledWith(
        { id: 3 },
        { failedAttempts: 0, lockedUntil: null },
      );
    });

    it('a phrase minted a minute ago opens the door (no age rule here)', async () => {
      recoveryRepo.findOne.mockResolvedValue(
        enrolled({ createdAt: new Date(Date.now() - 60_000) }),
      );

      await expect(service.verifyRecoveryPhrase(7, phrase)).resolves.toBe(
        'accepted',
      );
    });

    it('a wrong phrase draws on the SAME counter the shortcut uses', async () => {
      recoveryRepo.findOne.mockResolvedValue(enrolled());
      recoveryBuilder.execute.mockResolvedValue({
        affected: 1,
        raw: [{ failedAttempts: 1 }],
      });

      await expect(service.verifyRecoveryPhrase(7, 'wrong')).resolves.toBe(
        'invalid_phrase',
      );
      expect(setSql(recoveryBuilder.set)).toContain('"failedAttempts" + 1');
    });

    it('locks on the attempt that reaches the limit, and stays locked', async () => {
      recoveryRepo.findOne.mockResolvedValue(enrolled());
      recoveryBuilder.execute.mockResolvedValue({
        affected: 1,
        raw: [{ failedAttempts: RECOVERY_MAX_FAILED_ATTEMPTS }],
      });
      await expect(service.verifyRecoveryPhrase(7, 'wrong')).resolves.toBe(
        'locked',
      );

      recoveryRepo.findOne.mockResolvedValue(
        enrolled({ lockedUntil: new Date(Date.now() + 60_000) }),
      );
      // The RIGHT phrase is refused while locked — and not even verified.
      await expect(service.verifyRecoveryPhrase(7, phrase)).resolves.toBe(
        'locked',
      );
    });

    it('no phrase enrolled reads exactly like a wrong phrase, and COSTS the same', async () => {
      recoveryRepo.findOne.mockResolvedValue(null);

      // (F38) Unauthenticated door: an un-enrolled account must not answer
      // faster than an enrolled one with a wrong phrase. The native argon2
      // module cannot be spied on, so the COST itself is asserted: the
      // 19 MiB / t=2 verify takes tens of milliseconds; the bare early return
      // it replaces took none.
      const started = performance.now();
      await expect(service.verifyRecoveryPhrase(7, phrase)).resolves.toBe(
        'invalid_phrase',
      );
      expect(performance.now() - started).toBeGreaterThan(15);
      expect(recoveryRepo.update).not.toHaveBeenCalled();
    });
  });

  // Amendment (lxxxii) clause 1: the delay is 6 h, and the (xlii) age floor
  // is DEFINED as the delay, so it follows — a phrase minted after a
  // compromise still cannot buy the shortcut inside the window it removes.
  describe('delay constants', () => {
    it('the reset delay is 6 hours and the age floor equals it', () => {
      expect(RESET_DELAY_MS).toBe(6 * 60 * 60 * 1000);
      expect(RECOVERY_MIN_AGE_MS).toBe(RESET_DELAY_MS);
      expect(RESET_DELAY_RECOVERY_MS).toBeLessThan(RESET_DELAY_MS);
    });
  });

  describe('cancel / expiry serialization (falsification 10)', () => {
    it('cancels only a row that is still pending', async () => {
      resetBuilder.execute.mockResolvedValue({ affected: 1, raw: [] });

      await expect(service.cancelReset(7)).resolves.toBe(true);

      expect(
        boundParamsWhere(
          resetBuilder.andWhere,
          (params) => params.status === 'pending',
        ),
      ).toBeDefined();
    });

    it('reports no cancellation when the ceremony already left pending', async () => {
      // The expiry commit won the race: nothing to cancel, and emphatically no
      // rollback of the completed state.
      resetBuilder.execute.mockResolvedValue({ affected: 0, raw: [] });

      await expect(service.cancelReset(7)).resolves.toBe(false);
    });

    it('commits only passed deadlines, still filtered on pending', async () => {
      resetBuilder.execute.mockResolvedValue({
        affected: 1,
        raw: [{ id: 5, userId: 7 }],
      });

      await service.completeDueResets();

      expect(
        boundParamsWhere(
          resetBuilder.where,
          (params) => params.status === 'pending',
        ),
      ).toBeDefined();
      expect(
        sqlFragments(resetBuilder.andWhere).some((sql) =>
          sql.includes('"deadlineAt" <= now()'),
        ),
      ).toBe(true);
    });

    it('invalidates an unspent recovery phrase when a ceremony completes', async () => {
      resetBuilder.execute.mockResolvedValue({
        affected: 1,
        raw: [{ id: 5, userId: 7 }],
      });

      await service.completeDueResets();

      expect(recoveryBuilder.execute).toHaveBeenCalled();
      expect(
        sqlFragments(recoveryBuilder.andWhere).some((sql) =>
          sql.includes('"usedAt" IS NULL'),
        ),
      ).toBe(true);
    });

    it('does nothing at all when no deadline has passed', async () => {
      resetBuilder.execute.mockResolvedValue({ affected: 0, raw: [] });

      await service.completeDueResets();

      expect(recoveryBuilder.execute).not.toHaveBeenCalled();
    });

    it('survives a failing sweep so the scheduler keeps running', async () => {
      const errorSpy = jest
        .spyOn(Logger.prototype, 'error')
        .mockImplementation(() => undefined);
      resetBuilder.execute.mockRejectedValue(new Error('db down'));

      await expect(service.completeDueResets()).resolves.toBeUndefined();
      expect(errorSpy).toHaveBeenCalled();
      errorSpy.mockRestore();
    });
  });

  describe('consumeCompletedReset', () => {
    it('spends a completed, unconsumed ceremony exactly once', async () => {
      resetBuilder.execute.mockResolvedValue({ affected: 1, raw: [] });

      await expect(service.consumeCompletedReset(7)).resolves.toBe(true);

      expect(
        sqlFragments(resetBuilder.andWhere).some((sql) =>
          sql.includes('"consumedAt" IS NULL'),
        ),
      ).toBe(true);
      expect(
        boundParamsWhere(
          resetBuilder.andWhere,
          (params) => params.status === 'completed',
        ),
      ).toBeDefined();
    });

    it('authorizes nothing when there is no completed ceremony', async () => {
      resetBuilder.execute.mockResolvedValue({ affected: 0, raw: [] });

      await expect(service.consumeCompletedReset(7)).resolves.toBe(false);
    });

    it('only spends a grant inside its bounded window', async () => {
      // A completed ceremony nobody used is an INSTANT replacement grant that
      // cancelReset can no longer touch, so it must lapse rather than stand
      // open forever.
      resetBuilder.execute.mockResolvedValue({ affected: 1, raw: [] });

      await service.consumeCompletedReset(7);

      const params = boundParams(resetBuilder.andWhere, 'graceSince');
      expect(params).toBeDefined();
      expect(
        sqlFragments(resetBuilder.andWhere).some((sql) =>
          sql.includes('"completedAt"'),
        ),
      ).toBe(true);
      const since = params?.graceSince as Date;
      expect(Date.now() - since.getTime()).toBeGreaterThanOrEqual(
        COMPLETED_GRANT_TTL_MS - 5000,
      );
    });

    it('hides a lapsed grant from the connect-time status too', async () => {
      resetRepo.findOne.mockResolvedValue(null);
      resetBuilder.getOne.mockResolvedValue(null);

      await expect(service.getStatusForUser(7)).resolves.toBeNull();

      expect(boundParams(resetBuilder.andWhere, 'graceSince')).toBeDefined();
    });
  });

  describe('getStatusForUser', () => {
    it('reports a pending ceremony with its deadline', async () => {
      const deadlineAt = new Date(Date.now() + 1000);
      resetRepo.findOne.mockResolvedValue({
        status: 'pending',
        deadlineAt,
        shortened: true,
      });

      // `shortened` travels with the summary: a session reconnecting INTO a
      // recovery-key ceremony must not describe the 1 h wait as the 72 h one.
      await expect(service.getStatusForUser(7)).resolves.toEqual({
        status: 'pending',
        deadlineAt,
        shortened: true,
      });
    });

    it('reports an unspent completed ceremony', async () => {
      const deadlineAt = new Date(Date.now() - 1000);
      resetBuilder.getOne.mockResolvedValue({
        status: 'completed',
        deadlineAt,
        shortened: false,
      });

      await expect(service.getStatusForUser(7)).resolves.toEqual({
        status: 'completed',
        deadlineAt,
        shortened: false,
      });
    });

    it('reports nothing when the account has no ceremony', async () => {
      await expect(service.getStatusForUser(7)).resolves.toBeNull();
    });
  });

  describe('setRecoveryKey (falsification 21)', () => {
    const phrase =
      'legal winner thank year wave sausage worth useful legal winner thank yellow';

    it('stores a memory-hard verifier, never the phrase and never a fast hash', async () => {
      await service.setRecoveryKey(7, phrase);

      const stored = rowArg(recoveryRepo.insert).verifierHash as string;
      // A fast hash (or the phrase itself) fails every one of these.
      expect(stored.startsWith('$argon2id$')).toBe(true);
      expect(stored).not.toContain(phrase);
      expect(await argon2.verify(stored, phrase)).toBe(true);
      expect(await argon2.verify(stored, 'wrong phrase')).toBe(false);
    });

    it('pins the parameters the verifier is stored with', async () => {
      await service.setRecoveryKey(7, phrase);

      const stored = rowArg(recoveryRepo.insert).verifierHash as string;
      // PHC encodes the cost parameters; drifting below them silently weakens
      // every future enrollment, which no behavioural test would notice.
      expect(stored).toContain(`m=${RECOVERY_ARGON2_OPTIONS.memoryCost}`);
      expect(stored).toContain(`t=${RECOVERY_ARGON2_OPTIONS.timeCost}`);
      expect(stored).toContain(`p=${RECOVERY_ARGON2_OPTIONS.parallelism}`);
    });

    it('produces a different verifier each time (salted)', async () => {
      await service.setRecoveryKey(7, phrase);
      await service.setRecoveryKey(7, phrase);

      expect(rowArg(recoveryRepo.insert, 0).verifierHash).not.toEqual(
        rowArg(recoveryRepo.insert, 1).verifierHash,
      );
    });

    it('replacing a phrase clears the spent and lockout state', async () => {
      recoveryRepo.findOne.mockResolvedValue({ id: 3, userId: 7 });

      await service.setRecoveryKey(7, phrase);

      expect(recoveryRepo.update).toHaveBeenCalledWith(
        { id: 3 },
        expect.objectContaining({
          usedAt: null,
          failedAttempts: 0,
          lockedUntil: null,
        }),
      );
      expect(recoveryRepo.insert).not.toHaveBeenCalled();
    });

    // Amendment (xlii). `createdAt` is a @CreateDateColumn, so an UPDATE
    // leaves it at the ORIGINAL enrollment. Without this the age gate is
    // trivially bypassed: a thief REPLACES the phrase on a long-standing row
    // and their brand-new secret inherits an age it never had, buying the 1 h
    // window the gate exists to deny. The gate governs the SECRET, not the row.
    it('replacing a phrase RESTARTS the age clock', async () => {
      const enrolledLongAgo = new Date(Date.now() - 400 * 24 * 3600 * 1000);
      recoveryRepo.findOne.mockResolvedValue({
        id: 3,
        userId: 7,
        createdAt: enrolledLongAgo,
      });

      const before = Date.now();
      await service.setRecoveryKey(7, phrase);

      // `rowArg` reads the FIRST argument; an update's patch is the second.
      const calls = recoveryRepo.update.mock.calls as Array<
        [unknown, { createdAt?: Date }]
      >;
      const patch = calls[0][1];
      expect(patch.createdAt).toBeInstanceOf(Date);
      expect(patch.createdAt!.getTime()).toBeGreaterThanOrEqual(before);
    });

    it('reports whether the enrollment REPLACED an existing phrase', async () => {
      // The caller words the notification from this, so a replacement is not
      // announced as a first enrollment.
      recoveryRepo.findOne.mockResolvedValue(null);
      await expect(service.setRecoveryKey(7, phrase)).resolves.toBe(false);

      recoveryRepo.findOne.mockResolvedValue({ id: 3, userId: 7 });
      await expect(service.setRecoveryKey(7, phrase)).resolves.toBe(true);
    });
  });

  describe('setRecoveryKey identity backup (amendment (lxxviii))', () => {
    const phrase =
      'legal winner thank year wave sausage worth useful legal winner thank yellow';
    // Clause 1: the sealed blob rides the enrolment.
    const backup = {
      blob: 'c2VhbGVkLWJsb2I=',
      salt: 'c2FsdC1zaXh0ZWVuLWI=',
      iterations: 600000,
      version: 1,
    };

    it('writes the sealed backup IN THE SAME statement as the verifier', async () => {
      // One statement is the atomicity guarantee: a blob sealed under a
      // phrase whose verifier never landed (or vice versa) must be
      // unrepresentable. Without the backup wiring this row carries no
      // backup* columns at all and every assertion below fails.
      await service.setRecoveryKey(7, phrase, backup);

      const row = rowArg(recoveryRepo.insert);
      expect(row.backupBlob).toBe(backup.blob);
      expect(row.backupSalt).toBe(backup.salt);
      expect(row.backupIterations).toBe(backup.iterations);
      expect(row.backupVersion).toBe(backup.version);
      expect(row.backupUpdatedAt).toBeInstanceOf(Date);
      expect(typeof row.verifierHash).toBe('string');
    });

    it('a replacement carries the backup in the SAME update as the verifier', async () => {
      recoveryRepo.findOne.mockResolvedValue({ id: 3, userId: 7 });

      await service.setRecoveryKey(7, phrase, backup);

      expect(recoveryRepo.update).toHaveBeenCalledWith(
        { id: 3 },
        expect.objectContaining({
          backupBlob: backup.blob,
          backupSalt: backup.salt,
          backupIterations: backup.iterations,
          backupVersion: backup.version,
        }),
      );
    });

    it('an enrolment WITHOUT a backup never touches the stored blob (older client)', async () => {
      recoveryRepo.findOne.mockResolvedValue({ id: 3, userId: 7 });

      await service.setRecoveryKey(7, phrase);

      const calls = recoveryRepo.update.mock.calls as Array<
        [unknown, Record<string, unknown>]
      >;
      expect('backupBlob' in calls[0][1]).toBe(false);
    });
  });

  describe('getIdentityBackup / hasIdentityBackup (amendment (lxxviii))', () => {
    const storedRow = {
      id: 3,
      userId: 7,
      backupBlob: 'c2VhbGVkLWJsb2I=',
      backupSalt: 'c2FsdC1zaXh0ZWVuLWI=',
      backupIterations: 600000,
      backupVersion: 1,
    };

    it('serves the stored backup exactly as written (round trip)', async () => {
      recoveryRepo.findOne.mockResolvedValue(storedRow);

      await expect(service.getIdentityBackup(7)).resolves.toEqual({
        blob: storedRow.backupBlob,
        salt: storedRow.backupSalt,
        iterations: storedRow.backupIterations,
        version: storedRow.backupVersion,
      });
      await expect(service.hasIdentityBackup(7)).resolves.toBe(true);
    });

    it('a verifier-only row (pre-(lxxviii) enrolment) has NO backup', async () => {
      recoveryRepo.findOne.mockResolvedValue({
        id: 3,
        userId: 7,
        backupBlob: null,
        backupSalt: null,
        backupIterations: null,
        backupVersion: null,
      });

      await expect(service.getIdentityBackup(7)).resolves.toBeNull();
      await expect(service.hasIdentityBackup(7)).resolves.toBe(false);
      // (lxxxiii) clause 4: but it IS a phrase — the Chats nudge must not ask
      // its owner for one.
      await expect(service.hasRecoveryPhrase(7)).resolves.toBe(true);
    });

    it('no recovery row at all means no backup', async () => {
      recoveryRepo.findOne.mockResolvedValue(null);

      await expect(service.getIdentityBackup(7)).resolves.toBeNull();
      await expect(service.hasIdentityBackup(7)).resolves.toBe(false);
      await expect(service.hasRecoveryPhrase(7)).resolves.toBe(false);
    });
  });
});
