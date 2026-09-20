import { Server, Socket } from 'socket.io';

/**
 * Per-user Socket.IO room. Every authenticated socket joins this on connect
 * (`ChatGateway.handleConnection`), so a user with several tabs open has
 * several sockets in one room.
 *
 * Addressing realtime events by ROOM rather than by a single socket id is
 * load-bearing (BE-007). The gateway used to keep a `Map<userId, socketId>`
 * and emit to `onlineUsers.get(id)`; because that map was last-write-wins,
 * opening a second tab silently stopped the first one receiving anything —
 * it stayed connected and authenticated but was no longer addressable, and
 * push was suppressed for it too. Rooms fix that class of bug outright:
 * Socket.IO maintains membership itself, including removal on disconnect,
 * so there is no map to go stale and no guarded-disconnect dance.
 *
 * Note this is still per-process. Without a Redis adapter a second backend
 * container has its own rooms, so horizontal scale would need one.
 */
export function userRoom(userId: number): string {
  return `user:${userId}`; // log-guard: key
}

/**
 * Per-DEVICE Socket.IO room (spec §5.3). Every authenticated socket joins this
 * alongside its user room, using the `deviceId` JWT claim (a token issued
 * before that claim existed is device 1, §8), so ciphertext can be addressed
 * to the one device that can actually decrypt it.
 *
 * The user room stays the address for METADATA every device must see
 * (reactions, delivery, list changes, deletes); this room is for ciphertext
 * and for anything else that is true of one device only.
 */
export function deviceRoom(userId: number, deviceId: number): string {
  return `device:${userId}:${deviceId}`; // log-guard: key
}

/**
 * Is this user connected on at least one socket?
 *
 * Replaces the old `onlineUsers.has(id)` presence check. Room occupancy is
 * multi-tab correct by construction: closing one of two tabs leaves the room
 * non-empty, whereas the old map could be cleared by whichever socket
 * happened to disconnect last.
 */
export function isUserOnline(server: Server, userId: number): boolean {
  const socketIds = server.sockets?.adapter?.rooms?.get(userRoom(userId));
  return socketIds !== undefined && socketIds.size > 0;
}

/**
 * The device's most recently connected socket, or undefined when that device
 * has no live socket.
 *
 * The single resolution point for anything that must treat one socket as "the"
 * socket of a device. Delivery of ciphertext and the decision to suppress a
 * push MUST both go through this, or they disagree: address the newest tab
 * while polling every tab for focus and you get the case where the message is
 * delivered to a background tab, the push is suppressed because a DIFFERENT
 * tab is focused, and the user sees neither. Resolving once keeps them
 * coherent by construction.
 */
export function newestSocketForDevice(
  server: Server,
  userId: number,
  deviceId: number,
): Socket | undefined {
  const socketIds = server.sockets?.adapter?.rooms?.get(
    deviceRoom(userId, deviceId),
  );
  if (!socketIds || socketIds.size === 0) return undefined;
  // Set preserves insertion order, so the last entry is the newest join.
  let newestId: string | undefined;
  for (const socketId of socketIds) newestId = socketId;
  return newestId ? server.sockets?.sockets?.get(newestId) : undefined;
}

/**
 * EVERY live socket of ONE device (spec §5.5 revocation kick).
 *
 * Distinct from {@link newestSocketForDevice} on purpose: delivery narrows to
 * the newest tab because Signal decryption is not idempotent, but a KICK must
 * reach every tab of the revoked device — leaving an older tab connected would
 * leave it able to send, which is exactly what revocation removes.
 */
export function socketsForDevice(
  server: Server,
  userId: number,
  deviceId: number,
): Socket[] {
  const socketIds = server.sockets?.adapter?.rooms?.get(
    deviceRoom(userId, deviceId),
  );
  if (!socketIds) return [];
  const sockets: Socket[] = [];
  // Snapshot first: disconnecting mutates the room set the iterator walks.
  for (const socketId of [...socketIds]) {
    const socket = server.sockets?.sockets?.get(socketId);
    if (socket) sockets.push(socket);
  }
  return sockets;
}

/**
 * Deliver to exactly ONE socket of ONE device — the most recently connected
 * (spec §5.3: `emitToNewestTab` survives, demoted to *within one device*).
 *
 * RESERVED FOR CIPHERTEXT-BEARING EVENTS (`newMessage`, `messageEdited`).
 * Everything else must use `server.to(userRoom(id))` so every device receives.
 *
 * Why this exists. Signal decryption is NOT idempotent: decrypting a message
 * consumes its message key and advances the ratchet. Tabs of one web device
 * share one IndexedDB session store, and the client's Web Lock serialises them
 * but does not deduplicate them — so fanning one ciphertext to two tabs makes
 * the first decrypt succeed and the second FAIL, landing in the client's
 * decryption failure policy. That path is documented client-side as the most
 * dangerous code in its messaging layer, because a wrong branch there can
 * destroy a working session.
 *
 * Note what this is NOT: it is not a way to pick one device out of several.
 * Under envelopes each device has its OWN ciphertext, so the caller emits once
 * PER DEVICE and this narrows each of those emits to that device's newest tab.
 *
 * TEMPORARY, per device. Remove once the client either (a) checks a shared
 * decrypted-message cache before attempting a live decrypt, race-free, or
 * (b) provably no-ops when a sibling TAB of the same device already decrypted
 * the ciphertext. Then these events move to `server.to(deviceRoom(id, did))` —
 * and push suppression must move to device-room-wide in the SAME change, never
 * separately.
 */
export function emitToDeviceNewestSocket(
  server: Server,
  userId: number,
  deviceId: number,
  event: string,
  payload: unknown,
): boolean {
  const socket = newestSocketForDevice(server, userId, deviceId);
  if (!socket) return false;
  socket.emit(event, payload);
  return true;
}
