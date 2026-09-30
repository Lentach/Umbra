import * as bcrypt from 'bcrypt';
import { NotFoundException, UnauthorizedException } from '@nestjs/common';

import { UsersService } from './users.service';

jest.mock('bcrypt', () => ({
  compare: jest.fn(),
  hash: jest.fn(),
}));

// Decision 76: the client checks a typed password here before deriving the
// contact-backup wrap from it. The route must answer the question and do
// NOTHING else — no session, no password stamp, no write.
describe('UsersService.verifyPassword', () => {
  let service: UsersService;

  const storedHash = '$2b$10$storedhash';
  const mockRepo = {
    findOne: jest.fn(),
    save: jest.fn(),
    update: jest.fn(),
  };
  const mockRefreshTokens = {
    createToken: jest.fn(),
    revokeAllForUser: jest.fn(),
  };

  beforeEach(() => {
    jest.clearAllMocks();
    mockRepo.findOne.mockResolvedValue({
      id: 7,
      password: storedHash,
      passwordChangedAt: null,
    });

    // Only the users repo and the refresh-token service are reachable from
    // verifyPassword; the other collaborators stay empty stubs.
    const deps = [
      mockRepo,
      {},
      {},
      {},
      {},
      {},
      {},
      {},
      {},
      mockRefreshTokens,
    ] as unknown as ConstructorParameters<typeof UsersService>;
    service = new UsersService(...deps);
  });

  it('resolves for the right password and writes nothing', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(true);

    await expect(service.verifyPassword(7, 'right')).resolves.toBeUndefined();

    expect(bcrypt.compare).toHaveBeenCalledWith('right', storedHash);
    expect(mockRepo.save).not.toHaveBeenCalled();
    expect(mockRepo.update).not.toHaveBeenCalled();
    expect(mockRefreshTokens.createToken).not.toHaveBeenCalled();
    expect(mockRefreshTokens.revokeAllForUser).not.toHaveBeenCalled();
    expect(bcrypt.hash).not.toHaveBeenCalled();
  });

  it('refuses a wrong password with 401 Invalid password', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(false);

    await expect(service.verifyPassword(7, 'wrong')).rejects.toThrow(
      new UnauthorizedException('Invalid password'),
    );
    expect(mockRepo.save).not.toHaveBeenCalled();
  });

  it('refuses an account that no longer exists without comparing', async () => {
    mockRepo.findOne.mockResolvedValue(null);

    await expect(service.verifyPassword(7, 'right')).rejects.toThrow(
      NotFoundException,
    );
    expect(bcrypt.compare).not.toHaveBeenCalled();
  });
});
