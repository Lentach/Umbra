import { ExecutionContext, Injectable } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';
import { proxiedClientIp } from './client-ip';

/**
 * HTTP-only rate-limit guard, registered globally via APP_GUARD.
 *
 * Why a custom guard:
 * - The backend runs behind nginx, which sets `X-Real-IP = $remote_addr`. The default
 *   ThrottlerGuard tracker uses `req.ip`, which (without trust-proxy) resolves to the
 *   nginx upstream — so EVERY client would share one bucket (a global lockout). We track
 *   the real client IP from `X-Real-IP` (then `req.ip`).
 * - As a global guard it would otherwise also run on the WebSocket gateway and crash on
 *   `res.header()` (sockets have no HTTP response). We skip non-HTTP contexts; WS keeps
 *   its own `WsThrottlerGuard`.
 *
 * Why we do NOT fall back to X-Forwarded-For: host nginx sets
 * `X-Forwarded-For $proxy_add_x_forwarded_for`, which APPENDS the real client to whatever
 * the client sent. So `X-Forwarded-For: 1.2.3.4` arrives as `1.2.3.4, <real-client-ip>`
 * and the FIRST hop is the attacker's spoofed value — an IP-based limit (e.g. the register
 * brute-force throttle) would be bypassable with one header. Trusting it is unsafe, so the
 * fallback is dropped entirely.
 *
 * Trade-off: any route that reaches here without `X-Real-IP` now falls through to `req.ip`,
 * which behind the proxy is the nginx upstream — collapsing all such callers into ONE bucket
 * (a global lockout, the exact failure this guard exists to avoid). Every proxied nginx
 * location MUST set `proxy_set_header X-Real-IP $remote_addr` for per-client throttling.
 */
@Injectable()
export class HttpThrottlerGuard extends ThrottlerGuard {
  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;
    return super.canActivate(context);
  }

  protected getTracker(req: Record<string, unknown>): Promise<string> {
    // Express request headers; nginx controls X-Real-IP, so it is not client-spoofable.
    const headers = (req.headers ?? {}) as Record<
      string,
      string | string[] | undefined
    >;
    const tracker =
      proxiedClientIp(headers) ??
      (typeof req.ip === 'string' ? req.ip : undefined) ??
      'unknown';
    return Promise.resolve(tracker);
  }
}
