import { createServer, type Server } from 'node:http';
import { AddressInfo } from 'node:net';
import {
  LinkPreviewService,
  MAX_IMAGE_BYTES,
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

// C1: the og:image travels to the web sender as `imageData` (base64), fetched
// through the same SSRF-safe path, so no receiver ever loads it.
describe('LinkPreviewService – og:image imageData', () => {
  let service: LinkPreviewService;
  let fetchImpl: jest.Mock;
  const page = (image: string) =>
    `<head><meta property="og:title" content="T"/><meta property="og:image" content="${image}"/></head>`;

  function response(
    contentType: string,
    chunks: Uint8Array[],
    extraHeaders: Record<string, string> = {},
  ) {
    const read = jest.fn();
    for (const value of chunks) read.mockResolvedValueOnce({ done: false, value });
    read.mockResolvedValue({ done: true, value: undefined });
    const cancel = jest.fn().mockResolvedValue(undefined);
    return {
      status: 200,
      ok: true,
      headers: {
        get: (h: string) =>
          h.toLowerCase() === 'content-type'
            ? contentType
            : (extraHeaders[h.toLowerCase()] ?? null),
      },
      body: { getReader: () => ({ read, cancel }) },
      cancel,
    } as unknown as Response & { cancel: jest.Mock };
  }

  function redirect(location: string) {
    return {
      status: 302,
      ok: false,
      headers: { get: (h: string) => (h.toLowerCase() === 'location' ? location : null) },
      body: null,
    } as unknown as Response;
  }

  const html = (s: string) => response('text/html', [new TextEncoder().encode(s)]);
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);

  beforeEach(() => {
    service = new LinkPreviewService();
    fetchImpl = jest.fn();
    service.fetchImpl = fetchImpl as unknown as typeof fetch;
  });

  it('returns the image bytes as base64 and keeps imageUrl for old clients', async () => {
    fetchImpl
      .mockResolvedValueOnce(html(page('/og.jpg')))
      .mockResolvedValueOnce(response('image/jpeg', [jpeg]));

    const result = await service.fetchPreview('https://example.com/page');

    expect(result).toEqual({
      url: 'https://example.com/page',
      title: 'T',
      imageUrl: 'https://example.com/og.jpg',
      imageData: Buffer.from(jpeg).toString('base64'),
    });
    expect(fetchImpl).toHaveBeenLastCalledWith(
      'https://example.com/og.jpg',
      expect.objectContaining({ redirect: 'manual' }),
    );
  });

  it('never fetches a private or plain-http og:image', async () => {
    fetchImpl.mockResolvedValueOnce(html(page('https://169.254.169.254/x.jpg')));
    const priv = await service.fetchPreview('https://example.com/a');
    fetchImpl.mockResolvedValueOnce(html(page('http://example.com/x.jpg')));
    const plain = await service.fetchPreview('https://example.com/b');

    expect(priv?.imageData).toBeUndefined();
    expect(plain?.imageData).toBeUndefined();
    expect(fetchImpl).toHaveBeenCalledTimes(2); // the pages only
  });

  it('refuses an image redirect into a private host, keeping title and imageUrl', async () => {
    fetchImpl
      .mockResolvedValueOnce(html(page('https://cdn.example.com/og.jpg')))
      .mockResolvedValueOnce(redirect('https://127.0.0.1/secret.jpg'));

    const result = await service.fetchPreview('https://example.com/page');

    expect(result?.title).toBe('T');
    expect(result?.imageData).toBeUndefined();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(fetchImpl).not.toHaveBeenCalledWith('https://127.0.0.1/secret.jpg', expect.anything());
  });

  it('refuses an image redirect that downgrades to http', async () => {
    fetchImpl
      .mockResolvedValueOnce(html(page('https://cdn.example.com/og.jpg')))
      .mockResolvedValueOnce(redirect('http://cdn.example.com/og.jpg'));

    const result = await service.fetchPreview('https://example.com/page');

    expect(result?.imageData).toBeUndefined();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it('follows a public image redirect', async () => {
    fetchImpl
      .mockResolvedValueOnce(html(page('https://example.com/og.jpg')))
      .mockResolvedValueOnce(redirect('https://cdn.example.com/og.jpg'))
      .mockResolvedValueOnce(response('image/jpeg', [jpeg]));

    const result = await service.fetchPreview('https://example.com/page');

    expect(result?.imageData).toBe(Buffer.from(jpeg).toString('base64'));
  });

  it('drops a non-image content type', async () => {
    fetchImpl
      .mockResolvedValueOnce(html(page('https://example.com/og.jpg')))
      .mockResolvedValueOnce(response('text/html', [jpeg]));

    const result = await service.fetchPreview('https://example.com/page');

    expect(result?.imageData).toBeUndefined();
    expect(result?.imageUrl).toBe('https://example.com/og.jpg');
  });

  it('aborts a streamed image past the 2 MiB cap', async () => {
    const chunk = new Uint8Array(MAX_IMAGE_BYTES / 2);
    const big = response('image/png', [chunk, chunk, new Uint8Array(1), chunk]);
    fetchImpl
      .mockResolvedValueOnce(html(page('https://example.com/og.png')))
      .mockResolvedValueOnce(big);

    const result = await service.fetchPreview('https://example.com/page');

    expect(result?.imageData).toBeUndefined();
    expect(result?.title).toBe('T');
  });

  it('refuses a declared Content-Length over the cap without reading', async () => {
    const big = response('image/png', [jpeg], {
      'content-length': String(MAX_IMAGE_BYTES + 1),
    });
    fetchImpl
      .mockResolvedValueOnce(html(page('https://example.com/og.png')))
      .mockResolvedValueOnce(big);

    const result = await service.fetchPreview('https://example.com/page');

    expect(result?.imageData).toBeUndefined();
  });

  it('keeps the preview when the image fetch throws', async () => {
    fetchImpl
      .mockResolvedValueOnce(html(page('https://example.com/og.png')))
      .mockRejectedValueOnce(new Error('ECONNRESET'));

    const result = await service.fetchPreview('https://example.com/page');

    expect(result?.title).toBe('T');
    expect(result?.imageData).toBeUndefined();
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
