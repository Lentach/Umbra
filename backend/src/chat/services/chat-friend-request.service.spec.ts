import { Test, TestingModule } from '@nestjs/testing';
import { ConflictException } from '@nestjs/common';
import { ChatFriendRequestService } from './chat-friend-request.service';
import { FriendsService } from '../../friends/friends.service';
import { BlockedService } from '../../blocked/blocked.service';
import { UsersService } from '../../users/users.service';
import { ConversationsService } from '../../conversations/conversations.service';
import { MessagesService } from '../../messages/messages.service';
import { MediaCleanupService } from '../../media/media-cleanup.service';
import { ChatConversationService } from './chat-conversation.service';
import { ChatValidationService } from './chat-validation.service';
import { Socket, Server } from 'socket.io';
import {
  FriendRequest,
  FriendRequestStatus,
} from '../../friends/friend-request.entity';
import { User } from '../../users/user.entity';
import {
  DevicesService,
  FirstContactDevice,
} from '../../key-bundles/devices.service';
import { DeviceListService } from '../../key-bundles/device-list.service';

describe('ChatFriendRequestService', () => {
  let service: ChatFriendRequestService;
  let friendsService: jest.Mocked<FriendsService>;
  let blockedService: jest.Mocked<BlockedService>;
  let usersService: jest.Mocked<UsersService>;
  let conversationsService: jest.Mocked<ConversationsService>;
  let mockClient: Partial<Socket>;
  let chatValidationService: jest.Mocked<ChatValidationService>;
  let mockServer: Partial<Server>;
  let onlineRooms: Map<string, Set<string>>;
  let firstContactDevicesFor: jest.Mock<
    Promise<Map<number, FirstContactDevice[]>>,
    [number[]]
  >;
  let pendingReplacementUserIds: jest.Mock<Promise<Set<number>>, [number[]]>;

  // Mark a user online by placing a socket in their per-user room — the same
  // structure isUserOnline/socketsForUser read. Two ids in one set = two tabs.
  const setOnline = (userId: number) => {
    onlineRooms.set(`user:${userId}`, new Set([`socket-${userId}`]));
  };

  const mockSender = { id: 1, username: 'alice', tag: '0001' };
  const mockRecipient = { id: 2, username: 'bob', tag: '0002' };
  const mockFriendRequest = {
    id: 10,
    status: 'pending',
    sender: mockSender,
    receiver: mockRecipient,
  };

  beforeEach(async () => {
    mockClient = { data: { user: { id: 1 } }, emit: jest.fn() };
    onlineRooms = new Map();
    mockServer = {
      to: jest.fn().mockReturnThis(),
      emit: jest.fn(),
      sockets: { adapter: { rooms: onlineRooms } } as any,
    };
    firstContactDevicesFor = jest
      .fn<Promise<Map<number, FirstContactDevice[]>>, [number[]]>()
      .mockResolvedValue(new Map());
    pendingReplacementUserIds = jest
      .fn<Promise<Set<number>>, [number[]]>()
      .mockResolvedValue(new Set());
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ChatFriendRequestService,
        {
          provide: FriendsService,
          useValue: {
            sendRequest: jest.fn(),
            acceptRequest: jest.fn(),
            rejectRequest: jest.fn(),
            unfriend: jest.fn(),
            getFriends: jest.fn().mockResolvedValue([]),
            getPendingRequests: jest.fn().mockResolvedValue([]),
            getSentRequests: jest.fn().mockResolvedValue([]),
            getPendingRequestCount: jest.fn().mockResolvedValue(0),
          },
        },
        {
          provide: BlockedService,
          useValue: {
            isBlocked: jest.fn().mockResolvedValue(false),
            getBlockedUserIds: jest.fn().mockResolvedValue([]),
            getBlockedByUserIds: jest.fn().mockResolvedValue([]),
          },
        },
        {
          provide: UsersService,
          useValue: {
            findById: jest.fn(),
            findByUsernameAndTag: jest.fn(),
          },
        },
        {
          provide: ConversationsService,
          useValue: {
            findOrCreate: jest.fn().mockResolvedValue({ id: 100 }),
            findByUser: jest.fn().mockResolvedValue([]),
            findByUsers: jest.fn().mockResolvedValue({ id: 50 }),
            delete: jest.fn().mockResolvedValue(undefined),
          },
        },
        {
          provide: MessagesService,
          useValue: {
            findMediaUrlsByConversation: jest.fn().mockResolvedValue([]),
          },
        },
        {
          provide: MediaCleanupService,
          useValue: {
            deleteMediaFile: jest.fn().mockResolvedValue(undefined),
          },
        },
        {
          provide: ChatConversationService,
          useValue: {
            conversationsWithUnread: jest.fn().mockResolvedValue([]),
          },
        },
        {
          provide: ChatValidationService,
          useValue: {
            validateCanMessage: jest.fn().mockResolvedValue({ valid: true }),
          },
        },
        { provide: DevicesService, useValue: { firstContactDevicesFor } },
        { provide: DeviceListService, useValue: { pendingReplacementUserIds } },
      ],
    }).compile();

    service = module.get<ChatFriendRequestService>(ChatFriendRequestService);
    friendsService = module.get(FriendsService) as jest.Mocked<FriendsService>;
    blockedService = module.get(BlockedService) as jest.Mocked<BlockedService>;
    usersService = module.get(UsersService) as jest.Mocked<UsersService>;
    conversationsService = module.get(
      ConversationsService,
    ) as jest.Mocked<ConversationsService>;
    chatValidationService = module.get(
      ChatValidationService,
    ) as jest.Mocked<ChatValidationService>;
  });

  describe('handleSendFriendRequest', () => {
    it('emits friendRequestSent when request is pending', async () => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockRecipient as any);
      friendsService.sendRequest.mockResolvedValue({
        ...mockFriendRequest,
        status: 'pending',
      } as any);

      await service.handleSendFriendRequest(
        mockClient as any,
        { recipientId: 2 },
        mockServer as any,
      );

      expect(friendsService.sendRequest).toHaveBeenCalledWith(
        mockSender,
        mockRecipient,
      );
      expect(mockClient.emit).toHaveBeenCalledWith(
        'friendRequestSent',
        expect.any(Object),
      );
    });

    it('addresses newFriendRequest to the recipient room so every open tab receives it (BE-007 multi-tab)', async () => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockRecipient as any);
      friendsService.sendRequest.mockResolvedValue({
        ...mockFriendRequest,
        status: 'pending',
      } as any);
      // Recipient is online on TWO tabs: both sockets share the one per-user
      // room. The retired onlineUsers map was last-write-wins, so it could only
      // ever hold one socket id and the other tab silently went dark (BE-007).
      onlineRooms.set('user:2', new Set(['tab-a', 'tab-b']));

      await service.handleSendFriendRequest(
        mockClient as any,
        { recipientId: 2 },
        mockServer as any,
      );

      // Delivery targets the room, never an individual socket id, so both tabs
      // receive. This is the assertion that would have caught BE-007.
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith(
        'newFriendRequest',
        expect.any(Object),
      );
      expect(mockServer.to).not.toHaveBeenCalledWith('tab-a');
      expect(mockServer.to).not.toHaveBeenCalledWith('tab-b');
    });

    it('emits accepted readiness to both users without opening a conversation when request is accepted (mutual)', async () => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockRecipient as any);
      friendsService.sendRequest.mockResolvedValue({
        ...mockFriendRequest,
        status: 'accepted',
      } as any);
      setOnline(2);

      await service.handleSendFriendRequest(
        mockClient as any,
        { recipientId: 2 },
        mockServer as any,
      );

      const acceptedPayload = expect.objectContaining({
        id: 10,
        conversationId: 100,
        chatReady: true,
      });
      expect(mockClient.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
      expect(conversationsService.findOrCreate).toHaveBeenCalledWith(
        mockSender,
        mockRecipient,
      );
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'openConversation',
        expect.anything(),
      );
      expect(mockServer.emit).not.toHaveBeenCalledWith(
        'openConversation',
        expect.anything(),
      );
    });

    it('emits chatReady false to both users when auto-accept conversation creation fails', async () => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockRecipient as any);
      friendsService.sendRequest.mockResolvedValue({
        ...mockFriendRequest,
        status: 'accepted',
      } as any);
      conversationsService.findOrCreate.mockRejectedValue(
        new Error('database unavailable'),
      );
      setOnline(2);

      await service.handleSendFriendRequest(
        mockClient as any,
        { recipientId: 2 },
        mockServer as any,
      );

      const acceptedPayload = expect.objectContaining({
        id: 10,
        conversationId: null,
        chatReady: false,
      });
      expect(mockClient.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
      expect(mockServer.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
    });

    it.each([
      ['invalid payload', { recipientId: -1 }, 'invalid_payload'],
      ['recipient blocked sender', { recipientId: 2 }, 'blocked'],
    ])('emits scoped send failure for %s', async (_label, data, reason) => {
      if (reason === 'blocked') {
        usersService.findById
          .mockResolvedValueOnce(mockSender as any)
          .mockResolvedValueOnce(mockRecipient as any);
        blockedService.isBlocked.mockResolvedValue(true);
      }

      await service.handleSendFriendRequest(
        mockClient as any,
        data,
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: data.recipientId,
        reason,
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });

    it('emits scoped send failure when sending to self', async () => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockSender as any);

      await service.handleSendFriendRequest(
        mockClient as any,
        { recipientId: 1 },
        mockServer as any,
      );

      expect(friendsService.sendRequest).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: 1,
        reason: 'self_request',
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });

    it('emits scoped send failure when user is not found', async () => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(null);

      await service.handleSendFriendRequest(
        mockClient as any,
        { recipientId: 999 },
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: 999,
        reason: 'user_not_found',
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });

    it.each([
      ['Already friends', 'already_friends'],
      ['Friend request already sent', 'duplicate_request'],
      ['unexpected request error', 'invalid_payload'],
    ])('maps send request conflicts to %s', async (message, reason) => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockRecipient as any);
      friendsService.sendRequest.mockRejectedValue(
        message === 'unexpected request error'
          ? new Error(message)
          : new ConflictException(message),
      );

      await service.handleSendFriendRequest(
        mockClient as any,
        { recipientId: 2 },
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestFailed', {
        action: 'send',
        requestId: null,
        recipientId: 2,
        reason,
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });
  });

  describe('handleAcceptFriendRequest', () => {
    const acceptedRequest = {
      ...mockFriendRequest,
      status: 'accepted',
      sender: mockSender,
      receiver: mockRecipient,
    };

    const setUpAcceptedRequest = () => {
      friendsService.acceptRequest.mockResolvedValue(acceptedRequest as any);
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockRecipient as any);
      conversationsService.findOrCreate.mockResolvedValue({ id: 100 } as any);
    };

    it('emits accepted readiness to acceptor and online sender after creating the conversation', async () => {
      setUpAcceptedRequest();
      setOnline(1);

      await service.handleAcceptFriendRequest(
        mockClient as any,
        { requestId: 10 },
        mockServer as any,
      );

      const acceptedPayload = expect.objectContaining({
        id: 10,
        conversationId: 100,
        chatReady: true,
      });
      expect(friendsService.acceptRequest).toHaveBeenCalledWith(10, 1);
      expect(mockClient.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
      expect(mockServer.to).toHaveBeenCalledWith('user:1');
      expect(mockServer.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
      expect(conversationsService.findOrCreate).toHaveBeenCalled();
    });

    it('does not emit openConversation after accepting a request', async () => {
      setUpAcceptedRequest();

      await service.handleAcceptFriendRequest(
        mockClient as any,
        { requestId: 10 },
        mockServer as any,
      );

      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'openConversation',
        expect.anything(),
      );
    });

    it('emits chatReady false to both users and all list refreshes when conversation creation fails', async () => {
      setUpAcceptedRequest();
      conversationsService.findOrCreate.mockRejectedValue(
        new Error('database unavailable'),
      );
      setOnline(1);

      await service.handleAcceptFriendRequest(
        mockClient as any,
        { requestId: 10 },
        mockServer as any,
      );

      const acceptedPayload = expect.objectContaining({
        id: 10,
        conversationId: null,
        chatReady: false,
      });
      expect(mockClient.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
      expect(mockServer.emit).toHaveBeenCalledWith(
        'friendRequestAccepted',
        acceptedPayload,
      );
      expect(mockClient.emit).toHaveBeenCalledWith('conversationsList', []);
      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestsList', []);
      expect(mockClient.emit).toHaveBeenCalledWith('sentRequestsList', []);
      expect(mockClient.emit).toHaveBeenCalledWith('pendingRequestsCount', {
        count: 0,
      });
      expect(mockClient.emit).toHaveBeenCalledWith('friendsList', []);
      expect(mockServer.emit).toHaveBeenCalledWith('conversationsList', []);
      expect(mockServer.emit).toHaveBeenCalledWith('sentRequestsList', []);
      expect(mockServer.emit).toHaveBeenCalledWith('friendsList', []);
    });

    it('emits acceptance after conversationsList and before request lists', async () => {
      setUpAcceptedRequest();

      await service.handleAcceptFriendRequest(
        mockClient as any,
        { requestId: 10 },
        mockServer as any,
      );

      const callOrder = (event: string) =>
        (mockClient.emit as jest.Mock).mock.invocationCallOrder[
          (mockClient.emit as jest.Mock).mock.calls.findIndex(
            ([name]) => name === event,
          )
        ];
      expect(callOrder('conversationsList')).toBeLessThan(
        callOrder('friendRequestAccepted'),
      );
      expect(callOrder('friendRequestAccepted')).toBeLessThan(
        callOrder('friendRequestsList'),
      );
      expect(callOrder('friendRequestAccepted')).toBeLessThan(
        callOrder('sentRequestsList'),
      );
    });

    it.each([
      ['invalid payload', { requestId: -1 }, 'invalid_payload'],
      ['accept failure', { requestId: 999 }, 'accept_failed'],
    ])('emits scoped accept failure for %s', async (_label, data, reason) => {
      if (reason === 'accept_failed') {
        friendsService.acceptRequest.mockRejectedValue(
          new Error('Request not found'),
        );
      }

      await service.handleAcceptFriendRequest(
        mockClient as any,
        data,
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestFailed', {
        action: 'accept',
        requestId: data.requestId,
        recipientId: null,
        reason,
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });
  });

  describe('handleRejectFriendRequest', () => {
    it('emits friendRequestRejected and friendRequestsList', async () => {
      friendsService.rejectRequest.mockResolvedValue({
        ...mockFriendRequest,
        status: 'rejected',
      } as any);
      friendsService.getPendingRequests.mockResolvedValue([]);
      friendsService.getPendingRequestCount.mockResolvedValue(0);
      mockClient.data = { user: { id: 2 } };
      setOnline(1);

      await service.handleRejectFriendRequest(
        mockClient as Socket,
        { requestId: 10 },
        mockServer as Server,
      );

      expect(friendsService.rejectRequest).toHaveBeenCalledWith(10, 2);
      expect(mockClient.emit).toHaveBeenCalledWith(
        'friendRequestRejected',
        expect.any(Object),
      );
      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestsList', []);
      expect(mockClient.emit).toHaveBeenCalledWith('sentRequestsList', []);
      expect(mockClient.emit).toHaveBeenCalledWith('pendingRequestsCount', {
        count: 0,
      });
      expect(mockServer.to).toHaveBeenCalledWith('user:1');
      expect(mockServer.emit).toHaveBeenCalledWith('sentRequestsList', []);
    });

    it.each([
      ['invalid payload', { requestId: -1 }, 'invalid_payload'],
      ['reject failure', { requestId: 10 }, 'reject_failed'],
    ])('emits scoped reject failure for %s', async (_label, data, reason) => {
      if (reason === 'reject_failed') {
        friendsService.rejectRequest.mockRejectedValue(
          new Error('Request not found'),
        );
      }

      await service.handleRejectFriendRequest(
        mockClient as any,
        data,
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestFailed', {
        action: 'reject',
        requestId: data.requestId,
        recipientId: null,
        reason,
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });
  });
  describe('handleEnsureInvitationChat', () => {
    const validRequest = {
      peerUserId: 2,
      correlationId: 'session_1-token',
    };

    const setUpFriendship = () => {
      usersService.findById
        .mockResolvedValueOnce(mockSender as any)
        .mockResolvedValueOnce(mockRecipient as any);
      conversationsService.findOrCreate.mockResolvedValue({ id: 100 } as any);
    };

    it('emits caller-only invitation chat readiness and conversation lists without opening a conversation', async () => {
      setUpFriendship();
      setOnline(2);

      await service.handleEnsureInvitationChat(
        mockClient as any,
        validRequest,
        mockServer as any,
      );

      expect(chatValidationService.validateCanMessage).toHaveBeenCalledWith(
        1,
        2,
      );
      expect(mockClient.emit).toHaveBeenCalledWith('invitationChatReady', {
        peerUserId: 2,
        correlationId: 'session_1-token',
        conversationId: 100,
        chatReady: true,
      });
      expect(mockClient.emit).toHaveBeenCalledWith('conversationsList', []);
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith('conversationsList', []);
      expect(mockServer.emit).not.toHaveBeenCalledWith(
        'invitationChatReady',
        expect.anything(),
      );
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'openConversation',
        expect.anything(),
      );
    });

    it('echoes peerUserId and correlationId verbatim and does not create a conversation for non-friends', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: false,
        error: 'You can only message friends',
      });

      await service.handleEnsureInvitationChat(
        mockClient as any,
        validRequest,
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('invitationChatReady', {
        peerUserId: 2,
        correlationId: 'session_1-token',
        conversationId: null,
        chatReady: false,
        reason: 'not_friends',
      });
      expect(conversationsService.findOrCreate).not.toHaveBeenCalled();
    });

    it('is idempotent across different correlation tokens', async () => {
      usersService.findById.mockResolvedValue(mockSender as any);
      conversationsService.findOrCreate.mockResolvedValue({ id: 100 } as any);

      await service.handleEnsureInvitationChat(
        mockClient as any,
        { peerUserId: 2, correlationId: 'first_token' },
        mockServer as any,
      );
      await service.handleEnsureInvitationChat(
        mockClient as any,
        { peerUserId: 2, correlationId: 'second_token' },
        mockServer as any,
      );

      expect(conversationsService.findOrCreate).toHaveBeenCalledTimes(2);
      expect(mockClient.emit).toHaveBeenCalledWith('invitationChatReady', {
        peerUserId: 2,
        correlationId: 'first_token',
        conversationId: 100,
        chatReady: true,
      });
      expect(mockClient.emit).toHaveBeenCalledWith('invitationChatReady', {
        peerUserId: 2,
        correlationId: 'second_token',
        conversationId: 100,
        chatReady: true,
      });
    });

    // The hand-rolled fakes below are far narrower than the socket.io Socket/Server
    // and TypeORM User surfaces they stand in for, and no runtime check could make
    // them wider. `as unknown as` is the deliberate, local bridge; the casts stay
    // inline because `mockClient`/`mockServer` are rebuilt in `beforeEach`, so a
    // hoisted alias would capture a stale fake.
    it('reports chat_setup_failed when findOrCreate throws so the retry row cannot hang', async () => {
      usersService.findById.mockResolvedValue(mockSender as unknown as User);
      conversationsService.findOrCreate.mockRejectedValue(
        new Error('Failed to find or create conversation between 1 and 2'),
      );

      await service.handleEnsureInvitationChat(
        mockClient as unknown as Socket,
        validRequest,
        mockServer as unknown as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('invitationChatReady', {
        peerUserId: 2,
        correlationId: validRequest.correlationId,
        conversationId: null,
        chatReady: false,
        reason: 'chat_setup_failed',
      });
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'conversationsList',
        expect.anything(),
      );
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'openConversation',
        expect.anything(),
      );
    });

    it('reports user_not_found when a participant no longer exists', async () => {
      usersService.findById.mockResolvedValue(null);

      await service.handleEnsureInvitationChat(
        mockClient as unknown as Socket,
        validRequest,
        mockServer as unknown as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('invitationChatReady', {
        peerUserId: 2,
        correlationId: validRequest.correlationId,
        conversationId: null,
        chatReady: false,
        reason: 'user_not_found',
      });
      expect(conversationsService.findOrCreate).not.toHaveBeenCalled();
    });

    // `expectedRecipientId` is the correlation contract: a malformed token with a
    // usable peer id must still name that peer, or the client cannot clear the
    // right row's retry state and it hangs. Only an unusable peer id yields null.
    it.each([
      [
        'a 65-character correlationId',
        { peerUserId: 2, correlationId: 'a'.repeat(65) },
        2,
      ],
      [
        'a correlationId containing markup',
        { peerUserId: 2, correlationId: 'bad<token' },
        2,
      ],
      [
        'a correlationId containing a newline',
        { peerUserId: 2, correlationId: 'bad\ntoken' },
        2,
      ],
      [
        'a correlationId containing whitespace',
        { peerUserId: 2, correlationId: 'bad token' },
        2,
      ],
      ['a non-string correlationId', { peerUserId: 2, correlationId: 42 }, 2],
      ['a missing peerUserId', { correlationId: 'valid_token' }, null],
      [
        'a negative peerUserId',
        { peerUserId: -2, correlationId: 'valid_token' },
        null,
      ],
    ])(
      'rejects %s before conversation or readiness emits',
      async (_label, data, expectedRecipientId) => {
        await service.handleEnsureInvitationChat(
          mockClient as unknown as Socket,
          data,
          mockServer as unknown as Server,
        );

        expect(mockClient.emit).toHaveBeenCalledWith('friendRequestFailed', {
          action: 'ensure_chat',
          requestId: null,
          recipientId: expectedRecipientId,
          reason: 'invalid_payload',
        });
        expect(mockClient.emit).not.toHaveBeenCalledWith(
          'invitationChatReady',
          expect.anything(),
        );
        expect(mockClient.emit).not.toHaveBeenCalledWith(
          'conversationsList',
          expect.anything(),
        );
        expect(conversationsService.findOrCreate).not.toHaveBeenCalled();
      },
    );
  });

  describe('handleGetFriendRequests', () => {
    it('emits mapped sent requests without changing the inbound pending count', async () => {
      const sentRequest = Object.assign(new FriendRequest(), {
        id: 11,
        status: FriendRequestStatus.PENDING,
        sender: Object.assign(new User(), mockSender),
        receiver: Object.assign(new User(), mockRecipient),
        createdAt: new Date('2026-07-27T10:00:00.000Z'),
        respondedAt: null,
      });
      friendsService.getSentRequests.mockResolvedValue([sentRequest]);
      friendsService.getPendingRequestCount.mockResolvedValue(7);

      await service.handleGetFriendRequests(mockClient as Socket);

      expect(mockClient.emit).toHaveBeenCalledWith('friendRequestsList', []);
      expect(mockClient.emit).toHaveBeenCalledWith('sentRequestsList', [
        expect.objectContaining({
          id: 11,
          sender: expect.objectContaining({
            id: 1,
            username: 'alice',
            tag: '0001',
            about: null,
            profilePhotos: [],
          }),
          receiver: expect.objectContaining({
            id: 2,
            username: 'bob',
            tag: '0002',
            about: null,
            profilePhotos: [],
          }),
          status: FriendRequestStatus.PENDING,
          createdAt: new Date('2026-07-27T10:00:00.000Z'),
          respondedAt: null,
        }),
      ]);
      expect(mockClient.emit).toHaveBeenCalledWith('pendingRequestsCount', {
        count: 7,
      });
      expect(friendsService.getPendingRequestCount).toHaveBeenCalledTimes(1);
    });
  });

  describe('handleUnfriend', () => {
    it('tells the initiator WHICH PEER left, never their own id', async () => {
      await service.handleUnfriend(
        mockClient as any,
        { userId: 2 },
        mockServer as any,
      );

      expect(friendsService.unfriend).toHaveBeenCalledWith(1, 2);
      expect(conversationsService.findByUsers).toHaveBeenCalledWith(1, 2);
      expect(mockClient.emit).toHaveBeenCalledWith('unfriended', { userId: 2 });
      // Regression guard, and the reason this test exists. The client feeds this
      // id into removeConversationsForUser, whose predicate matches userOne OR
      // userTwo — and the caller is a participant in every one of their own
      // conversations. So echoing `currentUserId` back to the initiator matched
      // ALL of them and irreversibly destroyed the decrypted plaintext of every
      // chat on that device. It was live in production.
      expect(mockClient.emit).not.toHaveBeenCalledWith('unfriended', {
        userId: 1,
      });
    });

    it('broadcasts unfriended to the other user when online', async () => {
      setOnline(2);

      await service.handleUnfriend(
        mockClient as any,
        { userId: 2 },
        mockServer as any,
      );

      // The peer is told who removed THEM — the initiator's id.
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith('unfriended', { userId: 1 });
    });

    it('emits error when unfriend fails', async () => {
      friendsService.unfriend.mockRejectedValue(new Error('Not friends'));

      await service.handleUnfriend(
        mockClient as any,
        { userId: 2 },
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Not friends',
      });
    });
  });

  describe('handleGetFriends', () => {
    it('excludes blocked users from friendsList', async () => {
      const friend = {
        id: 2,
        username: 'bob',
        tag: '0002',
        profilePictureUrl: null,
      };
      friendsService.getFriends.mockResolvedValue([friend] as any);
      blockedService.getBlockedUserIds.mockResolvedValue([2]);
      blockedService.getBlockedByUserIds.mockResolvedValue([]);

      await service.handleGetFriends(mockClient as any);

      expect(mockClient.emit).toHaveBeenCalledWith('friendsList', []);
    });

    it('emits mapped friend payload when no blocks', async () => {
      const friend = {
        id: 2,
        username: 'bob',
        tag: '0002',
        profilePictureUrl: null,
      };
      friendsService.getFriends.mockResolvedValue([friend] as any);
      blockedService.getBlockedUserIds.mockResolvedValue([]);
      blockedService.getBlockedByUserIds.mockResolvedValue([]);

      await service.handleGetFriends(mockClient as any);

      expect(mockClient.emit).toHaveBeenCalledWith(
        'friendsList',
        expect.arrayContaining([
          expect.objectContaining({ id: 2, username: 'bob', tag: '0002' }),
        ]),
      );
    });

    // Item 5 (decision 47): the friends list is where a device learns each
    // friend device's REQUEST queue, to hand it a box queue of its own.
    describe('devices (friend request queues)', () => {
      const sid = 'A'.repeat(43);
      const sealPub = 'B'.repeat(43);
      const friend = (id: number) => ({
        id,
        username: `u${id}`,
        tag: '0001',
        profilePictureUrl: null,
      });
      const devicesOf = (payload: unknown) =>
        new Map(
          (payload as { id: number; devices: unknown }[]).map((f) => [
            f.id,
            f.devices,
          ]),
        );
      const emitted = (emit: unknown, event: string) =>
        (emit as jest.Mock).mock.calls
          .filter(([name]) => name === event)
          .map(([, payload]: [string, unknown]) => payload);

      it("carries each friend's live published devices, null until a device publishes, in ONE lookup for every friend", async () => {
        friendsService.getFriends.mockResolvedValue([
          friend(2),
          friend(3),
          friend(4),
        ] as never);
        firstContactDevicesFor.mockResolvedValue(
          new Map([
            [
              2,
              [
                { deviceId: 1, requestSid: null, requestSealPub: null },
                { deviceId: 3, requestSid: sid, requestSealPub: sealPub },
              ],
            ],
            [3, [{ deviceId: 1, requestSid: sid, requestSealPub: sealPub }]],
          ]),
        );

        await service.handleGetFriends(mockClient as Socket);

        const [list] = emitted(mockClient.emit, 'friendsList');
        expect(devicesOf(list)).toEqual(
          new Map([
            [
              2,
              [
                { deviceId: 1, requestSid: null, sealPub: null },
                { deviceId: 3, requestSid: sid, sealPub },
              ],
            ],
            [3, [{ deviceId: 1, requestSid: sid, sealPub }]],
            // No live device holding a bundle: nothing to address.
            [4, []],
          ]),
        );
        expect(firstContactDevicesFor.mock.calls).toEqual([[[2, 3, 4]]]);
        expect(pendingReplacementUserIds.mock.calls).toEqual([[[2, 3, 4]]]);
      });

      it('answers devices: [] for a friend who owes a replacement enrollment', async () => {
        friendsService.getFriends.mockResolvedValue([
          friend(2),
          friend(3),
        ] as never);
        firstContactDevicesFor.mockResolvedValue(
          new Map([
            [2, [{ deviceId: 2, requestSid: sid, requestSealPub: sealPub }]],
            [3, [{ deviceId: 1, requestSid: sid, requestSealPub: sealPub }]],
          ]),
        );
        pendingReplacementUserIds.mockResolvedValue(new Set([2]));

        await service.handleGetFriends(mockClient as Socket);

        // As `searchUsers`: a roster that cannot receive is never addressed.
        const [list] = emitted(mockClient.emit, 'friendsList');
        expect(devicesOf(list)).toEqual(
          new Map([
            [2, []],
            [3, [{ deviceId: 1, requestSid: sid, sealPub }]],
          ]),
        );
      });

      it('never looks up the devices of a blocked friend', async () => {
        friendsService.getFriends.mockResolvedValue([
          friend(2),
          friend(3),
        ] as never);
        blockedService.getBlockedByUserIds.mockResolvedValue([2]);

        await service.handleGetFriends(mockClient as Socket);

        expect(firstContactDevicesFor.mock.calls).toEqual([[[3]]]);
      });

      it('carries devices on the list BOTH sides get when a request is accepted', async () => {
        friendsService.acceptRequest.mockResolvedValue({
          ...mockFriendRequest,
          status: 'accepted',
        } as never);
        usersService.findById
          .mockResolvedValueOnce(mockSender as never)
          .mockResolvedValueOnce(mockRecipient as never);
        friendsService.getFriends.mockResolvedValue([friend(3)] as never);
        firstContactDevicesFor.mockResolvedValue(
          new Map([
            [3, [{ deviceId: 1, requestSid: sid, requestSealPub: sealPub }]],
          ]),
        );
        setOnline(1);
        setOnline(2);

        await service.handleAcceptFriendRequest(
          mockClient as Socket,
          { requestId: 10 },
          mockServer as Server,
        );

        const expected = new Map([
          [3, [{ deviceId: 1, requestSid: sid, sealPub }]],
        ]);
        const lists = [
          ...emitted(mockClient.emit, 'friendsList'),
          ...emitted(mockServer.emit, 'friendsList'),
        ];
        expect(lists).toHaveLength(2);
        for (const list of lists) expect(devicesOf(list)).toEqual(expected);
      });
    });
  });
});
