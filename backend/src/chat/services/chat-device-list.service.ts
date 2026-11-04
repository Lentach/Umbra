import { Injectable, Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import {
  DeviceListRejectedError,
  DeviceListService,
} from '../../key-bundles/device-list.service';
import {
  EnrollDeviceAuthorityDto,
  GetDeviceListDto,
  GetDeviceListsDto,
  UpdateDeviceListDto,
} from '../dto/device-list.dto';
import { validateDto } from '../utils/dto.validator';
import { userRoom } from '../utils/user-room';
import { deviceAuthorizationPayload } from '../mappers/device-authorization.mapper';

/**
 * socket.io declares `Socket.data` as `any`; one documented narrowing keeps
 * that assertion in a single place (same pattern as chat-key-exchange).
 */
function socketUserId(client: Socket): number | undefined {
  return (client.data as { user?: { id: number } }).user?.id;
}
/**
 * Wire surface of the DAK-signed device list (Phase 2 T2, spec §7 row 424:
 * `getDeviceList` / `deviceListChanged`; the enrollment event is T2's — §7
 * names no enrollment event because enrollment rides the enable-linking
 * action that precedes provisioning, spec §3 "created on the primary when
 * multi-device is first enabled").
 *
 * Contract style: request-event → response-event, refusals as
 * `success:false` answers with stable codes — a deliberate refusal is an
 * answer, not a server `error`. Every accepted list WRITE broadcasts
 * `deviceListChanged { userId, listVersion }` to the account's sessions
 * (§5.3: the user room carries list changes; peers re-fetch via
 * `getDeviceList`).
 */
@Injectable()
export class ChatDeviceListService {
  private readonly logger = new Logger(ChatDeviceListService.name);

  constructor(private readonly deviceListService: DeviceListService) {}

  async handleEnrollDeviceAuthority(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(EnrollDeviceAuthorityDto, data);
      await this.deviceListService.enroll(userId, {
        dakPub: dto.dakPub,
        enrollmentSig: dto.enrollmentSig,
        createdAt: dto.createdAt,
        listCanonical: dto.listCanonical,
        listSignature: dto.listSignature,
      });
      client.emit('deviceAuthorityEnrolled', { success: true, listVersion: 1 });
      server
        .to(userRoom(userId))
        .emit('deviceListChanged', { userId, listVersion: 1 });
    } catch (error) {
      if (error instanceof DeviceListRejectedError) {
        // The gate did its job; the client reads the code, never retries
        // blindly. Nothing was written.
        client.emit('deviceAuthorityEnrolled', {
          success: false,
          error: error.code,
        });
        return;
      }
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`enrollDeviceAuthority failed: ${message}`);
      client.emit('deviceAuthorityEnrolled', {
        success: false,
        error: 'enrollment_failed',
      });
    }
  }

  async handleUpdateDeviceList(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const userId = socketUserId(client);
    if (!userId) return;
    try {
      const dto = validateDto(UpdateDeviceListDto, data);
      const listVersion = await this.deviceListService.applySignedListUpdate(
        userId,
        {
          listCanonical: dto.listCanonical,
          listSignature: dto.listSignature,
        },
      );
      client.emit('deviceListUpdated', { success: true, listVersion });
      server
        .to(userRoom(userId))
        .emit('deviceListChanged', { userId, listVersion });
    } catch (error) {
      if (error instanceof DeviceListRejectedError) {
        client.emit('deviceListUpdated', {
          success: false,
          error: error.code,
        });
        return;
      }
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`updateDeviceList failed: ${message}`);
      client.emit('deviceListUpdated', {
        success: false,
        error: 'update_failed',
      });
    }
  }

  /**
   * Serves the stored enrollment + list of the CALLER'S OWN account, in the
   * byte-exact form of [deviceAuthorizationPayload]: the I7 own-skew re-fetch,
   * the connect refresh, the link ceremony and the devices screen read it, and
   * it discloses nothing the caller does not already hold.
   *
   * OWN ID ONLY (Phase 4 step 5; decisions 114, 117). This once served any
   * account's roster to any authenticated caller, and then (amendment (xliii))
   * to friends and conversation partners. Both entitlements read the friend and
   * conversation rows, which are gone: a friend's list now arrives over the box
   * or from the `searchUsers` handle lookup, never by id, so the server
   * consults no friendship and no chat.
   *
   * A request for any other id is SILENT, matching the error path below: I5
   * makes silence fail-closed on the client ("cannot verify", never "no
   * devices"), and answering would itself confirm whether the account exists.
   */
  async handleGetDeviceList(client: Socket, data: unknown): Promise<void> {
    const requesterId = socketUserId(client);
    if (!requesterId) return;
    try {
      const dto = validateDto(GetDeviceListDto, data);
      await this.serveDeviceList(client, requesterId, dto.userId);
    } catch (error) {
      // Silence is fail-closed on the client (I5: an unanswered fetch means
      // "cannot verify", never "no devices").
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`getDeviceList failed: ${message}`);
    }
  }

  /**
   * `getDeviceLists { userIds }` (metadata-privacy item 5, E20a): one request
   * for several users at once. Each user named gets EXACTLY the
   * [handleGetDeviceList] treatment — the same own-id rule, the same
   * replacement-owed refusal, the same `deviceList` answer — so a batch can
   * never reach a roster a single request could not. A refused user stays
   * silent while the others are served; an invalid batch (empty, over 256, a
   * duplicate, an id outside 1..2³¹−1) is refused whole, in silence.
   *
   * Users are served one after another, not in parallel: 256 users in
   * parallel would hold the connection pool against every other request.
   * One user's failure does not silence the rest.
   */
  async handleGetDeviceLists(client: Socket, data: unknown): Promise<void> {
    const requesterId = socketUserId(client);
    if (!requesterId) return;
    let dto: GetDeviceListsDto;
    try {
      dto = validateDto(GetDeviceListsDto, data);
    } catch {
      this.logger.warn(`[device-list] batch REFUSED reason=invalid_payload`);
      return;
    }
    let failed = 0;
    let firstFailure = '';
    for (const userId of dto.userIds) {
      try {
        await this.serveDeviceList(client, requesterId, userId);
      } catch (error) {
        if (failed === 0) {
          firstFailure = error instanceof Error ? error.message : String(error);
        }
        failed++;
      }
    }
    if (failed > 0) {
      this.logger.error(
        `getDeviceLists failed for ${failed} of ${dto.userIds.length}: ${firstFailure}`,
      );
    }
  }

  /**
   * The per-user rule both verbs share: emit `deviceList` for [userId] when
   * it is the caller's own and the account owes no replacement enrollment,
   * else nothing. Throws on a lookup failure; each caller decides what a
   * failure silences.
   */
  private async serveDeviceList(
    client: Socket,
    requesterId: number,
    userId: number,
  ): Promise<void> {
    if (requesterId !== userId) {
      this.logger.warn(`[device-list] REFUSED reason=not_entitled`);
      return;
    }
    const row = await this.deviceListService.getAuthorization(userId);
    if (
      (await this.deviceListService.pendingReplacementVersion(userId)) !== null
    ) {
      // Amendment (xlv) clause 2, widened to every account shape by (l).
      //
      // Two shapes reach here, and BOTH serve a roster that cannot receive:
      //
      //  * NO enrollment row. `authorization: null` is not merely "not
      //    enrolled" on the wire — the client answers it by SYNTHESIZING the
      //    single device 1 a non-enrolled account has by construction. A
      //    completed §6.2 reset breaks that construction: ids are never
      //    reused ((a)), so the recovering device is id >= 2 and device 1 is
      //    revoked.
      //  * A SURVIVING enrollment row, which is the shape (l) fixes. The
      //    teardown deliberately leaves the row ((xxix)) and only stamps
      //    `devices.revokedAt`, so `listCanonical` still names the pre-reset
      //    devices LIVE. A peer holding the pre-reset anchor VERIFIES that
      //    dead roster — the enrollment was signed by the very key it pinned
      //    — and where the only live entry is device 1 the envelope is
      //    accepted (device 1 is exempt from the liveness refusal), commits
      //    with `encryptedContent = null`, and the recovering device reads
      //    `none_for_device` forever. The sender sees success.
      //
      // Either way the loss is silent, permanent and bidirectional, and the
      // send path cannot notice. So refuse, exactly as an entitlement
      // refusal does — silence is fail-closed on the client (I5: "cannot
      // verify", never "no devices"), which downgrades silent message loss
      // to a visible send failure until the recovering device re-enrolls
      // ((xlv) clause 1).
      this.logger.warn(
        `[device-list] REFUSED reason=no_addressable_device (replacement enrollment owed — post-reset or post-rotation; enrolled=${row != null})`,
      );
      return;
    }
    client.emit('deviceList', {
      userId,
      authorization: deviceAuthorizationPayload(row),
    });
  }
}
