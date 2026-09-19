import { Injectable, Logger } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { Server, Socket } from 'socket.io';
import { RefreshTokensService } from '../../auth/refresh-tokens.service';
import { FcmTokensService } from '../../fcm-tokens/fcm-tokens.service';
import { WebPushSubscriptionsService } from '../../web-push-subscriptions/web-push-subscriptions.service';
import {
  DeviceListRejectedError,
  DeviceListService,
} from '../../key-bundles/device-list.service';
import {
  CanonicalDeviceListError,
  parseCanonicalDeviceList,
} from '../../key-bundles/device-list-canonical.util';
import { DevicesService } from '../../key-bundles/devices.service';
import {
  DEFAULT_DEVICE_ID,
  KeyBundlesService,
} from '../../key-bundles/key-bundles.service';
import { ProvisioningStagesService } from '../../key-bundles/provisioning-stages.service';
import { RevokeDeviceDto } from '../dto/device-list.dto';
import { validateDto } from '../utils/dto.validator';
import { deviceRoom, socketsForDevice, userRoom } from '../utils/user-room';

/**
 * socket.io declares `Socket.data` as `any`, so the session principal is
 * narrowed at runtime here — once per service, exactly like the rest of the
 * device surface. An unauthenticated socket answers `undefined` and the
 * handler returns without emitting anything.
 *
 * A missing `deviceId` means device 1 (§8): a token issued before the claim
 * existed belongs to the account's original device, which is the same reading
 * `handleConnection` applies when it joins the device room.
 */
function socketPrincipal(
  client: Socket,
): { userId: number; deviceId: number } | undefined {
  const data: unknown = client.data;
  if (data === null || typeof data !== 'object' || !('user' in data)) {
    return undefined;
  }
  const user = data.user;
  if (
    user === null ||
    typeof user !== 'object' ||
    !('id' in user) ||
    typeof user.id !== 'number'
  ) {
    return undefined;
  }
  const deviceId =
    'deviceId' in user && typeof user.deviceId === 'number'
      ? user.deviceId
      : DEFAULT_DEVICE_ID;
  return { userId: user.id, deviceId };
}

/** Every refusal code this handler can answer with (all pre-write). */
type RevocationRefusal =
  | 'not_primary'
  | 'cannot_revoke_self'
  | 'cannot_revoke_primary'
  | 'unknown_device'
  | 'already_revoked'
  | 'list_device_mismatch'
  | 'invalid_canonical';

/**
 * Wire surface of device revocation (Phase 2 T6, spec §5.5, §7 row 424
 * `revokeDevice`).
 *
 * ONE transaction does the durable half — the DAK-signed list mutation, the
 * `revokedAt` stamp, that device's refresh sessions, and that device's key
 * material — so there is no window where the list says revoked while the
 * device still holds a session, or vice versa. The list mutation reuses T2's
 * gate (`applySignedListUpdate`): the server never mints a list version, and a
 * revocation is just a mutation whose canonical bytes carry `revokedAt`.
 *
 * Everything that CANNOT be transactional (push rows in other modules, the
 * in-memory provisioning stages, socket kicks) runs strictly AFTER the commit,
 * because each is only safe once the durable decision is final: kicking before
 * the commit would drop a session for a revocation that then rolled back.
 *
 * Contract style matches the rest of the device-list surface: request-event →
 * response-event, refusals as `success:false` answers with stable codes. The
 * caller's answer is `deviceRevocationCompleted`; the REVOKED device gets
 * `deviceRevoked` (spec §12 amendment (xxvi)) and is then disconnected.
 */
@Injectable()
export class ChatDeviceRevocationService {
  private readonly logger = new Logger(ChatDeviceRevocationService.name);

  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly deviceListService: DeviceListService,
    private readonly devicesService: DevicesService,
    private readonly keyBundlesService: KeyBundlesService,
    private readonly refreshTokensService: RefreshTokensService,
    private readonly stages: ProvisioningStagesService,
    private readonly fcmTokensService: FcmTokensService,
    private readonly webPushSubscriptionsService: WebPushSubscriptionsService,
  ) {}

  /**
   * Is `deviceId` shown as revoked in these signed canonical bytes?
   *
   * Amendment (xxi): the request and the signature must agree, or the teardown
   * would cut off a device the account's own signed list still calls live —
   * peers follow the list, so they would keep addressing envelopes to it.
   */
  private listRevokes(listCanonical: string, deviceId: number): boolean {
    const list = parseCanonicalDeviceList(Buffer.from(listCanonical, 'base64'));
    const entry = list.devices.find((device) => device.deviceId === deviceId);
    return entry !== undefined && entry.revokedAt !== undefined;
  }

  /**
   * Pre-write gauntlet (spec §12 amendment (xxi)). Returns a refusal code, or
   * null when the request may proceed to the transaction.
   *
   * `isPrimary` on the CALLER is defence in depth, not the authority: only the
   * primary holds the DAK private key (§3), so an impostor cannot produce the
   * signature `applySignedListUpdate` demands. Device 1 with no row is treated
   * as the primary per §8 — every pre-Phase-1 account is single-device and its
   * row appears only on first connect.
   */
  private async refuse(
    userId: number,
    callerDeviceId: number,
    dto: RevokeDeviceDto,
  ): Promise<RevocationRefusal | null> {
    if (dto.deviceId === callerDeviceId) return 'cannot_revoke_self';

    const rows = await this.devicesService.listForUser(userId);
    const caller = rows.find((row) => row.deviceId === callerDeviceId);
    const callerIsPrimary =
      caller === undefined
        ? callerDeviceId === DEFAULT_DEVICE_ID
        : caller.isPrimary;
    if (!callerIsPrimary) return 'not_primary';

    const target = rows.find((row) => row.deviceId === dto.deviceId);
    if (!target) return 'unknown_device';
    if (target.isPrimary) return 'cannot_revoke_primary';
    if (target.revokedAt !== null) return 'already_revoked';

    try {
      if (!this.listRevokes(dto.listCanonical, dto.deviceId)) {
        return 'list_device_mismatch';
      }
    } catch (error) {
      if (error instanceof CanonicalDeviceListError) return 'invalid_canonical';
      throw error;
    }
    return null;
  }

  async handleRevokeDevice(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const principal = socketPrincipal(client);
    if (!principal) return;
    const { userId, deviceId: callerDeviceId } = principal;

    let dto: RevokeDeviceDto;
    try {
      dto = validateDto(RevokeDeviceDto, data);
    } catch (error) {
      client.emit('deviceRevocationCompleted', {
        success: false,
        error: error instanceof Error ? error.message : String(error),
      });
      return;
    }

    try {
      const refusal = await this.refuse(userId, callerDeviceId, dto);
      if (refusal) {
        this.logger.warn(
          `[revoke] REFUSED callerDeviceId=${callerDeviceId} targetDeviceId=${dto.deviceId} reason=${refusal}`,
        );
        client.emit('deviceRevocationCompleted', {
          success: false,
          error: refusal,
        });
        return;
      }

      let listVersion = 0;
      try {
        await this.dataSource.transaction(async (manager) => {
          // The stamp goes first and is the concurrency arbiter: its
          // `revokedAt IS NULL` predicate serializes two racing revocations of
          // the same device, so the loser aborts before touching the list.
          const stamped = await this.devicesService.revoke(
            userId,
            dto.deviceId,
            manager,
          );
          if (!stamped) throw new AlreadyRevokedError();
          listVersion = await this.deviceListService.applySignedListUpdate(
            userId,
            {
              listCanonical: dto.listCanonical,
              listSignature: dto.listSignature,
            },
            manager,
          );
          await this.refreshTokensService.revokeForDevice(
            userId,
            dto.deviceId,
            manager,
          );
          await this.keyBundlesService.purgeDeviceMaterial(
            userId,
            dto.deviceId,
            manager,
          );
        });
      } catch (error) {
        if (error instanceof AlreadyRevokedError) {
          client.emit('deviceRevocationCompleted', {
            success: false,
            error: 'already_revoked',
          });
          return;
        }
        if (error instanceof DeviceListRejectedError) {
          // Nothing was written — the whole transaction rolled back, so the
          // device is still live and the client may re-sign and retry.
          client.emit('deviceRevocationCompleted', {
            success: false,
            error: error.code,
          });
          return;
        }
        throw error;
      }

      // ---- post-commit: the revocation is now durable ----

      // Push rows live in other modules and cannot join the transaction. A
      // failure here means the revoked device keeps receiving notifications,
      // so it is loud, but it must not turn a committed revocation into an
      // error answer the client would retry.
      try {
        await this.fcmTokensService.removeForDevice(userId, dto.deviceId);
        await this.webPushSubscriptionsService.removeForDevice(
          userId,
          dto.deviceId,
        );
      } catch (error) {
        this.logger.error(
          `[revoke] push teardown FAILED deviceId=${dto.deviceId}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }

      // A security action never waits on a stuck link (§5.1 + amendment
      // (xxv)): every pending stage of the account is now stale by
      // construction, because this revocation took the next version slot.
      this.stages.discardForUser(userId);

      // Tell the device, THEN drop it (amendment (xxvi)). Best-effort by
      // design — an offline device gets nothing and meets the connect gate
      // instead, which is the durable enforcement.
      server
        .to(deviceRoom(userId, dto.deviceId))
        .emit('deviceRevoked', { userId, deviceId: dto.deviceId });
      const kicked = socketsForDevice(server, userId, dto.deviceId);
      for (const socket of kicked) socket.disconnect();

      this.logger.log(
        `[revoke] deviceId=${dto.deviceId} version=${listVersion} kickedSockets=${kicked.length}`,
      );
      client.emit('deviceRevocationCompleted', {
        success: true,
        deviceId: dto.deviceId,
        listVersion,
      });
      server
        .to(userRoom(userId))
        .emit('deviceListChanged', { userId, listVersion });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`revokeDevice failed: ${message}`);
      client.emit('deviceRevocationCompleted', {
        success: false,
        error: 'revoke_failed',
      });
    }
  }
}

/**
 * Internal transaction abort for "this device was revoked by someone else
 * while we were committing". Never leaves this file.
 */
class AlreadyRevokedError extends Error {}
