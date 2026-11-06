import { Response } from 'express';
import { BadRequestException } from '@nestjs/common';
import { GUARDS_METADATA } from '@nestjs/common/constants';
import { MediaController } from './media.controller';

const fakeRes = {
  setHeader: jest.fn(),
  status: jest.fn().mockReturnThis(),
  send: jest.fn(),
  sendFile: jest.fn(),
} as unknown as Response & { sendFile: jest.Mock };

describe('MediaController', () => {
  const controller = new MediaController();

  beforeEach(() => {
    jest.clearAllMocks();
  });

  // By default (MEDIA_X_ACCEL_REDIRECT unset) the controller serves the file directly,
  // independent of NODE_ENV — prod must NOT fall back to an empty X-Accel response.
  it('serveAvatars serves file directly by default', async () => {
    await controller.serveAvatars('uuid.jpg', fakeRes);
    expect(fakeRes.sendFile).toHaveBeenCalledWith(
      expect.stringMatching(/avatars[/\\]uuid\.jpg/),
    );
  });

  it('serveAvatars rejects path traversal filenames before sending a file', async () => {
    await expect(
      controller.serveAvatars('../secret.bin', fakeRes),
    ).rejects.toThrow(BadRequestException);
    expect(fakeRes.sendFile).not.toHaveBeenCalled();
  });

  // Avatars are public: every profile photo is fetched by <img> tags that carry
  // no Authorization header.
  it('serveAvatars is public (no auth guard)', () => {
    const descriptor = Object.getOwnPropertyDescriptor(
      MediaController.prototype,
      'serveAvatars',
    );
    const handler: unknown = descriptor?.value;
    expect(typeof handler).toBe('function');
    expect(
      Reflect.getMetadata(GUARDS_METADATA, handler as object),
    ).toBeUndefined();
  });
});
