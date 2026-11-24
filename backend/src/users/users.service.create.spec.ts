import { ConflictException } from '@nestjs/common';
import { QueryFailedError } from 'typeorm';

import { UsersService } from './users.service';
import { User } from './user.entity';

// The database's answer to a registration that lost a race: Postgres 23505 as
// TypeORM hands it over (`QueryFailedError` around the pg driver error).
function uniqueViolation(constraint: string): QueryFailedError {
  return new QueryFailedError(
    'INSERT INTO "users"',
    [],
    Object.assign(new Error('duplicate key value violates unique constraint'), {
      code: '23505',
      constraint,
    }),
  );
}

const LOWER_NAME_INDEX = 'UQ_users_lower_username';
const NAME_TAG_CONSTRAINT = 'UQ_82ed9e04d0b61a87074cf8a8d39';

describe('UsersService.create (BE-05: a lost registration race is never a 500)', () => {
  const mockRepo = {
    save: jest.fn(),
    create: jest.fn((u: unknown) => u),
  };
  let service: UsersService;

  beforeEach(() => {
    jest.clearAllMocks();
    mockRepo.save.mockReset();
    service = new UsersService(
      mockRepo as never,
      {} as never,
      {} as never,
      {} as never,
    );
    jest.spyOn(service, 'findByUsernameAndTag').mockResolvedValue(null);
  });

  async function rejection(promise: Promise<unknown>): Promise<unknown> {
    return promise.then(
      () => {
        throw new Error('expected a rejection');
      },
      (error: unknown) => error,
    );
  }

  it('a name taken between the check and the insert answers exactly as the name-taken check does', async () => {
    // The answer of the ordinary path: the name is seen as taken up front.
    jest
      .spyOn(service, 'findByUsername')
      .mockResolvedValueOnce([{ id: 1 } as User]);
    const upFront = await rejection(service.create('Alice', 'CorrectHorse1'));
    expect(upFront).toBeInstanceOf(ConflictException);

    // The race: the check saw nobody, the insert hit the name index.
    jest.spyOn(service, 'findByUsername').mockResolvedValueOnce([]);
    mockRepo.save.mockRejectedValueOnce(uniqueViolation(LOWER_NAME_INDEX));
    const raced = await rejection(service.create('alice', 'CorrectHorse1'));

    expect(raced).toBeInstanceOf(ConflictException);
    expect((raced as ConflictException).getStatus()).toBe(
      (upFront as ConflictException).getStatus(),
    );
    expect((raced as ConflictException).getResponse()).toEqual(
      (upFront as ConflictException).getResponse(),
    );
    expect(mockRepo.save.mock.calls).toHaveLength(1);
  });

  it('a (username, tag) collision at the insert draws the tag again', async () => {
    jest.spyOn(service, 'findByUsername').mockResolvedValue([]);
    mockRepo.save
      .mockRejectedValueOnce(uniqueViolation(NAME_TAG_CONSTRAINT))
      .mockImplementationOnce((u: unknown) => Promise.resolve(u));

    const user = await service.create('alice', 'CorrectHorse1');

    expect(user.username).toBe('alice');
    expect(user.tag).toMatch(/^\d{4}$/);
    expect(mockRepo.save.mock.calls).toHaveLength(2);
  });

  it('a (username, tag) collision on every draw ends as the existing 409, after a bounded number of inserts', async () => {
    jest.spyOn(service, 'findByUsername').mockResolvedValue([]);
    mockRepo.save.mockRejectedValue(uniqueViolation(NAME_TAG_CONSTRAINT));

    const error = await rejection(service.create('alice', 'CorrectHorse1'));

    expect(error).toBeInstanceOf(ConflictException);
    expect((error as ConflictException).message).toBe(
      'Could not generate unique tag, please try again',
    );
    expect(mockRepo.save.mock.calls).toHaveLength(10);
  });

  it('any other insert failure is passed on untouched', async () => {
    jest.spyOn(service, 'findByUsername').mockResolvedValue([]);
    const failure = new QueryFailedError(
      'INSERT INTO "users"',
      [],
      Object.assign(new Error('connection terminated'), { code: '57P01' }),
    );
    mockRepo.save.mockRejectedValueOnce(failure);

    expect(await rejection(service.create('alice', 'CorrectHorse1'))).toBe(
      failure,
    );
    expect(mockRepo.save.mock.calls).toHaveLength(1);
  });
});
