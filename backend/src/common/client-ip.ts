/**
 * The client address our nginx reported, or `undefined` when the request did
 * not come through it (a direct hit on :3000 — dev only; prod binds 127.0.0.1).
 *
 * Reads ONLY `X-Real-IP`. Every proxied location sets it to `$remote_addr`
 * (`infra/nginx/fireplace.conf`), which REPLACES whatever the client sent, so
 * behind the proxy it is not client-spoofable. Never X-Forwarded-For: nginx
 * sets that to `$proxy_add_x_forwarded_for`, which APPENDS the real client to
 * the client's own value — `X-Forwarded-For: 1.2.3.4` arrives as
 * `1.2.3.4, <real-client>`, so its first hop is the caller's choice and a
 * limit keyed on it is bypassed with one header.
 *
 * Shared by `HttpThrottlerGuard` and `WsThrottlerGuard` so both transports
 * agree on who a client is.
 */
export function proxiedClientIp(
  headers: Record<string, string | string[] | undefined> | undefined,
): string | undefined {
  const value = headers?.['x-real-ip'];
  // A duplicated header arrives comma-joined from Node, or as an array.
  if (Array.isArray(value)) return value[0]?.trim();
  if (typeof value === 'string') return value.split(',')[0]?.trim();
  return undefined;
}
