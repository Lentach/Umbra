// backend/src/backup/contact-backup.controller.spec.ts
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import { BadRequestException, ValidationPipe } from '@nestjs/common';
import { GUARDS_METADATA } from '@nestjs/common/constants';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { ContactBackupController } from './contact-backup.controller';
import { ContactBackupService } from './contact-backup.service';
import { PutContactBackupDto } from './dto/contact-backup.dto';

const mockService = () => ({
  get: jest.fn(),
  put: jest.fn(),
});

const SALT = 'c2FsdC1zYWx0LXNhbHQtc2FsdA';
const CK_ID = 'AAAAAAAAAAAAAAAAAAAAAA';
// Both `blob` and `wraps[].ct` are standard base64 (the client's
// `base64Encode`), and the DTO now enforces that charset.
const WRAP_CT = 'd3JhcFB3';
const BLOB = 'c2VhbGVk';

const fakeReq = { user: { id: 42 } };

// Decorator metadata hangs off the FUNCTION OBJECT on the prototype; read it
// through the property descriptor so nothing is treated as an unbound method
// call (same pattern as media.controller.spec.ts).
function controllerMethod(name: 'getContacts' | 'putContacts'): object {
  const descriptor = Object.getOwnPropertyDescriptor(
    ContactBackupController.prototype,
    name,
  );
  const value: unknown = descriptor?.value;
  if (typeof value !== 'function') {
    throw new Error(
      `ContactBackupController.prototype.${name} is not a method.`,
    );
  }
  return value;
}

describe('ContactBackupController', () => {
  let controller: ContactBackupController;
  let service: ReturnType<typeof mockService>;

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      imports: [ThrottlerModule.forRoot([{ ttl: 60000, limit: 100 }])],
      controllers: [ContactBackupController],
      providers: [{ provide: ContactBackupService, useFactory: mockService }],
    }).compile();

    controller = module.get(ContactBackupController);
    service = module.get(ContactBackupService);
  });

  it('guards both routes with JWT auth', () => {
    for (const methodName of ['getContacts', 'putContacts'] as const) {
      const guards: unknown = Reflect.getMetadata(
        GUARDS_METADATA,
        controllerMethod(methodName),
      );

      expect(Array.isArray(guards)).toBe(true);
      expect(guards).toContain(JwtAuthGuard);
    }
  });

  it('reads the account from the JWT, never from the body', async () => {
    const dto: PutContactBackupDto = {
      v: 1,
      baseRev: 0,
      salt: SALT,
      ckId: CK_ID,
      wraps: [{ kind: 'password', ct: WRAP_CT }],
      blob: BLOB,
    };
    service.put.mockResolvedValue({ rev: 1, updatedAt: new Date() });

    await controller.putContacts(dto, fakeReq);

    expect(service.put).toHaveBeenCalledWith(42, dto);
    await controller.getContacts(fakeReq);
    expect(service.get).toHaveBeenCalledWith(42);
  });

  it('strips a body-supplied userId before the controller sees it', async () => {
    // The global pipe is `new ValidationPipe({ whitelist: true })` (main.ts):
    // a hostile body cannot smuggle another account's id into the DTO.
    const sanitized: unknown = await new ValidationPipe({
      whitelist: true,
    }).transform(
      {
        v: 1,
        baseRev: 0,
        salt: SALT,
        ckId: CK_ID,
        wraps: [{ kind: 'password', ct: WRAP_CT }],
        blob: BLOB,
        userId: 99,
      },
      { type: 'body', metatype: PutContactBackupDto },
    );

    expect(sanitized).not.toHaveProperty('userId');
  });

  it('throttles the PUT at the client debounce, well under the GET', () => {
    // @Throttle metadata lives on the route handler under THROTTLER:<key><name>.
    const limit = (fn: object): unknown =>
      Reflect.getMetadata('THROTTLER:LIMITdefault', fn);
    const ttl = (fn: object): unknown =>
      Reflect.getMetadata('THROTTLER:TTLdefault', fn);

    // A write rewrites a 2 MB TOAST column, and the client debounces uploads
    // by 5 s — a permissive PUT limit only buys an authenticated account
    // cheap WAL and dead-tuple churn. Reads are a cheap single-row select.
    expect(limit(controllerMethod('putContacts'))).toBe(10);
    expect(ttl(controllerMethod('putContacts'))).toBe(60000);
    expect(limit(controllerMethod('getContacts'))).toBe(30);
    expect(ttl(controllerMethod('getContacts'))).toBe(60000);
  });

  it('accepts only base64 in blob and in every wrap ct', async () => {
    // Without a charset the endpoint is a 2,000,000-char key-value store for
    // any registered account: a length cap alone never says "ciphertext".
    // The client emits standard base64 with padding (frontend
    // contact_backup.dart `sealPayload` and `wrap`), so nothing else is a
    // backup this server should be storing.
    const body = (over: object) => ({
      v: 1,
      baseRev: 0,
      salt: SALT,
      ckId: CK_ID,
      wraps: [{ kind: 'password', ct: WRAP_CT }],
      blob: BLOB,
      ...over,
    });
    const validate = (over: object): Promise<unknown> =>
      new ValidationPipe({ whitelist: true }).transform(body(over), {
        type: 'body',
        metatype: PutContactBackupDto,
      });

    await expect(validate({ blob: 'c2VhbGVkIQ==' })).resolves.toMatchObject({
      blob: 'c2VhbGVkIQ==',
    });

    // base64url, a stray space, over-padding, and raw JSON — every one of
    // them is something the client cannot have produced.
    for (const blob of ['sealed-blob_x', 'sealed blob', 'c2VhbGVk===', '{}']) {
      await expect(validate({ blob })).rejects.toThrow(BadRequestException);
    }
    await expect(
      validate({ wraps: [{ kind: 'password', ct: 'wrap pw!' }] }),
    ).rejects.toThrow(BadRequestException);
  });
});
