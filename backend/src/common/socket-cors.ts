/**
 * The Socket.IO CORS origin check: in production only `ALLOWED_ORIGINS`, in
 * dev also localhost and LAN (a phone on Wi-Fi).
 *
 * Shared by EVERY gateway, and that is load-bearing: `ChatGateway` (`/`) and
 * `BoxGateway` (`/box`) ride one engine.io server on one port, and Nest
 * builds that server from the options of whichever gateway it scans FIRST
 * (`SocketServerProvider.scanForSocketServer`); the second only adds a
 * namespace. A gateway declaring different options would make the server's
 * CORS policy depend on module order.
 */
export function buildCorsOrigin() {
  const allowed = (process.env.ALLOWED_ORIGINS || 'http://localhost:3000')
    .split(',')
    .map((o) => o.trim());
  const isProd = process.env.NODE_ENV === 'production';
  return (origin: string, cb: (err: Error | null, allow?: boolean) => void) => {
    if (!origin) {
      cb(null, true);
      return;
    }
    if (allowed.includes(origin)) {
      cb(null, true);
      return;
    }
    if (
      !isProd &&
      (origin.startsWith('http://localhost:') ||
        origin.startsWith('http://127.0.0.1:') ||
        origin.startsWith('http://192.168.') ||
        origin.startsWith('http://10.'))
    ) {
      cb(null, true);
      return;
    }
    cb(new Error('Not allowed by CORS'), false);
  };
}
