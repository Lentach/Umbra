// backend/src/secret-notes/secret-notes.controller.spec.ts
import { Test } from '@nestjs/testing';
import { SecretNotesController } from './secret-notes.controller';
import { SecretNotesService } from './secret-notes.service';

const mockService = () => ({
  create: jest.fn(),
  findByToken: jest.fn(),
  revealAndDelete: jest.fn(),
});

// A well-formed token: 32 lowercase hex chars (crypto.randomBytes(16).toString('hex')).
// The controller now gates on /^[0-9a-f]{32}$/ before any service/DB/HTML work,
// so valid-path tests must use a token that passes the gate.
// gitleaks:allow — a counting-pattern test fixture, not a secret; the
// pre-commit scan flags any 32-hex literal near the word "token".
const VALID_TOKEN = '0123456789abcdef0123456789abcdef'; // gitleaks:allow
const INVALID_TOKENS = [
  '<script>alert(1)</script>', // XSS-shaped
  'ZZZZ', // non-hex
  '0123456789abcdef0123456789abcde', // 31 chars (too short)
  '0123456789abcdef0123456789abcdeff', // 33 chars (too long)
  '0123456789ABCDEF0123456789abcdef', // uppercase hex rejected
  '', // empty
];
const mockRes = () => {
  const res: any = {};
  res.send = jest.fn().mockReturnValue(res);
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  res.setHeader = jest.fn().mockReturnValue(res);
  return res;
};

describe('SecretNotesController', () => {
  let controller: SecretNotesController;
  let service: ReturnType<typeof mockService>;

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      controllers: [SecretNotesController],
      providers: [{ provide: SecretNotesService, useFactory: mockService }],
    }).compile();

    controller = module.get(SecretNotesController);
    service = module.get(SecretNotesService);
  });

  describe('createNote', () => {
    it('returns token for valid request', async () => {
      service.create.mockResolvedValue({ token: 'abc123' });
      const result = await controller.createNote({ ciphertext: 'enc', expiresIn: 3600 });
      expect(result).toEqual({ token: 'abc123' });
      expect(service.create).toHaveBeenCalledWith('enc', 3600);
    });

    it.each([3600, 21600, 43200, 86400])(
      'passes whitelisted TTL %d through unchanged',
      async (ttl) => {
        service.create.mockResolvedValue({ token: 'tok' });
        await controller.createNote({ ciphertext: 'enc', expiresIn: ttl });
        expect(service.create).toHaveBeenCalledWith('enc', ttl);
      },
    );

    it('falls back to 21600 for a non-whitelisted TTL (7200)', async () => {
      service.create.mockResolvedValue({ token: 'tok' });
      await controller.createNote({ ciphertext: 'enc', expiresIn: 7200 });
      expect(service.create).toHaveBeenCalledWith('enc', 21600);
    });

    it.each([0, -1, 60, 3599, 1000000])(
      'falls back to 21600 for out-of-whitelist TTL %d',
      async (ttl) => {
        service.create.mockResolvedValue({ token: 'tok' });
        await controller.createNote({ ciphertext: 'enc', expiresIn: ttl });
        expect(service.create).toHaveBeenCalledWith('enc', 21600);
      },
    );
  });

  describe('getNotePage', () => {
    it('sends HTML when note exists', async () => {
      const future = new Date(Date.now() + 60000);
      service.findByToken.mockResolvedValue({ token: VALID_TOKEN, expiresAt: future });
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      expect(res.send).toHaveBeenCalled();
      const html = res.send.mock.calls[0][0];
      expect(html).toContain('Reveal');
      expect(res.setHeader).toHaveBeenCalledWith(
        'Content-Security-Policy',
        expect.stringContaining("script-src 'nonce-"),
      );
      expect(html).toContain("addEventListener('click', reveal)");
      expect(html).not.toContain('onclick=');
    });

    it('sends destroyed HTML when note not found', async () => {
      service.findByToken.mockResolvedValue(null);
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      expect(res.send).toHaveBeenCalled();
      const html = res.send.mock.calls[0][0];
      expect(html).toContain('no longer exists');
    });

    it('sets Cache-Control no-store on the found-note page', async () => {
      const future = new Date(Date.now() + 60000);
      service.findByToken.mockResolvedValue({ token: VALID_TOKEN, expiresAt: future });
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      expect(res.setHeader).toHaveBeenCalledWith('Cache-Control', 'no-store');
    });

    it('sets Cache-Control no-store on the missing-note page', async () => {
      service.findByToken.mockResolvedValue(null);
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      expect(res.setHeader).toHaveBeenCalledWith('Cache-Control', 'no-store');
    });

    it('landing page unhides the error element with display block', async () => {
      // Regression: display = '' cannot override a stylesheet display:none rule.
      const future = new Date(Date.now() + 60000);
      service.findByToken.mockResolvedValue({ token: VALID_TOKEN, expiresAt: future });
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      const html = res.send.mock.calls[0][0];
      expect(html).toContain("style.display = 'block'");
    });

    it('landing page includes an exit link back to the app', async () => {
      const future = new Date(Date.now() + 60000);
      service.findByToken.mockResolvedValue({ token: VALID_TOKEN, expiresAt: future });
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      const html = res.send.mock.calls[0][0];
      expect(html).toContain('class="applink" href="/"');
    });

    it('destroyed page includes an exit link back to the app', async () => {
      service.findByToken.mockResolvedValue(null);
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      const html = res.send.mock.calls[0][0];
      expect(html).toContain('class="applink" href="/"');
    });

    // Security: token gate runs BEFORE any service/DB hit or HTML interpolation.
    it('rejects an XSS-shaped token without calling findByToken and still hardens headers', async () => {
      const res = mockRes();
      await controller.getNotePage('<script>alert(1)</script>', res);
      // No service/DB call on the reject path.
      expect(service.findByToken).not.toHaveBeenCalled();
      // Served the destroyed page (never the token-interpolated landing page).
      expect(res.send).toHaveBeenCalled();
      const html = res.send.mock.calls[0][0];
      expect(html).toContain('no longer exists');
      expect(html).not.toContain('<script>alert(1)</script>');
      // Hardened headers are still applied even when the token is rejected.
      expect(res.setHeader).toHaveBeenCalledWith(
        'Content-Security-Policy',
        expect.stringContaining("script-src 'nonce-"),
      );
      expect(res.setHeader).toHaveBeenCalledWith('Cache-Control', 'no-store');
    });

    it('serves the destroyed page for every malformed token shape without a service call', async () => {
      for (const token of INVALID_TOKENS) {
        const res = mockRes();
        await controller.getNotePage(token, res);
        const html = res.send.mock.calls[0][0];
        expect(html).toContain('no longer exists');
      }
      expect(service.findByToken).not.toHaveBeenCalled();
    });

    // Burn-order hardening: key validation/import must precede the destructive
    // reveal fetch in the inline script, and the 32-byte key guard must exist.
    it('imports/validates the key before the destructive reveal fetch', async () => {
      const future = new Date(Date.now() + 60000);
      service.findByToken.mockResolvedValue({ token: VALID_TOKEN, expiresAt: future });
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      const html = res.send.mock.calls[0][0];
      const importIdx = html.indexOf('crypto.subtle.importKey');
      const fetchIdx = html.indexOf("fetch('/note/");
      expect(importIdx).toBeGreaterThan(-1);
      expect(fetchIdx).toBeGreaterThan(-1);
      expect(importIdx).toBeLessThan(fetchIdx);
      expect(html).toContain('keyBytes.length !== 32');
    });

    // Round 2: the inline key extraction takes only the part before the first
    // '&', so the trailing &c=/&e= fragment params never corrupt the AES key.
    it('extracts the key as the pre-& segment of the fragment', async () => {
      const future = new Date(Date.now() + 60000);
      service.findByToken.mockResolvedValue({ token: VALID_TOKEN, expiresAt: future });
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      const html = res.send.mock.calls[0][0];
      expect(html).toContain("location.hash.slice(1).split('&')[0]");
    });

    // Round 2: wireAppLinks rewrites every applink to the chat deep link using
    // ONLY the digits captured from the fragment's c= param.
    it('wires applinks to a digits-only notify_conv deep link', async () => {
      const future = new Date(Date.now() + 60000);
      service.findByToken.mockResolvedValue({ token: VALID_TOKEN, expiresAt: future });
      const res = mockRes();
      await controller.getNotePage(VALID_TOKEN, res);
      const html = res.send.mock.calls[0][0];
      // Digits-only capture guards against templating anything but a conv id.
      expect(html).toContain('[#&]c=(\\d+)(&|$)');
      expect(html).toContain('a.applink');
      expect(html).toContain("'/?notify_conv=' + match[1]");
    });
  });

  describe('noteStatus', () => {
    it('reports alive for an existing unexpired note', async () => {
      service.findByToken.mockResolvedValue({
        token: VALID_TOKEN,
        expiresAt: new Date(Date.now() + 60000),
      });
      await expect(controller.noteStatus(VALID_TOKEN)).resolves.toEqual({
        alive: true,
      });
      expect(service.findByToken).toHaveBeenCalledWith(VALID_TOKEN);
    });

    it('reports dead when the note is gone (read or expired)', async () => {
      service.findByToken.mockResolvedValue(null);
      await expect(controller.noteStatus(VALID_TOKEN)).resolves.toEqual({
        alive: false,
      });
    });

    it.each(INVALID_TOKENS)(
      'rejects malformed token %j before any service/DB work',
      async (token) => {
        await expect(controller.noteStatus(token)).resolves.toEqual({
          alive: false,
        });
        expect(service.findByToken).not.toHaveBeenCalled();
      },
    );
  });

  describe('revealNote', () => {
    it('returns ciphertext when note exists', async () => {
      service.revealAndDelete.mockResolvedValue({ ciphertext: 'enc' });
      const res = mockRes();
      await controller.revealNote(VALID_TOKEN, res);
      expect(res.json).toHaveBeenCalledWith({ ciphertext: 'enc' });
    });

    it('returns 404 when note gone', async () => {
      service.revealAndDelete.mockResolvedValue(null);
      const res = mockRes();
      await controller.revealNote(VALID_TOKEN, res);
      expect(res.status).toHaveBeenCalledWith(404);
    });

    // Security: token gate runs BEFORE the destructive revealAndDelete.
    it('returns 404 gone for an XSS-shaped token without calling the service', async () => {
      const res = mockRes();
      await controller.revealNote('<script>alert(1)</script>', res);
      expect(service.revealAndDelete).not.toHaveBeenCalled();
      expect(res.status).toHaveBeenCalledWith(404);
      expect(res.json).toHaveBeenCalledWith({ error: 'gone' });
    });

    it('never reveals for any malformed token shape', async () => {
      for (const token of INVALID_TOKENS) {
        const res = mockRes();
        await controller.revealNote(token, res);
        expect(res.status).toHaveBeenCalledWith(404);
        expect(res.json).toHaveBeenCalledWith({ error: 'gone' });
      }
      expect(service.revealAndDelete).not.toHaveBeenCalled();
    });
  });
});
