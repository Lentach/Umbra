import { LinkPreviewService } from './link-preview.service';

describe('LinkPreviewService', () => {
  let service: LinkPreviewService;
  let fetchMock: jest.Mock;

  beforeEach(() => {
    service = new LinkPreviewService();
    fetchMock = jest.fn();
    service.fetchImpl = fetchMock as unknown as typeof fetch;
  });

  function mockFetchResponse(html: string, ok = true) {
    const encoder = new TextEncoder();
    const chunks = [encoder.encode(html)];
    let readIndex = 0;
    fetchMock.mockResolvedValue({
      status: ok ? 200 : 500,
      ok,
      headers: { get: (key: string) => (key === 'content-type' ? 'text/html' : null) },
      body: {
        getReader: () => ({
          read: () => {
            if (readIndex < chunks.length) {
              const value = chunks[readIndex++];
              return Promise.resolve({ done: false, value });
            }
            return Promise.resolve({ done: true, value: new Uint8Array(0) });
          },
          cancel: jest.fn(),
        }),
      },
    });
  }

  describe('fetchPreview', () => {
    it('returns null when text has no URL', async () => {
      const result = await service.fetchPreview('hello world');
      expect(result).toBeNull();
      expect(fetchMock).not.toHaveBeenCalled();
    });

    it('returns null for private/local URLs', async () => {
      const result = await service.fetchPreview('http://localhost:3000/page');
      expect(result).toBeNull();
      expect(fetchMock).not.toHaveBeenCalled();
    });

    it('returns null for 127.0.0.1', async () => {
      const result = await service.fetchPreview('https://127.0.0.1/page');
      expect(result).toBeNull();
      expect(fetchMock).not.toHaveBeenCalled();
    });

    it('returns null for 192.168.x.x', async () => {
      const result = await service.fetchPreview('https://192.168.1.1/page');
      expect(result).toBeNull();
      expect(fetchMock).not.toHaveBeenCalled();
    });

    it('extracts title and imageUrl from og:meta', async () => {
      const html =
        '<head><meta property="og:title" content="Test Page"/><meta property="og:image" content="https://example.com/img.png"/></head>';
      mockFetchResponse(html);

      const result = await service.fetchPreview('https://example.com/page');

      expect(result).toEqual({
        url: 'https://example.com/page',
        title: 'Test Page',
        imageUrl: 'https://example.com/img.png',
      });
      expect(fetchMock).toHaveBeenCalledWith(
        'https://example.com/page',
        expect.objectContaining({ headers: { 'User-Agent': 'Mozilla/5.0 (compatible; ChatBot/1.0)' } }),
      );
    });

    it('resolves relative og:image URL against page URL', async () => {
      const html =
        '<head><meta property="og:title" content="Rel"/><meta property="og:image" content="/images/thumb.png"/></head>';
      mockFetchResponse(html);

      const result = await service.fetchPreview('https://example.com/article');

      expect(result?.imageUrl).toBe('https://example.com/images/thumb.png');
    });

    it('rejects http og:image (SSRF protection)', async () => {
      const html =
        '<head><meta property="og:title" content="X"/><meta property="og:image" content="http://evil.com/img.png"/></head>';
      mockFetchResponse(html);

      const result = await service.fetchPreview('https://example.com/page');

      expect(result?.imageUrl).toBeNull();
      expect(result?.title).toBe('X');
    });

    it('rejects private IP in og:image (SSRF protection)', async () => {
      const html =
        '<head><meta property="og:title" content="X"/><meta property="og:image" content="https://192.168.1.1/img.png"/></head>';
      mockFetchResponse(html);

      const result = await service.fetchPreview('https://example.com/page');

      expect(result?.imageUrl).toBeNull();
    });

    it('returns null when response is not ok', async () => {
      mockFetchResponse('<head></head>', false);

      const result = await service.fetchPreview('https://example.com/page');

      expect(result).toBeNull();
    });

    it('returns null when content-type is not text/html', async () => {
      fetchMock.mockResolvedValue({
        status: 200,
        ok: true,
        headers: { get: () => 'application/json' },
        body: { getReader: () => ({ read: () => Promise.resolve({ done: true, value: new Uint8Array(0) }), cancel: jest.fn() }) },
      });

      const result = await service.fetchPreview('https://example.com/api');

      expect(result).toBeNull();
    });

    it('extracts title from <title> when og:title missing', async () => {
      const html = '<head><title>Fallback Title</title></head>';
      mockFetchResponse(html);

      const result = await service.fetchPreview('https://example.com/page');

      expect(result?.title).toBe('Fallback Title');
      expect(result?.imageUrl).toBeNull();
    });

    it('returns null when neither title nor imageUrl present', async () => {
      const html = '<head><meta name="other" content="x"/></head>';
      mockFetchResponse(html);

      const result = await service.fetchPreview('https://example.com/page');

      expect(result).toBeNull();
    });
  });
});
