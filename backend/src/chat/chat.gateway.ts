import {
  WebSocketGateway,
  WebSocketServer,
  SubscribeMessage,
  OnGatewayConnection,
  OnGatewayDisconnect,
  ConnectedSocket,
  MessageBody,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { JwtService } from '@nestjs/jwt';
import { Logger, UseGuards } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { WsThrottlerGuard } from './guards/ws-throttler.guard';
import { UsersService } from '../users/users.service';
import { ChatMessageService } from './services/chat-message.service';
import { ChatFriendRequestService } from './services/chat-friend-request.service';
import { ChatConversationService } from './services/chat-conversation.service';
import { ChatKeyExchangeService } from './services/chat-key-exchange.service';
import { ChatPresenceService } from './services/chat-presence.service';
import { ChatBlockService } from './services/chat-block.service';
import { ChatSearchService } from './services/chat-search.service';
import { ChatReactionService } from './services/chat-reaction.service';
import { ChatReactionKeyService } from './services/chat-reaction-key.service';
import { ChatDeviceListService } from './services/chat-device-list.service';
import { ChatProvisioningService } from './services/chat-provisioning.service';
import { ChatDeviceRevocationService } from './services/chat-device-revocation.service';
import { deviceRoom, userRoom } from './utils/user-room';
import { DEFAULT_DEVICE_ID } from '../key-bundles/key-bundles.service';
import { DevicesService } from '../key-bundles/devices.service';
import { buildCorsOrigin } from '../common/socket-cors';

@WebSocketGateway({
  cors: { origin: buildCorsOrigin() },
})
export class ChatGateway implements OnGatewayConnection, OnGatewayDisconnect {
  private readonly logger = new Logger(ChatGateway.name);

  @WebSocketServer()
  server: Server;

  // Presence and delivery are derived from the per-user Socket.IO room
  // (`user:<id>`), NOT from a userId -> socketId map. The map this replaced was
  // last-write-wins, so a second tab silently made the first undeliverable
  // (BE-007). See `utils/user-room.ts`.

  constructor(
    private jwtService: JwtService,
    private usersService: UsersService,
    private chatMessageService: ChatMessageService,
    private chatFriendRequestService: ChatFriendRequestService,
    private chatConversationService: ChatConversationService,
    private chatKeyExchangeService: ChatKeyExchangeService,
    private chatPresenceService: ChatPresenceService,
    private chatBlockService: ChatBlockService,
    private chatSearchService: ChatSearchService,
    private chatReactionService: ChatReactionService,
    private chatDeviceListService: ChatDeviceListService,
    private chatProvisioningService: ChatProvisioningService,
    private devicesService: DevicesService,
    private chatDeviceRevocationService: ChatDeviceRevocationService,
    private chatReactionKeyService: ChatReactionKeyService,
  ) {}

  // On WebSocket connection — verify the JWT token.
  async handleConnection(client: Socket) {
    try {
      const token = client.handshake.auth?.token as string;

      if (!token) {
        this.logger.debug(
          '[auth-access-reject] reason=missing_access source=socket_connect',
        );
        client.disconnect();
        return;
      }

      const payload = this.jwtService.verify<{
        sub: number;
        iat?: number;
        deviceId?: number;
      }>(token);
      const user = await this.usersService.findById(payload.sub);

      if (!user) {
        this.logger.debug(
          `[auth-access-reject] reason=user_missing source=socket_connect`,
        );
        client.disconnect();
        return;
      }

      // Mirror JwtStrategy: a token issued before the last password change is invalid.
      if (user.passwordChangedAt) {
        const changedAtSeconds = Math.floor(
          user.passwordChangedAt.getTime() / 1000,
        );
        if (
          typeof payload.iat === 'number' &&
          payload.iat <= changedAtSeconds
        ) {
          this.logger.debug(
            `[auth-access-reject] reason=password_changed source=socket_connect`,
          );
          client.disconnect();
          return;
        }
      }

      // A revoked device may still hold a valid access JWT until natural
      // expiry (spec §5.5), so the session is refused HERE rather than only
      // at the handlers: reconnecting is how a kicked device would otherwise
      // come straight back. Amendment (xxii) — deny ONLY on an explicit
      // `revokedAt`; a MISSING row must never deny, because every
      // pre-Phase-1 account has no `devices` row until the `ensureRow` below
      // writes one (§8), and denying on absence would lock out every legacy
      // install.
      if (
        await this.devicesService.isRevoked(
          user.id,
          payload.deviceId ?? DEFAULT_DEVICE_ID,
        )
      ) {
        this.logger.warn(
          `[auth-access-reject] reason=device_revoked source=socket_connect deviceId=${payload.deviceId ?? DEFAULT_DEVICE_ID}`,
        );
        // Told, then dropped (amendment (xxvi)): a device that reconnects
        // after being kicked learns WHY instead of showing the generic
        // connection-lost banner. Emitted directly on the socket — it has not
        // joined any room yet.
        client.emit('deviceRevoked', {
          userId: user.id,
          deviceId: payload.deviceId ?? DEFAULT_DEVICE_ID,
        });
        client.disconnect();
        return;
      }

      client.data.user = {
        id: user.id,
        username: user.username,
        tag: user.tag,
        // Which device this session is (Phase 1, spec §4). A token issued
        // before the claim existed is device 1 (§8), never "unknown" — key
        // material has to land somewhere and that somewhere is the account's
        // original device.
        deviceId: payload.deviceId ?? DEFAULT_DEVICE_ID,
      };
      client.join(userRoom(user.id));
      // Ciphertext is addressed PER DEVICE (spec §5.3): each device gets its
      // own envelope, so it needs its own room. Metadata keeps using the user
      // room above so every device still sees it.
      client.join(deviceRoom(user.id, payload.deviceId ?? DEFAULT_DEVICE_ID));
      // Make sure the account's device-1 row exists (Phase 1, spec §4; the
      // only creator for accounts that predate provisioning). Fire-and-
      // forget: a failed write costs a missing row, never the session. No
      // timestamp is written — the server keeps no "last online" clock.
      void this.devicesService.ensureRow(
        user.id,
        payload.deviceId ?? DEFAULT_DEVICE_ID,
      );
      this.chatKeyExchangeService.deliverPendingSessionRebuilds(client);

      this.logger.debug(`User connected (socket: ${client.id})`);
      // Auth is complete — client may safely emit authenticated WS events.
      // `serverTime` is the client's only trustworthy clock reference. It
      // gates destroying expired message plaintext, which is irreversible:
      // the client holds ciphertext it can no longer decrypt, so a device with
      // a fast wall clock would otherwise wipe messages still live here. An
      // older client ignores the field; a newer client against an older server
      // sees none and simply never destroys on expiry.
      //
      // `deviceId` tells the client WHICH device this session is (spec §5.3).
      // It cannot derive that itself, and it must: a fan-out send addresses
      // every OTHER device of the account for self-sync and must never
      // address its own origin device (refused `self_envelope_for_origin_device`).
      // The server is the authority — the id comes from the JWT claim it just
      // validated. Additive: an older client ignores it.
      client.emit('socketReady', {
        serverTime: new Date().toISOString(),
        deviceId: payload.deviceId ?? DEFAULT_DEVICE_ID,
      });
    } catch (error) {
      const errorName =
        error instanceof Error ? error.name : 'UnknownSocketAuthError';
      const reason =
        errorName === 'TokenExpiredError'
          ? 'access_expired'
          : errorName === 'JsonWebTokenError'
            ? 'invalid_signature'
            : 'access_invalid';
      const line = `[auth-access-reject] reason=${reason} source=socket_connect errorType=${errorName}`;
      if (reason === 'invalid_signature') {
        this.logger.warn(line);
      } else {
        this.logger.debug(line);
      }
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    const user = client.data.user;
    if (!user) return;
    // No presence bookkeeping needed: Socket.IO removes the socket from its
    // rooms on disconnect, so `user:<id>` empties only when the LAST tab goes.
    // This is what retired the old guarded-delete dance, which existed because
    // an iOS suspend/resume reconnects with a NEW socket while the abandoned
    // OLD socket lingers to ping-timeout (~20s) — with a single-socket map that
    // stale disconnect could evict the live socket and silently drop peers'
    // newMessage emits to push. Room membership has no such failure mode.
    this.logger.debug(`User disconnected (socket: ${client.id})`);
  }

  // ========== MESSAGE HANDLERS ==========

  /** Per-user cap for outgoing messages; global ThrottlerModule default is 100/15min — too low for active chat. */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 300, ttl: 900000 } })
  @SubscribeMessage('sendMessage')
  async handleSendMessage(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatMessageService.handleSendMessage(client, data, this.server);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 300, ttl: 900000 } })
  @SubscribeMessage('getMessages')
  async handleGetMessages(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatMessageService.handleGetMessages(client, data);
  }

  /**
   * Local-plaintext reconciliation. Cheap (PK lookup + two predicates), and the
   * client throttles itself to a few passes a day, so the limit sits well under
   * `getMessages`.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('getServedMessageIds')
  async handleGetServedMessageIds(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatMessageService.handleGetServedMessageIds(client, data);
  }

  /**
   * Server-clock refresh for the client's in-session expiry sweep. The
   * `socketReady` observation ages out of client trust after ~30 minutes
   * (never extrapolated further); without a refresh, a connection that stays
   * up longer than that could never destroy expired plaintext until its next
   * reconnect. Stateless, no DB. The client asks roughly once per half hour,
   * so the limit sits far above real traffic.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('getServerTime')
  handleGetServerTime(@ConnectedSocket() client: Socket) {
    client.emit('serverTime', { serverTime: new Date().toISOString() });
  }

  @SubscribeMessage('messageDelivered')
  async handleMessageDelivered(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatMessageService.handleMessageDelivered(
      client,
      data,
      this.server,
    );
  }

  @SubscribeMessage('markConversationRead')
  async handleMarkConversationRead(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatMessageService.handleMarkConversationRead(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('clearChatHistory')
  handleClearChatHistory(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatMessageService.handleClearChatHistory(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('deleteMessage')
  handleDeleteMessage(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatMessageService.handleDeleteMessage(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('editMessage')
  handleEditMessage(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatMessageService.handleEditMessage(client, data, this.server);
  }

  // ========== TYPING INDICATOR ==========

  @SubscribeMessage('typing')
  async handleTyping(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ): Promise<void> {
    return this.chatPresenceService.handleTyping(client, data, this.server);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 120, ttl: 900000 } })
  @SubscribeMessage('addReaction')
  async handleAddReaction(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatReactionService.handleAddReaction(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 120, ttl: 900000 } })
  @SubscribeMessage('removeReaction')
  async handleRemoveReaction(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatReactionService.handleRemoveReaction(
      client,
      data,
      this.server,
    );
  }

  // Key distribution for blinded reaction tokens
  // (docs/design/reaction-privacy.md §3.1). Publishing is rare — key creation,
  // a rotation on revoke, a re-upload when a device is linked — so it is
  // throttled well below the reaction rate; the PULL side shares the reaction
  // limit because every device asks once per conversation it opens.
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('uploadReactionKey')
  async handleUploadReactionKey(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatReactionKeyService.handleUploadReactionKey(client, data);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 120, ttl: 900000 } })
  @SubscribeMessage('fetchReactionKey')
  async handleFetchReactionKey(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatReactionKeyService.handleFetchReactionKey(client, data);
  }

  @SubscribeMessage('recordingVoice')
  async handleRecordingVoice(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ): Promise<void> {
    return this.chatPresenceService.handleRecordingVoice(
      client,
      data,
      this.server,
    );
  }

  /** Lets client suppress push when already viewing this conversation (foreground + active chat). */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 120, ttl: 900000 } })
  @SubscribeMessage('pushClientState')
  handlePushClientState(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ): void {
    return this.chatPresenceService.handlePushClientState(client, data);
  }

  // ========== KEY EXCHANGE HANDLERS (E2E Encryption) ==========

  @SubscribeMessage('uploadKeyBundle')
  async handleUploadKeyBundle(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatKeyExchangeService.handleUploadKeyBundle(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('uploadOneTimePreKeys')
  async handleUploadOneTimePreKeys(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatKeyExchangeService.handleUploadOneTimePreKeys(client, data);
  }

  @UseGuards(WsThrottlerGuard)
  @SubscribeMessage('fetchPreKeyBundle')
  async handleFetchPreKeyBundle(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatKeyExchangeService.handleFetchPreKeyBundle(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @SubscribeMessage('checkOwnKeyBundle')
  async handleCheckOwnKeyBundle(@ConnectedSocket() client: Socket) {
    return this.chatKeyExchangeService.handleCheckOwnKeyBundle(client);
  }

  /**
   * Registration lock (§6.1). Throttled: a nonce is cheap, but an unbounded
   * issue loop is still an issue loop.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('getRegistrationLockNonce')
  handleGetRegistrationLockNonce(@ConnectedSocket() client: Socket) {
    return this.chatKeyExchangeService.handleGetRegistrationLockNonce(client);
  }

  /**
   * Reset ceremony (§6.2). Tight limit: the ceremony is already rate-limited by
   * its own one-pending/cooldown rules, and each call may run a memory-hard
   * verification when a recovery phrase is supplied.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('resetIdentityRequest')
  async handleResetIdentityRequest(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatKeyExchangeService.handleResetIdentityRequest(
      client,
      data,
      this.server,
    );
  }

  /**
   * Cancelling must stay generously available — it is the protective action,
   * and a user tapping it twice in a panic must not be throttled out of it.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('resetIdentityCancel')
  async handleResetIdentityCancel(@ConnectedSocket() client: Socket) {
    return this.chatKeyExchangeService.handleResetIdentityCancel(
      client,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('setRecoveryKey')
  async handleSetRecoveryKey(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatKeyExchangeService.handleSetRecoveryKey(
      client,
      data,
      this.server,
    );
  }

  /**
   * Serves the caller's phrase-sealed identity backup ((lxxviii) clause 1).
   * Same tier as `setRecoveryKey`: the blob is useless without the phrase,
   * but nothing legitimate fetches it in a loop.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('getIdentityBackup')
  async handleGetIdentityBackup(@ConnectedSocket() client: Socket) {
    return this.chatKeyExchangeService.handleGetIdentityBackup(client);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('requestSessionRebuild')
  async handleRequestSessionRebuild(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatKeyExchangeService.handleRequestSessionRebuild(
      client,
      data,
      this.server,
    );
  }

  // ========== DEVICE LIST (Phase 2 T2, spec §3/§7 row 424) ==========

  /**
   * DAK enrollment (§3). Tight limit like the reset ceremony: a legitimate
   * account enrolls once in its lifetime, and each attempt costs signature
   * verifications.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('enrollDeviceAuthority')
  async handleEnrollDeviceAuthority(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatDeviceListService.handleEnrollDeviceAuthority(
      client,
      data,
      this.server,
    );
  }

  /** DAK-signed list mutation (§3/§5.2) — mutating-action tier. */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('updateDeviceList')
  async handleUpdateDeviceList(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatDeviceListService.handleUpdateDeviceList(
      client,
      data,
      this.server,
    );
  }

  /** Serve any account's enrollment + signed list (I7) — fetch tier. */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 300, ttl: 900000 } })
  @SubscribeMessage('getDeviceList')
  async handleGetDeviceList(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatDeviceListService.handleGetDeviceList(client, data);
  }

  /**
   * Revocation (§5.5) — mutating-action tier, and deliberately as generous as
   * the list mutation it carries: a protective action must stay available (I4
   * spirit), and every refusal here is pre-write.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('revokeDevice')
  async handleRevokeDevice(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatDeviceRevocationService.handleRevokeDevice(
      client,
      data,
      this.server,
    );
  }

  // ========== PROVISIONING CEREMONY (Phase 2 T3, spec §5.1/§7 row 424) ==========

  /**
   * §5.1 ceremony open — `{ role?: 'new' | 'primary' }`, default 'new'
   * (amendment (lxxvii)). Tight limit like enrollment: a legitimate account
   * links at most two extra devices, ever, and each open allocates a
   * deviceId.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('openProvisioning')
  async handleOpenProvisioning(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatProvisioningService.handleOpenProvisioning(client, data);
  }

  /** SAS round: the primary presents its ephemeral (§5.1). */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('provisioningHello')
  handleProvisioningHello(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatProvisioningService.handleProvisioningHello(
      client,
      data,
      this.server,
    );
  }

  /** Stages the blob + signed v+1 mutation (§5.1 two-phase commit). */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('provisionDevice')
  async handleProvisionDevice(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatProvisioningService.handleProvisionDevice(
      client,
      data,
      this.server,
    );
  }

  /** Blob re-fetch until TTL/completion (§5.1; falsification 18). */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('fetchProvisioningBlob')
  handleFetchProvisioningBlob(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatProvisioningService.handleFetchProvisioningBlob(
      client,
      data,
    );
  }

  /** Two-phase commit, phase two — opener socket only (falsification 8). */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 10, ttl: 900000 } })
  @SubscribeMessage('provisioningComplete')
  async handleProvisioningComplete(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatProvisioningService.handleProvisioningComplete(
      client,
      data,
      this.server,
    );
  }

  /**
   * Cancel stays generously available, like resetIdentityCancel: it is the
   * protective action of the ceremony.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('cancelProvisioning')
  handleCancelProvisioning(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatProvisioningService.handleCancelProvisioning(
      client,
      data,
      this.server,
    );
  }

  // ========== CONVERSATION HANDLERS ==========

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('startConversation')
  async handleStartConversation(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatConversationService.handleStartConversation(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 300, ttl: 900000 } })
  @SubscribeMessage('getConversations')
  async handleGetConversations(@ConnectedSocket() client: Socket) {
    return this.chatConversationService.handleGetConversations(client);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('deleteConversationOnly')
  async handleDeleteConversationOnly(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    await this.chatConversationService.handleDeleteConversationOnly(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('setDisappearingTimer')
  async handleSetDisappearingTimer(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatConversationService.handleSetDisappearingTimer(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('setConversationMute')
  async handleSetConversationMute(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatConversationService.handleSetConversationMute(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('pinMessage')
  async handlePinMessage(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatConversationService.handlePinMessage(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 60, ttl: 900000 } })
  @SubscribeMessage('unpinMessage')
  async handleUnpinMessage(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatConversationService.handleUnpinMessage(
      client,
      data,
      this.server,
    );
  }

  // ========== FRIEND REQUEST HANDLERS ==========

  // The fetch tier, not a lookup tier: since metadata-privacy PR3.2 every
  // stranger search CLAIMS one one-time pre-key per target device, so it may
  // not drain a pool faster than `fetchPreKeyBundle` can (100 / 15 min).
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 100, ttl: 900000 } })
  @SubscribeMessage('searchUsers')
  async handleSearchUsers(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatSearchService.handleSearchUsers(client, data, this.server);
  }

  /**
   * A device publishes its box request queue (metadata-privacy PR3.2) —
   * once per boot, so the key-rebuild tier is generous. Answers on
   * `requestQueueSet`, the throttle refusal included.
   */
  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('setRequestQueue')
  async handleSetRequestQueue(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatSearchService.handleSetRequestQueue(client, data);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('sendFriendRequest')
  async handleSendFriendRequest(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatFriendRequestService.handleSendFriendRequest(
      client,
      data,
      this.server,
    );
  }

  @SubscribeMessage('acceptFriendRequest')
  async handleAcceptFriendRequest(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatFriendRequestService.handleAcceptFriendRequest(
      client,
      data,
      this.server,
    );
  }

  @SubscribeMessage('rejectFriendRequest')
  async handleRejectFriendRequest(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatFriendRequestService.handleRejectFriendRequest(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('ensureInvitationChat')
  async handleEnsureInvitationChat(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: unknown,
  ) {
    return this.chatFriendRequestService.handleEnsureInvitationChat(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 300, ttl: 900000 } })
  @SubscribeMessage('getFriendRequests')
  async handleGetFriendRequests(@ConnectedSocket() client: Socket) {
    return this.chatFriendRequestService.handleGetFriendRequests(client);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 300, ttl: 900000 } })
  @SubscribeMessage('getFriends')
  async handleGetFriends(@ConnectedSocket() client: Socket) {
    return this.chatFriendRequestService.handleGetFriends(client);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('unfriend')
  async handleUnfriend(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatFriendRequestService.handleUnfriend(
      client,
      data,
      this.server,
    );
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @SubscribeMessage('blockUser')
  async handleBlockUser(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatBlockService.handleBlockUser(client, data, this.server);
  }

  @SubscribeMessage('unblockUser')
  async handleUnblockUser(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: any,
  ) {
    return this.chatBlockService.handleUnblockUser(client, data);
  }

  @UseGuards(WsThrottlerGuard)
  @Throttle({ default: { limit: 300, ttl: 900000 } })
  @SubscribeMessage('getBlockedList')
  async handleGetBlockedList(@ConnectedSocket() client: Socket) {
    return this.chatBlockService.handleGetBlockedList(client);
  }
}
