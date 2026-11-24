import { json, type NextFunction, type Request, type Response } from 'express';

const backupJson = json({ limit: '4mb' });

/** The scheme `ExtractJwt.fromAuthHeaderAsBearerToken()` accepts: a token follows. */
const BEARER = /^bearer\s+\S+/i;

/**
 * The 4 MiB JSON parser of `PUT /backup/contacts`; see the long comment in
 * `main.ts` for why it is mounted before Nest's global parser and why this is
 * a NAMED function (`jsonParser`-named layers switch Nest's own parser off).
 *
 * It runs before `JwtAuthGuard`, so a request that carries no bearer token
 * never gets the 4 MiB room: it falls through to Nest's default 100 kb parser
 * (413 above that, otherwise the guard's own 401 with its CORS headers). The
 * token is NOT verified here; a junk bearer still earns the larger parse, and
 * the real JWT check stays in the guard.
 */
export function contactBackupJsonParser(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  if (!BEARER.test(req.headers.authorization ?? '')) {
    next();
    return;
  }
  backupJson(req, res, next);
}
