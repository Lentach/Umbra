import { Test } from '@nestjs/testing';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';

const createAuthServiceMock = () => ({
  register: jest.fn(),
  login: jest.fn(),
  refreshWithToken: jest.fn(),
  logoutRefreshToken: jest.fn(),
});

describe('AuthController', () => {
  let controller: AuthController;
  let authService: ReturnType<typeof createAuthServiceMock>;

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      controllers: [AuthController],
      providers: [{ provide: AuthService, useFactory: createAuthServiceMock }],
    }).compile();

    controller = module.get(AuthController);
    authService = module.get(AuthService);
  });

  it('register forwards username and password to AuthService', async () => {
    authService.register.mockResolvedValue({ token: 'register-token' });

    const result = await controller.register({
      username: 'alice',
      password: 'StrongPass123!',
    });

    expect(authService.register).toHaveBeenCalledWith(
      'alice',
      'StrongPass123!',
    );
    expect(result).toEqual({ token: 'register-token' });
  });

  it('login forwards identifier, password and the proxied client IP (X-Real-IP, not a spoofable header) to AuthService', async () => {
    authService.login.mockResolvedValue({
      access_token: 'a',
      refresh_token: 'r',
    });

    const result = await controller.login(
      { identifier: 'alice#1234', password: 'StrongPass123!' },
      {
        headers: { 'x-real-ip': '203.0.113.9', 'x-forwarded-for': '6.6.6.6' },
        ip: '127.0.0.1',
      } as never,
    );

    expect(authService.login).toHaveBeenCalledWith(
      'alice#1234',
      'StrongPass123!',
      '203.0.113.9',
    );
    expect(result).toEqual({
      access_token: 'a',
      refresh_token: 'r',
    });
  });

  it('refresh forwards refresh_token to AuthService.refreshWithToken, rotating only when the body asks', async () => {
    authService.refreshWithToken.mockResolvedValue({
      access_token: 'na',
      refresh_token: 'nr',
    });

    const result = await controller.refresh({ refresh_token: 'old_refresh' });
    await controller.refresh({ refresh_token: 'old_refresh', rotate: true });

    expect(authService.refreshWithToken.mock.calls).toEqual([
      ['old_refresh', false],
      ['old_refresh', true],
    ]);
    expect(result).toEqual({
      access_token: 'na',
      refresh_token: 'nr',
    });
  });

  it('logout forwards refresh_token to AuthService.logoutRefreshToken', async () => {
    authService.logoutRefreshToken.mockResolvedValue(undefined);

    await controller.logout({ refresh_token: 'to_revoke' });

    expect(authService.logoutRefreshToken).toHaveBeenCalledWith('to_revoke');
  });
});
