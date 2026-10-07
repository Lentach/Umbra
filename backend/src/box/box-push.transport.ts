import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as admin from 'firebase-admin';
import * as webPush from 'web-push';
import { parseWebPushSubscription, type NotifierPlatform } from './box-wire';

export type PushOutcome = 'sent' | 'gone' | 'failed';

/**
 * What the box pushes. `n`/`c` (decision 77: the queue's nid and its count
 * of waiting non-quiet blobs) ride a WEB PUSH wake-up only, inside its RFC
 * 8291-encrypted payload; FCM `data` transits Google readable, so an FCM
 * wake-up is `{type:'new_message'}` alone.
 */
export type BoxPush =
  | { type: 'notifier_challenge'; code: string }
  | { type: 'new_message' }
  | { type: 'new_message'; n: string; c: number };

/**
 * Sends one push to one raw token. A DI seam (`BOX_PUSH_TRANSPORT`): the
 * integration suite swaps in a recorder to read the challenge code.
 *
 * The box cannot reuse `PushNotificationsService`: it resolves tokens by user
 * id through `fcm-tokens/`, whose entity imports `users/` — I1 forbids that
 * import graph here.
 */
export interface BoxPushTransport {
  send(
    platform: NotifierPlatform,
    token: string,
    data: BoxPush,
  ): Promise<PushOutcome>;
}

export const BOX_PUSH_TRANSPORT = Symbol('BOX_PUSH_TRANSPORT');

/** web-push has no send timeout; one half-open connection must not hang a flush. */
const WEB_PUSH_SEND_TIMEOUT_MS = 10_000;

/**
 * How long the Web Push relay may hold a push for an offline device. A
 * challenge code lives 10 min (`BOX_CHALLENGE_TTL_MS`): a later delivery
 * carries a dead code. A wake-up is useful while a blob waits (up to 30 d,
 * `BOX_MSG_TTL_MS`); a day covers a phone off overnight, and the app drains
 * its queues on its next open anyway. The relay sees the TTL of every push
 * already, so neither value tells it anything new. FCM keeps its own
 * defaults: the native path is not part of this split.
 */
export const BOX_CHALLENGE_PUSH_TTL_S = 600;
export const BOX_WAKE_PUSH_TTL_S = 86_400;

function ttlFor(data: BoxPush): number {
  return data.type === 'notifier_challenge'
    ? BOX_CHALLENGE_PUSH_TTL_S
    : BOX_WAKE_PUSH_TTL_S;
}

@Injectable()
export class FirebaseWebPushTransport
  implements BoxPushTransport, OnModuleInit
{
  private readonly logger = new Logger(FirebaseWebPushTransport.name);
  private fcmReady = false;
  private webPushReady = false;

  onModuleInit(): void {
    // Same guards as PushNotificationsService, which may have initialised the
    // shared firebase-admin app / web-push VAPID details first.
    const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT;
    if (serviceAccountJson) {
      try {
        if (admin.apps.length === 0) {
          admin.initializeApp({
            credential: admin.credential.cert(JSON.parse(serviceAccountJson)),
          });
        }
        this.fcmReady = true;
      } catch {
        this.logger.error('[box] Firebase Admin init failed');
      }
    }
    const publicKey = process.env.WEB_PUSH_VAPID_PUBLIC_KEY;
    const privateKey = process.env.WEB_PUSH_VAPID_PRIVATE_KEY;
    if (publicKey && privateKey) {
      try {
        webPush.setVapidDetails(
          process.env.WEB_PUSH_VAPID_SUBJECT ?? 'mailto:fireplace@example.com',
          publicKey,
          privateKey,
        );
        this.webPushReady = true;
      } catch {
        this.logger.error('[box] Web Push VAPID init failed');
      }
    }
  }

  async send(
    platform: NotifierPlatform,
    token: string,
    data: BoxPush,
  ): Promise<PushOutcome> {
    if (platform === 'webpush') return this.sendWebPush(token, data);
    // FCM `data` transits Google readable: a nid or a count never goes there.
    if ('n' in data) {
      this.logger.error('[box] refused a web-push-only wake-up for fcm');
      return 'failed';
    }
    return this.sendFcm(token, data);
  }

  private async sendFcm(
    token: string,
    data: Exclude<BoxPush, { n: string }>,
  ): Promise<PushOutcome> {
    if (!this.fcmReady) return 'failed';
    try {
      // `data` transits Google readable: callers pass content-free maps only.
      await admin.messaging().send({
        token,
        data,
        android: { priority: 'high' },
        apns: { payload: { aps: { contentAvailable: true } } },
      });
      return 'sent';
    } catch (error) {
      // firebase-admin rejects with a FirebaseMessagingError carrying `code`.
      const failure = error as { code?: string };
      if (failure.code === 'messaging/registration-token-not-registered') {
        return 'gone';
      }
      // The code only: a token names a device.
      this.logger.warn(`[box] fcm push refused: ${failure.code ?? 'no code'}`);
      return 'failed';
    }
  }

  private async sendWebPush(
    token: string,
    data: BoxPush,
  ): Promise<PushOutcome> {
    const subscription = parseWebPushSubscription(token);
    if (!this.webPushReady || !subscription) return 'failed';
    let timer: NodeJS.Timeout | undefined;
    // Executor form on purpose: the tsconfig lib predates Promise.withResolvers.
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new Error('web-push send timed out')),
        WEB_PUSH_SEND_TIMEOUT_MS,
      );
    });
    try {
      // No `topic`: it is cleartext to the relay (backend/CLAUDE.md §9).
      await Promise.race([
        webPush.sendNotification(subscription, JSON.stringify(data), {
          TTL: ttlFor(data),
          urgency: 'high',
        }),
        timeout,
      ]);
      return 'sent';
    } catch (error) {
      // web-push rejects with a WebPushError carrying the relay's statusCode;
      // only 404/410 mean the subscription is gone (BE-500).
      const failure = error as { statusCode?: number };
      if (failure.statusCode === 404 || failure.statusCode === 410) {
        return 'gone';
      }
      // The status only: an endpoint names a device.
      this.logger.warn(
        `[box] web push refused: ${failure.statusCode ?? 'no status'}`,
      );
      return 'failed';
    } finally {
      clearTimeout(timer);
    }
  }
}
