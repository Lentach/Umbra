import {
  Injectable,
  ConflictException,
  UnauthorizedException,
  NotFoundException,
  ForbiddenException,
  Logger,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { hashPassword, verifyPassword } from '../auth-core/password-hash';
import { User } from './user.entity';
import { ProfilePhoto } from './profile-photo.entity';
import { LocalStorageService } from '../media/local-storage.service';
import { RefreshTokensService } from '../refresh-tokens/refresh-tokens.service';

/** Postgres unique-violation SQLSTATE. */
const PG_UNIQUE_VIOLATION = '23505';
/** Migration 0031: unique `LOWER(username)`. */
const LOWER_USERNAME_INDEX = 'UQ_users_lower_username';

/**
 * The violated constraint's name when `error` is a Postgres 23505 (TypeORM
 * wraps the driver error as `driverError`), else null.
 */
function uniqueViolationConstraint(error: unknown): string | null {
  if (typeof error !== 'object' || error === null) return null;
  const driverError: unknown =
    'driverError' in error ? error.driverError : error;
  if (
    typeof driverError === 'object' &&
    driverError !== null &&
    'code' in driverError &&
    driverError.code === PG_UNIQUE_VIOLATION
  ) {
    return 'constraint' in driverError &&
      typeof driverError.constraint === 'string'
      ? driverError.constraint
      : '';
  }
  return null;
}

@Injectable()
export class UsersService {
  private readonly auditLogger = new Logger('Audit');

  constructor(
    @InjectRepository(User)
    private usersRepo: Repository<User>,
    @InjectRepository(ProfilePhoto)
    private profilePhotoRepo: Repository<ProfilePhoto>,
    private storageService: LocalStorageService,
    private refreshTokensService: RefreshTokensService,
  ) {}

  private readonly accountDeletedListeners: Array<(userId: number) => void> =
    [];

  /** Called with the id right after an account's row is deleted. */
  onAccountDeleted(listener: (userId: number) => void): void {
    this.accountDeletedListeners.push(listener);
  }

  async create(username: string, password: string): Promise<User> {
    const existing = await this.findByUsername(username);
    if (existing.length > 0) {
      throw new ConflictException('nickname is already taken');
    }
    // Generate random 4-digit tag (1000-9999); retry on (username, tag) collision
    const hash = await hashPassword(password);
    const maxAttempts = 10;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const tag = String(Math.floor(1000 + Math.random() * 9000));
      const existing = await this.findByUsernameAndTag(username, tag);
      if (!existing) {
        const user = this.usersRepo.create({ password: hash, username, tag });
        try {
          return await this.usersRepo.save(user);
        } catch (error) {
          // A concurrent registration won between the checks and the insert.
          const constraint = uniqueViolationConstraint(error);
          if (constraint === LOWER_USERNAME_INDEX) {
            // Same answer as the check above: no new "does this name exist" oracle.
            throw new ConflictException('nickname is already taken');
          }
          if (constraint !== null) continue; // (username, tag) taken: draw the tag again
          throw error;
        }
      }
    }
    throw new ConflictException(
      'Could not generate unique tag, please try again',
    );
  }

  async findById(id: number): Promise<User | null> {
    return this.usersRepo.findOne({ where: { id } });
  }

  async findProfileById(id: number): Promise<User | null> {
    return this.usersRepo.findOne({
      where: { id },
      relations: { profilePhotos: true },
    });
  }

  async findByUsername(username: string): Promise<User[]> {
    return this.usersRepo
      .createQueryBuilder('user')
      .where('LOWER(user.username) = LOWER(:username)', { username })
      .getMany();
  }

  async findByUsernameAndTag(
    username: string,
    tag: string,
  ): Promise<User | null> {
    return this.usersRepo
      .createQueryBuilder('user')
      .where('LOWER(user.username) = LOWER(:username)', { username })
      .andWhere('user.tag = :tag', { tag })
      .getOne();
  }

  async updateProfileAbout(
    userId: number,
    about: string | null,
  ): Promise<User> {
    const user = await this.findById(userId);
    if (!user) throw new NotFoundException('User not found');
    user.about = about?.trim() || null;
    return this.usersRepo.save(user);
  }

  async getProfilePhotos(userId: number): Promise<ProfilePhoto[]> {
    return this.profilePhotoRepo.find({
      where: { userId },
      order: { position: 'ASC', id: 'ASC' },
    });
  }

  /**
   * LOGIN's check: verifies `plain` against the account's stored hash and, when
   * it is valid but still bcrypt (or old Argon2 parameters), stores a fresh
   * Argon2id hash. Every other door uses {@link passwordMatches}: they must not
   * write (`verifyPassword`, decision R76), or are about to replace/delete the row.
   * Only the `password` column changes: `passwordChangedAt` stays, so no
   * session is dropped. The write is conditional on the hash we just read, so a
   * concurrent password change is never overwritten.
   */
  async checkPassword(user: User, plain: string): Promise<boolean> {
    const verdict = await verifyPassword(plain, user.password);
    if (verdict.valid && verdict.needsRehash) {
      const fresh = await hashPassword(plain);
      await this.usersRepo.update(
        { id: user.id, password: user.password },
        { password: fresh },
      );
      user.password = fresh;
    }
    return verdict.valid;
  }

  private async passwordMatches(user: User, plain: string): Promise<boolean> {
    return (await verifyPassword(plain, user.password)).valid;
  }

  async resetPassword(
    userId: number,
    oldPassword: string,
    newPassword: string,
  ): Promise<void> {
    const user = await this.findById(userId);
    if (!user) {
      throw new NotFoundException('User not found');
    }

    // Verify old password
    const isValidPassword = await this.passwordMatches(user, oldPassword);
    if (!isValidPassword) {
      throw new UnauthorizedException('Invalid old password');
    }
    await this.setPassword(userId, newPassword, user);
    this.auditLogger.log(`resetPassword success`);
  }

  /**
   * Answers whether `password` is the account's current password, and nothing
   * else: no token, no session, no `passwordChangedAt`, no write of any kind.
   * The client checks a typed password here before deriving the contact-backup
   * wrap from it (metadata-privacy decision R76) — a wrap minted from a typo
   * would be one the real password can never open.
   */
  async verifyPassword(userId: number, password: string): Promise<void> {
    const user = await this.findById(userId);
    if (!user) {
      throw new NotFoundException('User not found');
    }

    const isValidPassword = await this.passwordMatches(user, password);
    if (!isValidPassword) {
      throw new ForbiddenException({ error: 'wrong_password' });
    }
  }

  /**
   * Stores a new password for an already-AUTHORIZED change (the caller proved
   * the old password, or the recovery phrase — spec §12 amendment (lxxxii)).
   *
   * Revoke every refresh token BEFORE stamping passwordChangedAt (stamped
   * last). A refresh token stolen before the reset must not be exchangeable
   * for a fresh 24h access JWT in the window between the stamp landing and
   * the revoke: /auth/refresh finds no row once revocation ran first. Doing
   * the revoke first also means a partial failure over-revokes (all sessions
   * dropped) rather than leaving a usable stolen token behind.
   */
  async setPassword(
    userId: number,
    newPassword: string,
    loaded?: User,
  ): Promise<Date> {
    const user = loaded ?? (await this.findById(userId));
    if (!user) {
      throw new NotFoundException('User not found');
    }
    const hash = await hashPassword(newPassword);
    await this.refreshTokensService.revokeAllForUser(userId);
    user.password = hash;
    user.passwordChangedAt = new Date();
    await this.usersRepo.save(user);
    return user.passwordChangedAt;
  }

  async deleteAccount(userId: number, password: string): Promise<void> {
    const user = await this.findById(userId);
    if (!user) {
      throw new NotFoundException('User not found');
    }

    const isValidPassword = await this.passwordMatches(user, password);
    if (!isValidPassword) {
      throw new UnauthorizedException('Invalid password');
    }

    // Revoke refresh tokens FIRST. Every destructive step below can throw, and
    // if the account survives while its refresh tokens do not it can still mint
    // fresh 24h access JWTs via /auth/refresh. Revoking up front guarantees a
    // mid-way failure over-revokes (session killed) rather than leaving a
    // loginable zombie.
    await this.refreshTokensService.revokeAllForUser(userId);

    // Collect filesystem targets BEFORE the removal (read-only query). The
    // actual, irreversible unlinks are deferred until AFTER a successful
    // commit so a failed removal never leaves a half-deleted, still-loginable
    // account whose avatars/keys are already gone.
    const profilePhotos = await this.getProfilePhotos(userId);
    const storageKeys = new Set(
      [
        user.profilePicturePublicId,
        ...profilePhotos.map((photo) => photo.storageKey),
      ].filter((storageKey): storageKey is string => storageKey != null),
    );

    // Every table that points at the user (key bundles, one-time pre-keys,
    // devices, profile photos, recovery/identity rows, contact backup) falls
    // away by ON DELETE CASCADE when the user row is removed. The old chat
    // tables are gone (Phase 4 step 5), so this is one statement.
    await this.usersRepo.remove(user);

    // The row is gone: tell the realtime layer (it drops the account's
    // sockets). A listener failing must not undo or fail the delete.
    for (const listener of this.accountDeletedListeners) {
      try {
        listener(userId);
      } catch {
        // best effort
      }
    }

    // Only after the account is durably gone do we run the irreversible
    // avatar unlinks. A failure here cannot resurrect the account.
    await Promise.all(
      [...storageKeys].map((storageKey) =>
        this.storageService.deleteAvatar(storageKey),
      ),
    );

    this.auditLogger.log(`deleteAccount success`);
  }
}
