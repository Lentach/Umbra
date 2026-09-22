import { Test, TestingModule } from '@nestjs/testing';
import { MessagesService } from '../../messages/messages.service';
import { ConversationsService } from '../../conversations/conversations.service';
import { ChatValidationService } from './chat-validation.service';
import { UsersService } from '../../users/users.service';
import { ChatLinkPreviewService } from './chat-link-preview.service';
import { PushNotificationCoalescingService } from '../../push-notifications/push-notification-coalescing.service';
import { MediaCleanupService } from '../../media/media-cleanup.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { DeviceListService } from '../../key-bundles/device-list.service';
import { AccountAuthorization } from '../../key-bundles/account-authorization.entity';
import { ChatMessageService } from './chat-message.service';
import { User } from '../../users/user.entity';
import { Conversation } from '../../conversations/conversation.entity';
import { Message, MessageDeliveryStatus } from '../../messages/message.entity';
import { Socket } from 'socket.io';
import { Server } from 'socket.io';
import { SERVED_MESSAGE_IDS_MAX_BATCH } from '../dto/served-message-ids.dto';

/**
 * Join a mock socket to its user room AND its device room, mirroring the real
 * adapter shape that newestSocketForDevice/emitToDeviceNewestSocket read (see
 * utils/user-room.ts): rooms is a Map<roomKey, Set<socketId>> and sockets is a
 * Map<socketId, Socket>. Set preserves insertion order, so the LAST socket
 * installed for a device is that device's newest tab.
 *
 * `deviceId` defaults to 1 because that is what a socket authenticated with a
 * token predating the claim gets (§8), which is every socket in the tests that
 * do not care about multi-device.
 */
type MockSocket = { id: string; data: any; emit: jest.Mock };
function installSocket(
  server: any,
  userId: number,
  socketId: string,
  data: any = {},
  deviceId = 1,
): MockSocket {
  const s = (server.sockets ??= {
    adapter: { rooms: new Map() },
    sockets: new Map(),
  });
  s.adapter ??= { rooms: new Map() };
  s.adapter.rooms ??= new Map();
  s.sockets ??= new Map();
  const socket: MockSocket = { id: socketId, data, emit: jest.fn() };
  for (const roomKey of [`user:${userId}`, `device:${userId}:${deviceId}`]) {
    let room: Set<string> | undefined = s.adapter.rooms.get(roomKey);
    if (!room) {
      room = new Set<string>();
      s.adapter.rooms.set(roomKey, room);
    }
    room.add(socketId);
  }
  s.sockets.set(socketId, socket);
  return socket;
}

describe('ChatMessageService', () => {
  let service: ChatMessageService;
  let messagesService: jest.Mocked<MessagesService>;
  let conversationsService: jest.Mocked<ConversationsService>;
  let chatValidationService: jest.Mocked<ChatValidationService>;
  let usersService: jest.Mocked<UsersService>;
  let chatLinkPreviewService: jest.Mocked<ChatLinkPreviewService>;
  let pushCoalescingService: jest.Mocked<PushNotificationCoalescingService>;

  const mockSender: Partial<User> = { id: 1, username: 'alice' };
  const mockRecipient: Partial<User> = { id: 2, username: 'bob' };
  const mockConversation: Partial<Conversation> = {
    id: 10,
    disappearingTimer: 86400,
  };
  const mockMessage = {
    id: 100,
    content: '',
    sender: mockSender,
    conversation: mockConversation,
    createdAt: new Date(),
    deliveryStatus: 'SENT',
    messageType: 'VOICE',
    mediaUrl: 'https://res.cloudinary.com/demo/video/upload/v1/x.m4a',
    mediaDuration: 5,
    expiresAt: null,
  } as Message;

  /**
   * Plain jest.fn handle for the served-ids lookup. Asserting through
   * `messagesService.findServedMessageIds` would reference a class-typed
   * method (unbound-method); the raw fn has no `this` to lose.
   */
  let findServedMessageIdsMock: jest.Mock;
  let findBySendTokenMock: jest.Mock;
  /**
   * Raw handles for the T4 fan-out asserts, for the same reason as
   * `findServedMessageIdsMock` above: a bare jest.fn has no `this` to lose,
   * while asserting through the class-typed method trips `unbound-method`.
   */
  let createMock: jest.Mock;
  let isActiveMock: jest.Mock;
  let isRevokedMock: jest.Mock;
  let getAuthorizationMock: jest.Mock;
  let pendingReplacementVersionMock: jest.Mock;
  let schedulePushMock: jest.Mock;
  let findByConversationMock: jest.Mock;
  let findEnvelopeCiphertextsMock: jest.Mock;
  /** Raw handle: `expect(mediaCleanup.deleteMediaFile)` is `unbound-method`. */
  let deleteMediaFileMock: jest.Mock;
  let mockClient: Partial<Socket>;
  let mockServer: Partial<Server>;

  beforeEach(async () => {
    findServedMessageIdsMock = jest.fn().mockResolvedValue([]);
    // No committed row by default: every pre-existing send law is unchanged,
    // because a send without a token never reaches this lookup anyway.
    findBySendTokenMock = jest.fn().mockResolvedValue(null);
    createMock = jest.fn();
    isActiveMock = jest.fn().mockResolvedValue(true);
    // The I6 SILENCE gate (§5.5): live by default, so every existing
    // getServedMessageIds law below is unchanged.
    isRevokedMock = jest.fn().mockResolvedValue(false);
    getAuthorizationMock = jest.fn().mockResolvedValue(null);
    // Default: nobody owes a replacement enrollment, which is the ordinary
    // shape. The (lx) tests opt into the owed state explicitly.
    pendingReplacementVersionMock = jest.fn().mockResolvedValue(null);
    schedulePushMock = jest.fn().mockResolvedValue(undefined);
    findByConversationMock = jest.fn().mockResolvedValue([]);
    findEnvelopeCiphertextsMock = jest.fn().mockResolvedValue(new Map());
    deleteMediaFileMock = jest.fn().mockResolvedValue(undefined);
    mockClient = {
      data: { user: { id: 1 } },
      emit: jest.fn(),
    };
    mockServer = { to: jest.fn().mockReturnThis(), emit: jest.fn() };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ChatMessageService,
        {
          provide: MessagesService,
          useValue: {
            stampEnvelope: jest.fn().mockResolvedValue(undefined),
            create: createMock,
            findByConversation: findByConversationMock,
            findEnvelopeCiphertexts: findEnvelopeCiphertextsMock,
            findMediaUrlsByConversation: jest.fn().mockResolvedValue([]),
            deleteAllByConversation: jest.fn().mockResolvedValue(undefined),
            hideMessageForUser: jest.fn().mockResolvedValue(true),
            markConversationAsReadFromSender: jest.fn(),
            findByIdWithConversation: jest.fn(),
            updateDeliveryStatus: jest.fn(),
            deleteById: jest.fn(),
            applyEdit: jest.fn(),
            findServedMessageIds: findServedMessageIdsMock,
            findBySendToken: findBySendTokenMock,
          },
        },
        {
          provide: ConversationsService,
          useValue: {
            findOrCreate: jest.fn(),
            findById: jest.fn(),
            clearPinnedMessage: jest.fn().mockResolvedValue(undefined),
          },
        },
        {
          provide: ChatValidationService,
          useValue: {
            validateCanMessage: jest.fn().mockResolvedValue({ valid: true }),
          },
        },
        {
          provide: UsersService,
          useValue: { findById: jest.fn() },
        },
        {
          provide: ChatLinkPreviewService,
          useValue: { fetchAndEmitIfNeeded: jest.fn() },
        },
        {
          provide: PushNotificationCoalescingService,
          useValue: {
            scheduleMessagePush: schedulePushMock,
          },
        },
        {
          provide: MediaCleanupService,
          useValue: {
            deleteMediaFile: deleteMediaFileMock,
          },
        },
        {
          provide: DevicesService,
          useValue: { isActive: isActiveMock, isRevoked: isRevokedMock },
        },
        {
          // Unenrolled by default: a single-device account quotes no list
          // version, so the §5.2 cross-check does not apply to it.
          provide: DeviceListService,
          useValue: {
            getAuthorization: getAuthorizationMock,
            pendingReplacementVersion: pendingReplacementVersionMock,
          },
        },
      ],
    }).compile();

    service = module.get<ChatMessageService>(ChatMessageService);
    messagesService = module.get(MessagesService);
    conversationsService = module.get(ConversationsService);
    chatValidationService = module.get(ChatValidationService);
    usersService = module.get(UsersService);
    chatLinkPreviewService = module.get(ChatLinkPreviewService);
    pushCoalescingService = module.get(PushNotificationCoalescingService);
    jest.clearAllMocks();
  });

  describe('handleSendMessage', () => {
    it('should reject non-allowlisted mediaUrl and emit error (no message created)', async () => {
      const data = {
        recipientId: 2,
        content: '',
        messageType: 'VOICE',
        mediaUrl: 'https://evil.com/malicious.mp3',
        mediaDuration: 5,
      };

      await service.handleSendMessage(
        mockClient as Socket,
        data,
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({
          message: expect.stringMatching(
            /Validation failed|self-hosted media URL|Cloudinary/i,
          ),
        }),
      );
      expect(messagesService.create).not.toHaveBeenCalled();
    });

    it('should accept valid Cloudinary mediaUrl and create message', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      messagesService.create.mockResolvedValue(mockMessage as Message);

      const data = {
        recipientId: 2,
        content: '',
        messageType: 'VOICE',
        mediaUrl:
          'https://res.cloudinary.com/demo/video/upload/v1/voice-messages/abc.m4a',
        mediaDuration: 5,
      };

      await service.handleSendMessage(
        mockClient as Socket,
        data,
        mockServer as Server,
      );

      expect(messagesService.create).toHaveBeenCalledWith(
        '',
        mockSender,
        mockConversation,
        expect.objectContaining({
          messageType: 'VOICE',
          mediaUrl: data.mediaUrl,
          mediaDuration: 5,
        }),
      );
      expect(mockClient.emit).toHaveBeenCalledWith(
        'messageSent',
        expect.any(Object),
      );
    });
    it('should not create message and emit error when validation rejects the send', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: false,
        error: 'blocked',
      });

      await service.handleSendMessage(
        mockClient as Socket,
        { recipientId: 2, content: 'hello' },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'blocked',
      });
      expect(messagesService.create).not.toHaveBeenCalled();
    });

    it('should pass encryptedContent to create and store [encrypted] as content', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      messagesService.create.mockResolvedValue({
        ...mockMessage,
        content: '[encrypted]',
        encryptedContent: '3:base64ciphertext==',
        messageType: 'TEXT',
      } as Message);

      const data = {
        recipientId: 2,
        content: '[encrypted]',
        encryptedContent: '3:base64ciphertext==',
      };

      await service.handleSendMessage(
        mockClient as Socket,
        data,
        mockServer as Server,
      );

      expect(messagesService.create).toHaveBeenCalledWith(
        '[encrypted]',
        mockSender,
        mockConversation,
        expect.objectContaining({
          encryptedContent: '3:base64ciphertext==',
        }),
      );
      expect(mockClient.emit).toHaveBeenCalledWith(
        'messageSent',
        expect.any(Object),
      );
    });

    it('forwards encryptedContent to link-preview service', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      messagesService.create.mockResolvedValue({
        ...mockMessage,
        content: '[encrypted]',
        encryptedContent: '3:base64ciphertext==',
        messageType: 'TEXT',
      } as Message);

      const data = {
        recipientId: 2,
        content: '[encrypted]',
        encryptedContent: '3:base64ciphertext==',
      };

      await service.handleSendMessage(
        mockClient as Socket,
        data,
        mockServer as Server,
      );

      // Forwarding contract: handleSendMessage passes encryptedContent through to
      // ChatLinkPreviewService (which owns the skip decision — covered in its own spec).
      expect(chatLinkPreviewService.fetchAndEmitIfNeeded).toHaveBeenCalledWith(
        expect.objectContaining({
          encryptedContent: '3:base64ciphertext==',
        }),
      );
    });

    const arrangeSuccessfulTextMessageSend = () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      messagesService.create.mockResolvedValue({
        ...mockMessage,
        content: 'hello',
        messageType: 'TEXT',
        mediaUrl: null,
        mediaDuration: null,
      } as Message);
    };

    // Metadata privacy PR0.2: the client reports only whether the app is on
    // screen, never which chat, so a visible app suppresses the push whatever
    // it shows — the open socket already delivered newMessage.
    it('does not schedule push while the recipient app is visible', async () => {
      arrangeSuccessfulTextMessageSend();
      const bob = installSocket(mockServer, 2, 'socket-bob', {
        pushClientState: { clientVisible: true },
      });

      await service.handleSendMessage(
        mockClient as Socket,
        { recipientId: 2, content: 'hello' },
        mockServer as Server,
      );

      expect(bob.emit).toHaveBeenCalledWith('newMessage', expect.anything());
      expect(pushCoalescingService.scheduleMessagePush).not.toHaveBeenCalled();
    });

    it('schedules push when the recipient socket is online but hidden', async () => {
      arrangeSuccessfulTextMessageSend();
      const bob = installSocket(mockServer, 2, 'socket-bob', {
        pushClientState: { clientVisible: false },
      });

      await service.handleSendMessage(
        mockClient as Socket,
        { recipientId: 2, content: 'hello' },
        mockServer as Server,
      );

      expect(bob.emit).toHaveBeenCalledWith('newMessage', expect.anything());
      expect(pushCoalescingService.scheduleMessagePush).toHaveBeenCalledWith(
        2,
        10,
        'alice',
      );
    });

    it('does not suppress push when the visible tab is not the newest (BE-007 coherence)', async () => {
      arrangeSuccessfulTextMessageSend();
      // Older tab is visible; newer tab is not. Delivery AND suppression both
      // resolve to the newest tab, so the older visible tab must not suppress
      // the push — otherwise the message lands on a background tab while the
      // push is dropped and the user sees neither (a regression that was backed out).
      installSocket(mockServer, 2, 'sock-old', {
        pushClientState: { clientVisible: true },
      });
      installSocket(mockServer, 2, 'sock-new', {
        pushClientState: { clientVisible: false },
      });

      await service.handleSendMessage(
        mockClient as Socket,
        { recipientId: 2, content: 'hello' },
        mockServer as Server,
      );

      expect(pushCoalescingService.scheduleMessagePush).toHaveBeenCalledWith(
        2,
        10,
        'alice',
      );
    });

    /**
     * The lost-ack reconcile (spec §5.4). Wire falsification 14 covers the
     * happy re-ack — same token, same conversation, one row. These cover the
     * two branches nothing exercised: the cross-conversation REFUSAL, and the
     * fact that a re-ack never re-fans.
     */
    describe('sendToken reconcile', () => {
      it('REFUSES a token already spent on a different conversation', async () => {
        arrangeSuccessfulTextMessageSend();
        // A token is unique per SENDER, not per conversation. Re-acking it here
        // would report success for a message THIS conversation never received,
        // and writing it would violate UNIQUE(senderId, sendToken).
        findBySendTokenMock.mockResolvedValue({
          id: 77,
          conversation: { id: 999 },
        });

        await service.handleSendMessage(
          mockClient as Socket,
          { recipientId: 2, content: 'hello', sendToken: 'tok-abcdefgh' },
          mockServer as Server,
        );

        expect(mockClient.emit).toHaveBeenCalledWith('error', {
          message: 'duplicate_send_token',
        });
        expect(mockClient.emit).not.toHaveBeenCalledWith(
          'messageSent',
          expect.anything(),
        );
        expect(createMock).not.toHaveBeenCalled();
      });

      it('re-acks a token committed on THIS conversation without writing again', async () => {
        arrangeSuccessfulTextMessageSend();
        findBySendTokenMock.mockResolvedValue({
          id: 77,
          content: 'hello',
          conversation: mockConversation,
          sender: mockSender,
        });

        await service.handleSendMessage(
          mockClient as Socket,
          { recipientId: 2, content: 'hello', sendToken: 'tok-abcdefgh' },
          mockServer as Server,
        );

        // Re-fanning would deliver the same ciphertext twice, and Signal
        // decryption is not idempotent.
        expect(createMock).not.toHaveBeenCalled();
        expect(mockClient.emit).toHaveBeenCalledWith(
          'messageSent',
          expect.objectContaining({ id: 77 }),
        );
      });

      it('scopes the reconcile lookup to the authenticated sender', async () => {
        arrangeSuccessfulTextMessageSend();

        await service.handleSendMessage(
          mockClient as Socket,
          { recipientId: 2, content: 'hello', sendToken: 'tok-abcdefgh' },
          mockServer as Server,
        );

        // The sender comes from the socket, never from the payload.
        expect(findBySendTokenMock).toHaveBeenCalledWith(1, 'tok-abcdefgh');
      });
    });
  });

  describe('send fan-out ingest (spec §5.2 + §12 amendments (v)/(vi))', () => {
    /** The happy-path lookups every send below needs. */
    const arrangeSend = () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      createMock.mockResolvedValue(mockMessage);
    };

    /** An enrolled account whose current signed list is at [version]. */
    const authorization = (
      userId: number,
      version: number,
    ): AccountAuthorization =>
      ({
        userId,
        dakPub: `dak-${userId}`,
        enrollmentSig: `esig-${userId}`,
        enrollmentCreatedAt: new Date(1_700_000_000_000),
        listVersion: version,
        listSignature: `lsig-${userId}`,
        listCanonical: `canon-${userId}`,
        // The entity's `user` relation and `updatedAt` are never read by the
        // §5.2 cross-check, so this stays a partial stand-in.
      }) as AccountAuthorization;

    const send = (data: Record<string, unknown>) =>
      service.handleSendMessage(
        mockClient as Socket,
        data,
        mockServer as Server,
      );

    /** The payload of the caller's first emit of [event], if any. */
    const emittedPayload = (event: string) =>
      ((mockClient.emit as jest.Mock).mock.calls as unknown[][]).find(
        (call) => call[0] === event,
      )?.[1];

    it('normalizes a legacy single-ciphertext send to one device-1 envelope', async () => {
      arrangeSend();

      await send({
        recipientId: 2,
        content: '[encrypted]',
        encryptedContent: '3:legacy-ciphertext',
      });

      expect(createMock).toHaveBeenCalledWith(
        '[encrypted]',
        mockSender,
        mockConversation,
        expect.objectContaining({
          // The legacy column SURVIVES for a legacy send: its row is
          // indistinguishable from a pre-migration row, and today's clients
          // still read it through the whole §8 rollout window.
          encryptedContent: '3:legacy-ciphertext',
          envelopes: [
            { userId: 2, deviceId: 1, ciphertext: '3:legacy-ciphertext' },
          ],
        }),
      );
    });

    it('writes a new-model send as envelopes only, leaving the legacy column NULL', async () => {
      arrangeSend();

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [
          { userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' },
          { userId: 2, deviceId: 2, ciphertext: '3:for-bob-2' },
          { userId: 1, deviceId: 3, ciphertext: '2:self-sync' },
        ],
      });

      expect(createMock).toHaveBeenCalledWith(
        '[encrypted]',
        mockSender,
        mockConversation,
        expect.objectContaining({
          encryptedContent: null,
          envelopes: [
            { userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' },
            { userId: 2, deviceId: 2, ciphertext: '3:for-bob-2' },
            { userId: 1, deviceId: 3, ciphertext: '2:self-sync' },
          ],
        }),
      );
    });

    it('refuses two envelopes for one device — decrypt is not idempotent', async () => {
      arrangeSend();

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [
          { userId: 2, deviceId: 2, ciphertext: '3:first' },
          { userId: 2, deviceId: 2, ciphertext: '3:second' },
        ],
      });

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'duplicate_envelope_device',
      });
      expect(createMock).not.toHaveBeenCalled();
    });

    it('refuses an envelope addressed to a third party', async () => {
      arrangeSend();

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [{ userId: 99, deviceId: 1, ciphertext: '3:eavesdrop' }],
      });

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'unknown_envelope_user',
      });
      expect(createMock).not.toHaveBeenCalled();
    });

    it('refuses a self-sync envelope addressed to the origin device', async () => {
      arrangeSend();

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [{ userId: 1, deviceId: 1, ciphertext: '2:to-myself' }],
      });

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'self_envelope_for_origin_device',
      });
      expect(createMock).not.toHaveBeenCalled();
    });

    it('refuses an envelope for a device that was never activated', async () => {
      arrangeSend();
      isActiveMock.mockResolvedValue(false);

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [{ userId: 2, deviceId: 4, ciphertext: '3:ghost-device' }],
      });

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'unknown_recipient_device',
      });
      expect(createMock).not.toHaveBeenCalled();
    });

    it('exempts device 1 from the liveness check — it predates the devices table', async () => {
      arrangeSend();
      isActiveMock.mockResolvedValue(false);

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
      });

      expect(isActiveMock).not.toHaveBeenCalled();
      expect(createMock).toHaveBeenCalled();
    });

    // Amendment (lx), from the second gate round. (l) put the
    // replacement-owed refusal on `getDeviceList`, which the send path never
    // calls — so the bounce below handed peers the orphaned signed record and a
    // legacy send to a never-enrolled post-reset account committed straight to
    // the revoked device 1.
    describe('(lx) a send is refused while a replacement enrollment is owed', () => {
      it('REFUSES a NEW-MODEL send and writes ZERO rows', async () => {
        arrangeSend();
        pendingReplacementVersionMock.mockImplementation((userId: number) =>
          Promise.resolve(userId === 2 ? 4 : null),
        );

        await send({
          recipientId: 2,
          content: '[encrypted]',
          tempId: 'temp-1',
          envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
        });

        expect(emittedPayload('error')).toEqual({
          message: 'recipient_device_list_replacement_owed',
        });
        expect(createMock).not.toHaveBeenCalled();
      });

      it('REFUSES a LEGACY send, which used to bounce nothing and commit', async () => {
        arrangeSend();
        // The never-enrolled post-reset shape: no authorization row anywhere,
        // so `staleLists` contributes nothing and the old code committed to the
        // revoked device 1.
        getAuthorizationMock.mockResolvedValue(null);
        pendingReplacementVersionMock.mockImplementation((userId: number) =>
          Promise.resolve(userId === 2 ? 1 : null),
        );

        await send({
          recipientId: 2,
          content: 'plain legacy body',
          tempId: 'temp-2',
        });

        expect(emittedPayload('error')).toEqual({
          message: 'recipient_device_list_replacement_owed',
        });
        expect(emittedPayload('deviceListStale')).toBeUndefined();
        expect(createMock).not.toHaveBeenCalled();
      });

      it('REFUSES when the SENDER owes one, naming the sender', async () => {
        arrangeSend();
        pendingReplacementVersionMock.mockImplementation((userId: number) =>
          Promise.resolve(userId === 1 ? 3 : null),
        );

        await send({
          recipientId: 2,
          content: '[encrypted]',
          envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
        });

        expect(emittedPayload('error')).toEqual({
          message: 'sender_device_list_replacement_owed',
        });
        expect(createMock).not.toHaveBeenCalled();
      });

      it('the orphaned record is NEVER handed back on the bounce', async () => {
        arrangeSend();
        // A surviving enrollment row AND a replacement owed: exactly the
        // post-reset shape whose record a peer would VERIFY under its
        // pre-reset anchor and then adopt as a roster of revoked devices.
        getAuthorizationMock.mockImplementation((userId: number) =>
          Promise.resolve(userId === 2 ? authorization(2, 7) : null),
        );
        pendingReplacementVersionMock.mockImplementation((userId: number) =>
          Promise.resolve(userId === 2 ? 8 : null),
        );

        await send({
          recipientId: 2,
          content: '[encrypted]',
          tempId: 'temp-3',
          recipientListVersion: 6,
          envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
        });

        // Pre-(lx) this emitted deviceListStale carrying dakPub/enrollmentSig/
        // listCanonical/listSignature for the dead roster.
        expect(emittedPayload('deviceListStale')).toBeUndefined();
        expect(emittedPayload('error')).toEqual({
          message: 'recipient_device_list_replacement_owed',
        });
        expect(createMock).not.toHaveBeenCalled();
      });

      it('POSITIVE CONTROL: an ordinary send is untouched', async () => {
        arrangeSend();

        await send({
          recipientId: 2,
          content: '[encrypted]',
          envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
        });

        // Nobody owes anything, so the refusal must stand aside entirely.
        expect(emittedPayload('error')).toBeUndefined();
        expect(createMock).toHaveBeenCalled();
      });
    });

    it('falsification 5: a stale recipient stamp refuses the send with ZERO rows written', async () => {
      arrangeSend();
      getAuthorizationMock.mockImplementation((userId: number) =>
        Promise.resolve(userId === 2 ? authorization(2, 7) : null),
      );

      await send({
        recipientId: 2,
        content: '[encrypted]',
        tempId: 'temp-42',
        recipientListVersion: 6,
        envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
      });

      expect(emittedPayload('deviceListStale')).toEqual({
        success: false,
        error: 'device_list_stale',
        tempId: 'temp-42',
        lists: [
          {
            userId: 2,
            version: 7,
            listCanonical: 'canon-2',
            listSignature: 'lsig-2',
            enrollment: {
              dakPub: 'dak-2',
              enrollmentSig: 'esig-2',
              enrollmentCreatedAt: 1_700_000_000_000,
            },
          },
        ],
      });
      // Nothing was persisted and nothing was delivered.
      expect(createMock).not.toHaveBeenCalled();
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'messageSent',
        expect.anything(),
      );
    });

    it('reports BOTH stale parties in one refusal, recipient first', async () => {
      arrangeSend();
      getAuthorizationMock.mockImplementation((userId: number) =>
        Promise.resolve(authorization(userId, 5)),
      );

      await send({
        recipientId: 2,
        content: '[encrypted]',
        senderListVersion: 4,
        recipientListVersion: 4,
        envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
      });

      const payload = emittedPayload('deviceListStale') as {
        lists: Array<{ userId: number }>;
      };
      expect(payload.lists.map((entry) => entry.userId)).toEqual([2, 1]);
    });

    it('treats an ABSENT stamp for an enrolled party as stale — fail closed', async () => {
      arrangeSend();
      getAuthorizationMock.mockImplementation((userId: number) =>
        Promise.resolve(userId === 2 ? authorization(2, 3) : null),
      );

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
      });

      expect(emittedPayload('deviceListStale')).toBeDefined();
      expect(createMock).not.toHaveBeenCalled();
    });

    it('skips the cross-check for a party that never enrolled', async () => {
      arrangeSend();

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' }],
      });

      expect(emittedPayload('deviceListStale')).toBeUndefined();
      expect(createMock).toHaveBeenCalled();
    });

    it('accepts a legacy send while NEITHER party is enrolled', async () => {
      arrangeSend();

      await send({
        recipientId: 2,
        content: '[encrypted]',
        encryptedContent: '3:legacy-ciphertext',
      });

      expect(emittedPayload('deviceListStale')).toBeUndefined();
      expect(createMock).toHaveBeenCalled();
    });

    // Amendment (x). A legacy send reaches device 1 only, so once the peer has
    // a device list, accepting it would silently DROP every other device —
    // exactly what invariant I5 forbids. Refusing it (and handing back the
    // signed list) is what upgrades the client to a fan-out, and is what lets
    // the client skip a device-list round trip on every single-device send.
    it('REFUSES a legacy send once the recipient is enrolled — never drops a device', async () => {
      arrangeSend();
      getAuthorizationMock.mockImplementation((userId: number) =>
        Promise.resolve(userId === 2 ? authorization(2, 4) : null),
      );

      await send({
        recipientId: 2,
        content: '[encrypted]',
        tempId: 'temp-legacy',
        encryptedContent: '3:legacy-ciphertext',
      });

      const payload = emittedPayload('deviceListStale') as {
        tempId?: string;
        lists: Array<{ userId: number; version: number }>;
      };
      expect(payload.tempId).toBe('temp-legacy');
      expect(payload.lists).toEqual([
        expect.objectContaining({ userId: 2, version: 4 }),
      ]);
      expect(createMock).not.toHaveBeenCalled();
    });

    it('REFUSES a legacy send once the SENDER is enrolled — its own devices need the copy', async () => {
      arrangeSend();
      getAuthorizationMock.mockImplementation((userId: number) =>
        Promise.resolve(userId === 1 ? authorization(1, 6) : null),
      );

      await send({
        recipientId: 2,
        content: '[encrypted]',
        encryptedContent: '3:legacy-ciphertext',
      });

      const payload = emittedPayload('deviceListStale') as {
        lists: Array<{ userId: number }>;
      };
      expect(payload.lists.map((entry) => entry.userId)).toEqual([1]);
      expect(createMock).not.toHaveBeenCalled();
    });

    it('never refuses a ciphertext-less send — it has no envelope to fan out', async () => {
      arrangeSend();
      getAuthorizationMock.mockImplementation((userId: number) =>
        Promise.resolve(authorization(userId, 9)),
      );

      await send({ recipientId: 2, content: '', messageType: 'PING' });

      expect(emittedPayload('deviceListStale')).toBeUndefined();
      expect(createMock).toHaveBeenCalled();
    });

    it('delivers each device its OWN ciphertext in its own device room', async () => {
      arrangeSend();
      const bobDevice1 = installSocket(mockServer, 2, 'socket-bob-d1', {}, 1);
      const bobDevice2 = installSocket(mockServer, 2, 'socket-bob-d2', {}, 2);

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [
          { userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' },
          { userId: 2, deviceId: 2, ciphertext: '3:for-bob-2' },
        ],
      });

      expect(bobDevice1.emit).toHaveBeenCalledWith(
        'newMessage',
        expect.objectContaining({ encryptedContent: '3:for-bob-1' }),
      );
      expect(bobDevice2.emit).toHaveBeenCalledWith(
        'newMessage',
        expect.objectContaining({ encryptedContent: '3:for-bob-2' }),
      );
      // Never the other device's ciphertext: decrypting a foreign envelope
      // consumes a key that device does not own and fails terminally.
      expect(bobDevice1.emit).not.toHaveBeenCalledWith(
        'newMessage',
        expect.objectContaining({ encryptedContent: '3:for-bob-2' }),
      );
      expect(bobDevice2.emit).not.toHaveBeenCalledWith(
        'newMessage',
        expect.objectContaining({ encryptedContent: '3:for-bob-1' }),
      );
      // Ciphertext is never room-broadcast to the account.
      expect(mockServer.to).not.toHaveBeenCalledWith('user:2');
    });

    it("delivers a self-sync envelope to the sender's OTHER device", async () => {
      arrangeSend();
      const aliceDevice2 = installSocket(
        mockServer,
        1,
        'socket-alice-d2',
        {},
        2,
      );

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [
          { userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' },
          { userId: 1, deviceId: 2, ciphertext: '2:self-sync' },
        ],
      });

      expect(aliceDevice2.emit).toHaveBeenCalledWith(
        'newMessage',
        expect.objectContaining({ encryptedContent: '2:self-sync' }),
      );
    });

    it('still pushes when only ONE of the recipient devices is visible', async () => {
      arrangeSend();
      installSocket(
        mockServer,
        2,
        'socket-bob-d1',
        { pushClientState: { clientVisible: true } },
        1,
      );
      installSocket(
        mockServer,
        2,
        'socket-bob-d2',
        { pushClientState: { clientVisible: false } },
        2,
      );

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [
          { userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' },
          { userId: 2, deviceId: 2, ciphertext: '3:for-bob-2' },
        ],
      });

      // Device 2 is in the background, so it still deserves a wake-up.
      expect(schedulePushMock).toHaveBeenCalledWith(2, 10, 'alice');
    });

    it('suppresses the push only when EVERY delivered device is visible', async () => {
      arrangeSend();
      const visible = { pushClientState: { clientVisible: true } };
      installSocket(mockServer, 2, 'socket-bob-d1', visible, 1);
      installSocket(mockServer, 2, 'socket-bob-d2', visible, 2);

      await send({
        recipientId: 2,
        content: '[encrypted]',
        envelopes: [
          { userId: 2, deviceId: 1, ciphertext: '3:for-bob-1' },
          { userId: 2, deviceId: 2, ciphertext: '3:for-bob-2' },
        ],
      });

      expect(schedulePushMock).not.toHaveBeenCalled();
    });
  });

  describe('E2E encrypted message types', () => {
    it('should store [encrypted] content and pass encryptedContent for PING', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      messagesService.create.mockResolvedValue({
        ...mockMessage,
        content: '[encrypted]',
        encryptedContent: '3:pingCiphertext==',
        messageType: 'TEXT', // server doesn't know real type when encrypted
        mediaUrl: null,
      } as Message);

      const data = {
        recipientId: 2,
        content: '[encrypted]',
        encryptedContent: '3:pingCiphertext==',
        // No messageType, mediaUrl — hidden inside encrypted envelope
      };

      await service.handleSendMessage(
        mockClient as Socket,
        data,
        mockServer as Server,
      );

      expect(messagesService.create).toHaveBeenCalledWith(
        '[encrypted]',
        mockSender,
        mockConversation,
        expect.objectContaining({
          encryptedContent: '3:pingCiphertext==',
        }),
      );
      // Verify no mediaUrl or messageType leaked from client
      const createCall = messagesService.create.mock.calls[0];
      const opts = createCall[3] as Record<string, unknown>;
      expect(opts.mediaUrl).toBeUndefined();
      expect(opts.messageType).toBeUndefined();
    });

    it.each([
      [
        'VOICE',
        '3:voiceCiphertext==',
        'http://localhost:3000/media/msgs/voice.bin',
      ],
      [
        'IMAGE',
        '3:imageCiphertext==',
        'http://localhost:3000/media/msgs/image.bin',
      ],
      [
        'GIF',
        '3:base64encryptedGifData',
        'http://localhost:3000/media/msgs/gif.bin',
      ],
      [
        'FILE',
        '3:base64encryptedFileData',
        'http://localhost:3000/media/msgs/file.bin',
      ],
      [
        'VIDEO',
        '3:base64encryptedVideoData',
        'http://localhost:3000/media/msgs/video.bin',
      ],
    ])(
      'should persist mediaUrl and messageType for encrypted %s',
      async (messageType, encryptedContent, mediaUrl) => {
        chatValidationService.validateCanMessage.mockResolvedValue({
          valid: true,
        });
        usersService.findById
          .mockResolvedValueOnce(mockSender as User)
          .mockResolvedValueOnce(mockRecipient as User);
        conversationsService.findOrCreate.mockResolvedValue(
          mockConversation as Conversation,
        );
        messagesService.create.mockResolvedValue({
          ...mockMessage,
          content: '[encrypted]',
          encryptedContent,
          messageType,
          mediaUrl,
        } as Message);

        const data = {
          recipientId: 2,
          content: '[encrypted]',
          encryptedContent,
          messageType,
          mediaUrl,
        };

        await service.handleSendMessage(
          mockClient as Socket,
          data,
          mockServer as Server,
        );

        const opts = messagesService.create.mock.calls[0][3] as Record<
          string,
          unknown
        >;
        expect(opts.encryptedContent).toBe(encryptedContent);
        expect(opts.messageType).toBe(messageType);
        expect(opts.mediaUrl).toBe(mediaUrl);
      },
    );

    it('should emit messageSent and newMessage with encryptedContent for online recipient', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );

      const savedMsg = {
        ...mockMessage,
        id: 200,
        content: '[encrypted]',
        encryptedContent: '3:cipher==',
        messageType: 'TEXT',
        mediaUrl: null,
        mediaDuration: null,
        reactions: null,
        replyTo: null,
        expiresAt: null,
      } as Message;
      messagesService.create.mockResolvedValue(savedMsg);

      const bob = installSocket(mockServer, 2, 'socket-bob');

      const data = {
        recipientId: 2,
        content: '[encrypted]',
        encryptedContent: '3:cipher==',
        tempId: 'temp-123',
      };

      await service.handleSendMessage(
        mockClient as Socket,
        data,
        mockServer as Server,
      );

      // messageSent to sender
      expect(mockClient.emit).toHaveBeenCalledWith(
        'messageSent',
        expect.objectContaining({
          content: '[encrypted]',
          encryptedContent: '3:cipher==',
          tempId: 'temp-123',
        }),
      );

      // newMessage to recipient (single newest tab via emitToNewestTab)
      expect(bob.emit).toHaveBeenCalledWith(
        'newMessage',
        expect.objectContaining({
          content: '[encrypted]',
          encryptedContent: '3:cipher==',
        }),
      );
    });

    it('delivers newMessage to exactly one (newest) tab and never via the user room', async () => {
      // Signal decryption is NOT idempotent: it consumes the message key and advances
      // the ratchet. Both tabs share one IndexedDB session, so fanning one ciphertext
      // to two tabs makes the second tab decrypt FAIL into the client's
      // session-destroying decryption-failure policy. newMessage MUST stay single-tab;
      // this test exists to stop anyone tidying it into a room emit.
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      messagesService.create.mockResolvedValue({
        ...mockMessage,
        id: 200,
        content: '[encrypted]',
        encryptedContent: '3:cipher==',
        messageType: 'TEXT',
        mediaUrl: null,
        mediaDuration: null,
      } as Message);
      const older = installSocket(mockServer, 2, 'sock-old');
      const newer = installSocket(mockServer, 2, 'sock-new');

      await service.handleSendMessage(
        mockClient as Socket,
        {
          recipientId: 2,
          content: '[encrypted]',
          encryptedContent: '3:cipher==',
        },
        mockServer as Server,
      );

      // Exactly the newest tab receives it; the older tab does not; never room-fanned.
      expect(newer.emit).toHaveBeenCalledWith('newMessage', expect.anything());
      expect(older.emit).not.toHaveBeenCalledWith(
        'newMessage',
        expect.anything(),
      );
      expect(mockServer.to).not.toHaveBeenCalledWith('user:2');
    });
  });

  describe('read-based disappearing messages', () => {
    it('stores disappearAfterSeconds with null expiresAt on send', async () => {
      chatValidationService.validateCanMessage.mockResolvedValue({
        valid: true,
      });
      usersService.findById
        .mockResolvedValueOnce(mockSender as User)
        .mockResolvedValueOnce(mockRecipient as User);
      conversationsService.findOrCreate.mockResolvedValue(
        mockConversation as Conversation,
      );
      messagesService.create.mockResolvedValue({
        ...mockMessage,
        disappearAfterSeconds: 300,
        expiresAt: null,
      } as Message);

      await service.handleSendMessage(
        mockClient as Socket,
        { recipientId: 2, content: 'hi', expiresIn: 300 },
        mockServer as Server,
      );

      expect(messagesService.create).toHaveBeenCalledWith(
        'hi',
        mockSender,
        mockConversation,
        expect.objectContaining({
          disappearAfterSeconds: 300,
          expiresAt: null,
        }),
      );
    });

    it('handleMarkConversationRead emits expiresAt to sender and reader', async () => {
      const conv = {
        id: 10,
        userOne: { id: 1 },
        userTwo: { id: 2 },
      };
      const expiresAt = new Date('2026-05-17T13:00:00Z');
      const updatedMsg = {
        id: 50,
        sender: { id: 2 },
        deliveryStatus: MessageDeliveryStatus.READ,
        expiresAt,
        disappearAfterSeconds: 3600,
      } as Message;

      conversationsService.findById.mockResolvedValue(conv as Conversation);
      messagesService.markConversationAsReadFromSender.mockResolvedValue([
        updatedMsg,
      ]);
      const toMock = jest.fn().mockReturnValue({ emit: jest.fn() });
      mockServer.to = toMock;

      mockClient.data = { user: { id: 1 } };

      await service.handleMarkConversationRead(
        mockClient as Socket,
        { conversationId: 10 },
        mockServer as Server,
      );

      expect(
        messagesService.markConversationAsReadFromSender,
      ).toHaveBeenCalledWith(10, 2);
      expect(toMock).toHaveBeenCalledWith('user:2');
      expect(toMock).toHaveBeenCalledWith('user:1');
      const emitCalls = toMock.mock.results.map((r) => r.value.emit.mock.calls);
      expect(
        emitCalls.some((calls) =>
          calls.some(
            (c) =>
              c[0] === 'messageDelivered' &&
              c[1].expiresAt === expiresAt.toISOString(),
          ),
        ),
      ).toBe(true);
    });
  });

  describe('handleMessageDelivered', () => {
    it('rejects when caller is the sender, not the recipient', async () => {
      // Message sender = userId 1 (the caller). Recipient = userId 2.
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      const msg = { id: 99, sender: { id: 1 }, conversation: conv };
      messagesService.findByIdWithConversation.mockResolvedValue(
        msg as Message,
      );
      messagesService.updateDeliveryStatus.mockResolvedValue(null);

      await service.handleMessageDelivered(
        mockClient as Socket,
        { messageId: 99 },
        mockServer as Server,
      );

      expect(messagesService.updateDeliveryStatus).not.toHaveBeenCalled();
    });

    it('allows when caller is the recipient', async () => {
      // Message sender = userId 2. Caller = userId 1 (recipient).
      const conv = { id: 10, userOne: { id: 2 }, userTwo: { id: 1 } };
      const updatedMsg = {
        id: 99,
        sender: { id: 2 },
        conversation: conv,
        deliveryStatus: 'DELIVERED',
      };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 99,
        sender: { id: 2 },
        conversation: conv,
      } as Message);
      messagesService.updateDeliveryStatus.mockResolvedValue(
        updatedMsg as Message,
      );

      await service.handleMessageDelivered(
        mockClient as Socket,
        { messageId: 99 },
        mockServer as Server,
      );

      expect(messagesService.updateDeliveryStatus).toHaveBeenCalledWith(
        99,
        MessageDeliveryStatus.DELIVERED,
      );
    });

    it('room-addresses messageDelivered so every tab of the sender receives it (BE-007 multi-tab)', async () => {
      const conv = { id: 10, userOne: { id: 2 }, userTwo: { id: 1 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 99,
        sender: { id: 2 },
        conversation: conv,
      } as Message);
      messagesService.updateDeliveryStatus.mockResolvedValue({
        id: 99,
        sender: { id: 2 },
        conversation: conv,
        deliveryStatus: 'DELIVERED',
      } as Message);
      // Sender (user 2) has TWO open tabs; both are joined to room user:2.
      installSocket(mockServer, 2, 'sock-2a');
      installSocket(mockServer, 2, 'sock-2b');

      await service.handleMessageDelivered(
        mockClient as Socket,
        { messageId: 99 },
        mockServer as Server,
      );

      // Room-addressed, not a single socket id: both tabs receive the receipt.
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
    });
  });

  describe('handleDeleteMessage', () => {
    /**
     * Captures the rooms a chained `server.to(a).to(b).emit(...)` addressed.
     * Locals, not `mockServer.to`, because `expect(mockServer.to)` is an
     * unbound-method lint error and the ratchet floor may not rise.
     */
    const captureFanOut = () => {
      const rooms: string[] = [];
      const emit = jest.fn();
      const chain = { to: jest.fn(), emit };
      chain.to.mockImplementation((room: string) => {
        rooms.push(room);
        return chain;
      });
      mockServer.to = chain.to as unknown as Server['to'];
      return { rooms, emit };
    };

    const arrangeDeletable = (pinnedMessageId: number | null = null) => {
      const conv = {
        id: 10,
        userOne: { id: 1 },
        userTwo: { id: 2 },
        pinnedMessageId,
      };
      const msg = {
        id: 55,
        sender: { id: 1 },
        conversation: conv,
        mediaUrl: null,
      };
      messagesService.findByIdWithConversation.mockResolvedValue(
        msg as Message,
      );
      messagesService.deleteById.mockResolvedValue(msg as Message);
      return msg;
    };

    it('clears pin and announces messageUnpinned to both users when deleting a pinned message for everyone', async () => {
      arrangeDeletable(55);
      const { rooms, emit } = captureFanOut();

      await service.handleDeleteMessage(
        mockClient as Socket,
        { messageId: 55, mode: 'for_everyone' },
        mockServer as Server,
      );

      expect(conversationsService.clearPinnedMessage).toHaveBeenCalledWith(10);
      expect(emit).toHaveBeenCalledWith('messageUnpinned', {
        conversationId: 10,
      });
      // The deleter's own other devices must drop the pinned banner too.
      expect(rooms).toContain('user:1');
      expect(rooms).toContain('user:2');
    });

    it('fans messageDeleted for_everyone to BOTH users rooms, so the deleter other devices purge too', async () => {
      arrangeDeletable();
      const { rooms, emit } = captureFanOut();

      await service.handleDeleteMessage(
        mockClient as Socket,
        { messageId: 55, mode: 'for_everyone' },
        mockServer as Server,
      );

      // The row, its envelopes and its media are gone for good. A device that
      // never hears this keeps decrypted plaintext forever: the client's
      // history merge never prunes rows a server snapshot omits.
      expect(emit).toHaveBeenCalledWith('messageDeleted', {
        messageId: 55,
        conversationId: 10,
        forEveryone: true,
      });
      expect(rooms).toEqual(['user:1', 'user:2']);
      // Socket-scoped delivery would reach exactly one of the deleter's tabs.
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'messageDeleted',
        expect.anything(),
      );
    });

    it('never unlinks the media of a message the caller did not send', async () => {
      // Membership is NOT authorization. The unlink used to run before
      // `deleteById` rejected the non-sender, so the peer could destroy the
      // sender's file on disk and leave the row behind pointing at nothing —
      // irreversible, and reproduced over the wire on the dev stack
      // (2026-09-14, msg 977). `deleteById` still refuses, so a test that
      // only asserts the refusal passes either way: the unlink is the claim.
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 55,
        sender: { id: 2 },
        conversation: conv,
        mediaUrl: 'http://localhost:3000/media/msgs/victim.bin',
      } as Message);
      messagesService.deleteById.mockResolvedValue(null);

      await service.handleDeleteMessage(
        mockClient as Socket,
        { messageId: 55, mode: 'for_everyone' },
        mockServer as Server,
      );

      expect(deleteMediaFileMock).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Only the sender can delete for everyone',
      });
    });

    it('keeps a for_me delete inside the hiding user rooms and never tells the peer', async () => {
      arrangeDeletable();
      const { rooms, emit } = captureFanOut();

      await service.handleDeleteMessage(
        mockClient as Socket,
        { messageId: 55, mode: 'for_me' },
        mockServer as Server,
      );

      // `hiddenByUserIds` is per-USER state: every device of the hider must
      // hide it, while the peer goes on reading the message.
      expect(emit).toHaveBeenCalledWith('messageDeleted', {
        messageId: 55,
        conversationId: 10,
        forEveryone: false,
      });
      expect(rooms).toEqual(['user:1']);
      expect(rooms).not.toContain('user:2');
    });

    it('fans chatHistoryCleared to both users, because the wipe destroys every row for both', async () => {
      conversationsService.findById.mockResolvedValue({
        id: 10,
        userOne: { id: 1 },
        userTwo: { id: 2 },
      } as never);
      const { rooms, emit } = captureFanOut();

      await service.handleClearChatHistory(
        mockClient as Socket,
        { conversationId: 10 },
        mockServer as Server,
      );

      expect(emit).toHaveBeenCalledWith('chatHistoryCleared', {
        conversationId: 10,
      });
      expect(rooms).toEqual(['user:1', 'user:2']);
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'chatHistoryCleared',
        expect.anything(),
      );
    });
  });

  describe('handleEditMessage', () => {
    it('normalizes a legacy edit to the peer device-1 envelope and echoes the editor', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      const msg = {
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'TEXT',
        // A LEGACY row: its ciphertext lives in the column, so the column must
        // keep being written (amendment (xxxii)).
        content: '[encrypted]',
        encryptedContent: 'old-cipher',
      } as unknown as Message;
      const editedAt = new Date('2026-06-22T12:00:00Z');
      messagesService.findByIdWithConversation.mockResolvedValue(msg);
      messagesService.applyEdit.mockResolvedValue({
        id: 100,
        editedAt,
      } as Message);
      const bob = installSocket(mockServer, 2, 'sock-bob');

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          encryptedContent: 'new-cipher',
        },
        mockServer as Server,
      );

      expect(messagesService.applyEdit).toHaveBeenCalledWith(100, 1, {
        encryptedContent: 'new-cipher',
        content: '[encrypted]',
        originDeviceId: 1,
        envelopes: [{ userId: 2, deviceId: 1, ciphertext: 'new-cipher' }],
      });
      // The editing device produced the ciphertext, so its echo carries none.
      expect(mockClient.emit).toHaveBeenCalledWith('messageEdited', {
        messageId: 100,
        conversationId: 10,
        content: '[encrypted]',
        editedAt: '2026-06-22T12:00:00.000Z',
        originDeviceId: 1,
        encryptedContent: null,
      });
      expect(bob.emit).toHaveBeenCalledWith('messageEdited', {
        messageId: 100,
        conversationId: 10,
        content: '[encrypted]',
        editedAt: '2026-06-22T12:00:00.000Z',
        originDeviceId: 1,
        encryptedContent: 'new-cipher',
      });
    });

    it('fans one edited ciphertext PER DEVICE and re-points originDeviceId at the editing device', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'TEXT',
        // A NEW-MODEL row: ciphertext lives only in envelopes.
        content: '[encrypted]',
        encryptedContent: null,
        originDeviceId: 1,
      } as unknown as Message);
      messagesService.applyEdit.mockResolvedValue({
        id: 100,
        editedAt: new Date('2026-06-22T12:00:00Z'),
      } as Message);
      isActiveMock.mockResolvedValue(true);
      const bob1 = installSocket(mockServer, 2, 'sock-bob-1');
      const bob2 = installSocket(mockServer, 2, 'sock-bob-2', {}, 2);
      const ownDevice3 = installSocket(mockServer, 1, 'sock-me-3', {}, 3);
      // The edit is issued from device 2 of the sender — a device that did NOT
      // send the row. Its ciphertexts are bound to ITS ratchet.
      const editor = { ...mockClient, data: { user: { id: 1, deviceId: 2 } } };

      await service.handleEditMessage(
        editor as unknown as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          envelopes: [
            { userId: 2, deviceId: 1, ciphertext: '3:bob-1' },
            { userId: 2, deviceId: 2, ciphertext: '3:bob-2' },
            { userId: 1, deviceId: 3, ciphertext: '2:self-3' },
          ],
        },
        mockServer as Server,
      );

      // The row is re-pointed at the EDITING device: the receiver selects its
      // Signal session from this field, so leaving it at 1 would Bad-MAC every
      // copy (amendment (xxx)).
      expect(messagesService.applyEdit).toHaveBeenCalledWith(100, 1, {
        // A new-model row's legacy column is never written.
        encryptedContent: undefined,
        content: '[encrypted]',
        originDeviceId: 2,
        envelopes: [
          { userId: 2, deviceId: 1, ciphertext: '3:bob-1' },
          { userId: 2, deviceId: 2, ciphertext: '3:bob-2' },
          { userId: 1, deviceId: 3, ciphertext: '2:self-3' },
        ],
      });
      // Each device gets exactly ITS OWN ciphertext — Signal decrypt is not
      // idempotent, so a shared payload would brick a ratchet.
      expect(bob1.emit).toHaveBeenCalledWith(
        'messageEdited',
        expect.objectContaining({
          encryptedContent: '3:bob-1',
          originDeviceId: 2,
        }),
      );
      expect(bob2.emit).toHaveBeenCalledWith(
        'messageEdited',
        expect.objectContaining({ encryptedContent: '3:bob-2' }),
      );
      expect(ownDevice3.emit).toHaveBeenCalledWith(
        'messageEdited',
        expect.objectContaining({ encryptedContent: '2:self-3' }),
      );
    });

    it('refuses two envelopes for one device on an edit', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'TEXT',
        content: '[encrypted]',
        encryptedContent: null,
      } as unknown as Message);
      isActiveMock.mockResolvedValue(true);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          envelopes: [
            { userId: 2, deviceId: 2, ciphertext: '3:first' },
            { userId: 2, deviceId: 2, ciphertext: '3:second' },
          ],
        },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('editMessageFailed', {
        messageId: 100,
        reason: 'duplicate_envelope_device',
      });
      expect(messagesService.applyEdit).not.toHaveBeenCalled();
    });

    it('refuses a self-sync envelope addressed to the EDITING device', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'TEXT',
        content: '[encrypted]',
        encryptedContent: null,
      } as unknown as Message);
      isActiveMock.mockResolvedValue(true);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          envelopes: [{ userId: 1, deviceId: 1, ciphertext: '2:to-myself' }],
        },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('editMessageFailed', {
        messageId: 100,
        reason: 'self_envelope_for_origin_device',
      });
      expect(messagesService.applyEdit).not.toHaveBeenCalled();
    });

    it('refuses an envelope for a device that is not live', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'TEXT',
        content: '[encrypted]',
        encryptedContent: null,
      } as unknown as Message);
      isActiveMock.mockResolvedValue(false);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          envelopes: [{ userId: 2, deviceId: 4, ciphertext: '3:ghost' }],
        },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('editMessageFailed', {
        messageId: 100,
        reason: 'unknown_recipient_device',
      });
      expect(messagesService.applyEdit).not.toHaveBeenCalled();
    });

    it('bounces a stale device list with deviceListStale and writes NOTHING', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'TEXT',
        content: '[encrypted]',
        encryptedContent: null,
      } as unknown as Message);
      isActiveMock.mockResolvedValue(true);
      getAuthorizationMock.mockImplementation((userId: number) =>
        Promise.resolve(
          userId === 2
            ? ({
                userId: 2,
                listVersion: 7,
                listCanonical: 'canon',
                listSignature: 'sig',
                dakPub: 'dak',
                enrollmentSig: 'esig',
                enrollmentCreatedAt: new Date(0),
              } as never)
            : null,
        ),
      );

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:bob-1' }],
          // Quoting v6 against the live v7.
          recipientListVersion: 6,
        },
        mockServer as Server,
      );

      expect(mockClient.emit).toHaveBeenCalledWith(
        'deviceListStale',
        expect.objectContaining({
          success: false,
          error: 'device_list_stale',
          messageId: 100,
        }),
      );
      // Falsification-5 shape: a refused edit mutates nothing at all.
      expect(messagesService.applyEdit).not.toHaveBeenCalled();
    });

    it('never mints or consumes a sendToken on an edit', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      messagesService.findByIdWithConversation.mockResolvedValue({
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'TEXT',
        content: '[encrypted]',
        encryptedContent: null,
      } as unknown as Message);
      messagesService.applyEdit.mockResolvedValue({
        id: 100,
        editedAt: new Date('2026-06-22T12:00:00Z'),
      } as Message);
      isActiveMock.mockResolvedValue(true);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          envelopes: [{ userId: 2, deviceId: 1, ciphertext: '3:bob-1' }],
        },
        mockServer as Server,
      );

      expect(
        JSON.stringify(messagesService.applyEdit.mock.calls[0]),
      ).not.toContain('sendToken');
    });

    it('emits editMessageFailed with reason not_sender when caller is not the sender', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      const msg = {
        id: 100,
        sender: { id: 2 },
        conversation: conv,
        createdAt: new Date(),
      } as unknown as Message;
      messagesService.findByIdWithConversation.mockResolvedValue(msg);
      messagesService.applyEdit.mockResolvedValue(null);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          encryptedContent: 'new-cipher',
        },
        mockServer as Server,
      );

      expect(messagesService.applyEdit).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('editMessageFailed', {
        messageId: 100,
        reason: 'not_sender',
      });
    });

    it('emits editMessageFailed with reason window_expired when the edit window has passed', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      const msg = {
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(Date.now() - 16 * 60 * 1000),
      } as unknown as Message;
      messagesService.findByIdWithConversation.mockResolvedValue(msg);
      messagesService.applyEdit.mockResolvedValue(null);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          encryptedContent: 'new-cipher',
        },
        mockServer as Server,
      );

      expect(messagesService.applyEdit).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('editMessageFailed', {
        messageId: 100,
        reason: 'window_expired',
      });
    });

    it('emits editMessageFailed with reason not_found when the message does not exist', async () => {
      messagesService.findByIdWithConversation.mockResolvedValue(null);
      messagesService.applyEdit.mockResolvedValue(null);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          encryptedContent: 'new-cipher',
        },
        mockServer as Server,
      );

      expect(messagesService.applyEdit).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('editMessageFailed', {
        messageId: 100,
        reason: 'not_found',
      });
    });

    it('emits editMessageFailed with reason not_text for a non-TEXT message', async () => {
      const conv = { id: 10, userOne: { id: 1 }, userTwo: { id: 2 } };
      const msg = {
        id: 100,
        sender: { id: 1 },
        conversation: conv,
        createdAt: new Date(),
        messageType: 'IMAGE',
      } as unknown as Message;
      messagesService.findByIdWithConversation.mockResolvedValue(msg);
      messagesService.applyEdit.mockResolvedValue(null);

      await service.handleEditMessage(
        mockClient as Socket,
        {
          messageId: 100,
          content: '[encrypted]',
          encryptedContent: 'new-cipher',
        },
        mockServer as Server,
      );

      expect(messagesService.applyEdit).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('editMessageFailed', {
        messageId: 100,
        reason: 'not_text',
      });
    });
  });

  describe('handleGetMessages (H-01 IDOR guard)', () => {
    it('refuses a non-member: returns empty history and never queries messages', async () => {
      // Caller is user 1 (beforeEach). Conversation 10 is between users 2 and 3.
      conversationsService.findById.mockResolvedValue({
        id: 10,
        userOne: { id: 2 },
        userTwo: { id: 3 },
      } as Conversation);

      await service.handleGetMessages(mockClient as Socket, {
        conversationId: 10,
      });

      expect(messagesService.findByConversation).not.toHaveBeenCalled();
      expect(mockClient.emit).toHaveBeenCalledWith('messageHistory', {
        conversationId: 10,
        messages: [],
      });
    });

    it('serves history to a participant', async () => {
      conversationsService.findById.mockResolvedValue({
        id: 10,
        userOne: { id: 1 },
        userTwo: { id: 2 },
      } as Conversation);
      messagesService.findByConversation.mockResolvedValue([]);

      await service.handleGetMessages(mockClient as Socket, {
        conversationId: 10,
      });

      expect(messagesService.findByConversation).toHaveBeenCalledWith(
        10,
        undefined,
        undefined,
        1,
      );
      expect(mockClient.emit).toHaveBeenCalledWith('messageHistory', {
        conversationId: 10,
        messages: [],
      });
    });
  });

  describe('per-device history reads (spec §5.3 + §12 amendment (viii))', () => {
    /** Caller is user 1; conversation 10 is with user 2. */
    const arrangeHistory = (rows: unknown[]) => {
      conversationsService.findById.mockResolvedValue({
        id: 10,
        userOne: { id: 1 },
        userTwo: { id: 2 },
      } as Conversation);
      findByConversationMock.mockResolvedValue(rows);
    };

    /** A row as `findByConversation` returns it. */
    const row = (fields: Record<string, unknown>) =>
      ({
        id: 100,
        content: '[encrypted]',
        sender: { id: 2, username: 'bob' },
        createdAt: new Date(),
        deliveryStatus: 'SENT',
        messageType: 'TEXT',
        encryptedContent: null,
        originDeviceId: null,
        sendToken: null,
        ...fields,
      }) as unknown as Message;

    /** The single served history row. */
    const served = () => {
      const call = (
        (mockClient.emit as jest.Mock).mock.calls as unknown[][]
      ).find((c) => c[0] === 'messageHistory');
      const payload = call?.[1];
      if (
        !payload ||
        typeof payload !== 'object' ||
        !('messages' in payload) ||
        !Array.isArray(payload.messages)
      ) {
        throw new Error('no messageHistory emitted');
      }
      return payload.messages[0] as Record<string, unknown>;
    };

    const get = () =>
      service.handleGetMessages(mockClient as Socket, { conversationId: 10 });

    it('serves THIS device its own envelope ciphertext', async () => {
      arrangeHistory([row({})]);
      findEnvelopeCiphertextsMock.mockResolvedValue(
        new Map([[100, '3:mine-only']]),
      );

      await get();

      expect(findEnvelopeCiphertextsMock).toHaveBeenCalledWith([100], 1, 1);
      expect(served().encryptedContent).toBe('3:mine-only');
      expect(served().envelopeStatus).toBeUndefined();
    });

    it('serves the legacy column to the row session owner (device 1)', async () => {
      arrangeHistory([row({ encryptedContent: '3:legacy' })]);

      await get();

      expect(served().encryptedContent).toBe('3:legacy');
      expect(served().envelopeStatus).toBeUndefined();
    });

    it('marks none_for_device for a linked device with no envelope, and never leaks the legacy ciphertext', async () => {
      // Device 2 of the RECIPIENT: the legacy ciphertext is bound to device 1's
      // ratchet, so serving it would fail terminally across all pre-link history.
      mockClient.data = { user: { id: 1, deviceId: 2 } };
      arrangeHistory([row({ encryptedContent: '3:legacy' })]);

      await get();

      expect(findEnvelopeCiphertextsMock).toHaveBeenCalledWith([100], 1, 2);
      expect(served().envelopeStatus).toBe('none_for_device');
      expect(served().encryptedContent).toBeNull();
    });

    it('marks own_origin on the sender own row at its origin device, and echoes sendToken there', async () => {
      arrangeHistory([
        row({
          sender: { id: 1, username: 'alice' },
          originDeviceId: 1,
          sendToken: 'tok-abcdefgh',
        }),
      ]);

      await get();

      expect(served().envelopeStatus).toBe('own_origin');
      expect(served().encryptedContent).toBeNull();
      // The origin device's lost-ack reconcile key (amendment (ix)).
      expect(served().sendToken).toBe('tok-abcdefgh');
    });

    it('never echoes sendToken to a device that did not originate the row', async () => {
      arrangeHistory([row({ sendToken: 'tok-abcdefgh' })]);
      findEnvelopeCiphertextsMock.mockResolvedValue(
        new Map([[100, '3:mine-only']]),
      );

      await get();

      expect(served().sendToken).toBeUndefined();
    });

    it('treats originDeviceId NULL as device 1 for the own-row gate', async () => {
      arrangeHistory([
        row({
          sender: { id: 1, username: 'alice' },
          originDeviceId: null,
          encryptedContent: '3:legacy-own',
        }),
      ]);

      await get();

      expect(served().encryptedContent).toBe('3:legacy-own');
      expect(served().envelopeStatus).toBeUndefined();
    });

    it('never marks a plaintext row — it has no ciphertext for anyone', async () => {
      arrangeHistory([row({ content: 'hello there', messageType: 'TEXT' })]);

      await get();

      expect(served().envelopeStatus).toBeUndefined();
      expect(served().content).toBe('hello there');
    });
  });

  describe('handleGetServedMessageIds', () => {
    /** Names of every event emitted to the caller in this test. */
    const emitted = () =>
      ((mockClient.emit as jest.Mock).mock.calls as unknown[][]).map((c) =>
        String(c[0]),
      );

    it('echoes the requestId with the ids the server still serves', async () => {
      findServedMessageIdsMock.mockResolvedValue([2, 4]);

      await service.handleGetServedMessageIds(mockClient as Socket, {
        requestId: 'abc',
        messageIds: [1, 2, 3, 4],
      });

      expect(findServedMessageIdsMock).toHaveBeenCalledWith([1, 2, 3, 4], 1);
      expect(mockClient.emit).toHaveBeenCalledWith('servedMessageIds', {
        requestId: 'abc',
        messageIds: [2, 4],
      });
    });

    it('answers a fully deleted history with an empty list', async () => {
      // Not an error case: the client is meant to destroy all of them.
      findServedMessageIdsMock.mockResolvedValue([]);

      await service.handleGetServedMessageIds(mockClient as Socket, {
        requestId: 'abc',
        messageIds: [1, 2],
      });

      expect(mockClient.emit).toHaveBeenCalledWith('servedMessageIds', {
        requestId: 'abc',
        messageIds: [],
      });
    });

    it('stays SILENT when the lookup throws', async () => {
      // The empty list above is an instruction to destroy plaintext, so a
      // database failure must never be able to manufacture one. No reply at
      // all leaves the client holding everything until the next attempt.
      findServedMessageIdsMock.mockRejectedValue(new Error('db down'));

      await service.handleGetServedMessageIds(mockClient as Socket, {
        requestId: 'abc',
        messageIds: [1, 2],
      });

      expect(emitted()).not.toContain('servedMessageIds');
    });

    it('gives a REVOKED device silence — never an empty list (I6, amendment (xxiii))', async () => {
      isRevokedMock.mockResolvedValue(true);
      findServedMessageIdsMock.mockResolvedValue([2, 4]);

      await service.handleGetServedMessageIds(mockClient as Socket, {
        requestId: 'abc',
        messageIds: [1, 2, 3, 4],
      });

      // An answer-shaped refusal would be read as "destroy all of them",
      // remotely wiping the local history §5.5 promises a revoked device
      // keeps. So: no reply, and the lookup is never even run.
      expect(emitted()).not.toContain('servedMessageIds');
      expect(emitted()).not.toContain('error');
      expect(findServedMessageIdsMock).not.toHaveBeenCalled();
    });

    it('answers a LIVE device truthfully in the same conditions', async () => {
      // The other half of the falsification: silence must be caused by the
      // revocation, not by the gate refusing everyone.
      isRevokedMock.mockResolvedValue(false);
      findServedMessageIdsMock.mockResolvedValue([7]);

      await service.handleGetServedMessageIds(mockClient as Socket, {
        requestId: 'abc',
        messageIds: [7, 8],
      });

      expect(mockClient.emit).toHaveBeenCalledWith('servedMessageIds', {
        requestId: 'abc',
        messageIds: [7],
      });
    });

    it('rejects a malformed batch without answering it', async () => {
      await service.handleGetServedMessageIds(mockClient as Socket, {
        requestId: 'abc',
        messageIds: ['nope'],
      });

      expect(findServedMessageIdsMock).not.toHaveBeenCalled();
      expect(emitted()).toEqual(['error']);
    });

    it('rejects a batch over the size cap', async () => {
      await service.handleGetServedMessageIds(mockClient as Socket, {
        requestId: 'abc',
        messageIds: Array.from(
          { length: SERVED_MESSAGE_IDS_MAX_BATCH + 1 },
          (_, i) => i + 1,
        ),
      });

      expect(findServedMessageIdsMock).not.toHaveBeenCalled();
      expect(emitted()).toEqual(['error']);
    });

    it('ignores an unauthenticated socket', async () => {
      const anonymous: Partial<Socket> = { data: {}, emit: jest.fn() };

      await service.handleGetServedMessageIds(anonymous as Socket, {
        requestId: 'abc',
        messageIds: [1],
      });

      expect(findServedMessageIdsMock).not.toHaveBeenCalled();
      expect(anonymous.emit).not.toHaveBeenCalled();
    });
  });
});
