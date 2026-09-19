import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as admin from 'firebase-admin';
import { FcmTokensService } from '../fcm-tokens/fcm-tokens.service';
import * as webPush from 'web-push';
import { WebPushSubscriptionsService } from '../web-push-subscriptions/web-push-subscriptions.service';

export interface NotifyOptions {
  conversationId: number; // required — always present (coalescing bucket key)
  unreadCount?: number; // cumulative unread in this conversation
  unreadTotal?: number; // user's total unread across all conversations
  unreadConversationIds?: number[]; // conv IDs with unread > 0
  senderName?: string; // sender display name (metadata-only; approved for notification title)
}

@Injectable()
export class PushNotificationsService implements OnModuleInit {
  private readonly logger = new Logger(PushNotificationsService.name);
  private fcmInitialized = false;
  private webPushInitialized = false;
  // BE-501: web-push has no built-in send timeout; cap each send so one half-open TCP
  // connection cannot hang the flush promise forever.
  private static readonly WEB_PUSH_SEND_TIMEOUT_MS = 10000;

  constructor(
    private readonly fcmTokensService: FcmTokensService,
    private readonly webPushSubscriptionsService: WebPushSubscriptionsService,
  ) {}

  onModuleInit() {
    this.initializeFcm();
    this.initializeWebPush();
  }

  private initializeFcm() {
    const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT;
    if (!serviceAccountJson) {
      this.logger.warn('FIREBASE_SERVICE_ACCOUNT not set — FCM push disabled');
      return;
    }

    if (admin.apps.length === 0) {
      try {
        admin.initializeApp({
          credential: admin.credential.cert(JSON.parse(serviceAccountJson)),
        });
        this.fcmInitialized = true;
        this.logger.log('Firebase Admin initialized');
      } catch (err) {
        this.logger.error('Firebase Admin init failed', err);
      }
    } else {
      this.fcmInitialized = true;
    }
  }

  private initializeWebPush() {
    const publicKey = process.env.WEB_PUSH_VAPID_PUBLIC_KEY;
    const privateKey = process.env.WEB_PUSH_VAPID_PRIVATE_KEY;
    const subject =
      process.env.WEB_PUSH_VAPID_SUBJECT ?? 'mailto:fireplace@example.com';

    if (!publicKey || !privateKey) {
      this.logger.warn(
        'WEB_PUSH_VAPID_PUBLIC_KEY/WEB_PUSH_VAPID_PRIVATE_KEY not set — Web Push disabled',
      );
      return;
    }

    try {
      webPush.setVapidDetails(subject, publicKey, privateKey);
      this.webPushInitialized = true;
      this.logger.log('Web Push VAPID initialized');
    } catch (err) {
      this.logger.error('Web Push VAPID init failed', err);
    }
  }

  async notify(userId: number, options: NotifyOptions): Promise<void> {
    await Promise.all([
      this.notifyFcm(userId, options),
      this.notifyWebPush(userId, options),
    ]);
  }

  /**
   * Phase 0a takeover alarm (multi-device spec §6.0): content-free security
   * notice to EVERY registered endpoint of the account after its key-bundle
   * identity was replaced. Deliberately bypasses the message coalescer (not
   * conversation-scoped, must not debounce) and carries only a type — the
   * client wakes and shows the "new device/browser sign-in" copy itself.
   * Endpoint sets are per-token/per-endpoint, so the replacing device may
   * receive its own alarm — harmless.
   */
  async notifyIdentityChanged(userId: number): Promise<void> {
    await Promise.all([
      this.notifyIdentityChangedFcm(userId),
      this.sendWebPushToUser(userId, { type: 'identity_changed' }),
    ]);
  }

  private async notifyIdentityChangedFcm(userId: number): Promise<void> {
    if (!this.fcmInitialized) return;
    const tokens = await this.fcmTokensService.findTokensByUserId(userId, [
      'android',
      'ios',
    ]);
    if (!tokens.length) return;
    try {
      await admin.messaging().sendEachForMulticast({
        tokens,
        data: { type: 'identity_changed' }, // content-free, Google-readable
        android: { priority: 'high' },
        apns: { payload: { aps: { contentAvailable: true } } },
      });
    } catch {
      // BE-502: no userId in prod-visible logs.
      this.logger.warn('FCM identity-changed send failed');
    }
  }

  /**
   * Phase 0b reset ceremony (multi-device spec §6.2): content-free notice that
   * an account-identity reset was requested, or that it was cancelled.
   *
   * Push is the ONLY channel that reaches a device whose app is closed, and
   * this app has no email — which is precisely why the ceremony's delay is
   * long. Bypasses the message coalescer (not conversation-scoped, must never
   * debounce) and carries only a type; the client renders its own copy and
   * offers the one-tap cancel.
   *
   * `identity_restored` (amendment (lxxviii) clause 2) rides the same channel:
   * content-free "your identity was restored on another install", sent to
   * every endpoint BEFORE the §6.2 teardown drops the push rows.
   */
  async notifyIdentityReset(
    userId: number,
    type:
      | 'identity_reset_pending'
      | 'identity_reset_cancelled'
      | 'recovery_key_enrolled'
      | 'identity_restored',
  ): Promise<void> {
    await Promise.all([
      this.notifyIdentityResetFcm(userId, type),
      this.sendWebPushToUser(userId, { type }),
    ]);
  }

  private async notifyIdentityResetFcm(
    userId: number,
    type:
      | 'identity_reset_pending'
      | 'identity_reset_cancelled'
      | 'recovery_key_enrolled'
      | 'identity_restored',
  ): Promise<void> {
    if (!this.fcmInitialized) return;
    const tokens = await this.fcmTokensService.findTokensByUserId(userId, [
      'android',
      'ios',
    ]);
    if (!tokens.length) return;
    try {
      await admin.messaging().sendEachForMulticast({
        tokens,
        data: { type }, // content-free, Google-readable
        android: { priority: 'high' },
        apns: { payload: { aps: { contentAvailable: true } } },
      });
    } catch {
      // BE-502: no userId in prod-visible logs.
      this.logger.warn('FCM identity-reset send failed');
    }
  }

  private async notifyFcm(
    userId: number,
    options: NotifyOptions,
  ): Promise<void> {
    if (!this.fcmInitialized) return;

    // Web clients are moving to standards-based Web Push.
    const tokens = await this.fcmTokensService.findTokensByUserId(userId, [
      'android',
      'ios',
    ]);
    if (!tokens.length) return;

    // Content-free wake-up (Signal/Wire model): the FCM `data` map transits Google
    // READABLE, so it carries ONLY the event type + conversationId (an opaque int used
    // for notification tap-routing/dedup). It intentionally omits senderName and unread
    // counts — those would leak who-messaged-whom and activity volume to Google. The app
    // wakes on this signal and fetches real state over its own authenticated socket.
    const data: Record<string, string> = {
      type: 'new_message',
      conversationId: String(options.conversationId),
    };

    try {
      const result = await admin.messaging().sendEachForMulticast({
        tokens,
        data, // metadata only — no message body
        android: { priority: 'high' },
        apns: { payload: { aps: { contentAvailable: true } } }, // silent push iOS
      });

      // Cleanup stale tokens (registration expired)
      const staleTokens: string[] = [];
      result.responses.forEach((r, i) => {
        if (
          !r.success &&
          r.error?.code === 'messaging/registration-token-not-registered'
        ) {
          staleTokens.push(tokens[i]);
        }
      });
      if (staleTokens.length) {
        await this.fcmTokensService.removeByTokens(staleTokens);
        this.logger.debug(
          `FCM cleanup removed ${staleTokens.length} stale tokens`,
        );
      }
      this.logger.debug(
        `FCM push attempted tokens=${tokens.length}, success=${result.successCount}, failure=${result.failureCount}`,
      );
    } catch (err) {
      // BE-502: recipient userId must not reach prod logs (prod keeps error/warn/log).
      // Keep a non-identifying operational signal; the userId-bearing detail goes to debug.
      this.logger.warn('FCM multicast send failed');
      this.logger.debug(`Failed to send push`, err);
    }
  }

  private async notifyWebPush(
    userId: number,
    options: NotifyOptions,
  ): Promise<void> {
    const body: Record<string, unknown> = {
      type: 'new_message',
      conversationId: options.conversationId,
    };
    if (options.unreadCount != null) {
      body.unreadCount = options.unreadCount;
    }
    if (options.unreadTotal != null) {
      body.unreadTotal = options.unreadTotal;
    }
    if (options.unreadConversationIds != null) {
      body.unreadConversationIds = options.unreadConversationIds;
    }
    if (options.senderName != null) {
      body.senderName = options.senderName;
    }
    await this.sendWebPushToUser(userId, body);
  }

  private async sendWebPushToUser(
    userId: number,
    body: Record<string, unknown>,
  ): Promise<void> {
    if (!this.webPushInitialized) return;

    const subscriptions =
      await this.webPushSubscriptionsService.findByUserId(userId);
    if (!subscriptions.length) return;

    // Deliberately NO `topic` (RFC 8030 collapse key): a `conv-<id>` topic is sent as a
    // CLEARTEXT header to the push relay (Mozilla/Apple/Google) and would leak per-
    // conversation activity + cadence. The payload body below is E2E-encrypted to the
    // browser, so senderName/counts inside it stay private; server-side coalescing and
    // client-side notification tags already de-dupe bursts without a relay collapse key.
    const payload = JSON.stringify(body);

    // BE-501: send to every subscription independently. sendNotification has no built-in
    // timeout, so a single half-open TCP connection would otherwise hang its await forever,
    // starve the remaining subscriptions in the sequential loop, and leak the flush promise.
    // Promise.allSettled lets each endpoint succeed or fail on its own, and sendOneWebPush
    // races the send against an explicit timeout.
    const results = await Promise.allSettled(
      subscriptions.map((subscription) =>
        this.sendOneWebPush(subscription, payload),
      ),
    );

    const staleEndpoints: string[] = [];
    results.forEach((result, i) => {
      if (result.status === 'fulfilled') return;
      const err: any = result.reason;
      const statusCode = Number(err?.statusCode);
      // BE-500: prune ONLY on the RFC-standard "subscription gone" codes (404/410).
      // A 400 is a payload/VAPID/library fault the relay returns for EVERY send, not a
      // per-subscription verdict — pruning on it would wipe every live row within a few
      // cycles. A timeout (no statusCode) likewise must never prune: that would turn a
      // transient relay incident into permanent mass unsubscription. Keeping a dead row
      // wastes one round trip; deleting a live row silently kills push until the user
      // re-enables it in Settings — always err toward keeping.
      if (statusCode === 404 || statusCode === 410) {
        staleEndpoints.push(subscriptions[i].endpoint);
        return;
      }
      // BE-502: no recipient identifier above debug (prod keeps error/warn/log).
      this.logger.debug(
        `Web Push delivery failed status=${statusCode || 'unknown'}`,
      );
    });

    if (staleEndpoints.length) {
      await this.webPushSubscriptionsService.removeByEndpoints(staleEndpoints);
      this.logger.debug(
        `Web Push cleanup removed ${staleEndpoints.length} stale subscriptions`,
      );
    }
    this.logger.debug(
      `Web Push attempted subscriptions=${subscriptions.length}, stale=${staleEndpoints.length}`,
    );
  }

  // Sends one Web Push and races it against WEB_PUSH_SEND_TIMEOUT_MS. A timeout rejects
  // with a plain Error (no statusCode), so the caller keeps the subscription — a transient
  // relay stall must NEVER be mistaken for "subscription gone" (that is BE-500 by another
  // route). Rejections carrying a relay statusCode (e.g. 404/410) pass through unchanged.
  private async sendOneWebPush(
    subscription: { endpoint: string; p256dh: string; auth: string },
    payload: string,
  ): Promise<void> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new Error('web-push send timed out')),
        PushNotificationsService.WEB_PUSH_SEND_TIMEOUT_MS,
      );
    });
    try {
      await Promise.race([
        webPush.sendNotification(
          {
            endpoint: subscription.endpoint,
            keys: {
              p256dh: subscription.p256dh,
              auth: subscription.auth,
            },
          },
          payload,
          {
            TTL: 120,
            urgency: 'high',
          },
        ),
        timeout,
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}
