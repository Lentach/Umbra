import { UnauthorizedException } from '@nestjs/common';
import { JwtStrategy } from './strategies/jwt.strategy';

describe('JwtStrategy.validate', () => {
  let strategy: JwtStrategy;
  const mockUsersService = { findById: jest.fn() };
  const mockDevicesService = { isRevoked: jest.fn() };
  const mockConfigService = { get: jest.fn().mockReturnValue('test-secret') };

  beforeEach(() => {
    jest.clearAllMocks();
    // Default: this device was never revoked, so the existing password-change
    // laws below are unaffected by the §5.5 gate.
    mockDevicesService.isRevoked.mockResolvedValue(false);
    strategy = new JwtStrategy(
      mockUsersService as never,
      mockDevicesService as never,
      mockConfigService as never,
    );
  });

  it('rejects when user not found', async () => {
    mockUsersService.findById.mockResolvedValue(null);
    await expect(
      strategy.validate({ sub: 1, username: 'a', tag: '1234', iat: 1000 }),
    ).rejects.toThrow(UnauthorizedException);
  });

  it('accepts token issued after passwordChangedAt', async () => {
    mockUsersService.findById.mockResolvedValue({
      id: 1,
      username: 'a',
      tag: '1234',
      profilePictureUrl: null,
      passwordChangedAt: new Date(900 * 1000),
    });
    const result = await strategy.validate({
      sub: 1,
      username: 'a',
      tag: '1234',
      iat: 1000,
    });
    expect(result.id).toBe(1);
  });

  it('rejects token issued before passwordChangedAt', async () => {
    mockUsersService.findById.mockResolvedValue({
      id: 1,
      username: 'a',
      tag: '1234',
      profilePictureUrl: null,
      passwordChangedAt: new Date(1000 * 1000),
    });
    await expect(
      strategy.validate({ sub: 1, username: 'a', tag: '1234', iat: 900 }),
    ).rejects.toThrow(UnauthorizedException);
  });

  it('rejects token issued in the same second as passwordChangedAt', async () => {
    mockUsersService.findById.mockResolvedValue({
      id: 1,
      username: 'a',
      tag: '1234',
      profilePictureUrl: null,
      passwordChangedAt: new Date(1000 * 1000),
    });
    await expect(
      strategy.validate({ sub: 1, username: 'a', tag: '1234', iat: 1000 }),
    ).rejects.toThrow(UnauthorizedException);
  });

  it('accepts when passwordChangedAt is null', async () => {
    mockUsersService.findById.mockResolvedValue({
      id: 1,
      username: 'a',
      tag: '1234',
      profilePictureUrl: null,
      passwordChangedAt: null,
    });
    const result = await strategy.validate({
      sub: 1,
      username: 'a',
      tag: '1234',
      iat: 1,
    });
    expect(result.id).toBe(1);
  });

  describe('the revoked-device gate (§5.5, amendment (xxii)/(xxiv))', () => {
    const liveUser = {
      id: 1,
      username: 'a',
      tag: '1234',
      profilePictureUrl: null,
      passwordChangedAt: null,
    };

    it('exposes the deviceId claim on the principal, so push rows can be attributed', async () => {
      mockUsersService.findById.mockResolvedValue(liveUser);

      const result = await strategy.validate({
        sub: 1,
        username: 'a',
        tag: '1234',
        iat: 1,
        deviceId: 2,
      });

      expect(result.deviceId).toBe(2);
      expect(mockDevicesService.isRevoked).toHaveBeenCalledWith(1, 2);
    });

    it('reads a claimless token as device 1 (§8), matching the socket path', async () => {
      mockUsersService.findById.mockResolvedValue(liveUser);

      const result = await strategy.validate({
        sub: 1,
        username: 'a',
        tag: '1234',
        iat: 1,
      });

      expect(result.deviceId).toBe(1);
      expect(mockDevicesService.isRevoked).toHaveBeenCalledWith(1, 1);
    });

    it('rejects a revoked device even though its JWT is still valid', async () => {
      mockUsersService.findById.mockResolvedValue(liveUser);
      mockDevicesService.isRevoked.mockResolvedValue(true);

      // This is the only thing standing between a revoked device and every
      // guarded REST route for the remaining life of its access token.
      await expect(
        strategy.validate({
          sub: 1,
          username: 'a',
          tag: '1234',
          iat: 1,
          deviceId: 2,
        }),
      ).rejects.toThrow(UnauthorizedException);
    });
  });
});
