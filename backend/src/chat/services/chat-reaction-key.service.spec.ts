import { Socket } from 'socket.io';
import { ChatReactionKeyService } from './chat-reaction-key.service';
import { MAX_ENVELOPES_PER_MESSAGE } from '../dto/chat.dto';

describe('ChatReactionKeyService', () => {
  const conversation = { id: 7, userOne: { id: 1 }, userTwo: { id: 2 } };

  let conversations: { findById: jest.Mock };
  let blocked: { isBlockedByEither: jest.Mock };
  let keys: { upload: jest.Mock; fetchOwn: jest.Mock };
  let service: ChatReactionKeyService;

  // `deviceId: null` = a token minted before the claim existed (§8), which the
  // handler must read as device 1.
  interface MockClient {
    data: { user?: { id: number; deviceId?: number } };
    emit: jest.Mock;
  }

  const client = (userId = 1, deviceId: number | null = 3): MockClient => ({
    data: {
      user: deviceId === null ? { id: userId } : { id: userId, deviceId },
    },
    emit: jest.fn(),
  });

  // The handlers take a real `Socket`; the cast lives in these two seams so
  // every assertion reads the mock's own `jest.Mock` emit.
  const upload = (socket: MockClient, data: unknown) =>
    service.handleUploadReactionKey(socket as unknown as Socket, data);
  const fetchKey = (socket: MockClient, data: unknown) =>
    service.handleFetchReactionKey(socket as unknown as Socket, data);

  const envelope = (userId: number, deviceId: number) => ({
    userId,
    deviceId,
    ciphertext: `3:key-${userId}-${deviceId}`,
  });

  beforeEach(() => {
    conversations = { findById: jest.fn().mockResolvedValue(conversation) };
    blocked = { isBlockedByEither: jest.fn().mockResolvedValue(false) };
    keys = {
      upload: jest.fn().mockResolvedValue({ accepted: true, epoch: 1 }),
      fetchOwn: jest.fn().mockResolvedValue(null),
    };
    service = new ChatReactionKeyService(
      conversations as never,
      blocked as never,
      keys as never,
    );
  });

  describe('uploadReactionKey', () => {
    it('publishes and answers the accepted epoch', async () => {
      const socket = client();

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: [envelope(2, 1), envelope(1, 4)],
      });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyUploaded', {
        success: true,
        epoch: 1,
      });
    });

    it('attributes the uploader to the SESSION, never to the payload', async () => {
      const socket = client(1, 3);

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        // A hostile client claiming someone else produced the ciphertext would
        // point the victim's device at the wrong Signal session.
        senderUserId: 2,
        senderDeviceId: 9,
        envelopes: [envelope(2, 1)],
      });

      expect(keys.upload).toHaveBeenCalledWith(
        7,
        1,
        { userId: 1, deviceId: 3 },
        [envelope(2, 1)],
      );
    });

    it('treats a session with no deviceId claim as device 1', async () => {
      const socket = client(1, null);

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: [envelope(2, 1)],
      });

      expect(keys.upload).toHaveBeenCalledWith(
        7,
        1,
        { userId: 1, deviceId: 1 },
        expect.anything(),
      );
    });

    it('reports stale_epoch with the epoch the server holds', async () => {
      keys.upload.mockResolvedValue({ accepted: false, epoch: 4 });
      const socket = client();

      await upload(socket, {
        conversationId: 7,
        epoch: 2,
        envelopes: [envelope(2, 1)],
      });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyUploaded', {
        success: false,
        error: 'stale_epoch',
        epoch: 4,
      });
    });

    it('refuses a third party userId with foreign_recipient and writes nothing', async () => {
      const socket = client();

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: [envelope(2, 1), envelope(99, 1)],
      });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyUploaded', {
        success: false,
        error: 'foreign_recipient',
      });
      expect(keys.upload).not.toHaveBeenCalled();
    });

    it('refuses two envelopes for one device and writes nothing', async () => {
      const socket = client();

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: [envelope(2, 1), envelope(2, 1)],
      });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyUploaded', {
        success: false,
        error: 'duplicate_envelope_device',
      });
      expect(keys.upload).not.toHaveBeenCalled();
    });

    it('refuses an over-bound envelope count before any lookup', async () => {
      const socket = client();
      const tooMany = Array.from(
        { length: MAX_ENVELOPES_PER_MESSAGE + 1 },
        (_unused, index) => envelope(2, index + 1),
      );

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: tooMany,
      });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyUploaded', {
        success: false,
        error: 'invalid_payload',
      });
      expect(conversations.findById).not.toHaveBeenCalled();
      expect(keys.upload).not.toHaveBeenCalled();
    });

    it('refuses a non-participant with unauthorized', async () => {
      const socket = client(42);

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: [envelope(2, 1)],
      });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyUploaded', {
        success: false,
        error: 'unauthorized',
      });
      expect(keys.upload).not.toHaveBeenCalled();
    });

    it('refuses a blocked pair with the SAME code, never leaking the block', async () => {
      blocked.isBlockedByEither.mockResolvedValue(true);
      const socket = client();

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: [envelope(2, 1)],
      });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyUploaded', {
        success: false,
        error: 'unauthorized',
      });
      expect(keys.upload).not.toHaveBeenCalled();
    });

    it('answers an unauthenticated socket with nothing at all', async () => {
      const socket: MockClient = { data: {}, emit: jest.fn() };

      await upload(socket, {
        conversationId: 7,
        epoch: 1,
        envelopes: [envelope(2, 1)],
      });

      expect(socket.emit).not.toHaveBeenCalled();
    });
  });

  describe('fetchReactionKey', () => {
    it("serves the CALLER's own (userId, deviceId) row", async () => {
      keys.fetchOwn.mockResolvedValue({
        epoch: 4,
        senderUserId: 1,
        senderDeviceId: 3,
        ciphertext: '3:mine',
      });
      const socket = client(2, 5);

      await fetchKey(socket, { conversationId: 7 });

      expect(keys.fetchOwn).toHaveBeenCalledWith(7, 2, 5);
      expect(socket.emit).toHaveBeenCalledWith('reactionKeyResponse', {
        conversationId: 7,
        epoch: 4,
        senderUserId: 1,
        senderDeviceId: 3,
        ciphertext: '3:mine',
      });
    });

    it('answers a null ciphertext at the current epoch when this device has no copy', async () => {
      keys.fetchOwn.mockResolvedValue({
        epoch: 2,
        senderUserId: null,
        senderDeviceId: null,
        ciphertext: null,
      });
      const socket = client();

      await fetchKey(socket, { conversationId: 7 });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyResponse', {
        conversationId: 7,
        epoch: 2,
        senderUserId: null,
        senderDeviceId: null,
        ciphertext: null,
      });
    });

    it('refuses a non-participant with unauthorized and reads nothing', async () => {
      const socket = client(42);

      await fetchKey(socket, { conversationId: 7 });

      expect(socket.emit).toHaveBeenCalledWith('reactionKeyResponse', {
        conversationId: 7,
        success: false,
        error: 'unauthorized',
      });
      expect(keys.fetchOwn).not.toHaveBeenCalled();
    });

    it('refuses a malformed payload with invalid_payload, not a null key', async () => {
      const socket = client();

      await fetchKey(socket, { conversationId: 'seven' });

      // A refusal MUST be distinguishable from "no key yet": an answer shaped
      // like `ciphertext: null` would have the client render placeholder chips
      // forever instead of retrying.
      expect(socket.emit).toHaveBeenCalledWith('reactionKeyResponse', {
        conversationId: null,
        success: false,
        error: 'invalid_payload',
      });
      expect(keys.fetchOwn).not.toHaveBeenCalled();
    });
  });
});
