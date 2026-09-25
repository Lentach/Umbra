import { Injectable, Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { UsersService } from '../../users/users.service';
import { FriendsService } from '../../friends/friends.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { DeviceListService } from '../../key-bundles/device-list.service';
import {
  DEFAULT_DEVICE_ID,
  PreKeyBundleResponse,
} from '../../key-bundles/key-bundles.service';
import { validateDto } from '../utils/dto.validator';
import { SearchUsersDto, SetRequestQueueDto } from '../dto/chat.dto';
import { UserMapper } from '../mappers/user.mapper';
import { deviceAuthorizationPayload } from '../mappers/device-authorization.mapper';
import { ChatKeyExchangeService } from './chat-key-exchange.service';

/** What `ChatGateway.handleConnection` writes to `Socket.data`. */
interface AuthenticatedSocketData {
  user?: { id: number; deviceId?: number };
}

function socketUser(client: Socket): AuthenticatedSocketData['user'] {
  // socket.io types `Socket.data` as `any`; the gateway is its only writer.
  const data = client.data as AuthenticatedSocketData;
  return data.user;
}

/**
 * First contact (metadata-privacy PR3.2, design §4.4).
 *
 * `searchUsers` answers a stranger's handle with everything a first contact
 * needs in ONE identity call: per addressable device a bundle (its next
 * one-time pre-key spent), the request queue that device published, and the
 * account's DAK-signed list so the searcher verifies the device set instead of
 * taking the server's word. Residual (design §5): identity sees "A looked up
 * B", once — the search is not logged.
 *
 * `setRequestQueue` is how a device publishes that queue.
 */
@Injectable()
export class ChatSearchService {
  private readonly logger = new Logger(ChatSearchService.name);

  constructor(
    private readonly usersService: UsersService,
    private readonly friendsService: FriendsService,
    private readonly devicesService: DevicesService,
    private readonly deviceListService: DeviceListService,
    private readonly chatKeyExchangeService: ChatKeyExchangeService,
  ) {}

  async handleSearchUsers(
    client: Socket,
    data: unknown,
    server: Server,
  ): Promise<void> {
    const currentUserId = socketUser(client)?.id;
    if (!currentUserId) return;

    try {
      const dto = validateDto(SearchUsersDto, data);
      const [username, tag] = dto.handle.split('#');
      const user = await this.usersService.findByUsernameAndTag(username, tag);
      // Self and friends answer empty BEFORE anything is claimed: a search
      // must never spend a pre-key it is not going to hand out.
      if (!user || user.id === currentUserId) {
        client.emit('searchUsersResult', []);
        return;
      }
      const friends = await this.friendsService.getFriends(currentUserId);
      if (friends.some((friend) => friend.id === user.id)) {
        client.emit('searchUsersResult', []);
        return;
      }
      client.emit('searchUsersResult', [
        {
          ...UserMapper.toPayload(user),
          ...(await this.reach(user.id, server)),
        },
      ]);
    } catch (error) {
      client.emit('error', {
        message: error instanceof Error ? error.message : 'Search failed',
      });
    }
  }

  /**
   * The devices and signed list of [userId] a first contact may address.
   *
   * An account that owes a replacement enrollment gets NEITHER, the same
   * refusal `getDeviceList` makes (amendment (xlv) clause 2): its roster
   * cannot receive, so a first contact sent to it would be lost in silence —
   * and nothing is claimed for it.
   */
  private async reach(userId: number, server: Server) {
    if (
      (await this.deviceListService.pendingReplacementVersion(userId)) !== null
    ) {
      return { devices: [], authorization: null };
    }
    const devices: Array<{
      deviceId: number;
      bundle: PreKeyBundleResponse;
      requestSid: string | null;
      sealPub: string | null;
    }> = [];
    for (const address of await this.devicesService.firstContactDevices(
      userId,
    )) {
      const bundle = await this.chatKeyExchangeService.claimBundle(
        userId,
        address.deviceId,
        server,
      );
      // Gone between the listing and the claim (a revoke or reset racing the
      // search): a device with no bundle cannot be reached, so it is not served.
      if (!bundle) continue;
      devices.push({
        deviceId: address.deviceId,
        bundle,
        requestSid: address.requestSid,
        sealPub: address.requestSealPub,
      });
    }
    return {
      devices,
      authorization: deviceAuthorizationPayload(
        await this.deviceListService.getAuthorization(userId),
      ),
    };
  }

  /**
   * Publishes the CALLER's request queue on the device its session names —
   * never a device from the payload (the same rule as key uploads, wire.md
   * "Per-device key material"). Answers `requestQueueSet { success, error? }`:
   * `invalid_payload`, `unknown_device` (no live row), `internal`.
   */
  async handleSetRequestQueue(client: Socket, data: unknown): Promise<void> {
    const user = socketUser(client);
    if (!user) return;

    let dto: SetRequestQueueDto;
    try {
      dto = validateDto(SetRequestQueueDto, data);
    } catch {
      client.emit('requestQueueSet', {
        success: false,
        error: 'invalid_payload',
      });
      return;
    }
    try {
      const stored = await this.devicesService.setRequestQueue(
        user.id,
        user.deviceId ?? DEFAULT_DEVICE_ID,
        dto.sid,
        dto.sealPub,
      );
      client.emit(
        'requestQueueSet',
        stored
          ? { success: true }
          : { success: false, error: 'unknown_device' },
      );
    } catch (error) {
      // Never the sid: it is a capability.
      this.logger.error(
        `setRequestQueue failed: ${error instanceof Error ? error.message : String(error)}`,
      );
      client.emit('requestQueueSet', { success: false, error: 'internal' });
    }
  }

  /**
   * The request queues of the CALLER's OTHER live devices (metadata-privacy
   * PR3.1 sibling queues, owner decision 26): a device swaps its self-queue
   * address with each sibling by sending an E2E `queue_handoff` into that
   * sibling's request queue. Own account only, so it names nobody the server
   * does not already tie to the caller; no pre-key is claimed (siblings
   * already hold sessions). Answers `ownRequestQueues { success, devices }`,
   * `devices` = `[{ deviceId, requestSid, sealPub }]` oldest first, null
   * until that device publishes; refusals `internal`, `rate_limited`.
   */
  async handleGetOwnRequestQueues(client: Socket): Promise<void> {
    const user = socketUser(client);
    if (!user) return;
    const callerDeviceId = user.deviceId ?? DEFAULT_DEVICE_ID;
    try {
      const addresses = await this.devicesService.firstContactDevices(user.id);
      client.emit('ownRequestQueues', {
        success: true,
        devices: addresses
          .filter((address) => address.deviceId !== callerDeviceId)
          .map((address) => ({
            deviceId: address.deviceId,
            requestSid: address.requestSid,
            sealPub: address.requestSealPub,
          })),
      });
    } catch (error) {
      // Never a sid: each one is a capability.
      this.logger.error(
        `getOwnRequestQueues failed: ${error instanceof Error ? error.message : String(error)}`,
      );
      client.emit('ownRequestQueues', { success: false, error: 'internal' });
    }
  }
}
