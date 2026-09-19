import { Injectable, Logger } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { RefreshTokensService } from '../auth/refresh-tokens.service';
import { Device } from './device.entity';
import { DevicesService } from './devices.service';
import { KeyBundle } from './key-bundle.entity';
import { OneTimePreKey } from './one-time-pre-key.entity';

/** What the recovering device must be told to finish recovery. */
export interface ResetRosterResult {
  /** The freshly ALLOCATED id of the recovering device — never 1. */
  deviceId: number;
  /** Ids stamped revoked by this teardown (for the log and the tests). */
  revokedDeviceIds: number[];
  /** New session for that device, since every old session was dropped. */
  accessDeviceId: number;
  refreshToken: string;
  /**
   * The version the recovering device's REPLACEMENT enrollment must carry
   * (amendment (xlv) clause 1): the surviving row's `listVersion` + 1, or 1
   * when the account never enrolled. Required, not optional — every completed
   * reset owes a re-enrollment, and an absent field would let a caller forget
   * one silently.
   */
  nextListVersion: number;
}

/**
 * The §6.2 reset roster teardown (multi-device spec §12 amendments (f) and
 * (xxviii)).
 *
 * Runs at the moment a reset actually COMPLETES — the identity-change
 * authorization that consumed the ceremony — not when it was requested.
 *
 * Why the recovering device cannot simply keep device 1 ((f)(i)): the §5.3
 * history read serves a legacy row's ciphertext to `deviceId == 1`, so a fresh
 * identity re-using id 1 would be positively served the OLD device 1's
 * ciphertext and would attempt a foreign-ratchet decrypt over the only copy of
 * that plaintext. Post-reset history is therefore `none_for_device` markers
 * everywhere, exactly falsification 13's no-device-1 case.
 *
 * `account_authorizations` is deliberately NOT touched here (amendment (xxix)):
 * its `listVersion` must survive so re-enrollment continues monotonically, and
 * dropping the row would make the account read as not-enrolled, which the
 * (xix) rollback pin correctly refuses.
 */
@Injectable()
export class ResetRosterService {
  private readonly logger = new Logger(ResetRosterService.name);

  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly devicesService: DevicesService,
    private readonly refreshTokensService: RefreshTokensService,
  ) {}

  /**
   * Moves the just-uploaded bundle onto a fresh device id, revokes every other
   * device of the account, and issues the recovering device a new session.
   *
   * ONE transaction: a half-applied teardown would leave either a roster with
   * two live primaries or key material stranded under a revoked id.
   *
   * `uploadedUnderDeviceId` is the session id the recovering device uploaded
   * with (device 1 for a fresh install). Its material is MOVED rather than
   * re-uploaded, so the account is never briefly without a published bundle.
   */
  async applyAfterReset(
    userId: number,
    uploadedUnderDeviceId: number,
  ): Promise<ResetRosterResult> {
    let deviceId = 0;
    let revokedDeviceIds: number[] = [];
    let refreshToken = '';
    let nextListVersion = 1;
    await this.dataSource.transaction(async (manager) => {
      // Allocated, never re-minted: the counter is monotonic and is left
      // untouched by the rest of this teardown ((f)(i)+(f)(iv)).
      deviceId = await this.devicesService.allocateDeviceId(userId);

      // The recovering device's row comes first, so the account is never
      // momentarily left with no live device.
      await manager.getRepository(Device).insert({
        userId,
        deviceId,
        isPrimary: true,
        platform: null,
      });

      // Carry the fresh material onto the new id. `(userId, deviceId)` is
      // unique and the id was just allocated, so this cannot collide. The
      // superseded devices' own bundles were already dropped by the identity
      // change that admitted this reset.
      await manager
        .getRepository(KeyBundle)
        .update({ userId, deviceId: uploadedUnderDeviceId }, { deviceId });
      await manager
        .getRepository(OneTimePreKey)
        .update({ userId, deviceId: uploadedUnderDeviceId }, { deviceId });

      revokedDeviceIds = await this.devicesService.revokeAllExcept(
        userId,
        deviceId,
        manager,
      );
      // Every pre-reset session dies: those devices no longer hold the
      // account's identity, and a reset is precisely the "I lost control of
      // the old devices" ceremony. The recovering device is then handed the
      // only live session, carrying its new device id. BOTH ride the caller's
      // manager: a session wipe that committed while the roster mutation
      // rolled back would leave the account signed out of an un-revoked
      // roster, with the reset ceremony already spent.
      await this.refreshTokensService.revokeAllForUser(userId, manager);
      refreshToken = await this.refreshTokensService.createToken(
        userId,
        deviceId,
        null,
        manager,
      );

      // (xlv) clause 1: the version the recovering device's REPLACEMENT
      // enrollment must carry. Read inside the transaction beside the roster
      // it describes. The row itself is deliberately left alone ((xxix)) —
      // only its version is borrowed, so the replacement advances instead of
      // colliding. No row (an account that never enrolled) means the
      // replacement is a FIRST enrollment, which is version 1 by definition.
      const [existing] = await manager.query<{ listVersion: number }[]>(
        'SELECT "listVersion" FROM account_authorizations WHERE "userId" = $1',
        [userId],
      );
      nextListVersion = (existing?.listVersion ?? 0) + 1;
    });

    this.logger.warn(
      `[reset-roster] recoveringDeviceId=${deviceId} movedFrom=${uploadedUnderDeviceId} revoked=[${revokedDeviceIds.join(',')}] nextListVersion=${nextListVersion}`,
    );
    return {
      deviceId,
      revokedDeviceIds,
      accessDeviceId: deviceId,
      refreshToken,
      nextListVersion,
    };
  }
}
