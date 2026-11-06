import { Injectable } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { validateDto } from '../utils/dto.validator';
import { TypingDto } from '../dto/typing.dto';
import { RecordingVoiceDto } from '../dto/recording-voice.dto';
import { isUserOnline, userRoom } from '../utils/user-room';

/**
 * `typing` / `recordingVoice` relays. A frame is relayed only when the payload
 * parses and the recipient has a live socket; there is no friendship or block
 * check, because the server keeps no friend or block rows any more (Phase 4
 * step 5, decision 126: a block is device-only, so a blocked sender's typing
 * indicator is hidden by the blocking device, not by the server). Both are
 * un-throttled keystroke-rate events, so nothing here touches the database.
 */
@Injectable()
export class ChatPresenceService {
  async handleTyping(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const senderId: number = client.data.user?.id;
    if (!senderId) return;
    try {
      const dto = validateDto(TypingDto, data);
      if (!isUserOnline(server, dto.recipientId)) return;
      server.to(userRoom(dto.recipientId)).emit('partnerTyping', {
        senderId,
        conversationId: dto.conversationId,
      });
    } catch {
      return; // invalid payload — silent no-op (fail closed)
    }
  }

  async handleRecordingVoice(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const senderId: number = client.data.user?.id;
    if (!senderId) return;
    try {
      const dto = validateDto(RecordingVoiceDto, data);
      if (!isUserOnline(server, dto.recipientId)) return;
      server.to(userRoom(dto.recipientId)).emit('partnerRecordingVoice', {
        senderId,
        conversationId: dto.conversationId,
        isRecording: dto.isRecording,
      });
    } catch {
      return; // invalid payload — silent no-op (fail closed)
    }
  }
}
