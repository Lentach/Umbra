import { Body, Controller, INestApplication, Put } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { contactBackupJsonParser } from './contact-backup-json';

/** What a handler sees of a body; the route is the real path, the handler a probe. */
let reached: Array<{ route: string; size: number }> = [];

@Controller()
class ProbeController {
  @Put('backup/contacts')
  contacts(@Body() body: { blob?: string }) {
    reached.push({ route: 'contacts', size: body?.blob?.length ?? -1 });
    return { ok: true };
  }

  @Put('other')
  other(@Body() body: { blob?: string }) {
    reached.push({ route: 'other', size: body?.blob?.length ?? -1 });
    return { ok: true };
  }
}

describe('contact-backup JSON parser (BE-06)', () => {
  let app: INestApplication;
  let base: string;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      controllers: [ProbeController],
    }).compile();
    app = moduleRef.createNestApplication();
    // The same mount as main.ts, before Nest's own parser.
    app.use('/backup/contacts', contactBackupJsonParser);
    await app.listen(0, '127.0.0.1');
    base = await app.getUrl();
  });

  afterAll(async () => {
    await app.close();
  });

  beforeEach(() => {
    reached = [];
  });

  function put(path: string, chars: number, authorization?: string) {
    return fetch(`${base}${path}`, {
      method: 'PUT',
      headers: {
        'content-type': 'application/json',
        ...(authorization ? { authorization } : {}),
      },
      body: JSON.stringify({ blob: 'x'.repeat(chars) }),
    });
  }

  it('a request with no bearer token is not buffered past the default 100 kb', async () => {
    const res = await put('/backup/contacts', 1_000_000);
    expect(res.status).toBe(413);
    expect(reached).toEqual([]);
  });

  it('a non-bearer scheme gets no more than the default either', async () => {
    const res = await put('/backup/contacts', 1_000_000, 'Basic abc');
    expect(res.status).toBe(413);
    expect(reached).toEqual([]);
  });

  it('a small body with no token still reaches Nest, whose guard answers it', async () => {
    const res = await put('/backup/contacts', 1_000);
    expect(res.status).toBe(200);
    expect(reached).toEqual([{ route: 'contacts', size: 1_000 }]);
  });

  it('a bearer request keeps the 4 MiB room: 3 MB arrives whole', async () => {
    const res = await put(
      '/backup/contacts',
      3_000_000,
      'Bearer some.jwt.here',
    );
    expect(res.status).toBe(200);
    expect(reached).toEqual([{ route: 'contacts', size: 3_000_000 }]);
  });

  it('a bearer request still stops at 4 MiB', async () => {
    const res = await put(
      '/backup/contacts',
      4_500_000,
      'Bearer some.jwt.here',
    );
    expect(res.status).toBe(413);
    expect(reached).toEqual([]);
  });

  it('other routes keep the default limit, bearer or not', async () => {
    const res = await put('/other', 200_000, 'Bearer some.jwt.here');
    expect(res.status).toBe(413);
    expect(reached).toEqual([]);
  });
});
