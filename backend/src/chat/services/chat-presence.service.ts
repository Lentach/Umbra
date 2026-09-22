import { Injectable } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { validateDto } from '../utils/dto.validator';
import { BlockedService } from '../../blocked/blocked.service';
import { PushClientStateDto } from '../dto/push-client-state.dto';
import { TypingDto } from '../dto/typing.dto';
import { RecordingVoiceDto } from '../dto/recording-voice.dto';
import { isUserOnline, userRoom } from '../utils/user-room';

// Block-verdict cache for the high-frequency, un-throttled presence path. `typing` and
// `recordingVoice` fire on every keystroke (backend/CLAUDE.md §6 — not throttled), so a DB
// round trip per event would be self-inflicted load. The symmetric isBlockedByEither verdict
// is memoised per unordered user pair with a short TTL. Staleness is bounded and acceptable:
// a blocked user's typing indicator may leak for at most one TTL window after the block lands,
// a far smaller harm than a query per keystroke. Bounded exactly like lastPreKeyFetchByPair in
// chat-key-exchange.service.ts (TTL sweep + max-entries LRU eviction).
const BLOCK_VERDICT_CACHE_TTL_MS = 5000;
const BLOCK_VERDICT_CACHE_MAX_ENTRIES = 10000;

@Injectable()
export class ChatPresenceService {
  private readonly blockVerdictByPair = new Map<
    string,
    { blocked: boolean; ts: number }
  >();

  constructor(private readonly blockedService: BlockedService) {}

  async handleTyping(client: Socket, data: any, server: Server): Promise<void> {
    const senderId: number = client.data.user?.id;
    if (!senderId) return;
    try {
      const dto = validateDto(TypingDto, data);
      if (!isUserOnline(server, dto.recipientId)) return;
      // Block gate — fail silently so we never leak the moderation decision to the sender.
      if (await this.isBlockedByEitherCached(senderId, dto.recipientId)) return;
      server.to(userRoom(dto.recipientId)).emit('partnerTyping', {
        senderId,
        conversationId: dto.conversationId,
      });
    } catch {
      return; // invalid payload or block-check failure — silent no-op (fail closed)
    }
  }

  handlePushClientState(client: Socket, data: any): void {
    const userId: number = client.data.user?.id;
    if (!userId) return;
    try {
      const dto = validateDto(PushClientStateDto, data);
      // Picked field by field: validateDto does not strip extras, and a client
      // that predates PR0.2 still sends activeConversationId — never store it.
      client.data.pushClientState = { clientVisible: dto.clientVisible };
    } catch {
      return;
    }
  }

  async handleRecordingVoice(
    client: Socket,
    data: any,
    server: Server,
  ): Promise<void> {
    const senderId: number = client.data.user?.id;
    if (!senderId) return;
    try {
      const dto = validateDto(RecordingVoiceDto, data);
      if (!isUserOnline(server, dto.recipientId)) return;
      // Block gate — fail silently so we never leak the moderation decision to the sender.
      if (await this.isBlockedByEitherCached(senderId, dto.recipientId)) return;
      server.to(userRoom(dto.recipientId)).emit('partnerRecordingVoice', {
        senderId,
        conversationId: dto.conversationId,
        isRecording: dto.isRecording,
      });
    } catch {
      return; // invalid payload or block-check failure — silent no-op (fail closed)
    }
  }

  /**
   * Cached, symmetric block check for the presence hot path. Returns true if either user
   * has blocked the other. Verdicts are memoised per unordered pair for
   * BLOCK_VERDICT_CACHE_TTL_MS so the un-throttled typing path stays off the DB.
   */
  private async isBlockedByEitherCached(
    userA: number,
    userB: number,
  ): Promise<boolean> {
    const now = Date.now();
    this.cleanupBlockVerdictCache(now);
    const key = userA < userB ? `${userA}:${userB}` : `${userB}:${userA}`;
    const cached = this.blockVerdictByPair.get(key);
    if (cached !== undefined && now - cached.ts < BLOCK_VERDICT_CACHE_TTL_MS) {
      return cached.blocked;
    }
    const blocked = await this.blockedService.isBlockedByEither(userA, userB);
    this.blockVerdictByPair.set(key, { blocked, ts: now });
    return blocked;
  }

  private cleanupBlockVerdictCache(now: number): void {
    for (const [key, entry] of this.blockVerdictByPair.entries()) {
      if (now - entry.ts > BLOCK_VERDICT_CACHE_TTL_MS) {
        this.blockVerdictByPair.delete(key);
      }
    }
    if (this.blockVerdictByPair.size <= BLOCK_VERDICT_CACHE_MAX_ENTRIES) {
      return;
    }
    const ordered = [...this.blockVerdictByPair.entries()].sort(
      (a, b) => a[1].ts - b[1].ts,
    );
    const toDelete =
      this.blockVerdictByPair.size - BLOCK_VERDICT_CACHE_MAX_ENTRIES;
    for (let i = 0; i < toDelete; i++) {
      this.blockVerdictByPair.delete(ordered[i][0]);
    }
  }
}
