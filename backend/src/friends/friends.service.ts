import {
  Injectable,
  ConflictException,
  NotFoundException,
  Logger,
  Inject,
  forwardRef,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { DataSource, Repository } from 'typeorm';
import { FriendRequest, FriendRequestStatus } from './friend-request.entity';
import { User } from '../users/user.entity';
import { BlockedService } from '../blocked/blocked.service';

@Injectable()
export class FriendsService {
  private readonly logger = new Logger(FriendsService.name);

  constructor(
    @InjectRepository(FriendRequest)
    private friendRequestRepository: Repository<FriendRequest>,
    private dataSource: DataSource,
    @Inject(forwardRef(() => BlockedService))
    private blockedService: BlockedService,
  ) {}

  async sendRequest(sender: User, receiver: User): Promise<FriendRequest> {
    if (sender.id === receiver.id) {
      throw new ConflictException('Cannot send friend request to yourself');
    }

    // Check if already friends
    const existingAccepted = await this.friendRequestRepository.findOne({
      where: [
        {
          sender: { id: sender.id },
          receiver: { id: receiver.id },
          status: FriendRequestStatus.ACCEPTED,
        },
        {
          sender: { id: receiver.id },
          receiver: { id: sender.id },
          status: FriendRequestStatus.ACCEPTED,
        },
      ],
    });

    if (existingAccepted) {
      throw new ConflictException('Already friends');
    }

    // Check for duplicate pending request
    const existingPending = await this.friendRequestRepository.findOne({
      where: {
        sender: { id: sender.id },
        receiver: { id: receiver.id },
        status: FriendRequestStatus.PENDING,
      },
    });

    if (existingPending) {
      throw new ConflictException('Friend request already sent');
    }

    // Wrap the check-create-update sequence in a transaction to prevent
    // duplicate ACCEPTED rows when two users call this simultaneously (race condition).
    return await this.dataSource.transaction(async (manager) => {
      // Check for reverse pending request (mutual requests = auto-accept both)
      const reversePending = await manager.findOne(FriendRequest, {
        where: {
          sender: { id: receiver.id },
          receiver: { id: sender.id },
          status: FriendRequestStatus.PENDING,
        },
      });

      // A prior REJECTED row for this exact (sender, receiver) pair collides
      // with the UNIQUE(sender_id, receiver_id) index on re-send, which would
      // surface as a generic "Failed to send friend request". Clear it so a
      // previously-rejected user can be re-added as a fresh request.
      await manager
        .createQueryBuilder()
        .delete()
        .from(FriendRequest)
        .where(
          'sender_id = :senderId AND receiver_id = :receiverId AND status = :status',
          {
            senderId: sender.id,
            receiverId: receiver.id,
            status: FriendRequestStatus.REJECTED,
          },
        )
        .execute();

      // Create the new request
      const newRequest = manager.create(FriendRequest, {
        sender,
        receiver,
        status: FriendRequestStatus.PENDING,
      });

      await manager.save(FriendRequest, newRequest);

      // Auto-accept both if reverse pending exists
      if (reversePending) {
        const now = new Date();
        await manager.update(
          FriendRequest,
          { id: reversePending.id },
          {
            status: FriendRequestStatus.ACCEPTED,
            respondedAt: now,
          },
        );

        await manager.update(
          FriendRequest,
          { id: newRequest.id },
          {
            status: FriendRequestStatus.ACCEPTED,
            respondedAt: now,
          },
        );

        const updated = await manager.findOne(FriendRequest, {
          where: { id: newRequest.id },
          relations: {
            sender: true,
            receiver: true,
          },
        });
        return updated!;
      }

      return newRequest;
    });
  }

  async acceptRequest(
    requestId: number,
    userId: number,
  ): Promise<FriendRequest> {
    const request = await this.friendRequestRepository.findOne({
      where: { id: requestId },
      relations: {
        sender: true,
        receiver: true,
      },
    });

    if (!request) {
      throw new NotFoundException('Friend request not found');
    }

    if (request.receiver.id !== userId) {
      throw new ConflictException('Only receiver can accept this request');
    }

    // BE-101: never let a blocked pair become friends. If either side has
    // blocked the other, refuse the accept even if a stale PENDING row survives.
    if (
      await this.blockedService.isBlockedByEither(
        request.sender.id,
        request.receiver.id,
      )
    ) {
      throw new ConflictException(
        'Cannot accept a request from a blocked user',
      );
    }

    // BE-102: conditional PENDING -> ACCEPTED transition. Without the status
    // predicate a REJECTED row could be resurrected to ACCEPTED, and two
    // concurrent (unthrottled) accept handlers could both apply the update.
    const result = await this.friendRequestRepository.update(
      { id: requestId, status: FriendRequestStatus.PENDING },
      {
        status: FriendRequestStatus.ACCEPTED,
        respondedAt: new Date(),
      },
    );

    if (!result.affected) {
      // No PENDING row transitioned. Reload to tell an idempotent retry
      // (already ACCEPTED by a concurrent handler / double-tap) apart from an
      // illegal transition (REJECTED or gone). Keep the retry path quiet.
      const current = await this.friendRequestRepository.findOne({
        where: { id: requestId },
        relations: {
          sender: true,
          receiver: true,
        },
      });
      if (current && current.status === FriendRequestStatus.ACCEPTED) {
        return current;
      }
      throw new ConflictException('Friend request is no longer pending');
    }

    const updated = await this.friendRequestRepository.findOne({
      where: { id: requestId },
      relations: {
        sender: true,
        receiver: true,
      },
    });
    return updated!;
  }

  async rejectRequest(
    requestId: number,
    userId: number,
  ): Promise<FriendRequest> {
    const request = await this.friendRequestRepository.findOne({
      where: { id: requestId },
      relations: {
        sender: true,
        receiver: true,
      },
    });

    if (!request) {
      throw new NotFoundException('Friend request not found');
    }

    if (request.receiver.id !== userId) {
      throw new ConflictException('Only receiver can reject this request');
    }

    // BE-102: conditional PENDING -> REJECTED transition so an already ACCEPTED
    // friendship cannot be flipped to REJECTED by a late/duplicate reject, and a
    // double-tap reject stays idempotent.
    const result = await this.friendRequestRepository.update(
      { id: requestId, status: FriendRequestStatus.PENDING },
      {
        status: FriendRequestStatus.REJECTED,
        respondedAt: new Date(),
      },
    );

    if (!result.affected) {
      const current = await this.friendRequestRepository.findOne({
        where: { id: requestId },
        relations: {
          sender: true,
          receiver: true,
        },
      });
      if (current && current.status === FriendRequestStatus.REJECTED) {
        return current;
      }
      throw new ConflictException('Friend request is no longer pending');
    }

    const updated = await this.friendRequestRepository.findOne({
      where: { id: requestId },
      relations: {
        sender: true,
        receiver: true,
      },
    });
    return updated!;
  }

  async areFriends(userId1: number, userId2: number): Promise<boolean> {
    const friendship = await this.friendRequestRepository.findOne({
      where: [
        {
          sender: { id: userId1 },
          receiver: { id: userId2 },
          status: FriendRequestStatus.ACCEPTED,
        },
        {
          sender: { id: userId2 },
          receiver: { id: userId1 },
          status: FriendRequestStatus.ACCEPTED,
        },
      ],
    });

    return !!friendship;
  }

  async getPendingRequests(userId: number): Promise<FriendRequest[]> {
    const requests = await this.friendRequestRepository.find({
      where: {
        receiver: { id: userId },
        status: FriendRequestStatus.PENDING,
      },
      relations: {
        sender: true,
        receiver: true,
      },
      order: { createdAt: 'DESC' },
    });

    // BE-101: hide pending requests from anyone the user has blocked or who has
    // blocked the user, so a blocked sender's row can never be accepted from the
    // list. Same block-set convention as the conversation-list filter.
    const [blockedIds, blockedByIds] = await Promise.all([
      this.blockedService.getBlockedUserIds(userId),
      this.blockedService.getBlockedByUserIds(userId),
    ]);
    const excludeSet = new Set([...blockedIds, ...blockedByIds]);
    return requests.filter((r) => !excludeSet.has(r.sender.id));
  }
  async getSentRequests(userId: number): Promise<FriendRequest[]> {
    return this.friendRequestRepository.find({
      where: {
        sender: { id: userId },
        status: FriendRequestStatus.PENDING,
      },
      relations: {
        sender: true,
        receiver: true,
      },
      order: { createdAt: 'DESC' },
    });
  }

  async getFriends(userId: number): Promise<User[]> {
    const friendRequests = await this.friendRequestRepository.find({
      where: [
        {
          sender: { id: userId },
          status: FriendRequestStatus.ACCEPTED,
        },
        {
          receiver: { id: userId },
          status: FriendRequestStatus.ACCEPTED,
        },
      ],
      relations: {
        sender: { profilePhotos: true },
        receiver: { profilePhotos: true },
      },
    });

    const friendIds = new Set<number>();
    friendRequests.forEach((fr) => {
      if (fr.sender.id === userId) {
        friendIds.add(fr.receiver.id);
      } else {
        friendIds.add(fr.sender.id);
      }
    });

    return Array.from(friendIds)
      .map((id) => {
        const request = friendRequests.find(
          (fr) =>
            (fr.sender.id === userId && fr.receiver.id === id) ||
            (fr.receiver.id === userId && fr.sender.id === id),
        );
        if (!request) return null;
        return request.sender.id === userId ? request.receiver : request.sender;
      })
      .filter((f) => f !== null);
  }

  /**
   * Delete EVERY friend_request row between the two users regardless of status
   * or direction. Used by the block flow (BE-101): a surviving PENDING (or
   * REJECTED) row could later be accepted/re-sent into a friendship with a
   * blocked user. Deliberately broader than unfriend(), which removes only
   * ACCEPTED rows for the normal unfriend wire contract (root CLAUDE.md §7).
   */
  async removeFriendRequestsForPair(
    userId1: number,
    userId2: number,
  ): Promise<number> {
    const result = await this.friendRequestRepository
      .createQueryBuilder()
      .delete()
      .from(FriendRequest)
      .where(
        '(sender_id = :a AND receiver_id = :b) OR (sender_id = :b AND receiver_id = :a)',
        { a: userId1, b: userId2 },
      )
      .execute();
    return result.affected ?? 0;
  }

  async unfriend(userId1: number, userId2: number): Promise<boolean> {
    // TypeORM .delete() does NOT support nested relation conditions (sender: { id })
    // so we must find first, then remove by entity instance (uses primary key)
    const friendships = await this.friendRequestRepository.find({
      where: [
        {
          sender: { id: userId1 },
          receiver: { id: userId2 },
          status: FriendRequestStatus.ACCEPTED,
        },
        {
          sender: { id: userId2 },
          receiver: { id: userId1 },
          status: FriendRequestStatus.ACCEPTED,
        },
      ],
    });

    this.logger.debug(
      `unfriend: found ${friendships.length} ACCEPTED records for the pair`,
    );

    if (friendships.length === 0) {
      return false;
    }

    await this.friendRequestRepository.remove(friendships);
    this.logger.debug(`unfriend: removed ${friendships.length} records`);
    return true;
  }

  async getPendingRequestCount(userId: number): Promise<number> {
    return this.friendRequestRepository.countBy({
      receiver: { id: userId },
      status: FriendRequestStatus.PENDING,
    });
  }
}
