import { Injectable, Logger } from '@nestjs/common';
import type { Socket } from 'socket.io';
import { BOX_DELIVERY_WINDOW } from './box.constants';
import { BoxService } from './box.service';

interface Slot {
  socket: Socket;
  /** Subscribed rids in rotation order: base64url → bytes. */
  rids: Map<string, Buffer>;
  /** Pushed, not yet acked on this socket: message id → rid (base64url). */
  inFlight: Map<string, string>;
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
 *   rid (its in-flight copies are released, not acked).
 * - At-least-once: nothing here deletes; a pushed-but-unacked message is
 *   pushed again on the next subscribe, so the client dedups (PR2.1 wire id).
 */
@Injectable()
export class BoxDelivery {
  private readonly logger = new Logger(BoxDelivery.name);
  /** rid (base64url) → the socket id that owns it. */
  private readonly owners = new Map<string, string>();
  private readonly slots = new Map<string, Slot>();

  constructor(private readonly source: BoxService) {}

  attach(socket: Socket, rids: Buffer[]): void {
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
    for (const bytes of rids) {
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
  }

  detachSocket(socketId: string): void {
    const slot = this.slots.get(socketId);
    if (!slot) return;
    for (const rid of slot.rids.keys()) {
      if (this.owners.get(rid) === socketId) this.owners.delete(rid);
    }
    this.slots.delete(socketId);
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

  /** The socket acked `id`: its window slot frees and the next one goes out. */
  onAcked(socketId: string, id: Buffer): void {
    const slot = this.slots.get(socketId);
    if (slot?.inFlight.delete(id.toString('base64url'))) this.pump(slot);
  }

  private release(socketId: string, rid: string): void {
    const slot = this.slots.get(socketId);
    if (!slot) return;
    slot.rids.delete(rid);
    for (const [id, owner] of slot.inFlight) {
      if (owner === rid) slot.inFlight.delete(id);
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
        slot.inFlight.set(key, rid);
        slot.socket.emit('msg', {
          rid,
          id: key,
          blob: blob.toString('base64url'),
        });
        sent++;
      }
      if (sent === 0) return;
    }
  }
}
