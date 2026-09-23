import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as admin from 'firebase-admin';
import * as webPush from 'web-push';
import { parseWebPushSubscription, type NotifierPlatform } from './box-wire';

export type PushOutcome = 'sent' | 'gone' | 'failed';

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
    data: Record<string, string>,
  ): Promise<PushOutcome>;
}

export const BOX_PUSH_TRANSPORT = Symbol('BOX_PUSH_TRANSPORT');

/** web-push has no send timeout; one half-open connection must not hang a flush. */
const WEB_PUSH_SEND_TIMEOUT_MS = 10_000;

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
    data: Record<string, string>,
  ): Promise<PushOutcome> {
    if (platform === 'fcm') return this.sendFcm(token, data);
    return this.sendWebPush(token, data);
  }

  private async sendFcm(
    token: string,
    data: Record<string, string>,
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
      const failure = error as { code?: unknown };
      return failure.code === 'messaging/registration-token-not-registered'
        ? 'gone'
        : 'failed';
    }
  }

  private async sendWebPush(
    token: string,
    data: Record<string, string>,
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
          TTL: 120,
          urgency: 'high',
        }),
        timeout,
      ]);
      return 'sent';
    } catch (error) {
      // web-push rejects with a WebPushError carrying the relay's statusCode;
      // only 404/410 mean the subscription is gone (BE-500).
      const failure = error as { statusCode?: unknown };
      return failure.statusCode === 404 || failure.statusCode === 410
        ? 'gone'
        : 'failed';
    } finally {
      clearTimeout(timer);
    }
  }
}
