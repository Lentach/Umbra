import { Injectable, Logger } from '@nestjs/common';
import { randomBytes } from 'crypto';
import { Server, Socket } from 'socket.io';
import {
  DEFAULT_DEVICE_ID,
  DeviceMaterialConflictError,
  IdentityLockedError,
  IdentityRestoreRefusedError,
  KeyBundlesService,
  PreKeyBundleResponse,
} from '../../key-bundles/key-bundles.service';
import { IdentityResetService } from '../../key-bundles/identity-reset.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { DeviceListService } from '../../key-bundles/device-list.service';
import { ConversationsService } from '../../conversations/conversations.service';
import { PushNotificationsService } from '../../push-notifications/push-notifications.service';
import { validateDto } from '../utils/dto.validator';
import { UploadKeyBundleDto } from '../dto/upload-key-bundle.dto';
import {
  ResetIdentityRequestDto,
  SetRecoveryKeyDto,
} from '../dto/identity-reset.dto';
import { UploadOneTimePreKeysDto } from '../dto/upload-one-time-pre-keys.dto';
import { FetchPreKeyBundleDto } from '../dto/fetch-pre-key-bundle.dto';
import { RequestSessionRebuildDto } from '../dto/request-session-rebuild.dto';
import { deviceRoom, socketsForDevice, userRoom } from '../utils/user-room';
import { JwtService } from '@nestjs/jwt';
import { UsersService } from '../../users/users.service';
import { FcmTokensService } from '../../fcm-tokens/fcm-tokens.service';
import { WebPushSubscriptionsService } from '../../web-push-subscriptions/web-push-subscriptions.service';
import {
  ResetRosterResult,
  ResetRosterService,
} from '../../key-bundles/reset-roster.service';

const PRE_KEY_LOW_THRESHOLD = 10;
const PRE_KEY_FETCH_MIN_INTERVAL_MS = 750;
const PRE_KEY_FETCH_MAP_TTL_MS = 10 * 60 * 1000;
const PRE_KEY_FETCH_MAP_MAX_ENTRIES = 10000;
const SESSION_REBUILD_REQUEST_TTL_MS = 24 * 60 * 60 * 1000;
const SESSION_REBUILD_MAP_MAX_RECIPIENTS = 10000;

/**
 * Lifetime of a registration-lock nonce (§6.1). Short: it only has to survive
 * one client round-trip between asking for it and uploading the signed bundle.
 */
const REGISTRATION_LOCK_NONCE_TTL_MS = 5 * 60 * 1000;
const REGISTRATION_LOCK_NONCE_BYTES = 32;

/** Nonce issued to one authenticated socket session. */
interface RegistrationLockNonce {
  nonce: string;
  expiresAt: number;
}

/** The per-socket bag the gateway populates once a session is authenticated. */
interface AuthenticatedSocketData {
  /**
   * `deviceId` comes from the JWT (Phase 1, spec §4). Absent on a token issued
   * before the claim existed — device 1 by definition (§8).
   */
  user?: { id: number; deviceId?: number };
  registrationLockNonce?: RegistrationLockNonce;
}

/**
 * socket.io declares `Socket.data` as `any`, so every read off it is untyped.
 * One documented narrowing keeps that assertion in a single place instead of
 * repeating it at each access site.
 */
function socketData(client: Socket): AuthenticatedSocketData {
  return client.data as AuthenticatedSocketData;
}

/** Message of an unknown thrown value, without trusting it to be an Error. */
function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

@Injectable()
export class ChatKeyExchangeService {
  private readonly logger = new Logger(ChatKeyExchangeService.name);
  private readonly lastPreKeyFetchByPair = new Map<string, number>();
  private readonly pendingSessionRebuildsByRecipient = new Map<
    number,
    Map<number, number>
  >();

  constructor(
    private readonly keyBundlesService: KeyBundlesService,
    private readonly conversationsService: ConversationsService,
    private readonly pushNotificationsService: PushNotificationsService,
    private readonly identityResetService: IdentityResetService,
    private readonly devicesService: DevicesService,
    private readonly resetRosterService: ResetRosterService,
    private readonly usersService: UsersService,
    private readonly jwtService: JwtService,
    private readonly fcmTokensService: FcmTokensService,
    private readonly webPushSubscriptionsService: WebPushSubscriptionsService,
    private readonly deviceListService: DeviceListService,
  ) {}

  /**
   * Drops every push endpoint of an account after a §6.2 roster teardown.
   *
   * Every row belonged to a device the teardown just revoked, and a
   * NULL-`deviceId` row cannot be attributed to any of them (amendment
   * (xxiv)). Fire-and-forget: a failure must not fail the recovery, but it is
   * loud, because the alternative is pushing an account's notifications to
   * devices it no longer trusts.
   */
  private async dropAccountPushRows(userId: number): Promise<void> {
    try {
      await this.fcmTokensService.removeByUserId(userId);
      await this.webPushSubscriptionsService.removeByUserId(userId);
    } catch (error) {
      this.logger.error(
        `[reset-roster] push teardown FAILED: ${errorMessage(error)}`,
      );
    }
  }

  /**
   * Tells every device the §6.2 teardown just revoked, then drops its sockets
   * (amendment (xli)).
   *
   * The database half of the teardown is atomic; this is the half that makes
   * it take effect on a connection that is ALREADY open. Both §5.5 session
   * gates run at connect time only, and `getServedMessageIds` is the sole
   * per-event revocation re-check, so without this a superseded device that
   * never disconnects keeps the entire remaining gateway surface — reading
   * and sending on the account whose takeover this ceremony just undid.
   *
   * Deliberately mirrors T6 `revokeDevice`: announce on the device room FIRST
   * so a live client can log itself out cleanly (amendment (xxvi)), then
   * disconnect. Synchronous and best-effort — it runs AFTER the teardown has
   * committed, so a throw here must not surface as a failed recovery. An
   * offline device receives nothing and meets the connect gate instead, which
   * is the durable enforcement.
   *
   * THE RECOVERING CALLER IS EXCLUDED FROM BOTH HALVES, and the announcement
   * matters more than the disconnect. Its socket is still joined to the room
   * of its PRE-reset device id, which this teardown just revoked, so a
   * room-wide emit reaches it — and the client's `deviceRevoked` handler does
   * NOT filter on device id (`connection_provider.dart:_onOwnDeviceRevoked`
   * reads the id only for its diagnostic line, then logs out unconditionally).
   * It would therefore wipe the very session it had just adopted from the ack,
   * moments earlier. Sparing it from `disconnect()` alone does not help: the
   * event alone is enough to destroy the recovery.
   *
   * Excluded server-side rather than filtered client-side on purpose. A client
   * that ignored a `deviceRevoked` whose id did not match its own would also
   * ignore a REAL revocation whenever its own device id is unconfirmed —
   * trading a recoverable annoyance for a silent security failure.
   */
  private evictSupersededDevices(
    userId: number,
    revokedDeviceIds: number[],
    server: Server,
    exceptSocketId: string,
    reason?: 'restored',
  ): void {
    let kicked = 0;
    for (const revokedDeviceId of revokedDeviceIds) {
      try {
        server
          .to(deviceRoom(userId, revokedDeviceId))
          .except(exceptSocketId)
          .emit('deviceRevoked', {
            userId,
            deviceId: revokedDeviceId,
            // (lxxviii): a restore is not a takeover — the revoked device's
            // client words the logout accordingly. Absent on every other
            // teardown, so the historic payload is byte-identical.
            ...(reason ? { reason } : {}),
          });
        const sockets = socketsForDevice(server, userId, revokedDeviceId);
        for (const socket of sockets) {
          // Never the recovering caller — see the call site.
          if (socket.id === exceptSocketId) continue;
          socket.disconnect();
          kicked += 1;
        }
      } catch (error) {
        this.logger.error(
          `[reset-roster] eviction FAILED deviceId=${revokedDeviceId}: ${errorMessage(error)}`,
        );
      }
    }
    this.logger.log(
      `[reset-roster] evicted devices=[${revokedDeviceIds.join(',')}] kickedSockets=${kicked}`,
    );
  }

  /**
   * Issues a single-use nonce for a registration-lock proof (§6.1).
   *
   * Held on the socket itself, so it dies with the session and cannot be
   * replayed from another connection. CSPRNG, never a counter or a timestamp:
   * a predictable nonce would let a proof be prepared in advance.
   */
  handleGetRegistrationLockNonce(client: Socket): void {
    const userId = socketData(client).user?.id;
    if (!userId) return;
    const nonce = randomBytes(REGISTRATION_LOCK_NONCE_BYTES).toString('base64');
    const issued: RegistrationLockNonce = {
      nonce,
      expiresAt: Date.now() + REGISTRATION_LOCK_NONCE_TTL_MS,
    };
    socketData(client).registrationLockNonce = issued;
    client.emit('registrationLockNonce', { nonce });
  }

  /**
   * Takes this session's nonce out of play and returns it only if the echo
   * matches and it has not expired. Single-use: the stored value is cleared on
   * every attempt, valid or not, so one issued nonce authorizes at most one
   * upload attempt.
   */
  private consumeRegistrationLockNonce(
    client: Socket,
    echoed: string | undefined,
  ): string | null {
    const data = socketData(client);
    const issued = data.registrationLockNonce;
    data.registrationLockNonce = undefined;
    if (!issued || !echoed) return null;
    if (issued.expiresAt <= Date.now()) return null;
    if (issued.nonce !== echoed) return null;
    return issued.nonce;
  }

  async handleUploadKeyBundle(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    try {
      const dto = validateDto(UploadKeyBundleDto, data);
      // Consumed on every attempt, so one issued nonce buys one try.
      const nonce = this.consumeRegistrationLockNonce(client, dto.nonce);
      // The device comes from the SESSION, never from the payload: a
      // bundle belongs to the device whose authenticated socket uploaded
      // it (spec §5.1). A client-named device would let one session
      // scatter key material across namespaces peers later fetch.
      const deviceId = socketData(client).user?.deviceId ?? DEFAULT_DEVICE_ID;
      // Never-activated-id rejection (spec §5.1 / §12 amendment (b)): key
      // material may land only on a device the provisioning commit actually
      // activated. Device 1 predates the devices table and stays exempt.
      if (
        deviceId !== DEFAULT_DEVICE_ID &&
        !(await this.devicesService.isActive(userId, deviceId))
      ) {
        this.logger.warn(
          `uploadKeyBundle refused: never-activated deviceId=${deviceId}`,
        );
        client.emit('keyBundleUploaded', {
          success: false,
          error: 'device_not_active',
        });
        return;
      }
      const result = await this.keyBundlesService.upsertKeyBundle(
        userId,
        {
          registrationId: dto.registrationId,
          identityPublicKey: dto.identityPublicKey,
          signedPreKeyId: dto.signedPreKeyId,
          signedPreKeyPublic: dto.signedPreKeyPublic,
          signedPreKeySignature: dto.signedPreKeySignature,
        },
        nonce != null &&
          (dto.identitySignature != null || dto.restoreSignature != null)
          ? {
              signature: dto.identitySignature,
              nonce,
              restoreSignature: dto.restoreSignature,
            }
          : undefined,
        deviceId,
      );
      // A reset that just COMPLETED is the moment the §6.2 roster teardown
      // runs (spec §12 amendments (f)/(xxviii)): the recovering device is
      // moved onto a freshly allocated id, every pre-reset device is revoked,
      // and its session is re-issued because all the old ones were dropped. A
      // SIGNED rotation deliberately does not do this — that account still
      // holds its other devices.
      //
      // A RESTORE (amendment (lxxviii) clause 2) runs the SAME teardown — the
      // restoring install is a fresh wipe, so every other device is presumed
      // lost — but first drops the caller's pre-wipe one-time pre-keys: their
      // private halves died with the wipe, and the teardown below MOVES this
      // device's rows onto the fresh id, which would otherwise carry them
      // along as unanswerable X3DH offers.
      const restored = result.authorizedBy === 'restore';
      let roster: ResetRosterResult | null = null;
      let reissuedAccessToken: string | null = null;
      if (result.authorizedBy === 'reset' || restored) {
        if (restored) {
          await this.keyBundlesService.purgeDeviceOneTimePreKeys(
            userId,
            deviceId,
          );
        }
        roster = await this.resetRosterService.applyAfterReset(
          userId,
          deviceId,
        );
        // The claim set must match login's exactly, so every consumer of it
        // behaves identically (same rule as the provisioning rebind).
        const user = await this.usersService.findById(userId);
        if (user) {
          reissuedAccessToken = this.jwtService.sign({
            sub: userId,
            username: user.username,
            tag: user.tag,
            deviceId: roster.deviceId,
          });
        }
        if (restored) {
          this.logger.log(
            `[identity-restore] from=${deviceId} to=${roster.deviceId}`,
          );
        }
      }
      // `identityChanged` tells THIS device that its own upload is what
      // replaced the stored identity — and therefore what wrote the audit row
      // it will read back at the next connect. Without it the device that just
      // recovered through the reset ceremony warns its own user that "another
      // sign-in replaced your keys", which trains people to dismiss the one
      // alarm that detects a real takeover. Additive field: an older client
      // ignores it.
      //
      // After a reset the answer additionally carries the device id the
      // material now lives under plus a fresh session for it. The client MUST
      // adopt these before uploading one-time pre-keys, or those keys land in
      // the namespace the teardown just abandoned.
      //
      // `nextListVersion` is amendment (xlv) clause 1. The recovering device
      // has to RE-ENROLL — the teardown revoked every device the old list
      // named and allocated an id it does not name, and the DAK that signed it
      // died with the lost devices, so `updateDeviceList` is not open to this
      // client. A replacement enrollment must ADVANCE past the surviving
      // `listVersion` ((xxix)), which only the server can read: the client
      // cannot verify that row (its enrollment signature is orphaned by the
      // identity change) and must not be made to guess. Dictating the number
      // grants the server no authority it lacks — the client still signs the
      // list, and a server naming a stale version merely gets its own
      // enrollment refused, which it could achieve by refusing outright.
      // A recovery whose re-enrollment never landed — the socket dropped, the
      // ack timed out, the app was killed — would otherwise stay un-addressable
      // forever: the roster block above runs ONLY on the upload that consumes
      // the ceremony, so nothing re-fires on a later launch, and the account is
      // left fail-closed by clause 2 with no way back except another 6 h
      // ceremony. The server already knows this state exactly (it is the same
      // predicate clause 2 refuses on), so it re-offers the terms on any
      // authenticated upload and the client simply retries.
      const owedVersion = roster
        ? null
        : await this.deviceListService.pendingReplacementVersion(userId);
      client.emit('keyBundleUploaded', {
        success: true,
        identityChanged: result.identityChanged,
        ...(roster && reissuedAccessToken
          ? {
              deviceId: roster.deviceId,
              access_token: reissuedAccessToken,
              refresh_token: roster.refreshToken,
              // (lxxviii): the identity did NOT change, E still verifies the
              // surviving enrollment — the client re-signs the list with its
              // restored DAK at this version (`updateDeviceList`, not a
              // re-enrolment).
              ...(restored ? { restored: true } : {}),
              nextListVersion: roster.nextListVersion,
            }
          : {}),
        // No session is reissued here: this upload authenticated normally, so
        // the caller already holds the right one. Carrying no tokens is also
        // what keeps the client's rebind path from re-running.
        ...(owedVersion !== null
          ? { deviceId, nextListVersion: owedVersion }
          : {}),
      });
      if (result.identityChanged) {
        // Fire-and-forget: the alarm must never fail or delay the upload ack.
        void this.notifyIdentityChanged(client, userId, server);
      }
      if (roster) {
        // (lxxviii): a content-free "your identity was restored elsewhere"
        // push to every endpoint — BEFORE the rows are dropped below, or there
        // is nothing left to deliver it to. Awaited for exactly that ordering;
        // failure is logged, never fatal (the recovery already committed).
        if (restored) {
          await this.pushNotificationsService
            .notifyIdentityReset(userId, 'identity_restored')
            .catch(() => this.logger.warn('identity-restored push failed'));
        }
        // Push endpoints belong to devices this teardown just revoked, and a
        // NULL-deviceId row cannot be attributed (amendment (xxiv)). The
        // recovering device re-registers on its next start.
        void this.dropAccountPushRows(userId);
      }
      if (roster) {
        // Evict what the teardown revoked (amendment (xli)). The transaction
        // stamps `revokedAt` and drops every refresh token, but BOTH §5.5
        // session gates are connect-time only and `getServedMessageIds` is the
        // sole per-event revocation re-check — so a superseded device holding
        // ONE continuous socket would keep the whole remaining gateway surface
        // after the very ceremony meant to evict it.
        //
        // STRICTLY AFTER THE ACK, AND NEVER THIS SOCKET. The recovering client
        // is still authenticated as its PRE-reset device id, so it sits in a
        // room this teardown just revoked: evicting first would disconnect the
        // caller before the ack carrying its new deviceId and session could be
        // written, and socket.io marks a socket disconnected synchronously, so
        // that emit would silently no-op. Its old refresh token is already
        // revoked and its old JWT already gated, so the recovery would strand
        // on every single run — and it would quietly undo the whole point of
        // the reissued-session contract this ack exists to deliver.
        //
        // Sparing the caller costs nothing: the client adopts the session and
        // reconnects immediately, which disposes this socket anyway, and a
        // client that ignores the ack meets the connect gate on its next
        // reconnect — the same durable enforcement an offline device meets.
        this.evictSupersededDevices(
          userId,
          roster.revokedDeviceIds,
          server,
          client.id,
          restored ? 'restored' : undefined,
        );
      }
    } catch (error) {
      if (error instanceof IdentityLockedError) {
        // Not a failure to report as an error: the lock did its job. The client
        // reads this as "go through the reset ceremony", never as "retry".
        this.logger.warn(`uploadKeyBundle refused by registration lock`);
        client.emit('keyBundleUploaded', {
          success: false,
          error: 'identity_locked',
        });
        return;
      }
      if (error instanceof DeviceMaterialConflictError) {
        // (lxiv) clause 1: the guard did its job — a foreign install tried to
        // write into a namespace whose material it does not hold (the
        // revoked-device-signs-back-in shape). Never a retry; the device's
        // route forward is the §5.1 link ceremony.
        this.logger.warn(`uploadKeyBundle refused by device material guard`);
        client.emit('keyBundleUploaded', {
          success: false,
          error: 'device_material_conflict',
        });
        return;
      }
      if (error instanceof IdentityRestoreRefusedError) {
        // (lxxviii) clause 2: the restore proof did not verify under the
        // stored identity key. Nothing was written; the phrase (and the blob
        // it unsealed) is not this account's. Never a retry.
        this.logger.warn(`uploadKeyBundle refused invalid restore proof`);
        client.emit('keyBundleUploaded', {
          success: false,
          error: 'restore_refused',
        });
        return;
      }
      this.logger.error(`uploadKeyBundle failed: ${error.message}`);
      client.emit('error', {
        message: error?.message || 'Failed to upload key bundle',
      });
    }
  }

  /**
   * Phase 0a takeover alarm (multi-device spec §6.0). After a key-bundle
   * upload REPLACED the stored identity:
   * 1. `ownIdentityReplaced` to the account's OTHER live sessions
   *    (`client.to(room)` excludes the uploading socket — it caused the event).
   * 2. Content-free push to every registered endpoint (offline sessions).
   * 3. `peerIdentityChanged` to every conversation peer's room, feeding the
   *    in-conversation timeline row (owner-ratified 2026-08-17).
   * Wording rule: clients render this as "new device/browser sign-in" — the
   * same branch fires on every legitimate reinstall/migration, not just
   * takeover. Same-identity re-uploads (the every-connect path) never reach
   * here: upsertKeyBundle only reports identityChanged on a differing key.
   */
  private async notifyIdentityChanged(
    client: Socket,
    userId: number,
    server: Server,
  ): Promise<void> {
    const occurredAt = new Date().toISOString();
    try {
      client.to(userRoom(userId)).emit('ownIdentityReplaced', { occurredAt });
      const pushPromise = this.pushNotificationsService
        .notifyIdentityChanged(userId)
        .catch(() => this.logger.warn('identity-changed push failed'));
      const conversations = await this.conversationsService.findByUser(userId);
      const peerIds = new Set<number>();
      for (const conv of conversations) {
        const peerId =
          conv.userOne?.id === userId ? conv.userTwo?.id : conv.userOne?.id;
        if (peerId != null && peerId !== userId) peerIds.add(peerId);
      }
      for (const peerId of peerIds) {
        server
          .to(userRoom(peerId))
          .emit('peerIdentityChanged', { userId, occurredAt });
      }
      await pushPromise;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`identity-changed notify failed: ${message}`);
    }
  }

  async handleUploadOneTimePreKeys(client: Socket, data: any): Promise<void> {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    try {
      // ORDER IS CLIENT-SIDE, SETTLED for the identity-upload path (was an
      // open decision on 2026-08-19): when the client publishes an identity it
      // STASHES the one-time pre-keys and releases them only on the
      // `keyBundleUploaded { success:true }` ack (`encryption_provider.dart`,
      // `_pendingOneTimePreKeyUpload`; a refusal drops the stash and records
      // `OTP_UPLOAD_DROPPED`; `test_e2e/stale_otp_epoch_test.dart` mirrors the
      // order). So a signature-authorized rotation no longer has its keys
      // arrive before its bundle. Two other emitters remain and are NOT
      // races: `preKeysLow` replenishment (`encryption_provider.dart`
      // `_replenishOneTimePreKeys`) sends under the CURRENT published identity
      // with no bundle in flight, and the un-enrolled remint carve-out in
      // `KeyBundlesService.uploadOneTimePreKeys` still tolerates keys-first
      // for that population. The server-side rescues tried and rejected before
      // the client fix (awaiting this socket's in-flight bundle upload after
      // one macrotask; a timed poll for it) stay rejected: the refusal below is
      // the identity pin doing its job, not a race to paper over.
      const dto = validateDto(UploadOneTimePreKeysDto, data);
      // Session-bound, like the bundle above.
      const deviceId = socketData(client).user?.deviceId ?? DEFAULT_DEVICE_ID;
      // Never-activated-id rejection (spec §5.1 / §12 amendment (b)), same
      // gate as the bundle; this handler's refusal shape is the error event.
      if (
        deviceId !== DEFAULT_DEVICE_ID &&
        !(await this.devicesService.isActive(userId, deviceId))
      ) {
        this.logger.warn(
          `uploadOneTimePreKeys refused: never-activated deviceId=${deviceId}`,
        );
        client.emit('error', { message: 'device_not_active' });
        return;
      }
      await this.keyBundlesService.uploadOneTimePreKeys(
        userId,
        dto.keys,
        dto.identityPublicKey,
        deviceId,
        dto.registrationId,
      );
      client.emit('oneTimePreKeysUploaded', { count: dto.keys.length });
    } catch (error) {
      if (error instanceof IdentityLockedError) {
        // The lock did its job, so this is not a server fault: the caller's
        // identity is not the one this account publishes. Same vocabulary as
        // the bundle refusal — the route forward is the reset ceremony.
        this.logger.warn(`uploadOneTimePreKeys refused by registration lock`);
      } else if (error instanceof DeviceMaterialConflictError) {
        // (lxiv) clause 1, OTP half: a foreign install may not deposit OTPs
        // into a pool it does not own. The emitted message carries the code.
        this.logger.warn(
          `uploadOneTimePreKeys refused by device material guard`,
        );
      } else {
        this.logger.error(`uploadOneTimePreKeys failed: ${error.message}`);
      }
      client.emit('error', {
        message: error?.message || 'Failed to upload one-time pre-keys',
      });
    }
  }

  /**
   * Answers whether the authenticated caller already has a public bundle, plus
   * the account-protection state a reconnecting session needs to render:
   * an in-flight reset ceremony, and the last identity replacement.
   *
   * This deliberately does not fetch a bundle: fetchPreKeyBundle consumes a
   * one-time pre-key.
   */
  async handleCheckOwnKeyBundle(client: Socket): Promise<void> {
    const userId: number = client.data.user?.id;
    if (!userId) return;

    try {
      // Per device: this answer gates key generation on the client, and a
      // device that never published its own bundle must not be told one exists
      // just because a sibling device has one.
      const deviceId = socketData(client).user?.deviceId ?? DEFAULT_DEVICE_ID;
      const exists = await this.keyBundlesService.hasKeyBundle(
        userId,
        deviceId,
      );
      // Additive fields: an older client ignores them, and a newer client
      // treats a missing payload as UNKNOWN rather than as "nothing pending".
      const [
        reset,
        identityChange,
        linkingEnabled,
        hasIdentityBackup,
        hasRecoveryPhrase,
      ] = await Promise.all([
        this.identityResetService.getStatusForUser(userId),
        this.keyBundlesService.latestIdentityChange(userId),
        // (lxxiii) clause 2 — the client learns the lock state with the
        // bundle answer. Additive; an absent field reads as `true`
        // client-side (fail-closed to the pre-(lxxiii) gate, never to a
        // refused mint).
        this.keyBundlesService.isEnrolled(userId),
        // (lxxviii) clause 1 — additive: drives the "create your backup"
        // nudge on an enrolled primary without one.
        this.identityResetService.hasIdentityBackup(userId),
        // (lxxxiii) clause 4 — additive: a phrase exists, blob or not. The
        // Chats-list nudge and the post-registration offer key off THIS, so a
        // pre-(lxxviii) verifier-only phrase is not nagged into replacement.
        this.identityResetService.hasRecoveryPhrase(userId),
      ]);
      client.emit('ownKeyBundleStatus', {
        exists,
        linkingEnabled,
        hasIdentityBackup,
        hasRecoveryPhrase,
        identityReset: reset
          ? {
              status: reset.status,
              deadlineAt: reset.deadlineAt.toISOString(),
              // Same flag the live broadcast carries, so a session that
              // reconnects INTO a recovery-key ceremony describes the 1 h
              // wait as 1 h rather than as the default 6 h.
              shortened: reset.shortened,
            }
          : null,
        identityReplacedAt: identityChange
          ? identityChange.at.toISOString()
          : null,
        // (lxxx) clause 5: additive. The key the change ENDED at, so a client
        // can tell "someone replaced my identity" from "my own identity was
        // (re)published" — the latter is what a restored install sees in its
        // own history with no dismissal watermark left to suppress it.
        identityReplacedTo: identityChange ? identityChange.to : null,
      });
    } catch (error) {
      // Silence is fail-closed on the client: it treats no status as UNKNOWN.
      this.logger.error(`checkOwnKeyBundle failed: ${error.message}`);
    }
  }

  /**
   * Starts an account-identity reset ceremony (§6.2).
   *
   * Reachable with credentials alone, by design: this is the path for someone
   * who genuinely lost their device keys. The protection is not secrecy but
   * TIME plus NOISE — every session and every push endpoint learns immediately,
   * and any one of them can cancel with a single tap for the whole delay.
   */
  async handleResetIdentityRequest(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const userId = socketData(client).user?.id;
    if (!userId) return;

    try {
      const dto = validateDto(ResetIdentityRequestDto, data);
      const result = await this.identityResetService.requestReset(
        userId,
        dto.recoveryPhrase,
      );
      client.emit('identityResetStatus', {
        status: result.status,
        deadlineAt: result.deadlineAt
          ? result.deadlineAt.toISOString()
          : undefined,
        shortened: result.shortened,
        // Only the requester is told WHY the shortcut was denied. The room-wide
        // `identityResetPending` alarm below deliberately carries no phrase
        // verdict: the other sessions need the deadline and the cancel button,
        // not a fact about the phrase.
        phraseTooNew: result.phraseTooNew,
      });
      // Only a NEW ceremony rings the bells. Re-reporting an existing one to a
      // reconnecting client must not re-notify every device.
      if (result.status === 'pending' && result.deadlineAt) {
        void this.notifyIdentityResetPending(
          userId,
          result.deadlineAt,
          result.shortened,
          server,
        );
      }
    } catch (error) {
      this.logger.error(`resetIdentityRequest failed: ${errorMessage(error)}`);
      client.emit('error', {
        message: errorMessage(error) || 'Failed to start identity reset',
      });
    }
  }

  /**
   * Cancels the pending ceremony (§6.2). No key required — a session that can
   * see the notification must be able to stop it, which is the entire point of
   * the delay.
   */
  async handleResetIdentityCancel(
    client: Socket,
    server: Server,
  ): Promise<void> {
    const userId = socketData(client).user?.id;
    if (!userId) return;

    try {
      const cancelled = await this.identityResetService.cancelReset(userId);
      client.emit('identityResetCancelResult', { cancelled });
      if (cancelled) {
        const occurredAt = new Date().toISOString();
        // Whole room INCLUDING this socket: every surface clears together.
        server
          .to(userRoom(userId))
          .emit('identityResetCancelled', { occurredAt });
        void this.pushNotificationsService
          .notifyIdentityReset(userId, 'identity_reset_cancelled')
          .catch(() => this.logger.warn('identity-reset cancel push failed'));
      }
    } catch (error) {
      this.logger.error(`resetIdentityCancel failed: ${errorMessage(error)}`);
      client.emit('error', {
        message: errorMessage(error) || 'Failed to cancel identity reset',
      });
    }
  }

  /**
   * Announces a newly started ceremony to every session and every registered
   * push endpoint (§6.2). Push is the only channel that reaches a device whose
   * app is closed, which is what makes the delay meaningful.
   */
  private async notifyIdentityResetPending(
    userId: number,
    deadlineAt: Date,
    shortened: boolean,
    server: Server,
  ): Promise<void> {
    const occurredAt = new Date().toISOString();
    try {
      server.to(userRoom(userId)).emit('identityResetPending', {
        deadlineAt: deadlineAt.toISOString(),
        shortened,
        occurredAt,
      });
      await this.pushNotificationsService.notifyIdentityReset(
        userId,
        'identity_reset_pending',
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.error(`identity-reset notify failed: ${message}`);
    }
  }

  /**
   * Enrolls or replaces the account's recovery phrase (§6.2.1). The phrase is
   * generated and shown on the client; the server keeps only a memory-hard
   * verifier and never returns it.
   *
   * Enrolment is LOUD (amendment (xlii)). I4 says the recovery key shortens
   * the reset delay but is never silent — yet the step that DETERMINES that
   * delay used to happen with no announcement at all, so a thief holding a
   * session could arm their own phrase unobserved. The ceremony itself was
   * always announced; this closes the gap one step earlier, at the moment the
   * account's recovery secret changes.
   *
   * Fire-and-forget after the ack, exactly like the reset alarm: the alarm
   * must never fail or delay the operation it reports on.
   */
  async handleSetRecoveryKey(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const userId = socketData(client).user?.id;
    if (!userId) return;

    try {
      const dto = validateDto(SetRecoveryKeyDto, data);
      const replaced = await this.identityResetService.setRecoveryKey(
        userId,
        dto.phrase,
        // (lxxviii) clause 1: verifier and sealed blob land atomically.
        dto.backup,
      );
      client.emit('recoveryKeySet', { success: true });
      void this.notifyRecoveryKeyEnrolled(userId, replaced, server);
    } catch (error) {
      this.logger.error(`setRecoveryKey failed: ${errorMessage(error)}`);
      client.emit('recoveryKeySet', { success: false });
    }
  }

  /**
   * Serves the caller's phrase-sealed identity backup (amendment (lxxviii)
   * clause 1). Own account only, and harmless even so: the blob is AES-256-GCM
   * under a key derived from the phrase, which the server never sees. The
   * gateway throttles this like `setRecoveryKey` (10/15 min) — the blob is
   * useless without the phrase, but there is no reason to serve it in a loop.
   */
  async handleGetIdentityBackup(client: Socket): Promise<void> {
    const userId = socketData(client).user?.id;
    if (!userId) return;

    try {
      const backup = await this.identityResetService.getIdentityBackup(userId);
      client.emit('identityBackup', {
        exists: backup != null,
        ...(backup
          ? {
              blob: backup.blob,
              salt: backup.salt,
              iterations: backup.iterations,
              version: backup.version,
            }
          : {}),
      });
    } catch (error) {
      this.logger.error(`getIdentityBackup failed: ${errorMessage(error)}`);
      // Same fail-closed convention as the bundle status: the client treats a
      // missing answer as UNKNOWN, never as "no backup exists".
      client.emit('identityBackup', { exists: false, error: 'backup_failed' });
    }
  }

  /**
   * Tells every session and every push endpoint that the account's recovery
   * phrase was set or replaced (amendment (xlii)).
   *
   * Goes to the whole user room INCLUDING the device that did it: that device
   * already knows, and suppressing it would mean the fan-out has to reason
   * about which socket originated the change — the kind of exception that
   * later turns into a hole. Push reaches the devices whose app is closed,
   * which is the only channel that catches a thief acting while the owner's
   * phone is in a pocket.
   */
  private async notifyRecoveryKeyEnrolled(
    userId: number,
    replaced: boolean,
    server: Server,
  ): Promise<void> {
    try {
      server.to(userRoom(userId)).emit('recoveryKeyEnrolled', {
        replaced,
        occurredAt: new Date().toISOString(),
      });
      await this.pushNotificationsService.notifyIdentityReset(
        userId,
        'recovery_key_enrolled',
      );
    } catch (error) {
      this.logger.error(
        `recovery-key enrolment notify failed: ${errorMessage(error)}`,
      );
    }
  }

  async handleFetchPreKeyBundle(
    client: Socket,
    data: any,
    server: Server,
  ): Promise<void> {
    const requesterId: number = client.data.user?.id;
    if (!requesterId) return;

    try {
      const dto = validateDto(FetchPreKeyBundleDto, data);
      const targetDeviceId = dto.deviceId ?? DEFAULT_DEVICE_ID;
      if (
        this.isPreKeyFetchRateLimited(requesterId, dto.userId, targetDeviceId)
      ) {
        client.emit('error', {
          message:
            'Pre-key bundle fetch rate limit exceeded. Please retry shortly.',
        });
        return;
      }
      const bundle = await this.claimBundle(dto.userId, targetDeviceId, server);
      if (bundle) {
        this.clearPendingSessionRebuildRequest(requesterId, dto.userId);
      }

      client.emit('preKeyBundleResponse', {
        userId: dto.userId,
        // Echoed so a fan-out client can tell two in-flight per-device fetches
        // for one peer apart (spec §5.2).
        deviceId: targetDeviceId,
        bundle,
      });
    } catch (error) {
      this.logger.error(`fetchPreKeyBundle failed: ${error.message}`);
      client.emit('error', {
        message: error?.message || 'Failed to fetch pre-key bundle',
      });
    }
  }

  /**
   * Claims one bundle of [userId]'s device [deviceId] — spending its next
   * one-time pre-key — and tells THAT device to replenish when its pool runs
   * low. The one door every bundle leaves through (`fetchPreKeyBundle`, and
   * `searchUsers` since metadata-privacy PR3.2), so no path can drain a pool
   * without the replenishment signal.
   *
   * `preKeysLow` is counted per device since Phase 1 and routed to that
   * device's room (spec §5.2, decision-record T4 rider): telling every device
   * to mint keys for one device's empty pool is noise the others cannot act
   * on.
   */
  async claimBundle(
    userId: number,
    deviceId: number,
    server: Server,
  ): Promise<PreKeyBundleResponse | null> {
    const bundle = await this.keyBundlesService.fetchPreKeyBundle(
      userId,
      deviceId,
    );
    if (bundle) {
      const remaining = await this.keyBundlesService.countUnusedPreKeys(
        userId,
        deviceId,
      );
      if (remaining < PRE_KEY_LOW_THRESHOLD) {
        server
          .to(deviceRoom(userId, deviceId))
          .emit('preKeysLow', { remaining });
      }
    }
    return bundle;
  }

  /**
   * Paces bundle fetches per (requester, target USER, target DEVICE).
   *
   * The device dimension is load-bearing since Phase 1 made bundles and OTP
   * pools per-device: establishing sessions to a two-device peer needs two
   * fetches back to back, and a per-user key would REFUSE the second one
   * outright — making lawful multi-device fan-out impossible (spec §5.2).
   */
  private isPreKeyFetchRateLimited(
    requesterId: number,
    recipientId: number,
    recipientDeviceId: number,
  ): boolean {
    const now = Date.now();
    this.cleanupPreKeyFetchTracker(now);
    const key = `${requesterId}:${recipientId}:${recipientDeviceId}`; // log-guard: key
    const lastSeen = this.lastPreKeyFetchByPair.get(key);
    if (
      lastSeen !== undefined &&
      now - lastSeen < PRE_KEY_FETCH_MIN_INTERVAL_MS
    ) {
      return true;
    }
    this.lastPreKeyFetchByPair.set(key, now);
    return false;
  }

  private cleanupPreKeyFetchTracker(now: number): void {
    for (const [key, ts] of this.lastPreKeyFetchByPair.entries()) {
      if (now - ts > PRE_KEY_FETCH_MAP_TTL_MS) {
        this.lastPreKeyFetchByPair.delete(key);
      }
    }
    if (this.lastPreKeyFetchByPair.size <= PRE_KEY_FETCH_MAP_MAX_ENTRIES) {
      return;
    }

    const ordered = [...this.lastPreKeyFetchByPair.entries()].sort(
      (a, b) => a[1] - b[1],
    );
    const toDelete =
      this.lastPreKeyFetchByPair.size - PRE_KEY_FETCH_MAP_MAX_ENTRIES;
    for (let i = 0; i < toDelete; i++) {
      this.lastPreKeyFetchByPair.delete(ordered[i][0]);
    }
  }

  deliverPendingSessionRebuilds(client: Socket): void {
    const recipientId: number = client.data.user?.id;
    if (!recipientId) return;
    const pending = this.pendingSessionRebuildsByRecipient.get(recipientId);
    if (!pending) return;

    const now = Date.now();
    for (const [fromUserId, requestedAt] of pending.entries()) {
      if (now - requestedAt > SESSION_REBUILD_REQUEST_TTL_MS) {
        pending.delete(fromUserId);
        continue;
      }
      client.emit('sessionRebuildNeeded', { fromUserId });
    }
    if (pending.size === 0) {
      this.pendingSessionRebuildsByRecipient.delete(recipientId);
    }
  }

  private rememberSessionRebuildRequest(
    recipientId: number,
    requesterId: number,
  ): void {
    this.cleanupPendingSessionRebuilds(Date.now());
    let pending = this.pendingSessionRebuildsByRecipient.get(recipientId);
    if (!pending) {
      pending = new Map<number, number>();
      this.pendingSessionRebuildsByRecipient.set(recipientId, pending);
    }
    pending.set(requesterId, Date.now());
  }

  private clearPendingSessionRebuildRequest(
    recipientId: number,
    requesterId: number,
  ): void {
    const pending = this.pendingSessionRebuildsByRecipient.get(recipientId);
    if (!pending) return;
    pending.delete(requesterId);
    if (pending.size === 0) {
      this.pendingSessionRebuildsByRecipient.delete(recipientId);
    }
  }

  private cleanupPendingSessionRebuilds(now: number): void {
    for (const [recipientId, pending] of this
      .pendingSessionRebuildsByRecipient) {
      for (const [requesterId, requestedAt] of pending) {
        if (now - requestedAt > SESSION_REBUILD_REQUEST_TTL_MS) {
          pending.delete(requesterId);
        }
      }
      if (pending.size === 0) {
        this.pendingSessionRebuildsByRecipient.delete(recipientId);
      }
    }
    // Bound memory the same way the prekey-fetch tracker is bounded: a client
    // can mint pending entries for arbitrary recipientIds (DTO only checks
    // positive), so evict the least-recently-requested recipients past the cap.
    if (
      this.pendingSessionRebuildsByRecipient.size <=
      SESSION_REBUILD_MAP_MAX_RECIPIENTS
    ) {
      return;
    }
    const newest = (pending: Map<number, number>): number =>
      Math.max(...pending.values());
    const ordered = [...this.pendingSessionRebuildsByRecipient.entries()].sort(
      (a, b) => newest(a[1]) - newest(b[1]),
    );
    const toDelete =
      this.pendingSessionRebuildsByRecipient.size -
      SESSION_REBUILD_MAP_MAX_RECIPIENTS;
    for (let i = 0; i < toDelete; i++) {
      this.pendingSessionRebuildsByRecipient.delete(ordered[i][0]);
    }
  }

  /// Relay a session-rebuild request to every live socket for the target user.
  /// Called when receiver cannot decrypt an inbound message — asks sender to
  /// build over their stale session so their next send uses a fresh PreKeySignalMessage.
  async handleRequestSessionRebuild(
    client: Socket,
    data: any,
    server: Server,
  ): Promise<void> {
    const requesterId: number = client.data.user?.id;
    if (!requesterId) return;

    try {
      const dto = validateDto(RequestSessionRebuildDto, data);
      this.rememberSessionRebuildRequest(dto.recipientId, requesterId);
      server.to(userRoom(dto.recipientId)).emit('sessionRebuildNeeded', {
        fromUserId: requesterId,
      });
    } catch (error) {
      this.logger.error(`requestSessionRebuild failed: ${error.message}`);
      client.emit('error', {
        message: error?.message || 'Failed to request session rebuild',
      });
    }
  }
}
