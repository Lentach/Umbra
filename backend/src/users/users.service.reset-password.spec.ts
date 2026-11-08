import * as bcrypt from 'bcrypt';
import { UnauthorizedException } from '@nestjs/common';

import { UsersService } from './users.service';

jest.mock('bcrypt', () => ({
  compare: jest.fn(),
  hash: jest.fn(),
}));

describe('UsersService.resetPassword – refresh revocation ordering', () => {
  let service: UsersService;

  const mockUser = {
    id: 7,
    password: '$2b$10$oldhash...............................................',
    username: 'u',
    tag: '1234',
    passwordChangedAt: undefined as Date | undefined,
  };

  const mockRepo = {
    findOne: jest.fn(),
    save: jest.fn().mockResolvedValue(undefined),
  };
  const mockRefreshTokens = {
    revokeAllForUser: jest.fn().mockResolvedValue(undefined),
  };

  beforeEach(() => {
    jest.clearAllMocks();
    mockUser.passwordChangedAt = undefined;
    mockRepo.findOne.mockResolvedValue(mockUser);
    mockRepo.save.mockResolvedValue(undefined);
    (bcrypt.hash as jest.Mock).mockResolvedValue('$2b$10$newhash');

    service = new UsersService(
      mockRepo as any,
      {} as any,
      {} as any,
      {} as any,
      mockRefreshTokens as any,
    );
  });

  it('revokes all refresh tokens BEFORE stamping passwordChangedAt so a token stolen in the reset window is rejected', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(true);

    await service.resetPassword(7, 'old', 'NewValidPass1');

    expect(mockRefreshTokens.revokeAllForUser).toHaveBeenCalledWith(7);
    expect(mockRepo.save).toHaveBeenCalledWith(mockUser);
    // The revoke must land before the passwordChangedAt stamp is persisted.
    // Otherwise a stolen refresh token can be exchanged for a fresh access JWT
    // (whose iat > the floored passwordChangedAt) in the window between save and
    // revoke, surviving JwtStrategy's iat <= passwordChangedAt check.
    expect(
      mockRefreshTokens.revokeAllForUser.mock.invocationCallOrder[0],
    ).toBeLessThan(mockRepo.save.mock.invocationCallOrder[0]);
    expect(mockUser.passwordChangedAt).toBeInstanceOf(Date);
  });

  it('does not revoke tokens or persist a new password when the old password is wrong', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(false);

    await expect(
      service.resetPassword(7, 'wrong', 'NewValidPass1'),
    ).rejects.toThrow(UnauthorizedException);

    expect(mockRefreshTokens.revokeAllForUser).not.toHaveBeenCalled();
    expect(mockRepo.save).not.toHaveBeenCalled();
  });

  // Amendment (lxxxii) clause 2: the recovery-phrase door reaches the same
  // write with authorization already proven. The ordering law is the same.
  it('setPassword (the phrase door) revokes all refresh tokens before the stamp', async () => {
    await service.setPassword(7, 'NewValidPass1');

    expect(mockRefreshTokens.revokeAllForUser).toHaveBeenCalledWith(7);
    expect(
      mockRefreshTokens.revokeAllForUser.mock.invocationCallOrder[0],
    ).toBeLessThan(mockRepo.save.mock.invocationCallOrder[0]);
    expect(mockUser.passwordChangedAt).toBeInstanceOf(Date);
    expect(bcrypt.compare).not.toHaveBeenCalled();
  });
});
