// backend/src/backup/contact-backup.controller.spec.ts
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import { ValidationPipe } from '@nestjs/common';
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
      wraps: [{ kind: 'password', ct: 'wrap-pw' }],
      blob: 'sealed',
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
        wraps: [{ kind: 'password', ct: 'wrap-pw' }],
        blob: 'sealed',
        userId: 99,
      },
      { type: 'body', metatype: PutContactBackupDto },
    );

    expect(sanitized).not.toHaveProperty('userId');
  });
});
