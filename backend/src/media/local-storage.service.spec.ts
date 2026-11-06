import { Test } from '@nestjs/testing';
import { ConfigService } from '@nestjs/config';
import { LocalStorageService } from './local-storage.service';
import * as fs from 'fs/promises';
import * as path from 'path';

jest.mock('fs/promises');
const mockFs = fs as jest.Mocked<typeof fs>;

describe('LocalStorageService', () => {
  let service: LocalStorageService;

  beforeEach(async () => {
    jest.clearAllMocks();
    mockFs.mkdir.mockResolvedValue(undefined);
    mockFs.writeFile.mockResolvedValue(undefined);
    mockFs.unlink.mockResolvedValue(undefined);

    const module = await Test.createTestingModule({
      providers: [
        LocalStorageService,
        {
          provide: ConfigService,
          useValue: {
            get: (key: string) => {
              if (key === 'MEDIA_BASE_URL') return 'https://example.com';
              if (key === 'MEDIA_DIR') return '/app/media';
            },
          },
        },
      ],
    }).compile();

    service = module.get(LocalStorageService);
  });

  it('uploadAvatar returns secureUrl with /media/avatars/ path and .jpg extension', async () => {
    const result = await service.uploadAvatar(1, Buffer.from('data'), 'image/jpeg');
    expect(result.secureUrl).toMatch(
      /^https:\/\/example\.com\/media\/avatars\/.+\.jpg$/,
    );
  });

  it('uploadAvatar returns secureUrl with /media/avatars/ path and .png extension for PNG', async () => {
    const result = await service.uploadAvatar(1, Buffer.from('data'), 'image/png');
    expect(result.secureUrl).toMatch(
      /^https:\/\/example\.com\/media\/avatars\/.+\.png$/,
    );
    expect(result.publicId).toMatch(/^avatars\/.+\.png$/);
  });

  it('deleteFile calls unlink with correct path', async () => {
    await service.deleteFile('avatars/abc123.jpg');
    expect(mockFs.unlink).toHaveBeenCalledWith(
      path.join('/app/media', 'avatars/abc123.jpg'),
    );
  });

  it('deleteFile is a no-op for Cloudinary URLs (skips)', async () => {
    await service.deleteFile(
      'https://res.cloudinary.com/demo/image/upload/sample.jpg',
    );
    expect(mockFs.unlink).not.toHaveBeenCalled();
  });

  it('deleteFile does not throw if file not found', async () => {
    const err = Object.assign(new Error(), { code: 'ENOENT' });
    mockFs.unlink.mockRejectedValueOnce(err);
    await expect(service.deleteFile('avatars/missing.jpg')).resolves.not.toThrow();
  });

  // H-02: a crafted mediaUrl can yield a traversing publicId (e.g.
  // '../../etc/passwd' after extractPublicId). deleteFile must never unlink
  // anything outside MEDIA_DIR.
  it('deleteFile refuses a ../-escaping publicId and never unlinks', async () => {
    await service.deleteFile('../../etc/passwd');
    expect(mockFs.unlink).not.toHaveBeenCalled();
  });

  it('deleteFile refuses an avatars/../ traversal and never unlinks', async () => {
    await service.deleteFile('avatars/../../../etc/passwd');
    expect(mockFs.unlink).not.toHaveBeenCalled();
  });

  it('deleteFile refuses the media root itself', async () => {
    await service.deleteFile('.');
    expect(mockFs.unlink).not.toHaveBeenCalled();
  });
});
