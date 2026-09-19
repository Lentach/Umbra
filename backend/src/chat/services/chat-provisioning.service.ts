import { Injectable, Logger } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { Server, Socket } from 'socket.io';
import { RefreshTokensService } from '../../auth/refresh-tokens.service';
import { Device } from '../../key-bundles/device.entity';
import { DevicesService } from '../../key-bundles/devices.service';
import {
  DeviceListRejectedError,
  DeviceListService,
} from '../../key-bundles/device-list.service';
import {
  CanonicalDeviceListError,
  DeviceListEntry,
  ParsedDeviceList,
  parseCanonicalDeviceList,
} from '../../key-bundles/device-list-canonical.util';
import { verifyDeviceListSignature } from '../../key-bundles/device-list-signature.util';
import { ProvisioningStage } from '../../key-bundles/provisioning-stages.service';
import { ProvisioningStagesService } from '../../key-bundles/provisioning-stages.service';
import { UsersService } from '../../users/users.service';
import {
  CancelProvisioningDto,
  FetchProvisioningBlobDto,
  OpenProvisioningDto,
  ProvisionDeviceDto,
  ProvisioningCompleteDto,
  ProvisioningHelloDto,
} from '../dto/provisioning.dto';
import { validateDto } from '../utils/dto.validator';
import { userRoom } from '../utils/user-room';

/** Serialized Curve25519 public keys are 33 bytes (0x05-prefixed). */
const EPHEMERAL_PUBLIC_KEY_LENGTH = 33;

/**
 * socket.io declares `Socket.data` as `any`; one documented narrowing keeps
 * that assertion in a single place (same pattern as chat-device-list).
 */
function socketUserId(client: Socket): number | undefined {
  return (client.data as { user?: { id: number } }).user?.id;
}

/**
 * Wire surface of the §5.1 provisioning (linking) ceremony (Phase 2 T3, §7
 * row 424: `openProvisioning`, `provisioningHello`, `provisionDevice`,
 * `provisioningBlob`, `provisioningComplete` + the cancel path).
 *
 * The server is a BLIND RELAY with a liveness gate (I1): the IK-bearing blob
 * is opaque bytes encrypted client-side under the SAS-verified DH secret, and
 * the staged list mutation is verified against the ENROLLED DAK exactly like
 * every other mutation. `ephPubN` never transits here at all (amendment (c) —
 * it is QR/manual-code only), so no payload, field, or log line may carry it.
 *
 * Contract style matches chat-device-list: request-event → response-event,
 * refusals as `success:false` answers with stable codes. A stage lookup miss
 * is ALWAYS answered `unknown_stage` — expiry, foreign account, and genuinely
 * unknown ids are deliberately indistinguishable to the caller.
 */
@Injectable()
export class ChatProvisioningService {
  private readonly logger = new Logger(ChatProvisioningService.name);

  constructor(
    private readonly stages: ProvisioningStagesService,
    private readonly devicesService: DevicesService,
    private readonly deviceListService: DeviceListService,
    private readonly refreshTokensService: RefreshTokensService,
    private readonly usersService: UsersService,
    private readonly jwtService: JwtService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  /**
   * Either side opens a ceremony (amendment (lxxvii)): `role` defaults to
   * 'new' (the joining device — byte-compatible with the roleless v1 open),
   * 'primary' means the enrolled device opened and the joining device says
   * hello. The deviceId is allocated exactly once HERE and memoized on the
   * stage (amendment (a)); it is deliberately NOT in the answer — N learns
   * its id from the decrypted blob only, the primary from
   * `provisioningHelloAck` or the hello relay.
   */
  async handleOpenProvisioning(client: Socket, data?: unknown): Promise<void> {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(OpenProvisioningDto, data ?? {});
      const role = dto.role ?? 'new';
      const authorization =
        await this.deviceListService.getAuthorization(userId);
      if (!authorization) {
        client.emit('provisioningOpened', {
          success: false,
          error: 'not_enrolled',
        });
        return;
      }
      const deviceId = await this.devicesService.allocateDeviceId(userId);
      const stage = this.stages.open(userId, client.id, deviceId, role);
      client.emit('provisioningOpened', {
        success: true,
        provisioningId: stage.provisioningId,
        expiresAt: stage.expiresAt,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`openProvisioning failed userId=${userId}: ${message}`);
      client.emit('provisioningOpened', {
        success: false,
        error: 'open_failed',
      });
    }
  }

  /**
   * The OTHER party (the primary when the opener is 'new', the joining
   * device when the opener is 'primary') presents its ephemeral. The FIRST
   * one is pinned (amendment (c)); an identical retry re-answers success and
   * re-relays (idempotent — the first relay may have raced the opener's
   * listener), a different one is refused. The ack AND the relay carry the
   * memoized deviceId (amendment (lxxvii)): this is how the primary learns
   * the id it must sign, whichever socket it sits on. The wire field stays
   * `ephPubP` for v1 compatibility even though it is simply "the hello
   * party's ephemeral". An OPTIONAL `platform` label rides the same relay
   * (amendment (lxxx) clause 3) so a ceremony the PRIMARY opened can still
   * name the joining device; omitted by older clients, and the signer then
   * falls back to 'unknown'.
   */
  handleProvisioningHello(client: Socket, data: unknown, server: Server): void {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(ProvisioningHelloDto, data);
      const stage = this.liveStage(dto.provisioningId, userId);
      if (!stage) {
        client.emit('provisioningHelloAck', {
          success: false,
          error: 'unknown_stage',
        });
        return;
      }
      const decoded = Buffer.from(dto.ephPubP, 'base64');
      if (
        decoded.length !== EPHEMERAL_PUBLIC_KEY_LENGTH ||
        decoded.toString('base64') !== dto.ephPubP
      ) {
        client.emit('provisioningHelloAck', {
          success: false,
          error: 'invalid_ephemeral',
        });
        return;
      }
      if (stage.ephPubP !== null && stage.ephPubP !== dto.ephPubP) {
        client.emit('provisioningHelloAck', {
          success: false,
          error: 'ephemeral_already_pinned',
        });
        return;
      }
      stage.ephPubP = dto.ephPubP;
      // Record which socket the hello side speaks from: it fills whichever
      // role slot the opener did not take.
      if (stage.openerRole === 'new') {
        stage.primarySocketId = client.id;
      } else {
        stage.newDeviceSocketId = client.id;
      }
      client.emit('provisioningHelloAck', {
        success: true,
        deviceId: stage.deviceId,
      });
      // `platform` rides along only when the hello side sent one (amendment
      // (lxxx) clause 3): an older client omits it and the opener falls back
      // to 'unknown', exactly as before. Nothing is stored — the relay is
      // synchronous with the hello, so the stage never needs to hold it.
      server.to(stage.openerSocketId).emit('provisioningHello', {
        provisioningId: stage.provisioningId,
        ephPubP: dto.ephPubP,
        deviceId: stage.deviceId,
        ...(dto.platform === undefined ? {} : { platform: dto.platform }),
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(
        `provisioningHello failed userId=${userId}: ${message}`,
      );
      client.emit('provisioningHelloAck', {
        success: false,
        error: 'hello_failed',
      });
    }
  }

  /**
   * The PRIMARY stages the blob + signed v+1 mutation (§5.1 two-phase
   * commit) — explicitly `primarySocketId` only (amendment (lxxvii),
   * falsification F4). Everything is verified BEFORE staging; a retry
   * OVERWRITES the staged payload (the stage is not consumed until
   * completion).
   */
  async handleProvisionDevice(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(ProvisionDeviceDto, data);
      const stage = this.liveStage(dto.provisioningId, userId);
      if (!stage) {
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'unknown_stage',
        });
        return;
      }
      if (
        stage.ephPubP === null ||
        stage.primarySocketId === null ||
        stage.newDeviceSocketId === null
      ) {
        // Secrets-last (I3): a blob before the SAS round even started is a
        // protocol violation, not a race.
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'hello_not_pinned',
        });
        return;
      }
      if (client.id !== stage.primarySocketId) {
        // Only the primary holds the DAK; a blob from any other socket —
        // including the new device itself — is refused (F4).
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'not_primary',
        });
        return;
      }
      const authorization =
        await this.deviceListService.getAuthorization(userId);
      if (!authorization) {
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'not_enrolled',
        });
        return;
      }

      let staged: ParsedDeviceList;
      let stored: ParsedDeviceList;
      try {
        staged = this.decodeCanonical(dto.listCanonical);
        stored = this.decodeCanonical(authorization.listCanonical);
      } catch (error) {
        if (error instanceof CanonicalDeviceListError) {
          client.emit('provisionDeviceAck', {
            success: false,
            error: 'invalid_canonical',
          });
          return;
        }
        throw error;
      }
      if (staged.userId !== userId) {
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'canonical_user_mismatch',
        });
        return;
      }
      if (staged.version !== authorization.listVersion + 1) {
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'stale_version',
        });
        return;
      }
      if (
        !verifyDeviceListSignature({
          dakPub: authorization.dakPub,
          canonical: Buffer.from(dto.listCanonical, 'base64'),
          signature: dto.listSignature,
        })
      ) {
        this.logger.warn(
          `[provisioning] REFUSED stage with invalid list signature userId=${userId}`,
        );
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'invalid_list_signature',
        });
        return;
      }
      const added = this.addedEntry(stored, staged, stage);
      if (!added) {
        this.logger.warn(
          `[provisioning] REFUSED stage whose diff is not exactly the memoized device userId=${userId} deviceId=${stage.deviceId}`,
        );
        client.emit('provisionDeviceAck', {
          success: false,
          error: 'invalid_mutation',
        });
        return;
      }

      stage.blob = dto.blob;
      stage.stagedListCanonical = dto.listCanonical;
      stage.stagedListSignature = dto.listSignature;
      stage.platform = added.platform;
      client.emit('provisionDeviceAck', { success: true });
      server.to(stage.newDeviceSocketId).emit('provisioningBlob', {
        provisioningId: stage.provisioningId,
        blob: dto.blob,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`provisionDevice failed userId=${userId}: ${message}`);
      client.emit('provisionDeviceAck', {
        success: false,
        error: 'stage_failed',
      });
    }
  }

  /**
   * Blob re-fetch until TTL or completion (§5.1; falsification 18: a ceremony
   * killed between blob and complete leaves the blob re-fetchable). The NEW
   * device's socket only — knowledge of the provisioningId alone drives
   * nothing. The refusal keeps the v1 `not_opener` code (the new device IS
   * the opener in the default role).
   */
  handleFetchProvisioningBlob(client: Socket, data: unknown): void {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(FetchProvisioningBlobDto, data);
      const stage = this.liveStage(dto.provisioningId, userId);
      if (!stage) {
        client.emit('provisioningBlob', {
          success: false,
          error: 'unknown_stage',
        });
        return;
      }
      if (client.id !== stage.newDeviceSocketId) {
        client.emit('provisioningBlob', {
          success: false,
          error: 'not_opener',
        });
        return;
      }
      if (stage.consumed || stage.blob === null) {
        // A retired stage has no blob by construction (amendment (a): no
        // refetch after commit).
        client.emit('provisioningBlob', { success: false, error: 'no_blob' });
        return;
      }
      client.emit('provisioningBlob', {
        provisioningId: stage.provisioningId,
        blob: stage.blob,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(
        `fetchProvisioningBlob failed userId=${userId}: ${message}`,
      );
      client.emit('provisioningBlob', {
        success: false,
        error: 'fetch_failed',
      });
    }
  }

  /**
   * Two-phase commit, phase two (§5.1). The NEW device's socket ONLY
   * (falsification 8; refusal keeps the v1 `not_opener` code), one-shot via
   * the stage's synchronous CAS (amendment (a)), then ONE transaction:
   * devices row + signed list mutation + refresh session. The re-issued
   * tokens travel in the success answer on that socket (amendment (iii)) —
   * same trust surface as login's answer.
   */
  async handleProvisioningComplete(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(ProvisioningCompleteDto, data);
      const stage = this.liveStage(dto.provisioningId, userId);
      if (!stage) {
        client.emit('provisioningCompleted', {
          success: false,
          error: 'unknown_stage',
        });
        return;
      }
      if (client.id !== stage.newDeviceSocketId) {
        // Falsification 8: any session other than the new device's — even of
        // the same account — is rejected.
        client.emit('provisioningCompleted', {
          success: false,
          error: 'not_opener',
        });
        return;
      }
      if (stage.consumed) {
        client.emit('provisioningCompleted', {
          success: false,
          error: 'already_completed',
        });
        return;
      }
      if (
        stage.blob === null ||
        stage.stagedListCanonical === null ||
        stage.stagedListSignature === null
      ) {
        client.emit('provisioningCompleted', {
          success: false,
          error: 'not_staged',
        });
        return;
      }
      const user = await this.usersService.findById(userId);
      if (!user) {
        client.emit('provisioningCompleted', {
          success: false,
          error: 'complete_failed',
        });
        return;
      }
      // Synchronous compare-and-set: of two concurrent completes exactly one
      // proceeds to the transaction (amendment (a)).
      if (!this.stages.consume(stage.provisioningId)) {
        client.emit('provisioningCompleted', {
          success: false,
          error: 'already_completed',
        });
        return;
      }

      const stagedListCanonical = stage.stagedListCanonical;
      const stagedListSignature = stage.stagedListSignature;
      let listVersion = 0;
      let refreshToken = '';
      try {
        await this.dataSource.transaction(async (manager) => {
          await manager.getRepository(Device).insert({
            userId,
            deviceId: stage.deviceId,
            platform: stage.platform,
            isPrimary: false,
          });
          listVersion = await this.deviceListService.applySignedListUpdate(
            userId,
            {
              listCanonical: stagedListCanonical,
              listSignature: stagedListSignature,
            },
            manager,
          );
          // Inside the callback so a failure still aborts the commit; the
          // token row itself rides its own connection, and a leaked row for
          // an uncommitted device is inert (uploads for a never-activated
          // deviceId are rejected).
          refreshToken = await this.refreshTokensService.createToken(
            userId,
            stage.deviceId,
          );
        });
      } catch (error) {
        // The stage goes back to consumable either way: on stale_version the
        // primary re-signs v+2 and re-submits provisionDevice against the
        // SAME stage (falsification 20); on anything else a retry is at
        // worst another refusal.
        this.stages.restore(stage.provisioningId);
        if (
          error instanceof DeviceListRejectedError &&
          error.code === 'stale_version'
        ) {
          client.emit('provisioningCompleted', {
            success: false,
            error: 'stale_version',
          });
          return;
        }
        const message = error instanceof Error ? error.message : String(error);
        this.logger.error(
          `provisioningComplete commit failed userId=${userId}: ${message}`,
        );
        client.emit('provisioningCompleted', {
          success: false,
          error: 'commit_failed',
        });
        return;
      }

      // Payload shape EXACTLY matches login's (auth.service.ts) so every
      // downstream consumer of the claim set behaves identically.
      const accessToken = this.jwtService.sign({
        sub: userId,
        username: user.username,
        tag: user.tag,
        deviceId: stage.deviceId,
      });
      this.stages.retire(stage.provisioningId);
      this.logger.log(
        `[provisioning] committed userId=${userId} deviceId=${stage.deviceId} version=${listVersion}`,
      );
      client.emit('provisioningCompleted', {
        success: true,
        deviceId: stage.deviceId,
        access_token: accessToken,
        refresh_token: refreshToken,
      });
      server
        .to(userRoom(userId))
        .emit('deviceListChanged', { userId, listVersion });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(
        `provisioningComplete failed userId=${userId}: ${message}`,
      );
      client.emit('provisioningCompleted', {
        success: false,
        error: 'complete_failed',
      });
    }
  }

  /**
   * Cancel, accepted from ANY authenticated session of the account: the
   * server cannot cryptographically identify the primary (the DAK never
   * touches it), and a party cancelling its own ceremony is harmless — the
   * protective action stays generously available (I4 spirit). The relay
   * notifies every recorded party OTHER than the caller (amendment
   * (lxxvii)).
   */
  handleCancelProvisioning(
    client: Socket,
    data: unknown,
    server: Server,
  ): void {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(CancelProvisioningDto, data);
      const stage = this.liveStage(dto.provisioningId, userId);
      if (!stage || stage.consumed) {
        client.emit('provisioningCancelled', {
          success: false,
          error: 'unknown_stage',
        });
        return;
      }
      this.stages.discard(stage.provisioningId);
      const others = new Set(
        [stage.primarySocketId, stage.newDeviceSocketId].filter(
          (socketId): socketId is string =>
            socketId !== null && socketId !== client.id,
        ),
      );
      for (const socketId of others) {
        server.to(socketId).emit('provisioningCancelled', {
          provisioningId: stage.provisioningId,
        });
      }
      client.emit('provisioningCancelled', {
        success: true,
        provisioningId: stage.provisioningId,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(
        `cancelProvisioning failed userId=${userId}: ${message}`,
      );
      client.emit('provisioningCancelled', {
        success: false,
        error: 'cancel_failed',
      });
    }
  }

  /**
   * Stage lookup bound to the caller's account. A foreign account's stage is
   * answered exactly like an unknown one — existence must not leak across
   * accounts.
   */
  private liveStage(
    provisioningId: string,
    userId: number,
  ): ProvisioningStage | null {
    const stage = this.stages.get(provisioningId);
    if (!stage || stage.userId !== userId) return null;
    return stage;
  }

  /** Base64 transport sanity + strict canonical parse (falsification 23). */
  private decodeCanonical(listCanonical: string): ParsedDeviceList {
    const canonical = Buffer.from(listCanonical, 'base64');
    if (canonical.toString('base64') !== listCanonical) {
      throw new CanonicalDeviceListError('non-canonical base64');
    }
    return parseCanonicalDeviceList(canonical);
  }

  /**
   * The staged list must be the stored list plus EXACTLY the memoized
   * device: one new entry with the allocated id, a platform label, and NO
   * name (amendment (i) — names arrive with the Phase 3 rename UI); every
   * pre-existing entry byte-identical. Returns the added entry, or null when
   * the diff is anything else.
   */
  private addedEntry(
    stored: ParsedDeviceList,
    staged: ParsedDeviceList,
    stage: ProvisioningStage,
  ): DeviceListEntry | null {
    if (staged.devices.length !== stored.devices.length + 1) return null;
    let added: DeviceListEntry | null = null;
    const remaining = [...stored.devices];
    for (const entry of staged.devices) {
      const match = remaining.findIndex((d) => d.deviceId === entry.deviceId);
      if (match >= 0) {
        const previous = remaining[match];
        if (
          previous.platform !== entry.platform ||
          previous.addedAt !== entry.addedAt ||
          previous.name !== entry.name ||
          previous.revokedAt !== entry.revokedAt
        ) {
          return null;
        }
        remaining.splice(match, 1);
        continue;
      }
      if (added !== null) return null;
      added = entry;
    }
    if (remaining.length > 0 || added === null) return null;
    if (added.deviceId !== stage.deviceId) return null;
    if (added.name !== undefined) return null;
    if (added.revokedAt !== undefined) return null;
    // The canonical parser already caps platform at 32 chars; presence is
    // what this asserts.
    if (added.platform.length === 0) return null;
    return added;
  }
}
