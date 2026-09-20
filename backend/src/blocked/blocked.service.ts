import { Injectable, Logger, Inject, forwardRef } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { BlockedUser } from './blocked-user.entity';
import { User } from '../users/user.entity';
import { FriendsService } from '../friends/friends.service';
import { ConversationsService } from '../conversations/conversations.service';
import { MessagesService } from '../messages/messages.service';
import { MediaCleanupService } from '../media/media-cleanup.service';

@Injectable()
export class BlockedService {
  private readonly logger = new Logger(BlockedService.name);

  constructor(
    @InjectRepository(BlockedUser)
    private readonly blockedRepo: Repository<BlockedUser>,
    @Inject(forwardRef(() => FriendsService))
    private readonly friendsService: FriendsService,
    private readonly conversationsService: ConversationsService,
    private readonly messagesService: MessagesService,
    private readonly mediaCleanupService: MediaCleanupService,
  ) {}

  async block(blockerId: number, blockedId: number): Promise<BlockedUser> {
    if (blockerId === blockedId) {
      throw new Error('Cannot block yourself');
    }
    const existing = await this.blockedRepo.findOne({
      where: { blocker: { id: blockerId }, blocked: { id: blockedId } },
    });
    if (existing) {
      // BE-006: the block row is durable but a prior attempt may have committed
      // it and then failed before tearing down the friendship / conversation,
      // leaving a permanent split state the old early-return never healed.
      // Re-run the teardown so tapping Block again self-heals.
      await this.tearDownRelationship(blockerId, blockedId);
      return existing;
    }
    const record = this.blockedRepo.create({
      blocker: { id: blockerId } as User,
      blocked: { id: blockedId } as User,
    });
    await this.blockedRepo.save(record);
    await this.tearDownRelationship(blockerId, blockedId);
    this.logger.debug(`block recorded`);
    return record;
  }

  /**
   * Tear down every relationship artifact between a blocker/blocked pair.
   * Runs on BOTH the fresh-block and the already-blocked (retry) path so a
   * partially-applied block self-heals (BE-006).
   *
   * The friend-request removal is the CRITICAL DB step; its failure propagates
   * so the caller can surface/retry (and a retry re-heals). The conversation +
   * media cleanup stays best-effort and, per backend/CLAUDE.md §8, runs AFTER
   * the DB work and OUTSIDE any transaction: filesystem deletes cannot roll
   * back, so a rollback would leave media already destroyed.
   */
  private async tearDownRelationship(
    blockerId: number,
    blockedId: number,
  ): Promise<void> {
    // BE-101: remove friendship AND any pending/rejected requests for the pair
    // so a blocked user can never be accepted or re-added into a friendship.
    await this.friendsService.removeFriendRequestsForPair(blockerId, blockedId);

    // Delete the conversation and messages so that after unblock + re-add they get a fresh chat.
    try {
      const conv = await this.conversationsService.findByUsers(
        blockerId,
        blockedId,
      );
      if (conv) {
        const mediaUrls =
          await this.messagesService.findMediaUrlsByConversation(conv.id);
        // Media before rows: deleting the conversation cascades the messages,
        // after which the URLs can no longer be resolved (backend/CLAUDE.md §8).
        await Promise.all(
          mediaUrls.map((mediaUrl) =>
            this.mediaCleanupService.deleteMediaFile(mediaUrl),
          ),
        );
        await this.conversationsService.delete(conv.id);
        this.logger.debug(`Block: deleted conversation id=${conv.id}`);
      }
    } catch (err) {
      // BE-103: loud + reconcilable. The friendship rows are already gone; a
      // swallowed failure here orphans the conversation and its encrypted
      // messages, so log both user ids to allow reconciliation by hand.
      this.logger.error(
        `Block: failed to delete conversation (conversation/messages may be orphaned): ${(err as Error)?.message}`,
        (err as Error)?.stack,
      );
    }
  }

  async unblock(blockerId: number, blockedId: number): Promise<boolean> {
    const result = await this.blockedRepo.delete({
      blocker: { id: blockerId },
      blocked: { id: blockedId },
    });
    if (result.affected && result.affected > 0) {
      this.logger.debug(`unblock recorded`);
      return true;
    }
    return false;
  }

  async getBlockedUserIds(blockerId: number): Promise<number[]> {
    const rows = await this.blockedRepo.find({
      where: { blocker: { id: blockerId } },
      relations: {
        blocked: true,
      },
    });
    return rows.map((r) => r.blocked.id);
  }

  /** User IDs who have blocked this user (so we can hide them from their lists). */
  async getBlockedByUserIds(blockedId: number): Promise<number[]> {
    const rows = await this.blockedRepo.find({
      where: { blocked: { id: blockedId } },
      relations: {
        blocker: true,
      },
    });
    return rows.map((r) => r.blocker.id);
  }

  async getBlockedUsers(blockerId: number): Promise<User[]> {
    const rows = await this.blockedRepo.find({
      where: { blocker: { id: blockerId } },
      relations: {
        blocked: true,
      },
    });
    return rows.map((r) => r.blocked);
  }

  /** True if blockerId has blocked blockedId */
  async isBlocked(blockerId: number, blockedId: number): Promise<boolean> {
    const one = await this.blockedRepo.findOne({
      where: { blocker: { id: blockerId }, blocked: { id: blockedId } },
    });
    return !!one;
  }

  /** True if either user has blocked the other. Single query instead of two sequential round-trips. */
  async isBlockedByEither(userId1: number, userId2: number): Promise<boolean> {
    const count = await this.blockedRepo
      .createQueryBuilder('bu')
      .where(
        '(bu.blocker_id = :a AND bu.blocked_id = :b) OR (bu.blocker_id = :b AND bu.blocked_id = :a)',
        { a: userId1, b: userId2 },
      )
      .getCount();
    return count > 0;
  }
}
