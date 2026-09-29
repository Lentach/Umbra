import { Injectable, Logger } from '@nestjs/common';
import { randomBytes } from 'crypto';
import type { Socket } from 'socket.io';
import {
  BOX_DELIVERY_WINDOW,
  BOX_MSG_ID_BYTES,
  BOX_SOCKET_RID_CAP,
} from './box.constants';
import { BoxService } from './box.service';

interface InFlight {
  /** base64url */
  rid: string;
  /** Its one ack outside the ack limit is spent (`claimAck`). */
  claimed: boolean;
}

interface Slot {
  socket: Socket;
  /** Subscribed rids in rotation order: base64url → bytes. */
  rids: Map<string, Buffer>;
  /** Pushed, not yet acked on this socket, by message id (base64url). */
  inFlight: Map<string, InFlight>;
  /** Where the next round-robin pass starts. */
  cursor: number;
  running: boolean;
  again: boolean;
}

/**
 * Live delivery (G3 surface A §1 "Flow control"). In memory only, and it
 * holds no account, device or sender — a socket id and the rids that socket
 * proved it may read.
 *
 * - ONE `msg {rid, id, blob}` per frame, and at most 16 unacked per socket
 *   (the credit window): a 128-message backlog never lands as one 2.8 MB
 *   frame that would stall every ack reply behind it.
 * - Round-robin across the socket's rids, oldest first within a rid.
 * - The NEWEST subscriber of a rid wins it: a device's stale socket loses the
 *   rid (its in-flight copies are released, not acked), which frees its slot.
 * - At most 1 024 rids per socket (E10): past it a rid is refused, never
 *   swapped for one the socket holds.
 * - At-least-once: nothing here deletes; a pushed-but-unacked message is
 *   pushed again on the next subscribe, so the client dedups (PR2.1 wire id).
 * - A `live` blob (decision 61) is the exception: never stored, so pushed at
 *   most once, and only to the rid's socket of that moment. It takes a
 *   window slot like any frame until acked or the socket goes; with the
 *   window full it is dropped, so a sid holder cannot pile frames onto a
 *   socket that does not ack.
 * - Each push earns its socket ONE ack outside the per-address ack limit
 *   (`claimAck`): only that socket learned the id, so nobody else — not a
 *   sender flooding a public request sid — can spend its owner's budget.
 */
@Injectable()
export class BoxDelivery {
  private readonly logger = new Logger(BoxDelivery.name);
  /** rid (base64url) → the socket id that owns it. */
  private readonly owners = new Map<string, string>();
  private readonly slots = new Map<string, Slot>();

  constructor(private readonly source: BoxService) {}

  /**
   * Splits `rids` at the socket's rid cap, in order: `fits` it may hold — a
   * rid it already holds costs nothing — and `over`, the rest.
   */
  fit(socketId: string, rids: Buffer[]): { fits: Buffer[]; over: Buffer[] } {
    const held = this.slots.get(socketId)?.rids;
    const added = new Set<string>();
    const fits: Buffer[] = [];
    const over: Buffer[] = [];
    for (const bytes of rids) {
      const rid = bytes.toString('base64url');
      if (!held?.has(rid) && !added.has(rid)) {
        if ((held?.size ?? 0) + added.size >= BOX_SOCKET_RID_CAP) {
          over.push(bytes);
          continue;
        }
        added.add(rid);
      }
      fits.push(bytes);
    }
    return { fits, over };
  }

  /**
   * Gives the socket every rid that still fits under its cap and returns the
   * rest. Synchronous, so the cap holds even when several subscribe frames
   * on one socket passed `fit` before any of them got here.
   */
  attach(socket: Socket, rids: Buffer[]): Buffer[] {
    const { fits, over } = this.fit(socket.id, rids);
    if (fits.length === 0) return over;
    let slot = this.slots.get(socket.id);
    if (!slot) {
      slot = {
        socket,
        rids: new Map(),
        inFlight: new Map(),
        cursor: 0,
        running: false,
        again: false,
      };
      this.slots.set(socket.id, slot);
    }
    for (const bytes of fits) {
      const rid = bytes.toString('base64url');
      const previous = this.owners.get(rid);
      if (previous !== undefined && previous !== socket.id) {
        this.release(previous, rid);
      }
      this.owners.set(rid, socket.id);
      slot.rids.set(rid, bytes);
    }
    // After the subscribe ACK has gone out: the client sees `{ok:true}`
    // before the backlog, as the contract describes.
    const attached = slot;
    setImmediate(() => this.pump(attached));
    return over;
  }

  /**
   * Forgets the socket. Returns the rids it still owned: what it was handed
   * may be unread — a socket that dies silently is detached only at the
   * ping timeout, and every message stored meanwhile went to it, not to a
   * push.
   */
  detachSocket(socketId: string): Buffer[] {
    const slot = this.slots.get(socketId);
    if (!slot) return [];
    for (const rid of slot.rids.keys()) {
      if (this.owners.get(rid) === socketId) this.owners.delete(rid);
    }
    this.slots.delete(socketId);
    // `release` drops a rid a newer socket took: every rid left is still ours.
    return [...slot.rids.values()];
  }

  /** The queue is gone (deleted or reaped): no socket owns it any more. */
  forget(ridBytes: Buffer): void {
    const rid = ridBytes.toString('base64url');
    const owner = this.owners.get(rid);
    if (owner === undefined) return;
    this.owners.delete(rid);
    this.release(owner, rid);
  }

  /** A blob was stored for `rid`. False when no socket owns it (push instead). */
  onEnqueued(ridBytes: Buffer): boolean {
    const owner = this.owners.get(ridBytes.toString('base64url'));
    const slot = owner === undefined ? undefined : this.slots.get(owner);
    if (!slot) return false;
    this.pump(slot);
    return true;
  }

  /** A `live` blob for `rid`: one push to its socket now, if it has one with room. */
  pushLive(ridBytes: Buffer, blob: Buffer): void {
    const rid = ridBytes.toString('base64url');
    const owner = this.owners.get(rid);
    const slot = owner === undefined ? undefined : this.slots.get(owner);
    if (
      !slot ||
      !this.isLive(slot) ||
      slot.inFlight.size >= BOX_DELIVERY_WINDOW
    ) {
      return;
    }
    const id = randomBytes(BOX_MSG_ID_BYTES).toString('base64url');
    this.hand(slot, rid, id, blob);
  }

  /**
   * True once per push: `id` is in flight on this socket, so its ack answers
   * a frame the box handed THIS socket. Bounded by the window, and by the
   * pushes a sender's own `send` limit pays for.
   */
  claimAck(socketId: string, id: Buffer): boolean {
    const slot = this.slots.get(socketId);
    const frame = slot?.inFlight.get(id.toString('base64url'));
    if (!frame || frame.claimed) return false;
    frame.claimed = true;
    return true;
  }

  /** The socket acked `id`: its window slot frees and the next one goes out. */
  onAcked(socketId: string, id: Buffer): void {
    const slot = this.slots.get(socketId);
    if (slot?.inFlight.delete(id.toString('base64url'))) this.pump(slot);
  }

  private hand(slot: Slot, rid: string, id: string, blob: Buffer): void {
    slot.inFlight.set(id, { rid, claimed: false });
    slot.socket.emit('msg', { rid, id, blob: blob.toString('base64url') });
  }

  private release(socketId: string, rid: string): void {
    const slot = this.slots.get(socketId);
    if (!slot) return;
    slot.rids.delete(rid);
    for (const [id, frame] of slot.inFlight) {
      if (frame.rid === rid) slot.inFlight.delete(id);
    }
    slot.cursor = 0;
    this.pump(slot);
  }

  /** Serialised per socket: a trigger during a pass schedules one more pass. */
  private pump(slot: Slot): void {
    if (slot.running) {
      slot.again = true;
      return;
    }
    slot.running = true;
    void (async () => {
      try {
        do {
          slot.again = false;
          await this.drain(slot);
        } while (slot.again && this.isLive(slot));
      } catch (error) {
        // Nothing is lost: undelivered rows stay and the next trigger retries.
        this.logger.warn(
          `[box] delivery pass failed: ${error instanceof Error ? error.name : 'unknown'}`,
        );
      } finally {
        slot.running = false;
      }
    })();
  }

  private isLive(slot: Slot): boolean {
    return this.slots.get(slot.socket.id) === slot && slot.socket.connected;
  }

  private async drain(slot: Slot): Promise<void> {
    while (this.isLive(slot)) {
      const free = BOX_DELIVERY_WINDOW - slot.inFlight.size;
      if (free <= 0 || slot.rids.size === 0) return;
      const heads = await this.source.pendingHeads(
        [...slot.rids.values()],
        [...slot.inFlight.keys()].map((id) => Buffer.from(id, 'base64url')),
        free,
      );
      const byRid = new Map<string, Buffer[]>();
      for (const head of heads) {
        const rid = head.rid.toString('base64url');
        const ids = byRid.get(rid);
        if (ids) ids.push(head.id);
        else byRid.set(rid, [head.id]);
      }
      const order = [...slot.rids.keys()];
      const start = slot.cursor % Math.max(order.length, 1);
      const rotation = [...order.slice(start), ...order.slice(0, start)].filter(
        (rid) => byRid.has(rid),
      );
      slot.cursor = start + 1;
      const picks: { rid: string; id: Buffer }[] = [];
      for (let round = 0; picks.length < free; round++) {
        let took = false;
        for (const rid of rotation) {
          const id = byRid.get(rid)?.[round];
          if (id && picks.length < free) {
            picks.push({ rid, id });
            took = true;
          }
        }
        if (!took) break;
      }
      if (picks.length === 0) return;
      const blobs = await this.source.blobs(picks.map((p) => p.id));
      let sent = 0;
      for (const { rid, id } of picks) {
        const key = id.toString('base64url');
        const blob = blobs.get(key);
        // Re-checked after the awaits: the rid may have moved to a newer
        // socket, the message may have been acked or expired meanwhile.
        if (
          !blob ||
          !this.isLive(slot) ||
          this.owners.get(rid) !== slot.socket.id ||
          slot.inFlight.has(key) ||
          slot.inFlight.size >= BOX_DELIVERY_WINDOW
        ) {
          continue;
        }
        this.hand(slot, rid, key, blob);
        sent++;
      }
      if (sent === 0) return;
    }
  }
}
