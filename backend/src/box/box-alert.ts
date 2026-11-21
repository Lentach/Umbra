import { Injectable, Logger } from '@nestjs/common';

const PING_TIMEOUT_MS = 10_000;

/**
 * The box's alarm to the operator (plan D2 O1, decision 147): after each
 * reaper sweep, one GET to `BOX_ALERT_URL` (a healthchecks.io check) — the
 * plain URL while the box is fine, `<url>/fail` while any total is at WARN or
 * above (`BoxCeilingMonitor`) or the totals row is missing. healthchecks.io
 * emails the owner on a fail, and also when the pings stop (backend down).
 *
 * The ping carries ONE bit and no body: never a number, never an id. Unset
 * means off. The URL holds the check's secret, so it is never logged.
 */
@Injectable()
export class BoxAlert {
  private readonly logger = new Logger(BoxAlert.name);
  private readonly url: string | null;
  private failing = false;
  /** Swapped by tests. */
  fetchImpl: typeof fetch = fetch;

  constructor() {
    this.url = parseAlertUrl(process.env.BOX_ALERT_URL);
    if (process.env.BOX_ALERT_URL && !this.url) {
      this.logger.error('[box] BOX_ALERT_URL is not an https URL; alarm off');
    }
  }

  async report(alarming: boolean): Promise<void> {
    if (!this.url) return;
    const target = alarming ? `${this.url}/fail` : this.url;
    let failure: string | null = null;
    try {
      const res = await this.fetchImpl(target, {
        method: 'GET',
        signal: AbortSignal.timeout(PING_TIMEOUT_MS),
      });
      if (!res.ok) failure = `status ${res.status}`;
    } catch (err) {
      // A timeout is a DOMException, which is not always an Error subclass.
      const name = (err as { name?: unknown } | null)?.name;
      failure = typeof name === 'string' ? name : 'error';
    }
    // Once per streak: a long outage of the pinger is one line, not 144 a day.
    if (failure && !this.failing) {
      this.logger.warn(`[box] alarm ping failed (${failure})`);
    }
    this.failing = failure !== null;
  }
}

/** The URL without a trailing slash, or null unless it is https. */
export function parseAlertUrl(raw: string | undefined): string | null {
  if (!raw) return null;
  try {
    const url = new URL(raw.trim());
    if (url.protocol !== 'https:') return null;
    return url.toString().replace(/\/+$/, '');
  } catch {
    return null;
  }
}
