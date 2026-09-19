import { ChatReactionService } from './chat-reaction.service';

// A blinded reaction token (22 base64url chars) — the only shape the DTO
// accepts since D10 closed (2026-09-19).
const TOKEN = 'AAAAAAAAAAAAAAAAAAAAAA';

describe('ChatReactionService', () => {
  let service: ChatReactionService;
  let mockMessagesService: any;
  let mockBlockedService: any;
  let mockServer: any;
  let mockClient: any;

  const mockConversation = {
    id: 10,
    userOne: { id: 1 },
    userTwo: { id: 2 },
  };

  beforeEach(() => {
    mockMessagesService = {
      findByIdWithConversation: jest.fn(),
      addOrUpdateReaction: jest.fn(),
      removeReaction: jest.fn(),
    };
    mockBlockedService = {
      isBlockedByEither: jest.fn().mockResolvedValue(false),
    };
    service = new ChatReactionService(mockMessagesService, mockBlockedService);
    mockServer = {
      to: jest.fn().mockReturnThis(),
      emit: jest.fn(),
    };
    mockClient = { data: { user: { id: 1 } }, emit: jest.fn() };
  });

  describe('handleAddReaction', () => {
    it('should add reaction and emit to both parties', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue({
        id: 5,
        conversation: mockConversation,
      });
      mockMessagesService.addOrUpdateReaction.mockResolvedValue({
        id: 5,
        reactions: JSON.stringify({ [TOKEN]: [1] }),
      });

      await service.handleAddReaction(
        mockClient,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(mockMessagesService.addOrUpdateReaction).toHaveBeenCalledWith(
        5,
        1,
        TOKEN,
      );
      expect(mockClient.emit).toHaveBeenCalledWith('reactionUpdated', {
        messageId: 5,
        conversationId: 10,
        reactions: { [TOKEN]: [1] },
      });
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith('reactionUpdated', {
        messageId: 5,
        conversationId: 10,
        reactions: { [TOKEN]: [1] },
      });
    });

    it('should emit error on nonexistent message', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue(null);

      await service.handleAddReaction(
        mockClient,
        { messageId: 999, emoji: TOKEN },
        mockServer,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Message not found',
      });
      expect(mockMessagesService.addOrUpdateReaction).not.toHaveBeenCalled();
    });

    it('should not proceed if no user on client', async () => {
      await service.handleAddReaction(
        { data: {} } as any,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(
        mockMessagesService.findByIdWithConversation,
      ).not.toHaveBeenCalled();
    });

    it('should emit error on invalid dto', async () => {
      await service.handleAddReaction(
        mockClient,
        { messageId: -1, emoji: TOKEN },
        mockServer,
      );

      expect(mockClient.emit).toHaveBeenCalledWith(
        'error',
        expect.objectContaining({ message: expect.any(String) }),
      );
    });

    it('should emit Unauthorized and not react when user is not a conversation participant', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue({
        id: 5,
        conversation: { id: 10, userOne: { id: 2 }, userTwo: { id: 3 } },
      });

      await service.handleAddReaction(
        mockClient,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Unauthorized',
      });
      expect(mockMessagesService.addOrUpdateReaction).not.toHaveBeenCalled();
    });

    it('should not react or emit when either user has blocked the other', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue({
        id: 5,
        conversation: mockConversation,
      });
      mockBlockedService.isBlockedByEither.mockResolvedValue(true);

      await service.handleAddReaction(
        mockClient,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(mockBlockedService.isBlockedByEither).toHaveBeenCalledWith(1, 2);
      expect(mockMessagesService.addOrUpdateReaction).not.toHaveBeenCalled();
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'reactionUpdated',
        expect.anything(),
      );
      expect(mockServer.emit).not.toHaveBeenCalled();
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });

    // BE-007 multi-tab regression: delivery must target the recipient's per-user
    // room so every open tab receives it, not a single last-write-wins socket id.
    it('should deliver reactionUpdated to the recipient room, not a socket id (multi-tab)', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue({
        id: 5,
        conversation: mockConversation,
      });
      mockMessagesService.addOrUpdateReaction.mockResolvedValue({
        id: 5,
        reactions: JSON.stringify({ [TOKEN]: [1] }),
      });

      await service.handleAddReaction(
        mockClient,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.to).not.toHaveBeenCalledWith('socket-2');
    });
  });

  describe('handleRemoveReaction', () => {
    it('should remove reaction and emit to both parties', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue({
        id: 5,
        conversation: mockConversation,
      });
      mockMessagesService.removeReaction.mockResolvedValue({
        id: 5,
        reactions: JSON.stringify({}),
      });

      await service.handleRemoveReaction(
        mockClient,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      // No key argument: removal drops this user's single reaction whatever
      // key holds it, so a legacy plaintext entry cannot survive a token-shaped
      // removal (and vice versa).
      expect(mockMessagesService.removeReaction).toHaveBeenCalledWith(5, 1);
      expect(mockClient.emit).toHaveBeenCalledWith('reactionUpdated', {
        messageId: 5,
        conversationId: 10,
        reactions: {},
      });
      expect(mockServer.to).toHaveBeenCalledWith('user:2');
      expect(mockServer.emit).toHaveBeenCalledWith('reactionUpdated', {
        messageId: 5,
        conversationId: 10,
        reactions: {},
      });
    });

    it('should emit error on nonexistent message', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue(null);

      await service.handleRemoveReaction(
        mockClient,
        { messageId: 999, emoji: TOKEN },
        mockServer,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Message not found',
      });
      expect(mockMessagesService.removeReaction).not.toHaveBeenCalled();
    });

    it('should not proceed if no user on client', async () => {
      await service.handleRemoveReaction(
        { data: {} } as any,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(
        mockMessagesService.findByIdWithConversation,
      ).not.toHaveBeenCalled();
    });

    it('should emit Unauthorized and not remove reaction when user is not a conversation participant', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue({
        id: 5,
        conversation: { id: 10, userOne: { id: 2 }, userTwo: { id: 3 } },
      });

      await service.handleRemoveReaction(
        mockClient,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(mockClient.emit).toHaveBeenCalledWith('error', {
        message: 'Unauthorized',
      });
      expect(mockMessagesService.removeReaction).not.toHaveBeenCalled();
    });

    it('should not remove reaction or emit when either user has blocked the other', async () => {
      mockMessagesService.findByIdWithConversation.mockResolvedValue({
        id: 5,
        conversation: mockConversation,
      });
      mockBlockedService.isBlockedByEither.mockResolvedValue(true);

      await service.handleRemoveReaction(
        mockClient,
        { messageId: 5, emoji: TOKEN },
        mockServer,
      );

      expect(mockBlockedService.isBlockedByEither).toHaveBeenCalledWith(1, 2);
      expect(mockMessagesService.removeReaction).not.toHaveBeenCalled();
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'reactionUpdated',
        expect.anything(),
      );
      expect(mockServer.emit).not.toHaveBeenCalled();
      expect(mockClient.emit).not.toHaveBeenCalledWith(
        'error',
        expect.anything(),
      );
    });
  });
});
