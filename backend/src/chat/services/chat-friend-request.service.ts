import { ConflictException, Injectable, Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { userRoom, isUserOnline } from '../utils/user-room';
import { FriendsService } from '../../friends/friends.service';
import { BlockedService } from '../../blocked/blocked.service';
import { UsersService } from '../../users/users.service';
import { User } from '../../users/user.entity';
import { ConversationsService } from '../../conversations/conversations.service';
import { Conversation } from '../../conversations/conversation.entity';
import { MessagesService } from '../../messages/messages.service';
import { MediaCleanupService } from '../../media/media-cleanup.service';
import { validateDto } from '../utils/dto.validator';
import {
  SendFriendRequestDto,
  AcceptFriendRequestDto,
  RejectFriendRequestDto,
  UnfriendDto,
  EnsureInvitationChatDto,
} from '../dto/chat.dto';
import { FriendRequestMapper } from '../mappers/friend-request.mapper';
import { UserMapper } from '../mappers/user.mapper';
import {
  FriendRequest,
  FriendRequestStatus,
} from '../../friends/friend-request.entity';
import { ChatConversationService } from './chat-conversation.service';
import { ChatValidationService } from './chat-validation.service';

@Injectable()
export class ChatFriendRequestService {
  private readonly logger = new Logger(ChatFriendRequestService.name);

  constructor(
    private readonly friendsService: FriendsService,
    private readonly blockedService: BlockedService,
    private readonly usersService: UsersService,
    private readonly conversationsService: ConversationsService,
    private readonly messagesService: MessagesService,
    private readonly mediaCleanup: MediaCleanupService,
    private readonly chatConversationService: ChatConversationService,
    private readonly chatValidationService: ChatValidationService,
  ) {}

  /** Emit friendsList to client and optionally to another socket. */
  private async emitFriendsListToBoth(
    client: Socket,
    server: Server,
    clientUserId: number,
    otherUserId: number | undefined,
  ): Promise<void> {
    try {
      const clientFriends = await this.friendsService.getFriends(clientUserId);
      client.emit(
        'friendsList',
        clientFriends.map((u) => UserMapper.toPayload(u)),
      );
      if (otherUserId != null && isUserOnline(server, otherUserId)) {
        const otherFriends = await this.friendsService.getFriends(otherUserId);
        server.to(userRoom(otherUserId)).emit(
          'friendsList',
          otherFriends.map((u) => UserMapper.toPayload(u)),
        );
      }
    } catch (error) {
      this.logger.error('emitFriendsListToBoth (non-critical):', error);
    }
  }

  /** Emit conversationsList to client and optionally to another socket.
   *  Uses the same unread-count + blocked-user filtering as handleGetConversations. */
  private async emitConversationsListToBoth(
    client: Socket,
    server: Server,
    clientUserId: number,
    otherUserId: number | undefined,
  ): Promise<void> {
    try {
      const clientList = await this._buildConversationsList(clientUserId);
      client.emit('conversationsList', clientList);
      if (otherUserId != null && isUserOnline(server, otherUserId)) {
        const otherList = await this._buildConversationsList(otherUserId);
        server.to(userRoom(otherUserId)).emit('conversationsList', otherList);
      }
    } catch (error) {
      this.logger.error('emitConversationsListToBoth (non-critical):', error);
    }
  }

  /** Build the conversation list payload for a user, including unread counts and blocked-user filtering. */
  private async _buildConversationsList(userId: number): Promise<any[]> {
    const [rawConvs, blockedIds, blockedByUserIds] = await Promise.all([
      this.conversationsService.findByUser(userId),
      this.blockedService.getBlockedUserIds(userId),
      this.blockedService.getBlockedByUserIds(userId),
    ]);
    const excludeSet = new Set([...blockedIds, ...blockedByUserIds]);
    const filtered = rawConvs.filter((conv) => {
      const otherId =
        conv.userOne.id === userId ? conv.userTwo.id : conv.userOne.id;
      return !excludeSet.has(otherId);
    });
    return this.chatConversationService.conversationsWithUnread(
      filtered,
      userId,
    );
  }

  /** Emit pendingRequestsCount to client and optionally to another socket. */
  private async emitPendingCountToBoth(
    client: Socket,
    server: Server,
    clientUserId: number,
    otherUserId: number | undefined,
  ): Promise<void> {
    try {
      const clientCount =
        await this.friendsService.getPendingRequestCount(clientUserId);
      client.emit('pendingRequestsCount', { count: clientCount });
      if (otherUserId != null && isUserOnline(server, otherUserId)) {
        const otherCount =
          await this.friendsService.getPendingRequestCount(otherUserId);
        server
          .to(userRoom(otherUserId))
          .emit('pendingRequestsCount', { count: otherCount });
      }
    } catch (error) {
      this.logger.error('emitPendingCountToBoth (non-critical):', error);
    }
  }

  /** Emit sentRequestsList to client and optionally to another socket. */
  private async emitSentRequestsListToBoth(
    client: Socket,
    server: Server,
    clientUserId: number,
    otherUserId: number | undefined,
  ): Promise<void> {
    try {
      const clientSentRequests =
        await this.friendsService.getSentRequests(clientUserId);
      client.emit(
        'sentRequestsList',
        clientSentRequests.map(FriendRequestMapper.toPayload),
      );
      if (otherUserId != null && isUserOnline(server, otherUserId)) {
        const otherSentRequests =
          await this.friendsService.getSentRequests(otherUserId);
        server
          .to(userRoom(otherUserId))
          .emit(
            'sentRequestsList',
            otherSentRequests.map(FriendRequestMapper.toPayload),
          );
      }
    } catch (error) {
      this.logger.error('emitSentRequestsListToBoth (non-critical):', error);
    }
  }

  /** Emit full auto-accept flow with conversation readiness and refreshed lists. */
  private async emitAutoAcceptFlow(
    client: Socket,
    server: Server,
    sender: User,
    recipient: User,
    payload: any,
  ): Promise<void> {
    let conversation: { id: number } | null = null;
    try {
      conversation = await this.conversationsService.findOrCreate(
        sender,
        recipient,
      );
      this.logger.debug(
        `Auto-accept: conversation created/found id=${conversation.id}`,
      );
    } catch (error) {
      this.logger.error(
        'emitAutoAcceptFlow: findOrCreate (non-critical):',
        error,
      );
    }

    await this.emitConversationsListToBoth(
      client,
      server,
      sender.id,
      recipient.id,
    );

    const acceptedPayload = {
      ...payload,
      conversationId: conversation?.id ?? null,
      chatReady: conversation !== null,
    };
    try {
      client.emit('friendRequestAccepted', acceptedPayload);
      server
        .to(userRoom(recipient.id))
        .emit('friendRequestAccepted', acceptedPayload);
    } catch (error) {
      this.logger.error(
        'emitAutoAcceptFlow: friendRequestAccepted (non-critical):',
        error,
      );
    }

    await this.emitFriendsListToBoth(client, server, sender.id, recipient.id);
    await this.emitSentRequestsListToBoth(
      client,
      server,
      sender.id,
      recipient.id,
    );
    await this.emitPendingCountToBoth(client, server, sender.id, recipient.id);
  }

  async handleSendFriendRequest(client: Socket, data: unknown, server: Server) {
    const senderId: number = client.data.user?.id;
    if (!senderId) return;

    // A typed local instead of the old `data = dto` reassignment: rebinding the
    // `any` parameter kept every downstream read unsafe, and the new scoped
    // failure emits read `recipientId` off it.
    let dto: SendFriendRequestDto;
    try {
      dto = validateDto(SendFriendRequestDto, data);
    } catch {
      let recipientId: number | null = null;
      if (data !== null && typeof data === 'object' && 'recipientId' in data) {
        const candidate = data.recipientId;
        if (typeof candidate === 'number') recipientId = candidate;
      }
      client.emit('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId,
        reason: 'invalid_payload',
      });
      return;
    }

    const sender = await this.usersService.findById(senderId);
    const recipient = await this.usersService.findById(dto.recipientId);

    if (!sender || !recipient) {
      client.emit('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: dto.recipientId,
        reason: 'user_not_found',
      });
      return;
    }
    if (recipient.id === senderId) {
      client.emit('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: dto.recipientId,
        reason: 'self_request',
      });
      return;
    }

    // If recipient has blocked sender, do not allow the request
    const recipientBlockedSender = await this.blockedService.isBlocked(
      recipient.id,
      sender.id,
    );
    if (recipientBlockedSender) {
      client.emit('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: dto.recipientId,
        reason: 'blocked',
      });
      return;
    }

    // Step 2: Send friend request (CRITICAL - if this fails, entire operation fails)
    let friendRequest: any;
    let payload: any;
    try {
      this.logger.debug(
        `sendFriendRequest: sender=${sender.username} (id=${sender.id}), recipient=${recipient.username} (id=${recipient.id})`,
      );
      friendRequest = await this.friendsService.sendRequest(sender, recipient);
      this.logger.debug(
        `sendFriendRequest: created request id=${friendRequest.id}, status=${friendRequest.status}`,
      );

      payload = FriendRequestMapper.toPayload(friendRequest);
    } catch (error) {
      this.logger.error(`sendFriendRequest: Failed to send request:`, error);
      const reason =
        error instanceof ConflictException &&
        error.message === 'Already friends'
          ? 'already_friends'
          : error instanceof ConflictException &&
              error.message === 'Friend request already sent'
            ? 'duplicate_request'
            : 'invalid_payload';
      client.emit('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: dto.recipientId,
        reason,
      });
      return;
    }

    // Check if it was auto-accepted (mutual request scenario)
    if (friendRequest.status === FriendRequestStatus.ACCEPTED) {
      this.logger.debug(
        `Auto-accept: ${sender.username} <-> ${recipient.username}`,
      );
      await this.emitAutoAcceptFlow(client, server, sender, recipient, payload);
    } else {
      // Normal pending request flow
      // Step 4a: Notify sender (important but not critical)
      try {
        this.logger.debug(
          `sendFriendRequest: emitting friendRequestSent to sender ${sender.username}`,
        );
        client.emit('friendRequestSent', payload);
        const sentRequests =
          await this.friendsService.getSentRequests(senderId);
        client.emit(
          'sentRequestsList',
          sentRequests.map(FriendRequestMapper.toPayload),
        );
      } catch (error) {
        this.logger.error(
          'sendFriendRequest: Failed to emit friendRequestSent (non-critical):',
          error,
        );
      }

      // Step 4b: Notify recipient (non-critical). newFriendRequest is a pure
      // emit, so it goes to the per-user room unconditionally: a safe no-op
      // when the recipient is offline, and delivered to every open tab (BE-007).
      // The pending-count refresh runs a DB query, so it stays gated on presence
      // to avoid work no live socket would consume.
      try {
        const recipientOnline = isUserOnline(server, recipient.id);
        this.logger.debug(
          `sendFriendRequest: recipient ${recipient.username} (id=${recipient.id}) online=${recipientOnline}`,
        );
        server.to(userRoom(recipient.id)).emit('newFriendRequest', payload);
        if (recipientOnline) {
          const count = await this.friendsService.getPendingRequestCount(
            recipient.id,
          );
          server
            .to(userRoom(recipient.id))
            .emit('pendingRequestsCount', { count });
          this.logger.debug(
            `sendFriendRequest: emitted newFriendRequest + pendingRequestsCount(${count}) to recipient`,
          );
        }
      } catch (error) {
        this.logger.error(
          'sendFriendRequest: Failed to notify recipient (non-critical):',
          error,
        );
      }
    }
  }

  async handleAcceptFriendRequest(
    client: Socket,
    data: unknown,
    server: Server,
  ) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    let dto: AcceptFriendRequestDto;
    try {
      dto = validateDto(AcceptFriendRequestDto, data);
    } catch {
      let requestId: number | null = null;
      if (data !== null && typeof data === 'object' && 'requestId' in data) {
        const candidate = data.requestId;
        if (typeof candidate === 'number') requestId = candidate;
      }
      client.emit('friendRequestFailed', {
        action: 'accept',
        requestId,
        recipientId: null,
        reason: 'invalid_payload',
      });
      return;
    }

    // Step 1: Accept the friend request (CRITICAL - if this fails, entire operation fails)
    let friendRequest: FriendRequest;
    try {
      this.logger.debug(`acceptFriendRequest: requestId=${dto.requestId}`);
      friendRequest = await this.friendsService.acceptRequest(
        dto.requestId,
        userId,
      );
      this.logger.debug(
        `acceptFriendRequest: accepted, sender=${friendRequest.sender.id} (${friendRequest.sender.username}), receiver=${friendRequest.receiver.id} (${friendRequest.receiver.username})`,
      );
    } catch (error) {
      this.logger.error(
        'acceptFriendRequest: Failed to accept request:',
        error,
      );
      client.emit('friendRequestFailed', {
        action: 'accept',
        requestId: dto.requestId,
        recipientId: null,
        reason: 'accept_failed',
      });
      return;
    }

    // Step 2: Create conversation (important but not critical - partial success possible)
    let conversation: { id: number } | null = null;
    try {
      const senderUser = await this.usersService.findById(
        friendRequest.sender.id,
      );
      const receiverUser = await this.usersService.findById(
        friendRequest.receiver.id,
      );
      if (senderUser && receiverUser) {
        conversation = await this.conversationsService.findOrCreate(
          senderUser,
          receiverUser,
        );
        this.logger.debug(
          `acceptFriendRequest: conversation id=${conversation.id}`,
        );
      }
    } catch (error) {
      this.logger.error(
        'acceptFriendRequest: Failed to create conversation (non-critical):',
        error,
      );
      // Continue - users are friends even if conversation creation failed
    }

    // Step 3: Refresh conversations list (non-critical)
    await this.emitConversationsListToBoth(
      client,
      server,
      userId,
      friendRequest.sender.id,
    );

    const acceptedPayload = {
      ...FriendRequestMapper.toPayload(friendRequest),
      conversationId: conversation?.id ?? null,
      chatReady: conversation !== null,
    };
    client.emit('friendRequestAccepted', acceptedPayload);
    server
      .to(userRoom(friendRequest.sender.id))
      .emit('friendRequestAccepted', acceptedPayload);

    // Step 4: Update friend requests list and pending count (non-critical)
    try {
      const pendingRequests =
        await this.friendsService.getPendingRequests(userId);
      client.emit(
        'friendRequestsList',
        pendingRequests.map(FriendRequestMapper.toPayload),
      );
      const sentRequests = await this.friendsService.getSentRequests(userId);
      client.emit(
        'sentRequestsList',
        sentRequests.map(FriendRequestMapper.toPayload),
      );
      if (isUserOnline(server, friendRequest.sender.id)) {
        const senderSentRequests = await this.friendsService.getSentRequests(
          friendRequest.sender.id,
        );
        server
          .to(userRoom(friendRequest.sender.id))
          .emit(
            'sentRequestsList',
            senderSentRequests.map(FriendRequestMapper.toPayload),
          );
      }
      const pendingCount =
        await this.friendsService.getPendingRequestCount(userId);
      client.emit('pendingRequestsCount', { count: pendingCount });
    } catch (error) {
      this.logger.error(
        'acceptFriendRequest: friend requests list (non-critical):',
        error,
      );
    }

    // Step 5: Emit updated friends lists (non-critical)
    await this.emitFriendsListToBoth(
      client,
      server,
      userId,
      friendRequest.sender.id,
    );
  }

  async handleRejectFriendRequest(
    client: Socket,
    data: unknown,
    server: Server,
  ) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    let dto: RejectFriendRequestDto;
    try {
      dto = validateDto(RejectFriendRequestDto, data);
    } catch {
      const requestId =
        typeof data === 'object' &&
        data !== null &&
        'requestId' in data &&
        typeof data.requestId === 'number'
          ? data.requestId
          : null;
      client.emit('friendRequestFailed', {
        action: 'reject',
        requestId,
        recipientId: null,
        reason: 'invalid_payload',
      });
      return;
    }

    let friendRequest: FriendRequest;
    try {
      friendRequest = await this.friendsService.rejectRequest(
        dto.requestId,
        userId,
      );
    } catch (error) {
      this.logger.error(
        'rejectFriendRequest: Failed to reject request:',
        error,
      );
      client.emit('friendRequestFailed', {
        action: 'reject',
        requestId: dto.requestId,
        recipientId: null,
        reason: 'reject_failed',
      });
      return;
    }

    const payload = FriendRequestMapper.toPayload(friendRequest);
    client.emit('friendRequestRejected', payload);

    const pendingRequests =
      await this.friendsService.getPendingRequests(userId);
    client.emit(
      'friendRequestsList',
      pendingRequests.map(FriendRequestMapper.toPayload),
    );
    const sentRequests = await this.friendsService.getSentRequests(userId);
    client.emit(
      'sentRequestsList',
      sentRequests.map(FriendRequestMapper.toPayload),
    );

    if (isUserOnline(server, friendRequest.sender.id)) {
      const senderSentRequests = await this.friendsService.getSentRequests(
        friendRequest.sender.id,
      );
      server
        .to(userRoom(friendRequest.sender.id))
        .emit(
          'sentRequestsList',
          senderSentRequests.map(FriendRequestMapper.toPayload),
        );
    }

    const pendingCount =
      await this.friendsService.getPendingRequestCount(userId);
    client.emit('pendingRequestsCount', { count: pendingCount });
  }

  async handleEnsureInvitationChat(
    client: Socket,
    data: unknown,
    server: Server,
  ) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    let dto: EnsureInvitationChatDto;
    try {
      dto = validateDto(EnsureInvitationChatDto, data);
    } catch {
      // Correlate the failure to a peer when the raw payload at least carries a
      // usable id, so the client can clear exactly that row's retry state. Only a
      // peer id that is itself unusable leaves this null, in which case the client
      // surfaces the failure without touching any row.
      let recipientId: number | null = null;
      if (data !== null && typeof data === 'object' && 'peerUserId' in data) {
        const candidate = data.peerUserId;
        if (
          typeof candidate === 'number' &&
          Number.isInteger(candidate) &&
          candidate > 0
        ) {
          recipientId = candidate;
        }
      }
      client.emit('friendRequestFailed', {
        action: 'ensure_chat',
        requestId: null,
        recipientId,
        reason: 'invalid_payload',
      });
      return;
    }

    const validation = await this.chatValidationService.validateCanMessage(
      userId,
      dto.peerUserId,
    );
    if (!validation.valid) {
      client.emit('invitationChatReady', {
        peerUserId: dto.peerUserId,
        correlationId: dto.correlationId,
        conversationId: null,
        chatReady: false,
        reason: 'not_friends',
      });
      return;
    }

    const [user, peerUser] = await Promise.all([
      this.usersService.findById(userId),
      this.usersService.findById(dto.peerUserId),
    ]);
    if (!user || !peerUser) {
      client.emit('invitationChatReady', {
        peerUserId: dto.peerUserId,
        correlationId: dto.correlationId,
        conversationId: null,
        chatReady: false,
        reason: 'user_not_found',
      });
      return;
    }

    // findOrCreate THROWS on total failure (it never returns null). Unguarded, the
    // caller's retry row would stay in its retrying state forever waiting for a
    // correlated result that never arrives — the exact stuck state this flow exists
    // to remove. Report the failure honestly instead.
    let conversation: Conversation;
    try {
      conversation = await this.conversationsService.findOrCreate(
        user,
        peerUser,
      );
    } catch (error) {
      this.logger.error(
        'handleEnsureInvitationChat: findOrCreate failed:',
        error,
      );
      client.emit('invitationChatReady', {
        peerUserId: dto.peerUserId,
        correlationId: dto.correlationId,
        conversationId: null,
        chatReady: false,
        reason: 'chat_setup_failed',
      });
      return;
    }

    await this.emitConversationsListToBoth(
      client,
      server,
      userId,
      dto.peerUserId,
    );
    client.emit('invitationChatReady', {
      peerUserId: dto.peerUserId,
      correlationId: dto.correlationId,
      conversationId: conversation.id,
      chatReady: true,
    });
  }

  async handleGetFriendRequests(client: Socket) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    const friendRequests = await this.friendsService.getPendingRequests(userId);
    client.emit(
      'friendRequestsList',
      friendRequests.map(FriendRequestMapper.toPayload),
    );
    const sentRequests = await this.friendsService.getSentRequests(userId);
    client.emit(
      'sentRequestsList',
      sentRequests.map(FriendRequestMapper.toPayload),
    );

    const count = await this.friendsService.getPendingRequestCount(userId);
    client.emit('pendingRequestsCount', { count });
  }

  async handleGetFriends(client: Socket) {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    const [friends, blockedIds, blockedByUserIds] = await Promise.all([
      this.friendsService.getFriends(userId),
      this.blockedService.getBlockedUserIds(userId),
      this.blockedService.getBlockedByUserIds(userId),
    ]);
    const excludeSet = new Set([...blockedIds, ...blockedByUserIds]);
    const filtered = friends.filter((u) => !excludeSet.has(u.id));
    const list = filtered.map((u) => UserMapper.toPayload(u));
    client.emit('friendsList', list);
  }

  async handleUnfriend(client: Socket, data: any, server: Server) {
    const currentUserId: number = client.data.user?.id;
    if (!currentUserId) return;

    // `data` is `any` on the wire, so bind the VALIDATED id to a typed local and
    // use that everywhere below — reassigning `data` left every `data.userId`
    // read unchecked (and unsafe-typed) despite the DTO having already run.
    let peerId: number;
    try {
      peerId = validateDto(UnfriendDto, data).userId;
    } catch (error) {
      client.emit('error', { message: error.message });
      return;
    }

    this.logger.debug(
      `handleUnfriend: currentUserId=${currentUserId}, targetUserId=${peerId}`,
    );

    // Step 1: Delete the friend relationship (CRITICAL - if this fails, operation fails)
    try {
      await this.friendsService.unfriend(currentUserId, peerId);
    } catch (error) {
      this.logger.error('handleUnfriend: Failed to unfriend:', error);
      client.emit('error', {
        message: error.message || 'Failed to unfriend user',
      });
      return; // Critical failure - stop here
    }

    // Step 2: Delete the conversation (important but not critical)
    try {
      const conversation = await this.conversationsService.findByUsers(
        currentUserId,
        peerId,
      );
      if (conversation) {
        const mediaUrls =
          await this.messagesService.findMediaUrlsByConversation(
            conversation.id,
          );
        await Promise.all(
          mediaUrls.map((url) => this.mediaCleanup.deleteMediaFile(url)),
        );
        await this.conversationsService.delete(conversation.id);
        this.logger.debug(
          `handleUnfriend: deleted conversation id=${conversation.id}`,
        );
      }
    } catch (error) {
      // BE-103: the friendship is already gone at this point, so a swallowed
      // failure here orphans the conversation and its encrypted messages. Log
      // both user ids so the orphaned rows can be reconciled by hand.
      this.logger.error(
        `handleUnfriend: Failed to delete conversation between ${currentUserId} and ${peerId} (conversation/messages may be orphaned):`,
        error,
      );
      // Continue - users are unfriended even if conversation deletion failed
    }

    // Step 3: Notify both users (non-critical).
    //
    // Each side is told WHO LEFT THEIR LIST — i.e. the OTHER party's id. Do not
    // "simplify" this to one shared payload: the client feeds this id straight
    // into ConversationsProvider.removeConversationsForUser, whose predicate is
    // `userOne.id == id || userTwo.id == id`. The caller is a participant in
    // EVERY one of their own conversations, so sending the initiator its own id
    // matched all of them and irreversibly destroyed the decrypted plaintext of
    // the user's ENTIRE local history (the ratchet consumed the message keys, so
    // the server's ciphertext can never be re-read). That was live in prod.
    try {
      client.emit('unfriended', { userId: peerId });
      server
        .to(userRoom(peerId))
        .emit('unfriended', { userId: currentUserId });
    } catch (error) {
      this.logger.error(
        'handleUnfriend: emit unfriended (non-critical):',
        error,
      );
    }

    // Step 4 & 5: Refresh conversations and friends lists for both users (non-critical)
    await this.emitConversationsListToBoth(
      client,
      server,
      currentUserId,
      data.userId,
    );
    await this.emitFriendsListToBoth(
      client,
      server,
      currentUserId,
      data.userId,
    );
  }
}
