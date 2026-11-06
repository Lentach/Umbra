import { Server, Socket } from 'socket.io';
import { ChatPresenceService } from './chat-presence.service';

/** Just the part of a socket the service reads. */
const clientOf = (data: Record<string, unknown>) =>
  ({ data }) as unknown as Socket;

describe('ChatPresenceService', () => {
  let service: ChatPresenceService;
  let to: jest.Mock;
  let emit: jest.Mock;
  let server: Server;
  let client: Socket;

  beforeEach(() => {
    service = new ChatPresenceService();
    to = jest.fn().mockReturnThis();
    emit = jest.fn();
    server = {
      to,
      emit,
      // Room occupancy drives isUserOnline (see utils/user-room.ts): users 1 and 2
      // have a live socket; user 99 is absent, i.e. offline.
      sockets: {
        adapter: {
          rooms: new Map([
            ['user:1', new Set(['socket-1'])],
            ['user:2', new Set(['socket-2'])],
          ]),
        },
      },
    } as unknown as Server;
    client = clientOf({ user: { id: 1 } });
  });

  describe('handleTyping', () => {
    it('should emit partnerTyping to recipient', async () => {
      await service.handleTyping(
        client,
        { recipientId: 2, conversationId: 10 },
        server,
      );

      expect(to).toHaveBeenCalledWith('user:2');
      expect(emit).toHaveBeenCalledWith('partnerTyping', {
        senderId: 1,
        conversationId: 10,
      });
    });

    it('should not emit if recipient offline', async () => {
      await service.handleTyping(
        client,
        { recipientId: 99, conversationId: 10 },
        server,
      );

      expect(to).not.toHaveBeenCalled();
    });

    it('should not emit if no user on client', async () => {
      await service.handleTyping(
        clientOf({}),
        { recipientId: 2, conversationId: 10 },
        server,
      );

      expect(to).not.toHaveBeenCalled();
    });

    it('should not emit for an invalid payload', async () => {
      await service.handleTyping(client, { recipientId: 'x' }, server);

      expect(to).not.toHaveBeenCalled();
    });

    it('should emit partnerTyping for the reverse direction', async () => {
      await service.handleTyping(
        clientOf({ user: { id: 2 } }),
        { recipientId: 1, conversationId: 10 },
        server,
      );

      expect(to).toHaveBeenCalledWith('user:1');
      expect(emit).toHaveBeenCalledWith('partnerTyping', {
        senderId: 2,
        conversationId: 10,
      });
    });
  });

  describe('handleRecordingVoice', () => {
    it('should emit partnerRecordingVoice to recipient', async () => {
      await service.handleRecordingVoice(
        client,
        { recipientId: 2, conversationId: 10, isRecording: true },
        server,
      );

      expect(to).toHaveBeenCalledWith('user:2');
      expect(emit).toHaveBeenCalledWith('partnerRecordingVoice', {
        senderId: 1,
        conversationId: 10,
        isRecording: true,
      });
    });

    it('should not emit if recipient offline', async () => {
      await service.handleRecordingVoice(
        client,
        { recipientId: 99, conversationId: 10, isRecording: true },
        server,
      );

      expect(to).not.toHaveBeenCalled();
    });

    it('should not emit if no user on client', async () => {
      await service.handleRecordingVoice(
        clientOf({}),
        { recipientId: 2, conversationId: 10, isRecording: true },
        server,
      );

      expect(to).not.toHaveBeenCalled();
    });
  });
});
