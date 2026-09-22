import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { ThrottlerStorage, ThrottlerModuleOptions } from '@nestjs/throttler';
import { HttpThrottlerGuard } from './http-throttler.guard';

// The two overridden methods don't touch storage/options; supply typed stubs.
const makeGuard = () =>
  new HttpThrottlerGuard(
    { throttlers: [] } as unknown as ThrottlerModuleOptions,
    {} as unknown as ThrottlerStorage,
    new Reflector(),
  );

// Expose the protected getTracker without `any`.
type TrackerGuard = {
  getTracker(req: Record<string, unknown>): Promise<string>;
};

describe('HttpThrottlerGuard', () => {
  it('skips non-HTTP contexts so it never runs on the WS gateway', async () => {
    const guard = makeGuard();
    const wsCtx = { getType: () => 'ws' } as unknown as ExecutionContext;
    await expect(guard.canActivate(wsCtx)).resolves.toBe(true);
  });

  it('tracks the real client via X-Real-IP, not the nginx upstream', async () => {
    const guard = makeGuard() as unknown as TrackerGuard;
    const tracker = await guard.getTracker({
      headers: { 'x-real-ip': '203.0.113.7' },
      ip: '127.0.0.1',
    });
    expect(tracker).toBe('203.0.113.7');
  });

  it('ignores a spoofed X-Forwarded-For: its first hop never becomes the throttle key', async () => {
    const guard = makeGuard() as unknown as TrackerGuard;
    // nginx appends the real client, so `1.2.3.4` here is the attacker's spoofed
    // first hop. With no X-Real-IP the tracker must fall through to req.ip, NOT
    // adopt the attacker-controlled value.
    expect(
      await guard.getTracker({
        headers: { 'x-forwarded-for': '1.2.3.4, 10.0.0.1' },
        ip: '10.0.0.1',
      }),
    ).toBe('10.0.0.1');
    expect(await guard.getTracker({ headers: {}, ip: '192.0.2.5' })).toBe(
      '192.0.2.5',
    );
  });

  it('takes the first hop when X-Real-IP arrives as a string[] (merged duplicate headers)', async () => {
    const guard = makeGuard() as unknown as TrackerGuard;
    expect(
      await guard.getTracker({
        headers: { 'x-real-ip': ['203.0.113.7', '::1'] },
      }),
    ).toBe('203.0.113.7');
  });

  it('reads a blank X-Real-IP as no address and falls through to req.ip', async () => {
    const guard = makeGuard() as unknown as TrackerGuard;
    // Returned as '', it would be ONE bucket for every caller sending it blank.
    expect(
      await guard.getTracker({ headers: { 'x-real-ip': '' }, ip: '192.0.2.5' }),
    ).toBe('192.0.2.5');
  });

  it('returns "unknown" when no forwarding headers and no req.ip are present', async () => {
    const guard = makeGuard() as unknown as TrackerGuard;
    expect(await guard.getTracker({ headers: {} })).toBe('unknown');
  });

  it('prefers X-Real-IP over X-Forwarded-For when both are present', async () => {
    const guard = makeGuard() as unknown as TrackerGuard;
    expect(
      await guard.getTracker({
        headers: { 'x-real-ip': 'A', 'x-forwarded-for': 'B' },
      }),
    ).toBe('A');
  });
});
