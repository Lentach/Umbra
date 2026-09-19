import {
  Injectable,
  Logger,
  OnModuleDestroy,
} from '@nestjs/common';
import { PushNotificationsService } from './push-notifications.service';
import { MessagesService } from '../messages/messages.service';
import { ConversationNotificationPreferencesService } from '../conversation-notification-preferences/conversation-notification-preferences.service';

/** Trailing debounce window before firing one push for a burst in the same chat. */
const DEBOUNCE_MS = 2500;
/** Upper bound so rapid sends cannot postpone notification indefinitely. */
const MAX_WAIT_MS = 10000;
/**
 * Window for suppressing an immediately-repeated push with identical counts.
 * Race: flush() deletes its bucket and THEN awaits the unread summary; a
 * message arriving inside that await is already counted in flush #1's summary
 * but also opens bucket #2, whose flush would re-announce the exact same state
 * ("5 new messages" twice). Skipping the redundant SEND is safe server-side
 * (no push ⇒ nothing must be shown). The window is short so a genuinely new
 * equal-count state (read elsewhere, then new messages) still notifies.
 */
const DUPLICATE_SUPPRESS_MS = 10000;
/** Hard cap on the last-sent tracker (same pattern as the pre-key tracker). */
const LAST_SENT_MAX_ENTRIES = 10000;

interface PendingBucket {
  debounceTimer: NodeJS.Timeout;
  maxWaitTimer: NodeJS.Timeout;
  /** Display name of the message sender — shown as the notification title. */
  senderName?: string;
}

@Injectable()
export class PushNotificationCoalescingService implements OnModuleDestroy {
  private readonly logger = new Logger(PushNotificationCoalescingService.name);
  private readonly pending = new Map<string, PendingBucket>();
  /** Last counts actually sent per `${recipient}:${conversation}` — see DUPLICATE_SUPPRESS_MS. */
  private readonly lastSent = new Map<
    string,
    { unreadCount: number; unreadTotal: number; at: number }
  >();

  constructor(
    private readonly pushNotificationsService: PushNotificationsService,
    private readonly messagesService: MessagesService,
    private readonly notificationPreferences: ConversationNotificationPreferencesService,
  ) {}

  /**
   * Schedule a coalesced push for one message to recipientUserId in conversationId.
   * Multiple rapid messages collapse into a single notify with live unread counts.
   */
  scheduleMessagePush(
    recipientUserId: number,
    conversationId: number,
    senderName?: string,
  ): Promise<void> {
    const key = `${recipientUserId}:${conversationId}`;
    const existing = this.pending.get(key);

    if (existing) {
      clearTimeout(existing.debounceTimer);
      existing.debounceTimer = setTimeout(() => {
        void this.flush(key);
      }, DEBOUNCE_MS);
      if (senderName) existing.senderName = senderName;
      return Promise.resolve();
    }

    const bucket: PendingBucket = {
      debounceTimer: setTimeout(() => void this.flush(key), DEBOUNCE_MS),
      maxWaitTimer: setTimeout(() => void this.flush(key), MAX_WAIT_MS),
      senderName,
    };
    this.pending.set(key, bucket);
    return Promise.resolve();
  }

  private async flush(key: string): Promise<void> {
    const bucket = this.pending.get(key);
    if (!bucket) return;

    clearTimeout(bucket.debounceTimer);
    clearTimeout(bucket.maxWaitTimer);
    this.pending.delete(key);
    const senderName = bucket.senderName;

    const colon = key.indexOf(':');
    const recipientUserId = Number(key.slice(0, colon));
    const conversationId = Number(key.slice(colon + 1));

    if (
      !Number.isFinite(recipientUserId) ||
      !Number.isFinite(conversationId)
    ) {
      this.logger.warn(`Push coalesce flush skipped: invalid key ${key}`);
      return;
    }

    if (await this.notificationPreferences.isMuted(recipientUserId, conversationId)) {
      return;
    }

    let unreadCount: number | undefined;
    let unreadTotal: number | undefined;
    let unreadConversationIds: number[] | undefined;

    try {
      const summary = await this.messagesService.getUnreadSummaryForUser(recipientUserId);
      unreadTotal = summary.unreadTotal;
      unreadConversationIds = summary.unreadConversationIds;
      unreadCount = summary.countByConversationId.get(conversationId) ?? 0;
    } catch (err) {
      this.logger.warn(`Push coalesce: unread summary failed`, err);
    }

    if (unreadCount != null && unreadTotal != null) {
      const now = Date.now();
      const prev = this.lastSent.get(key);
      if (
        prev &&
        prev.unreadCount === unreadCount &&
        prev.unreadTotal === unreadTotal &&
        now - prev.at < DUPLICATE_SUPPRESS_MS
      ) {
        return; // identical state was just announced — redundant card
      }
      this.lastSent.set(key, { unreadCount, unreadTotal, at: now });
      this.pruneLastSent(now);
    }

    await this.pushNotificationsService
      .notify(recipientUserId, {
        conversationId,
        unreadCount,
        unreadTotal,
        unreadConversationIds,
        senderName,
      })
      .catch(() => {});
  }

  /** Drop expired entries; under cap pressure drop oldest first. */
  private pruneLastSent(now: number): void {
    for (const [k, v] of this.lastSent) {
      if (now - v.at >= DUPLICATE_SUPPRESS_MS) this.lastSent.delete(k);
    }
    if (this.lastSent.size > LAST_SENT_MAX_ENTRIES) {
      const excess = this.lastSent.size - LAST_SENT_MAX_ENTRIES;
      let dropped = 0;
      for (const k of this.lastSent.keys()) {
        this.lastSent.delete(k);
        if (++dropped >= excess) break;
      }
    }
  }

  onModuleDestroy(): void {
    for (const bucket of this.pending.values()) {
      clearTimeout(bucket.debounceTimer);
      clearTimeout(bucket.maxWaitTimer);
    }
    this.pending.clear();
    this.lastSent.clear();
  }
}
