import * as bcrypt from 'bcrypt';
import { UsersService } from './users.service';
import { UnauthorizedException } from '@nestjs/common';

jest.mock('bcrypt', () => ({
  compare: jest.fn(),
  hash: jest.fn(),
}));

describe('UsersService.deleteAccount – cascade', () => {
  let service: UsersService;

  const mockUser = {
    id: 7,
    password: '$2b$10$validhashhere........................................',
    username: 'u',
    tag: '1234',
  };

  const mockRepo = {
    findOne: jest.fn(),
    remove: jest.fn().mockResolvedValue(undefined),
  };
  const mockProfilePhotoRepo = {
    find: jest.fn().mockResolvedValue([]),
  };
  const mockStorage = { deleteAvatar: jest.fn() };
  const mockKeyBundles = {
    deleteByUserId: jest.fn().mockResolvedValue(undefined),
  };
  const mockRefreshTokens = {
    revokeAllForUser: jest.fn().mockResolvedValue(undefined),
  };
  const mockDataSource = {};

  beforeEach(() => {
    jest.clearAllMocks();
    mockProfilePhotoRepo.find.mockResolvedValue([]);
    mockRepo.remove.mockResolvedValue(undefined);

    service = new UsersService(
      mockRepo as any,
      mockProfilePhotoRepo as unknown as never,
      mockStorage as any,
      mockKeyBundles as any,
      mockDataSource as any,
      mockRefreshTokens as any,
    );
  });

  it('purges key bundles AFTER the user row is removed (post-commit backstop to the FK cascade)', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(true);
    mockRepo.findOne.mockResolvedValue(mockUser);

    await service.deleteAccount(7, 'correct-password');

    expect(mockKeyBundles.deleteByUserId).toHaveBeenCalledWith(7);
    expect(mockRepo.remove).toHaveBeenCalledWith(mockUser);
    // Irreversible external cleanup must run only once the account is durably
    // gone: the user row (and its ON DELETE CASCADE side rows) goes first,
    // then the idempotent explicit purge runs as a backstop. A regression that
    // destroys key bundles BEFORE the removal re-opens the zombie window.
    expect(
      mockKeyBundles.deleteByUserId.mock.invocationCallOrder[0],
    ).toBeGreaterThan(mockRepo.remove.mock.invocationCallOrder[0]);
  });

  it('rejects with UnauthorizedException when password is wrong', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(false);
    mockRepo.findOne.mockResolvedValue(mockUser);

    await expect(service.deleteAccount(7, 'wrong')).rejects.toThrow(
      UnauthorizedException,
    );

    // A wrong password must abort before any destructive work fires.
    expect(mockRefreshTokens.revokeAllForUser).not.toHaveBeenCalled();
    expect(mockRepo.remove).not.toHaveBeenCalled();
    expect(mockKeyBundles.deleteByUserId).not.toHaveBeenCalled();
    expect(mockStorage.deleteAvatar).not.toHaveBeenCalled();
  });

  it('deletes every unique avatar storage key exactly once', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(true);
    mockRepo.findOne.mockResolvedValue({
      ...mockUser,
      profilePicturePublicId: 'avatars/a.jpg',
    });
    mockProfilePhotoRepo.find.mockResolvedValue([
      { storageKey: 'avatars/a.jpg' },
      { storageKey: 'avatars/b.jpg' },
    ]);

    await service.deleteAccount(7, 'correct-password');

    expect(mockStorage.deleteAvatar).toHaveBeenCalledWith('avatars/a.jpg');
    expect(mockStorage.deleteAvatar).toHaveBeenCalledWith('avatars/b.jpg');
    // De-dup: a.jpg is both the avatar id and a photo key, purged only once.
    expect(mockStorage.deleteAvatar).toHaveBeenCalledTimes(2);
  });

  it('revokes refresh tokens before a failing removal and performs no external destruction (no loginable zombie)', async () => {
    (bcrypt.compare as jest.Mock).mockResolvedValue(true);
    mockRepo.findOne.mockResolvedValue({
      ...mockUser,
      profilePicturePublicId: 'avatars/a.jpg',
    });
    mockRepo.remove.mockRejectedValueOnce(new Error('delete aborted'));

    await expect(service.deleteAccount(7, 'correct-password')).rejects.toThrow(
      'delete aborted',
    );

    // Session is killed up front, so a stolen refresh token cannot be exchanged
    // for a fresh access JWT: the "deleted" account is not loginable.
    expect(mockRefreshTokens.revokeAllForUser).toHaveBeenCalledWith(7);
    expect(
      mockRefreshTokens.revokeAllForUser.mock.invocationCallOrder[0],
    ).toBeLessThan(mockRepo.remove.mock.invocationCallOrder[0]);
    // Nothing irreversible happened: no keys or avatars were destroyed, so the
    // account is fully intact rather than a half-deleted zombie.
    expect(mockStorage.deleteAvatar).not.toHaveBeenCalled();
    expect(mockKeyBundles.deleteByUserId).not.toHaveBeenCalled();
  });
});
