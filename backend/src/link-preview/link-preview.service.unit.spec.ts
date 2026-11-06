import { createServer, type Server } from 'node:http';
import { AddressInfo } from 'node:net';
import {
  LinkPreviewService,
  isPrivateIp,
  ssrfSafeFetch,
} from './link-preview.service';

// SSRF-blocking behaviour. A blocked URL must return null WITHOUT ever calling
// the outbound fetch (the URL-literal layer catches it); a hostname that only
// resolves to a private address is caught by the pinned-DNS agent at connect.
describe('LinkPreviewService – SSRF blocking', () => {
  let service: LinkPreviewService;
  let fetchImpl: jest.Mock;

  beforeEach(() => {
    service = new LinkPreviewService();
    // If this is called for a blocked URL the test fails: blocked URLs must
    // never reach the network.
    fetchImpl = jest.fn().mockResolvedValue({
      status: 200,
      ok: false,
      headers: { get: () => null },
      body: null,
    } as unknown as Response);
    service.fetchImpl = fetchImpl as unknown as typeof fetch;
  });

  const blocked = [
    'http://169.254.169.254/latest/meta-data/', // AWS IMDS
    'http://169.254.169.254/computeMetadata/v1/', // GCP IMDS
    'http://169.254.0.1/', // IPv4 link-local
    'http://[fe80::1]/', // IPv6 link-local
    'http://[fc00::1]/', // IPv6 ULA
    'http://[::1]/', // IPv6 loopback
    'http://[::]/', // IPv6 unspecified
    'http://[::ffff:127.0.0.1]/', // IPv4-mapped IPv6 loopback
    'http://[::ffff:169.254.169.254]/', // IPv4-mapped IPv6 metadata
    'http://10.0.0.1/', // RFC-1918
    'http://192.168.1.1/', // RFC-1918
    'http://127.0.0.1/', // loopback
    'http://127.1/', // short-form loopback (URL-normalized)
    'http://0.0.0.0/', // "this host"
    'http://localhost/', // loopback name
    'http://foo.localhost/', // loopback subdomain
    'http://172.16.0.1/', // RFC-1918
    'http://100.64.0.1/', // CGNAT
    'http://2130706433/', // decimal 127.0.0.1
    'http://0x7f000001/', // hex 127.0.0.1
    'http://0177.0.0.1/', // octal-leading 127.0.0.1
  ];

  test.each(blocked)('blocks %s', async (url) => {
    const result = await service.fetchPreview(url);
    expect(result).toBeNull();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('allows a public HTTPS URL', async () => {
    fetchImpl.mockResolvedValue({
      status: 200,
      ok: true,
      headers: { get: (h: string) => (h === 'content-type' ? 'text/html' : null) },
      body: {
        getReader: () => ({
          read: jest
            .fn()
            .mockResolvedValueOnce({
              done: false,
              value: new TextEncoder().encode(
                '<html><head><title>Example</title></head></html>',
              ),
            })
            .mockResolvedValueOnce({ done: true, value: undefined }),
          cancel: jest.fn(),
        }),
      },
    } as unknown as Response);

    const result = await service.fetchPreview('check out https://example.com');
    expect(result?.url).toBe('https://example.com');
    expect(fetchImpl).toHaveBeenCalledWith(
      'https://example.com',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
  });

  // ----- redirect-following SSRF (each hop must be re-validated) -----

  function htmlResponse(html: string) {
    return {
      status: 200,
      ok: true,
      headers: {
        get: (h: string) => (h === 'content-type' ? 'text/html' : null),
      },
      body: {
        getReader: () => ({
          read: jest
            .fn()
            .mockResolvedValueOnce({
              done: false,
              value: new TextEncoder().encode(html),
            })
            .mockResolvedValueOnce({ done: true, value: undefined }),
          cancel: jest.fn(),
        }),
      },
    } as unknown as Response;
  }

  function redirectResponse(location: string) {
    return {
      status: 302,
      ok: false,
      headers: {
        get: (h: string) =>
          h.toLowerCase() === 'location' ? location : null,
      },
      body: null,
    } as unknown as Response;
  }

  it('disables automatic redirect following (redirect: manual)', async () => {
    fetchImpl.mockReset();
    fetchImpl.mockResolvedValue(htmlResponse('<head><title>X</title></head>'));

    await service.fetchPreview('https://example.com/page');

    expect(fetchImpl).toHaveBeenCalledWith(
      'https://example.com/page',
      expect.objectContaining({ redirect: 'manual' }),
    );
  });

  it('follows a redirect to a public URL and previews the final page', async () => {
    fetchImpl.mockReset();
    fetchImpl
      .mockResolvedValueOnce(redirectResponse('https://cdn.example.com/real'))
      .mockResolvedValueOnce(htmlResponse('<head><title>Real</title></head>'));

    const result = await service.fetchPreview('https://example.com/start');

    expect(result?.title).toBe('Real');
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it('refuses a redirect that points at a private/metadata IP', async () => {
    fetchImpl.mockReset();
    fetchImpl.mockResolvedValueOnce(
      redirectResponse('http://169.254.169.254/latest/meta-data/'),
    );

    const result = await service.fetchPreview('https://evil.example.com/go');

    expect(result).toBeNull();
    expect(fetchImpl).toHaveBeenCalledTimes(1); // public URL only; never the metadata host
    expect(fetchImpl).not.toHaveBeenCalledWith(
      'http://169.254.169.254/latest/meta-data/',
      expect.anything(),
    );
  });

  it('gives up after too many redirects instead of looping', async () => {
    fetchImpl.mockReset();
    fetchImpl.mockResolvedValue(redirectResponse('https://example.com/next'));

    const result = await service.fetchPreview('https://example.com/start');

    expect(result).toBeNull();
    expect(fetchImpl.mock.calls.length).toBeLessThanOrEqual(6);
  });
});

describe('isPrivateIp', () => {
  const priv = [
    '0.0.0.0',
    '10.1.2.3',
    '100.64.0.1',
    '127.0.0.1',
    '169.254.169.254',
    '172.16.0.1',
    '172.31.255.255',
    '192.168.0.1',
    '198.18.0.1',
    '224.0.0.1',
    '255.255.255.255',
    '::1',
    '::',
    'fc00::1',
    'fd12:3456::1',
    'fe80::1',
    '::ffff:127.0.0.1',
    '::ffff:10.0.0.1',
    '64:ff9b::7f00:1', // NAT64-mapped 127.0.0.1
  ];
  test.each(priv)('treats %s as private', (ip) => {
    expect(isPrivateIp(ip)).toBe(true);
  });

  const pub = ['8.8.8.8', '1.1.1.1', '172.32.0.1', '192.169.0.1', '2606:4700::1111'];
  test.each(pub)('treats %s as public', (ip) => {
    expect(isPrivateIp(ip)).toBe(false);
  });
});

// End-to-end proof that undici honors connect.lookup. If it silently ignored
// the pinned lookup the SSRF control would fail OPEN and a lookup-only unit
// test would still pass. We stand up a REAL loopback server and drive the REAL
// ssrfSafeFetch/agent at `localhost` (resolved by the OS to loopback, no
// network). ssrfSafeLookup sees a private address and refuses BEFORE connect,
// so the server must receive zero requests and the rejection must carry
// ssrfSafeLookup's own "private address" message. A fail-open would instead
// reach the live server (hits > 0) or surface a plain OS connect error — so
// either assertion catches it. ssrfSafeFetch is called directly, so the
// service's isFetchableUrl hostname block is not what's under test here.
describe('ssrfSafeFetch – pinned-DNS agent is actually wired', () => {
  let server: Server;
  let hits = 0;
  let port = 0;

  beforeAll(async () => {
    server = createServer((_req, res) => {
      hits++;
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end('<head><title>should never be served</title></head>');
    });
    await new Promise<void>((resolve) =>
      server.listen(0, '127.0.0.1', resolve),
    );
    port = (server.address() as AddressInfo).port;
  });

  afterAll(async () => {
    await new Promise<void>((resolve, reject) =>
      server.close((e) => (e ? reject(e) : resolve())),
    );
  });

  it('refuses a hostname that resolves to a private address, never hitting the server', async () => {
    const err = await ssrfSafeFetch(`http://localhost:${port}/`, {}).then(
      () => null,
      (e: unknown) => e,
    );

    expect(hits).toBe(0);
    expect(err).toBeInstanceOf(Error);

    // Walk the cause chain: undici wraps the connector error as `.cause`.
    let messages = '';
    let node: unknown = err;
    for (let i = 0; i < 5 && node instanceof Error; i++) {
      messages += ` ${node.message}`;
      node = 'cause' in node ? node.cause : undefined;
    }
    expect(messages).toContain('private address');
  });
});
