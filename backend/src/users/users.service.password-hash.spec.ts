import * as bcrypt from 'bcrypt';
import * as argon2 from 'argon2';
import { UnauthorizedException } from '@nestjs/common';

import { UsersService } from './users.service';
import { User } from './user.entity';

// Real bcrypt and Argon2 on purpose: this is the D4 migration path end to end.
describe('UsersService passwords (plan D4: bcrypt → Argon2id)', () => {
  const mockRepo = {
    findOne: jest.fn(),
    save: jest.fn((u: unknown) => Promise.resolve(u)),
    update: jest.fn().mockResolvedValue(undefined),
    create: jest.fn((u: unknown) => u),
    createQueryBuilder: jest.fn(),
  };
  const mockRefreshTokens = {
    revokeAllForUser: jest.fn().mockResolvedValue(undefined),
  };
  let service: UsersService;

  beforeEach(() => {
    jest.clearAllMocks();
    service = new UsersService(
      mockRepo as never,
      {} as never,
      {} as never,
      {} as never,
      mockRefreshTokens as never,
    );
  });

  const userWith = (password: string) => ({ id: 7, password }) as User;

  describe('checkPassword (login)', () => {
    it('after a correct bcrypt password, stores an Argon2id hash of it, conditional on the old hash, without touching passwordChangedAt', async () => {
      const legacy = await bcrypt.hash('CorrectHorse1', 10);
      const user = userWith(legacy);

      await expect(service.checkPassword(user, 'CorrectHorse1')).resolves.toBe(
        true,
      );

      expect(mockRepo.update).toHaveBeenCalledTimes(1);
      const [where, set] = mockRepo.update.mock.calls[0] as [
        unknown,
        { password: string },
      ];
      expect(where).toEqual({ id: 7, password: legacy });
      expect(Object.keys(set)).toEqual(['password']);
      expect(set.password).toMatch(/^\$argon2id\$/);
      expect(await argon2.verify(set.password, 'CorrectHorse1')).toBe(true);
      expect(user.password).toBe(set.password);
      expect(mockRefreshTokens.revokeAllForUser).not.toHaveBeenCalled();
    });

    it('a wrong password against a bcrypt hash changes nothing', async () => {
      const legacy = await bcrypt.hash('CorrectHorse1', 10);
      await expect(
        service.checkPassword(userWith(legacy), 'nope'),
      ).resolves.toBe(false);
      expect(mockRepo.update).not.toHaveBeenCalled();
    });

    it('an up-to-date Argon2id hash verifies without a write', async () => {
      const current = await argon2.hash('CorrectHorse1', {
        type: argon2.argon2id,
        memoryCost: 19456,
        timeCost: 2,
        parallelism: 1,
      });
      await expect(
        service.checkPassword(userWith(current), 'CorrectHorse1'),
      ).resolves.toBe(true);
      expect(mockRepo.update).not.toHaveBeenCalled();
    });
  });

  it('create() stores an Argon2id hash, never the password', async () => {
    jest.spyOn(service, 'findByUsername').mockResolvedValue([]);
    jest.spyOn(service, 'findByUsernameAndTag').mockResolvedValue(null);

    await service.create('alice', 'CorrectHorse1');

    const stored = (mockRepo.create.mock.calls[0][0] as { password: string })
      .password;
    expect(stored).toMatch(/^\$argon2id\$v=19\$m=19456,p=1,t=2\$/);
    expect(await argon2.verify(stored, 'CorrectHorse1')).toBe(true);
  });

  it('resetPassword accepts the OLD password against a legacy bcrypt hash and stores the new one as Argon2id', async () => {
    const user = userWith(await bcrypt.hash('OldPass1xx', 10));
    mockRepo.findOne.mockResolvedValue(user);

    await service.resetPassword(7, 'OldPass1xx', 'NewPass1xx');

    expect(user.password).toMatch(/^\$argon2id\$/);
    expect(await argon2.verify(user.password, 'NewPass1xx')).toBe(true);
    expect(mockRefreshTokens.revokeAllForUser).toHaveBeenCalledWith(7);
  });

  it('resetPassword refuses a wrong old password', async () => {
    mockRepo.findOne.mockResolvedValue(
      userWith(await bcrypt.hash('OldPass1xx', 10)),
    );
    await expect(service.resetPassword(7, 'bad', 'NewPass1xx')).rejects.toThrow(
      UnauthorizedException,
    );
    expect(mockRepo.save).not.toHaveBeenCalled();
  });
});
