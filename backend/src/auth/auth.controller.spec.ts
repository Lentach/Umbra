import { Test } from '@nestjs/testing';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';

const createAuthServiceMock = () => ({
  login: jest.fn(),
  refreshWithToken: jest.fn(),
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

  // The per-IP login back-off and throttle key on this address, so it must be
  // nginx's X-Real-IP (replaced per request), never the client-appendable
  // X-Forwarded-For.
  it('login passes the proxied client IP (X-Real-IP, not X-Forwarded-For) to AuthService', async () => {
    await controller.login(
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
  });

  // The only controller-owned mapping on refresh: `rotate` is true ONLY for a
  // literal `true` in the body (absent / false -> the token stays, plan B4).
  it('refresh rotates only when the body asks', async () => {
    await controller.refresh({ refresh_token: 'old_refresh' });
    await controller.refresh({ refresh_token: 'old_refresh', rotate: true });

    expect(authService.refreshWithToken.mock.calls).toEqual([
      ['old_refresh', false],
      ['old_refresh', true],
    ]);
  });
});
