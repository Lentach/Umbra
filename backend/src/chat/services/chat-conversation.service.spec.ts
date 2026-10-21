import { Test, TestingModule } from '@nestjs/testing';
import { ConfigService } from '@nestjs/config';
import { ChatConversationService } from './chat-conversation.service';
import { ConversationsService } from '../../conversations/conversations.service';
import { MessagesService } from '../../messages/messages.service';
import { UsersService } from '../../users/users.service';
import { BlockedService } from '../../blocked/blocked.service';
import { ChatValidationService } from './chat-validation.service';
import { MediaCleanupService } from '../../media/media-cleanup.service';
import { ConversationNotificationPreferencesService } from '../../conversation-notification-preferences/conversation-notification-preferences.service';
import { Socket, Server } from 'socket.io';
import { Conversation } from '../../conversations/conversation.entity';
import { Message } from '../../messages/message.entity';
import { User } from '../../users/user.entity';

describe('ChatConversationService', () => {
  let service: ChatConversationService;
  let chatValidationService: jest.Mocked<ChatValidationService>;
  let usersService: jest.Mocked<UsersService>;
  let conversationsService: jest.Mocked<ConversationsService>;
  let messagesService: jest.Mocked<MessagesService>;
  let mockClient: Partial<Socket>;
  let notificationPreferences: jest.Mocked<ConversationNotificationPreferencesService>;
  let mockServer: Partial<Server>;
  // The env as `ConfigService` serves it; `LEGACY_WRITES_FROZEN` set per test.
  let env: Record<string, string | undefined>;

  beforeEach(async () => {
    mockClient = { data: { user: { id: 1 } }, emit: jest.fn() };
    env = {};
    mockServer = { to: jest.fn().mockReturnThis(), emit: jest.fn() };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ChatConversationService,
        {
          provide: ConversationsService,
          useValue: {
            findOrCreate: jest.fn(),
            findByUsers: jest.fn().mockResolvedValue(null),
            findByUser: jest.fn().mockResolvedValue([]),
            findById: jest.fn(),
            setPinnedMessage: jest.fn(),
            clearPinnedMessage: jest.fn(),
            updateDisappearingTimer: jest.fn(),
          },
        },
        {
          provide: MessagesService,
          useValue: {
            countUnreadForRecipient: jest.fn().mockResolvedValue(0),
            getLastMessage: jest.fn().mockResolvedValue(null),
            findMediaUrlsByConversation: jest.fn().mockResolvedValue([]),
            findByIdWithConversation: jest.fn(),
          },
        },
        { provide: UsersService, useValue: { findById: jest.fn() } },
        {
          provide: BlockedService,
          useValue: {
            getBlockedUserIds: jest.fn().mockResolvedValue([]),
            getBlockedByUserIds: jest.fn().mockResolvedValue([]),
          },
        },
        {
          provide: ChatValidationService,
          useValue: {
            validateCanMessage: jest.fn().mockResolvedValue({ valid: true }),
          },
        },
        {
          provide: MediaCleanupService,
          useValue: {
            deleteMediaFile: jest.fn().mockResolvedValue(undefined),
          },
        },
        {
          provide: ConversationNotificationPreferencesService,
          useValue: { setMute: jest.fn() },
        },
        {
          provide: ConfigService,
          useValue: { get: (key: string) => env[key] },
        },
      ],
    }).compile();

    service = module.get(ChatConversationService);
    chatValidationService = module.get(
      ChatValidationService,
    ) as jest.Mocked<ChatValidationService>;
    usersService = module.get(UsersService) as jest.Mocked<UsersService>;
    conversationsService = module.get(
      ConversationsService,
    ) as jest.Mocked<ConversationsService>;
    messagesService = module.get(
      MessagesService,
    ) as jest.Mocked<MessagesService>;
    notificationPreferences = module.get(
      ConversationNotificationPreferencesService,
    ) as jest.Mocked<ConversationNotificationPreferencesService>;
  });

  describe('handleStartConversation', () => {
    it('rejects when users are not friends', async () => {
      usersService.findById
        .mockResolvedValueOnce({ id: 1, username: 'alice' } as any)
        .mockResolvedValueOnce({ id: 2, username: 'bob' } as any);
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: false,
        error: 'You can only message friends',
      });

      await service.handleStartConversation(
        mockClient as any,
        { recipientId: 2 },
        mockServer as any,
      );

      expect(chatValidationService.validateCanMessage).toHaveBeenCalledWith(
        1,
        2,
      );
      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'You can only message friends',
      });
      expect(conversationsService.findOrCreate).not.toHaveBeenCalled();
    });

    it('allows when users are friends', async () => {
      usersService.findById
        .mockResolvedValueOnce({ id: 1, username: 'alice' } as any)
        .mockResolvedValueOnce({ id: 2, username: 'bob' } as any);
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      conversationsService.findOrCreate.mockResolvedValue({ id: 10 } as any);

      await service.handleStartConversation(
        mockClient as any,
        { recipientId: 2 },
        mockServer as any,
      );

      expect(conversationsService.findOrCreate).toHaveBeenCalled();
    });

    describe('LEGACY_WRITES_FROZEN=true (decision 111)', () => {
      beforeEach(() => {
        env = { LEGACY_WRITES_FROZEN: 'true' };
        usersService.findById
          .mockResolvedValueOnce({ id: 1, username: 'alice' } as User)
          .mockResolvedValueOnce({ id: 2, username: 'bob' } as User);
        conversationsService.findOrCreate.mockResolvedValue({
          id: 99,
        } as Conversation);
      });

      it('refuses a chat that does not exist yet and creates none', async () => {
        await service.handleStartConversation(
          mockClient as Socket,
          { recipientId: 2 },
          mockServer as Server,
        );

        expect(mockClient.emit).toHaveBeenCalledWith('error', {
          message: 'legacy_frozen',
        });
        expect(conversationsService.findOrCreate.mock.calls).toHaveLength(0);
      });

      it('still opens the existing chat, so old history stays reachable', async () => {
        conversationsService.findByUsers.mockResolvedValue({
          id: 10,
        } as Conversation);

        await service.handleStartConversation(
          mockClient as Socket,
          { recipientId: 2 },
          mockServer as Server,
        );

        expect(conversationsService.findByUsers.mock.calls).toEqual([[1, 2]]);
        expect(mockClient.emit).toHaveBeenCalledWith('openConversation', {
          conversationId: 10,
        });
        expect(conversationsService.findOrCreate.mock.calls).toHaveLength(0);
      });
    });
  });

  describe('handlePinMessage', () => {
    const conv = {
      id: 10,
      userOne: { id: 1 },
      userTwo: { id: 2 },
    };
    const msgA = {
      id: 100,
      content: 'a',
      conversation: conv,
      createdAt: new Date(),
      expiresAt: null,
      disappearAfterSeconds: null,
    };
    const msgB = {
      id: 101,
      content: 'b',
      conversation: conv,
      createdAt: new Date(),
      expiresAt: null,
      disappearAfterSeconds: null,
    };

    beforeEach(() => {
      conversationsService.findById.mockResolvedValue(conv as any);
      conversationsService.setPinnedMessage.mockImplementation(
        async (_cid, messageId, userId) =>
          ({
            id: 10,
            pinnedMessageId: messageId,
            pinnedAt: new Date(),
            pinnedByUserId: userId,
          }) as any,
      );
    });

    it('pins message B after message A (replace pin)', async () => {
      messagesService.findByIdWithConversation
        .mockResolvedValueOnce(msgA as any)
        .mockResolvedValueOnce(msgB as any);

      await service.handlePinMessage(
        mockClient as any,
        { conversationId: 10, messageId: 100 },
        mockServer as any,
      );
      await service.handlePinMessage(
        mockClient as any,
        { conversationId: 10, messageId: 101 },
        mockServer as any,
      );

      expect(conversationsService.setPinnedMessage).toHaveBeenNthCalledWith(
        1,
        10,
        100,
        1,
      );
      expect(conversationsService.setPinnedMessage).toHaveBeenLastCalledWith(
        10,
        101,
        1,
      );
      // The pin is now fanned to both participants' user rooms rather than
      // echoed to the pinning socket, so the observable is the ROOM emit.
      expect(mockServer.emit).toHaveBeenCalledWith(
        'messagePinned',
        expect.objectContaining({ pinnedMessageId: 100 }),
      );
      expect(mockServer.emit).toHaveBeenCalledWith(
        'messagePinned',
        expect.objectContaining({ pinnedMessageId: 101 }),
      );
    });

    it('rejects pin when message belongs to a different conversation', async () => {
      const foreignMsg = {
        id: 100,
        content: 'foreign',
        conversation: { id: 999, userOne: { id: 1 }, userTwo: { id: 2 } },
        createdAt: new Date(),
        expiresAt: null,
        disappearAfterSeconds: null,
      };
      messagesService.findByIdWithConversation.mockResolvedValue(
        foreignMsg as any,
      );

      await service.handlePinMessage(
        mockClient as any,
        { conversationId: 10, messageId: 100 },
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Message not in conversation',
      });
      expect(conversationsService.setPinnedMessage).not.toHaveBeenCalled();
    });

    it('rejects pin from non-member', async () => {
      mockClient = { data: { user: { id: 99 } }, emit: jest.fn() };
      conversationsService.findById.mockResolvedValue(conv as any);

      await service.handlePinMessage(
        mockClient as any,
        { conversationId: 10, messageId: 100 },
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Unauthorized',
      });
      expect(conversationsService.setPinnedMessage).not.toHaveBeenCalled();
    });

    it('rejects pin on expired message', async () => {
      const expiredMsg = {
        id: 100,
        content: 'expired',
        conversation: conv,
        createdAt: new Date('2020-01-01'),
        expiresAt: new Date('2020-01-02'),
        disappearAfterSeconds: null,
      };
      messagesService.findByIdWithConversation.mockResolvedValue(
        expiredMsg as any,
      );

      await service.handlePinMessage(
        mockClient as any,
        { conversationId: 10, messageId: 100 },
        mockServer as any,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Cannot pin expired message',
      });
      expect(conversationsService.setPinnedMessage).not.toHaveBeenCalled();
    });
  });
  describe('handleSetConversationMute', () => {
    it('rejects a mute request from a non-member', async () => {
      conversationsService.findById.mockResolvedValue({
        id: 10,
        userOne: { id: 2 },
        userTwo: { id: 3 },
      } as never);

      await service.handleSetConversationMute(
        mockClient as unknown as Socket,
        { conversationId: 10, duration: '8h' },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Unauthorized',
      });
      expect(notificationPreferences.setMute).not.toHaveBeenCalled();
    });

    it('stores an allowed viewer-private duration and emits only to that viewer', async () => {
      // Still "only that viewer" — but now to the viewer's whole USER ROOM, so
      // their other linked devices stop buzzing too. The peer must stay
      // uninformed: knowing you were muted is a leak.
      const to = jest.fn().mockReturnThis();
      const roomEmit = jest.fn();
      const clientEmit = jest.fn();
      const server = { to, emit: roomEmit } as unknown as Server;
      const client = {
        data: { user: { id: 1 } },
        emit: clientEmit,
      } as unknown as Socket;
      conversationsService.findById.mockResolvedValue({
        id: 10,
        userOne: { id: 1 },
        userTwo: { id: 2 },
      } as never);
      notificationPreferences.setMute.mockResolvedValue({
        muted: true,
        until: new Date('2026-07-13T10:00:00.000Z'),
      });

      await service.handleSetConversationMute(
        client,
        { conversationId: 10, duration: '8h' },
        server,
      );

      expect(notificationPreferences.setMute).toHaveBeenCalledWith(1, 10, '8h');
      expect(to).toHaveBeenCalledWith('user:1');
      expect(to).not.toHaveBeenCalledWith('user:2');
      expect(roomEmit).toHaveBeenCalledWith('conversationMuteUpdated', {
        conversationId: 10,
        muted: true,
        mutedUntil: new Date('2026-07-13T10:00:00.000Z'),
      });
    });
  });

  describe('BE-007 multi-tab realtime delivery', () => {
    // A per-user room whose membership set has TWO socket ids models a user
    // with two tabs open. Addressing the room (not one socket id) is what the
    // BE-007 fix guarantees: both tabs receive the event.
    const onlineServer = (userId: number, socketIds: string[]) =>
      ({
        to: jest.fn().mockReturnThis(),
        emit: jest.fn(),
        sockets: {
          adapter: { rooms: new Map([[`user:${userId}`, new Set(socketIds)]]) },
          sockets: new Map(),
        },
      }) as unknown as Server;

    it('delivers startConversation conversationsList to the recipient room, reaching every tab', async () => {
      const server = onlineServer(2, ['tab-a', 'tab-b']);
      usersService.findById
        .mockResolvedValueOnce({ id: 1, username: 'alice' } as any)
        .mockResolvedValueOnce({ id: 2, username: 'bob' } as any);
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      conversationsService.findOrCreate.mockResolvedValue({ id: 10 } as any);

      await service.handleStartConversation(
        mockClient as any,
        { recipientId: 2 },
        server as any,
      );

      // Targets the room, not a socket id — a second tab would also receive.
      expect(server.to).toHaveBeenCalledWith('user:2');
      expect(server.to).not.toHaveBeenCalledWith('tab-a');
    });

    it('does NOT build the recipient conversations list when the recipient is offline', async () => {
      const server = onlineServer(999, []); // recipient 2 is absent -> offline
      usersService.findById
        .mockResolvedValueOnce({ id: 1, username: 'alice' } as any)
        .mockResolvedValueOnce({ id: 2, username: 'bob' } as any);
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      conversationsService.findOrCreate.mockResolvedValue({ id: 10 } as any);

      await service.handleStartConversation(
        mockClient as any,
        { recipientId: 2 },
        server as any,
      );

      // Expensive build stays guarded: no conversations fetched for the offline peer.
      expect(conversationsService.findByUser).not.toHaveBeenCalledWith(2);
      expect(server.to).not.toHaveBeenCalledWith('user:2');
    });

    it('delivers messagePinned to the peer room, reaching every tab', async () => {
      const server = onlineServer(2, ['tab-a', 'tab-b']);
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      conversationsService.findById.mockResolvedValue(conv as any);
      conversationsService.setPinnedMessage.mockResolvedValue({
        id: 10,
        pinnedMessageId: 100,
        pinnedAt: new Date(),
        pinnedByUserId: 1,
      } as any);
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        content: 'a',
        conversation: conv,
        createdAt: new Date(),
        expiresAt: null,
        disappearAfterSeconds: null,
      } as any);

      await service.handlePinMessage(
        mockClient as any,
        { conversationId: 10, messageId: 100 },
        server as any,
      );

      expect(server.to).toHaveBeenCalledWith('user:2');
      expect(server.to).not.toHaveBeenCalledWith('tab-a');
    });

    it('delivers disappearingTimerUpdated to BOTH users rooms, never the calling socket alone', async () => {
      // Field-found 2026-09-14 on a 3-device account: the setter's OTHER
      // linked devices kept showing the timer they had just displaced, because
      // the update went to `client` instead of the setter's user room. A stale
      // timer is a stale SAFETY PROMISE — the user is told messages will vanish
      // on a schedule that is no longer in force.
      //
      // Doubles are LOCAL consts rather than `mockServer`/`mockClient` so the
      // assertions read a plain `jest.fn` instead of a member access, which is
      // what keeps eslint's `unbound-method` count flat — `scripts/lint-ratchet.mjs`
      // fails CI when real errors rise above the recorded floor.
      const to = jest.fn().mockReturnThis();
      const roomEmit = jest.fn();
      const clientEmit = jest.fn();
      const server = { to, emit: roomEmit } as unknown as Server;
      const client = {
        data: { user: { id: 1 } },
        emit: clientEmit,
      } as unknown as Socket;
      // Partial double: the handler reads only these three fields off the row.
      const conversation = {
        id: 10,
        userOne: { id: 1 },
        userTwo: { id: 2 },
      } as unknown as Conversation;
      conversationsService.findById.mockResolvedValue(conversation);
      conversationsService.updateDisappearingTimer.mockResolvedValue(
        conversation,
      );

      await service.handleSetDisappearingTimer(
        client,
        { conversationId: 10, seconds: 60 },
        server,
      );

      // The SETTER's own devices, which the old code never told.
      expect(to).toHaveBeenCalledWith('user:1');
      // The peer's devices, which always worked.
      expect(to).toHaveBeenCalledWith('user:2');
      expect(clientEmit).not.toHaveBeenCalledWith(
        'disappearingTimerUpdated',
        expect.anything(),
      );
    });

    // Same defect class as the timer above, found by reading the siblings after
    // the owner's report: every one of these used `client.emit`, so the ACTING
    // user's other devices were the only participants left uninformed.
    const localDoubles = () => {
      const to = jest.fn().mockReturnThis();
      const clientEmit = jest.fn();
      return {
        to,
        clientEmit,
        server: { to, emit: jest.fn() } as unknown as Server,
        client: {
          data: { user: { id: 1 } },
          emit: clientEmit,
        } as unknown as Socket,
        conversation: {
          id: 10,
          userOne: { id: 1 },
          userTwo: { id: 2 },
        } as unknown as Conversation,
      };
    };

    it('delivers messagePinned to BOTH users rooms, never the pinning socket alone', async () => {
      const { to, clientEmit, server, client, conversation } = localDoubles();
      conversationsService.findById.mockResolvedValue(conversation);
      conversationsService.setPinnedMessage.mockResolvedValue(conversation);
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        content: 'a',
        conversation,
        createdAt: new Date(),
        expiresAt: null,
        disappearAfterSeconds: null,
      } as unknown as Message);

      await service.handlePinMessage(
        client,
        { conversationId: 10, messageId: 100 },
        server,
      );

      expect(to).toHaveBeenCalledWith('user:1');
      expect(to).toHaveBeenCalledWith('user:2');
      expect(clientEmit).not.toHaveBeenCalledWith(
        'messagePinned',
        expect.anything(),
      );
    });

    it('delivers messageUnpinned to BOTH users rooms, never the unpinning socket alone', async () => {
      const { to, clientEmit, server, client, conversation } = localDoubles();
      conversationsService.findById.mockResolvedValue(conversation);
      // clearPinnedMessage resolves void, not the row.
      conversationsService.clearPinnedMessage.mockResolvedValue(undefined);

      await service.handleUnpinMessage(client, { conversationId: 10 }, server);

      expect(to).toHaveBeenCalledWith('user:1');
      expect(to).toHaveBeenCalledWith('user:2');
      expect(clientEmit).not.toHaveBeenCalledWith(
        'messageUnpinned',
        expect.anything(),
      );
    });

    it('delivers conversationMuteUpdated to the MUTERs room and never to the peer', async () => {
      // Mute is a private per-account preference: the other devices must learn
      // it (or one keeps buzzing), and the peer must NOT — that would leak
      // being muted.
      const { to, clientEmit, server, client, conversation } = localDoubles();
      conversationsService.findById.mockResolvedValue(conversation);
      notificationPreferences.setMute.mockResolvedValue({
        muted: true,
        until: null,
      });

      await service.handleSetConversationMute(
        client,
        { conversationId: 10, duration: 'forever' },
        server,
      );

      expect(to).toHaveBeenCalledWith('user:1');
      expect(to).not.toHaveBeenCalledWith('user:2');
      expect(clientEmit).not.toHaveBeenCalledWith(
        'conversationMuteUpdated',
        expect.anything(),
      );
    });
  });
});
