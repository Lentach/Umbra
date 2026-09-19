import { Injectable, Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import {
  DeviceListRejectedError,
  DeviceListService,
} from '../../key-bundles/device-list.service';
import {
  EnrollDeviceAuthorityDto,
  GetDeviceListDto,
  UpdateDeviceListDto,
} from '../dto/device-list.dto';
import { validateDto } from '../utils/dto.validator';
import { userRoom } from '../utils/user-room';
import { ChatValidationService } from './chat-validation.service';
import { ConversationsService } from '../../conversations/conversations.service';

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

  constructor(
    private readonly deviceListService: DeviceListService,
    private readonly chatValidationService: ChatValidationService,
    private readonly conversationsService: ConversationsService,
  ) {}

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
   * Serves the stored enrollment + list to a caller ENTITLED to it: peers run
   * the I7 chain themselves and need the full record. `listCanonical` is
   * echoed as the STORED base64 string verbatim (falsification 23);
   * `enrollmentCreatedAt` as the signed integer milliseconds, so E re-verifies
   * bit-for-bit.
   *
   * Entitlement (amendment (xliii)). This used to serve ANY account's roster
   * to ANY authenticated caller, which made it a device-count, platform and
   * timeline oracle over every user on the instance — a precise profiling
   * surface in an app whose premise is metadata minimisation, on a repository
   * public since 2026-08-18. Three ways in, in cost order:
   *
   *   1. YOUR OWN list. Always. The I7 own-skew re-fetch depends on it and it
   *      discloses nothing you do not already hold.
   *   2. Someone you may message — friends and not blocked either way. The
   *      predicate the gateway already uses everywhere else; no new
   *      authorisation concept is introduced here.
   *   3. Someone you share a conversation with, even if rule 2 now refuses.
   *      REQUIRED, not a convenience: a peer who later unfriends or blocks you
   *      would otherwise render history you ALREADY RECEIVED permanently
   *      undecryptable, because the accept-side gate needs their verified list
   *      to decrypt. A fix that silently destroys readable history is worse
   *      than the leak it closes.
   *
   * A refusal is SILENT, matching the error path below: I5 makes silence
   * fail-closed on the client ("cannot verify", never "no devices"), and
   * answering would itself confirm whether the account exists.
   */
  async handleGetDeviceList(client: Socket, data: unknown): Promise<void> {
    const requesterId = socketUserId(client);
    if (!requesterId) return;
    try {
      const dto = validateDto(GetDeviceListDto, data);
      if (!(await this.mayReadDeviceList(requesterId, dto.userId))) {
        this.logger.warn(
          `[device-list] REFUSED requesterId=${requesterId} targetUserId=${dto.userId} reason=not_entitled`,
        );
        return;
      }
      const row = await this.deviceListService.getAuthorization(dto.userId);
      if (
        (await this.deviceListService.pendingReplacementVersion(dto.userId)) !==
        null
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
          `[device-list] REFUSED targetUserId=${dto.userId} reason=no_addressable_device (replacement enrollment owed — post-reset or post-rotation; enrolled=${row != null})`,
        );
        return;
      }
      client.emit('deviceList', {
        userId: dto.userId,
        authorization: row
          ? {
              dakPub: row.dakPub,
              enrollmentSig: row.enrollmentSig,
              enrollmentCreatedAt: row.enrollmentCreatedAt.getTime(),
              listVersion: row.listVersion,
              listSignature: row.listSignature,
              listCanonical: row.listCanonical,
            }
          : null,
      });
    } catch (error) {
      // Silence is fail-closed on the client (I5: an unanswered fetch means
      // "cannot verify", never "no devices").
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(
        `getDeviceList failed requesterId=${requesterId}: ${message}`,
      );
    }
  }

  /**
   * May `requesterId` read `targetUserId`'s device roster? See the three rules
   * on [handleGetDeviceList] (amendment (xliii)).
   *
   * Ordered cheapest-first: the identity check costs nothing, the messaging
   * predicate is two indexed reads, and the conversation lookup only runs when
   * the messaging predicate has already refused — so the common case (a
   * friend) never pays for the carve-out.
   */
  private async mayReadDeviceList(
    requesterId: number,
    targetUserId: number,
  ): Promise<boolean> {
    if (requesterId === targetUserId) return true;
    const canMessage = await this.chatValidationService.validateCanMessage(
      requesterId,
      targetUserId,
    );
    if (canMessage.valid) return true;
    // The history carve-out: they can no longer message each other, but a
    // conversation between them exists, so messages already delivered still
    // need this list to decrypt.
    const conversation = await this.conversationsService.findByUsers(
      requesterId,
      targetUserId,
    );
    return conversation != null;
  }
}
