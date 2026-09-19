import {
  Injectable,
  ConflictException,
  UnauthorizedException,
  NotFoundException,
  BadRequestException,
  Logger,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { DataSource, EntityManager, Repository } from 'typeorm';
import * as bcrypt from 'bcrypt';
import { User } from './user.entity';
import { ProfilePhoto } from './profile-photo.entity';
import { LocalStorageService } from '../media/local-storage.service';
import { Conversation } from '../conversations/conversation.entity';
import { Message } from '../messages/message.entity';
import { FriendRequest } from '../friends/friend-request.entity';
import { FcmTokensService } from '../fcm-tokens/fcm-tokens.service';
import { KeyBundlesService } from '../key-bundles/key-bundles.service';
import { MessagesService } from '../messages/messages.service';
import { MediaCleanupService } from '../media/media-cleanup.service';
import { WebPushSubscriptionsService } from '../web-push-subscriptions/web-push-subscriptions.service';
import { RefreshTokensService } from '../auth/refresh-tokens.service';

@Injectable()
export class UsersService {
  private readonly auditLogger = new Logger('Audit');

  constructor(
    @InjectRepository(User)
    private usersRepo: Repository<User>,
    @InjectRepository(ProfilePhoto)
    private profilePhotoRepo: Repository<ProfilePhoto>,
    private storageService: LocalStorageService,
    private fcmTokensService: FcmTokensService,
    private webPushSubscriptionsService: WebPushSubscriptionsService,
    private keyBundlesService: KeyBundlesService,
    private dataSource: DataSource,
    private messagesService: MessagesService,
    private mediaCleanup: MediaCleanupService,
    private refreshTokensService: RefreshTokensService,
  ) {}

  async create(username: string, password: string): Promise<User> {
    const existing = await this.findByUsername(username);
    if (existing.length > 0) {
      throw new ConflictException('nickname is already taken');
    }
    // Generate random 4-digit tag (1000-9999); retry on (username, tag) collision
    const hash = await bcrypt.hash(password, 10);
    const maxAttempts = 10;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const tag = String(Math.floor(1000 + Math.random() * 9000));
      const existing = await this.findByUsernameAndTag(username, tag);
      if (!existing) {
        const user = this.usersRepo.create({ password: hash, username, tag });
        return this.usersRepo.save(user);
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

  async addProfilePhoto(
    userId: number,
    url: string,
    storageKey: string,
  ): Promise<ProfilePhoto[]> {
    return this.dataSource.transaction(async (manager) => {
      const user = await manager.findOne(User, {
        where: { id: userId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!user) throw new NotFoundException('User not found');

      const photosRepo = manager.getRepository(ProfilePhoto);
      const photos = await photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
      if (photos.length >= 3) {
        throw new BadRequestException(
          'A profile can have at most three photos',
        );
      }
      const saved = await photosRepo.save(
        photosRepo.create({
          userId,
          url,
          storageKey,
          isPrimary: photos.length === 0,
          position: photos.length,
        }),
      );
      if (saved.isPrimary) {
        await manager.update(User, userId, {
          profilePictureUrl: saved.url,
          profilePicturePublicId: saved.storageKey,
        });
      }
      return photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
    });
  }

  async setPrimaryProfilePhoto(
    userId: number,
    photoId: number,
  ): Promise<ProfilePhoto[]> {
    return this.dataSource.transaction(async (manager) => {
      const user = await manager.findOne(User, {
        where: { id: userId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!user) throw new NotFoundException('User not found');

      const photosRepo = manager.getRepository(ProfilePhoto);
      const photos = await photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
      const photo = photos.find(({ id }) => id === photoId);
      if (!photo) throw new NotFoundException('Profile photo not found');

      await this.persistProfilePhotoOrder(manager, userId, photos, [
        photoId,
        ...photos.filter(({ id }) => id !== photoId).map(({ id }) => id),
      ]);
      return photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
    });
  }

  async reorderProfilePhotos(
    userId: number,
    orderedIds: number[],
  ): Promise<ProfilePhoto[]> {
    return this.dataSource.transaction(async (manager) => {
      const user = await manager.findOne(User, {
        where: { id: userId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!user) throw new NotFoundException('User not found');

      const photosRepo = manager.getRepository(ProfilePhoto);
      const photos = await photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
      const photoIds = new Set(photos.map(({ id }) => id));
      const orderedIdSet = new Set(orderedIds);
      if (
        orderedIds.length !== photos.length ||
        orderedIdSet.size !== orderedIds.length ||
        orderedIds.some((id) => !photoIds.has(id))
      ) {
        throw new BadRequestException(
          'orderedIds must contain exactly the user profile photo ids',
        );
      }

      await this.persistProfilePhotoOrder(manager, userId, photos, orderedIds);
      return photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
    });
  }

  private async persistProfilePhotoOrder(
    manager: EntityManager,
    userId: number,
    photos: ProfilePhoto[],
    orderedIds: number[],
  ): Promise<void> {
    const photoById = new Map(photos.map((photo) => [photo.id, photo]));

    await manager.update(ProfilePhoto, { userId }, { isPrimary: false });
    for (const [position, id] of orderedIds.entries()) {
      await manager.update(
        ProfilePhoto,
        { id, userId },
        { position, isPrimary: position === 0 },
      );
    }

    const primaryPhoto = photoById.get(orderedIds[0]);
    await manager.update(User, userId, {
      profilePictureUrl: primaryPhoto?.url ?? null,
      profilePicturePublicId: primaryPhoto?.storageKey ?? null,
    });
  }

  async deleteProfilePhoto(
    userId: number,
    photoId: number,
  ): Promise<ProfilePhoto[]> {
    const photo = await this.profilePhotoRepo.findOne({
      where: { id: photoId, userId },
    });
    if (!photo) throw new NotFoundException('Profile photo not found');
    if (photo.storageKey)
      await this.storageService.deleteAvatar(photo.storageKey);

    return this.dataSource.transaction(async (manager) => {
      const user = await manager.findOne(User, {
        where: { id: userId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!user) throw new NotFoundException('User not found');

      const photosRepo = manager.getRepository(ProfilePhoto);
      const photos = await photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
      if (!photos.some(({ id }) => id === photoId)) {
        throw new NotFoundException('Profile photo not found');
      }

      await manager.delete(ProfilePhoto, { id: photoId, userId });
      const remainingPhotos = photos.filter(({ id }) => id !== photoId);
      await this.persistProfilePhotoOrder(
        manager,
        userId,
        remainingPhotos,
        remainingPhotos.map(({ id }) => id),
      );

      return photosRepo.find({
        where: { userId },
        order: { position: 'ASC', id: 'ASC' },
      });
    });
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
    const isValidPassword = await bcrypt.compare(oldPassword, user.password);
    if (!isValidPassword) {
      throw new UnauthorizedException('Invalid old password');
    }
    await this.setPassword(userId, newPassword, user);
    this.auditLogger.log(`resetPassword success`);
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
    const hash = await bcrypt.hash(newPassword, 10);
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

    const isValidPassword = await bcrypt.compare(password, user.password);
    if (!isValidPassword) {
      throw new UnauthorizedException('Invalid password');
    }

    // Revoke refresh tokens FIRST. Every destructive step below can throw, and
    // if the account survives while its refresh tokens do not it can still mint
    // fresh 24h access JWTs via /auth/refresh. Revoking up front guarantees a
    // mid-way failure over-revokes (session killed) rather than leaving a
    // loginable zombie.
    await this.refreshTokensService.revokeAllForUser(userId);

    // Collect filesystem targets BEFORE the transaction (read-only queries).
    // Message media URLs must be read while the rows still exist; the actual,
    // irreversible unlinks are deferred until AFTER a successful commit so a
    // rolled-back transaction never leaves a half-deleted, still-loginable
    // account whose media/keys are already gone.
    const profilePhotos = await this.getProfilePhotos(userId);
    const storageKeys = new Set(
      [
        user.profilePicturePublicId,
        ...profilePhotos.map((photo) => photo.storageKey),
      ].filter((storageKey): storageKey is string => storageKey != null),
    );

    const conversations = await this.usersRepo.manager.find(Conversation, {
      where: [{ userOne: { id: userId } }, { userTwo: { id: userId } }],
    });
    const mediaUrls: string[] = [];
    for (const conv of conversations) {
      const urls = await this.messagesService.findMediaUrlsByConversation(
        conv.id,
      );
      mediaUrls.push(...urls);
    }

    // All DB deletions in a single transaction to prevent partial deletion.
    // Non-cascading tables (conversations, messages, friend requests) are
    // removed explicitly; fcm tokens, web-push subscriptions and key bundles
    // fall away by ON DELETE CASCADE when the user row is removed here.
    await this.dataSource.transaction(async (manager) => {
      const conversationsInTx = await manager.find(Conversation, {
        where: [{ userOne: { id: userId } }, { userTwo: { id: userId } }],
      });

      for (const conv of conversationsInTx) {
        await manager.delete(Message, { conversation: { id: conv.id } });
        await manager.delete(Conversation, { id: conv.id });
      }

      // Use find-then-remove for friend requests (delete() can't use nested relation conditions)
      const friendRequests = await manager.find(FriendRequest, {
        where: [{ sender: { id: userId } }, { receiver: { id: userId } }],
      });
      if (friendRequests.length > 0) {
        await manager.remove(friendRequests);
      }

      await manager.remove(User, user);
    });

    // Only after the account is durably gone do we run the irreversible external
    // cleanup: side-table purges (idempotent backstop to the FK cascade above)
    // and filesystem unlinks. A failure here cannot resurrect the account.
    await this.fcmTokensService.removeByUserId(userId);
    await this.webPushSubscriptionsService.removeByUserId(userId);
    await this.keyBundlesService.deleteByUserId(userId);
    await Promise.all(
      [...storageKeys].map((storageKey) =>
        this.storageService.deleteAvatar(storageKey),
      ),
    );
    await Promise.all(
      mediaUrls.map((url) => this.mediaCleanup.deleteMediaFile(url)),
    );

    this.auditLogger.log(`deleteAccount success`);
  }
}
