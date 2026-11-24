import {
  ExecutionContext,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtAuthGuard } from './jwt-auth.guard';

describe('JwtAuthGuard', () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('logs invalid access reason without leaking URL query strings', () => {
    const warnSpy = jest
      .spyOn(Logger.prototype, 'warn')
      .mockImplementation(() => undefined);
    const guard = new JwtAuthGuard();
    const info = new Error('jwt malformed');
    info.name = 'JsonWebTokenError';
    const context = {
      switchToHttp: () => ({
        getRequest: () => ({
          method: 'GET',
          url: '/users/search?q=alice&token=do-not-log',
        }),
      }),
    } as unknown as ExecutionContext;

    expect(() => guard.handleRequest(null, null, info, context)).toThrow(
      UnauthorizedException,
    );

    expect(warnSpy).toHaveBeenCalledTimes(1);
    const logLine = warnSpy.mock.calls[0][0] as string;
    expect(logLine).toContain('reason=invalid_signature');
    expect(logLine).toContain('path=/users/search');
    expect(logLine).not.toContain('q=alice');
    expect(logLine).not.toContain('do-not-log');
  });

  it('logs access_expired at debug (not warn) for TokenExpiredError', () => {
    const warnSpy = jest
      .spyOn(Logger.prototype, 'warn')
      .mockImplementation(() => undefined);
    const debugSpy = jest
      .spyOn(Logger.prototype, 'debug')
      .mockImplementation(() => undefined);
    const guard = new JwtAuthGuard();
    const info = new Error('jwt expired');
    info.name = 'TokenExpiredError';
    const context = {
      switchToHttp: () => ({
        getRequest: () => ({ method: 'GET', url: '/messages?after=5' }),
      }),
    } as unknown as ExecutionContext;

    expect(() => guard.handleRequest(null, null, info, context)).toThrow(
      UnauthorizedException,
    );

    // Expiry is routine: it must NOT trip the invalid_signature warn canary.
    expect(warnSpy).not.toHaveBeenCalled();
    expect(debugSpy).toHaveBeenCalledTimes(1);
    const logLine = debugSpy.mock.calls[0][0] as string;
    expect(logLine).toContain('reason=access_expired');
  });

  it('logs access_invalid at debug (not warn) when info is null/unknown', () => {
    const warnSpy = jest
      .spyOn(Logger.prototype, 'warn')
      .mockImplementation(() => undefined);
    const debugSpy = jest
      .spyOn(Logger.prototype, 'debug')
      .mockImplementation(() => undefined);
    const guard = new JwtAuthGuard();
    const context = {
      switchToHttp: () => ({
        getRequest: () => ({ method: 'GET', url: '/me' }),
      }),
    } as unknown as ExecutionContext;

    expect(() => guard.handleRequest(null, null, null, context)).toThrow(
      UnauthorizedException,
    );

    expect(warnSpy).not.toHaveBeenCalled();
    expect(debugSpy).toHaveBeenCalledTimes(1);
    const logLine = debugSpy.mock.calls[0][0] as string;
    expect(logLine).toContain('reason=access_invalid');
  });

  it('prefers the stable route.path template over the concrete url', () => {
    const debugSpy = jest
      .spyOn(Logger.prototype, 'debug')
      .mockImplementation(() => undefined);
    const guard = new JwtAuthGuard();
    const info = new Error('jwt expired');
    info.name = 'TokenExpiredError';
    const context = {
      switchToHttp: () => ({
        getRequest: () => ({
          method: 'GET',
          route: { path: '/users/:id' },
          url: '/users/42?token=do-not-log',
        }),
      }),
    } as unknown as ExecutionContext;

    expect(() => guard.handleRequest(null, null, info, context)).toThrow(
      UnauthorizedException,
    );

    const logLine = debugSpy.mock.calls[0][0] as string;
    expect(logLine).toContain('path=/users/:id');
    expect(logLine).not.toContain('/users/42');
    expect(logLine).not.toContain('do-not-log');
  });
});
