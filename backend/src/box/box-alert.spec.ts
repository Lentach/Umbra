import { BoxAlert, parseAlertUrl } from './box-alert';

const URL_ = 'https://hc-ping.com/00000000-0000-4000-8000-000000000000';

function setup(
  env: string | undefined,
  respond: (url: string, init: RequestInit) => Promise<Response>,
) {
  const saved = process.env.BOX_ALERT_URL;
  if (env === undefined) delete process.env.BOX_ALERT_URL;
  else process.env.BOX_ALERT_URL = env;
  const alert = new BoxAlert();
  process.env.BOX_ALERT_URL = saved;
  if (saved === undefined) delete process.env.BOX_ALERT_URL;
  const fetchImpl = jest.fn(respond);
  alert.fetchImpl = fetchImpl;
  const logger = alert['logger'] as unknown as Record<string, jest.Mock>;
  const warn = jest.spyOn(logger as never, 'warn').mockImplementation();
  return { alert, fetchImpl, warn };
}

const ok = () => Promise.resolve(new Response(null, { status: 200 }));

describe('BoxAlert', () => {
  it('pings the check while fine and <url>/fail while alarming, with no body', async () => {
    const { alert, fetchImpl } = setup(`${URL_}/`, ok);
    await alert.report(false);
    await alert.report(true);
    expect(fetchImpl.mock.calls.map((c) => c[0])).toEqual([
      URL_,
      `${URL_}/fail`,
    ]);
    for (const [, init] of fetchImpl.mock.calls) {
      expect(init).toMatchObject({ method: 'GET' });
      expect(init).not.toHaveProperty('body');
    }
  });

  it('is off without a URL, and refuses a non-https one', async () => {
    for (const env of [undefined, 'http://hc-ping.com/x', 'not a url']) {
      const { alert, fetchImpl } = setup(env, ok);
      await alert.report(true);
      expect(fetchImpl).not.toHaveBeenCalled();
    }
  });

  it('logs a failing ping once per streak, never the URL', async () => {
    let status = 500;
    const { alert, warn } = setup(URL_, () =>
      Promise.resolve(new Response(null, { status })),
    );
    await alert.report(true);
    await alert.report(true);
    status = 200;
    await alert.report(false);
    status = 503;
    await alert.report(false);
    expect(warn.mock.calls.map((c) => c[0])).toEqual([
      '[box] alarm ping failed (status 500)',
      '[box] alarm ping failed (status 503)',
    ]);
  });

  it('a thrown fetch (timeout, DNS) never escapes the sweep', async () => {
    const { alert, warn } = setup(URL_, () =>
      Promise.reject(new DOMException('timed out', 'TimeoutError')),
    );
    await expect(alert.report(false)).resolves.toBeUndefined();
    expect(warn).toHaveBeenCalledWith('[box] alarm ping failed (TimeoutError)');
  });

  it('parseAlertUrl keeps only https and drops trailing slashes', () => {
    expect(parseAlertUrl(` ${URL_}// `)).toBe(URL_);
    expect(parseAlertUrl('ftp://x')).toBeNull();
    expect(parseAlertUrl('')).toBeNull();
  });
});
