import { json, type NextFunction, type Request, type Response } from 'express';

const backupJson = json({ limit: '4mb' });

/**
 * The 4 MiB JSON parser of `PUT /backup/contacts`; see the long comment in
 * `main.ts` for why it is mounted before Nest's global parser and why this is
 * a NAMED function (`jsonParser`-named layers switch Nest's own parser off).
 */
export function contactBackupJsonParser(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  backupJson(req, res, next);
}
