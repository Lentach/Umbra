import type { DataSource, EntityManager } from 'typeorm';

/**
 * Issue #208 (decision 125): deletes the box notifiers registered on a
 * revoked device's own push tokens — its FCM tokens, and the web-push
 * subscriptions whose endpoint is exactly one of [endpoints]. A web-push
 * token is its subscription's JSON (validated at registration); `CASE` keeps
 * an FCM token out of the JSON cast. Nothing ties a queue to a device: the
 * match is by token alone, and nothing is logged.
 */
export async function deleteNotifiersOnPushTokens(
  db: Pick<DataSource | EntityManager, 'query'>,
  tokens: string[],
  endpoints: string[],
): Promise<void> {
  if (tokens.length === 0 && endpoints.length === 0) return;
  await db.query(
    `DELETE FROM public.box_notifiers
      WHERE CASE WHEN platform = 'webpush'
                 THEN (token::jsonb ->> 'endpoint') = ANY($2::text[])
                 ELSE token = ANY($1::text[]) END`,
    [tokens, endpoints],
  );
}
