import { DataSource } from 'typeorm';
import { ProfilePhoto } from './profile-photo.entity';
import { User } from './user.entity';
import { UsersService } from './users.service';

describe('UsersService.addProfilePhoto', () => {
  const profilePhotoRepo = {
    find: jest.fn(),
  };
  const transactionalPhotoRepo = {
    find: jest.fn(),
    create: jest.fn(),
    save: jest.fn(),
  };
  const manager = {
    findOne: jest.fn(),
    getRepository: jest.fn(),
    update: jest.fn(),
  };
  const dataSource = {
    transaction: jest.fn(),
  };
  const service = new UsersService(
    {} as any,
    profilePhotoRepo as any,
    {} as any,
    {} as any,
    dataSource as unknown as DataSource,
    {} as any,
  );

  beforeEach(() => {
    jest.clearAllMocks();
    profilePhotoRepo.find.mockResolvedValue([]);
    manager.findOne.mockResolvedValue({ id: 7 });
    manager.getRepository.mockReturnValue(transactionalPhotoRepo);
    manager.update.mockResolvedValue(undefined);
    dataSource.transaction.mockImplementation(async (callback) => callback(manager));
    transactionalPhotoRepo.create.mockImplementation((photo) => photo);
    transactionalPhotoRepo.save.mockImplementation(async (photo) => ({ id: 1, ...photo }));
  });

  it('writes a primary photo and the legacy primary pointer atomically', async () => {
    const saved = {
      id: 1,
      userId: 7,
      url: '/avatars/new.jpg',
      storageKey: 'avatars/new.jpg',
      isPrimary: true,
    };
    transactionalPhotoRepo.find
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce([saved]);

    await expect(
      service.addProfilePhoto(7, saved.url, saved.storageKey),
    ).resolves.toEqual([saved]);

    expect(dataSource.transaction).toHaveBeenCalledTimes(1);
    expect(manager.findOne).toHaveBeenCalledWith(User, {
      where: { id: 7 },
      lock: { mode: 'pessimistic_write' },
    });
    expect(manager.getRepository).toHaveBeenCalledWith(ProfilePhoto);
    expect(manager.update).toHaveBeenCalledWith(User, 7, {
      profilePictureUrl: saved.url,
      profilePicturePublicId: saved.storageKey,
    });
  });

  it('rejects a full gallery while holding the owner lock', async () => {
    transactionalPhotoRepo.find.mockResolvedValue([
      { id: 1 },
      { id: 2 },
      { id: 3 },
    ]);

    await expect(
      service.addProfilePhoto(7, '/avatars/four.jpg', 'avatars/four.jpg'),
    ).rejects.toThrow('A profile can have at most three photos');

    expect(manager.findOne).toHaveBeenCalledWith(User, {
      where: { id: 7 },
      lock: { mode: 'pessimistic_write' },
    });
    expect(transactionalPhotoRepo.save).not.toHaveBeenCalled();
  });
});

describe('UsersService.reorderProfilePhotos', () => {
  const transactionalPhotoRepo = {
    find: jest.fn(),
  };
  const manager = {
    findOne: jest.fn(),
    getRepository: jest.fn(),
    update: jest.fn(),
  };
  const dataSource = {
    transaction: jest.fn(),
  };
  const service = new UsersService(
    {} as any,
    {} as any,
    {} as any,
    {} as any,
    dataSource as unknown as DataSource,
    {} as any,
  );
  const photos = [
    {
      id: 1,
      userId: 7,
      url: '/avatars/one.jpg',
      storageKey: 'avatars/one.jpg',
      position: 0,
      isPrimary: true,
    },
    {
      id: 2,
      userId: 7,
      url: '/avatars/two.jpg',
      storageKey: 'avatars/two.jpg',
      position: 1,
      isPrimary: false,
    },
    {
      id: 3,
      userId: 7,
      url: '/avatars/three.jpg',
      storageKey: 'avatars/three.jpg',
      position: 2,
      isPrimary: false,
    },
  ];

  beforeEach(() => {
    jest.clearAllMocks();
    manager.findOne.mockResolvedValue({ id: 7 });
    manager.getRepository.mockReturnValue(transactionalPhotoRepo);
    manager.update.mockResolvedValue(undefined);
    dataSource.transaction.mockImplementation(async (callback) => callback(manager));
  });

  it('reorders the full owned photo set and returns the fresh order', async () => {
    const reorderedPhotos = [
      { ...photos[2], position: 0, isPrimary: true },
      { ...photos[0], position: 1, isPrimary: false },
      { ...photos[1], position: 2, isPrimary: false },
    ];
    transactionalPhotoRepo.find
      .mockResolvedValueOnce(photos)
      .mockResolvedValueOnce(reorderedPhotos);

    await expect(service.reorderProfilePhotos(7, [3, 1, 2])).resolves.toEqual(
      reorderedPhotos,
    );

    expect(manager.update).toHaveBeenLastCalledWith(User, 7, {
      profilePictureUrl: '/avatars/three.jpg',
      profilePicturePublicId: 'avatars/three.jpg',
    });
  });

  it('rejects an ordered id set that is not exactly the user photo ids', async () => {
    transactionalPhotoRepo.find.mockResolvedValue(photos);

    await expect(service.reorderProfilePhotos(7, [1, 2, 99])).rejects.toThrow(
      'orderedIds must contain exactly the user profile photo ids',
    );

    expect(manager.update).not.toHaveBeenCalled();
  });

  it('clears the previous primary before making the first ordered photo primary', async () => {
    transactionalPhotoRepo.find
      .mockResolvedValueOnce(photos)
      .mockResolvedValueOnce([]);

    await service.reorderProfilePhotos(7, [3, 1, 2]);

    expect(manager.update).toHaveBeenNthCalledWith(
      1,
      ProfilePhoto,
      { userId: 7 },
      { isPrimary: false },
    );
    expect(manager.update).toHaveBeenNthCalledWith(
      2,
      ProfilePhoto,
      { id: 3, userId: 7 },
      { position: 0, isPrimary: true },
    );
    expect(manager.update).toHaveBeenNthCalledWith(
      3,
      ProfilePhoto,
      { id: 1, userId: 7 },
      { position: 1, isPrimary: false },
    );
    expect(manager.update).toHaveBeenNthCalledWith(
      4,
      ProfilePhoto,
      { id: 2, userId: 7 },
      { position: 2, isPrimary: false },
    );
  });
});
