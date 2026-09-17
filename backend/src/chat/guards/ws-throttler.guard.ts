import { ExecutionContext, Injectable, Logger } from '@nestjs/common';
import { ThrottlerGuard, ThrottlerLimitDetail } from '@nestjs/throttler';
import { MESSAGE_METADATA } from '@nestjs/websockets/constants';
import { Socket } from 'socket.io';

/** The stable refusal code every throttled handler answers with. */
export const RATE_LIMITED = 'rate_limited';

/**
 * How each throttled request ANSWERS when it is rate limited: the response
 * event of that request, plus the refusal body in that event's own shape.
 *
 * This table exists because the alternative is silence. `ThrottlerGuard` throws
 * `ThrottlerException`, Nest turns an unhandled WS exception into an
 * `exception` event, and this app's client listens to ~60 NAMED events plus
 * `error` — never `exception`. So before this table a throttled request was
 * answered by nothing at all, and any client state staked on the answer was
 * stranded: a throttled `editMessage` left an optimistically applied edit on
 * that device FOREVER while the server and the peer kept the old text, which is
 * the same divergence the `deviceListStale` edit path was fixed for.
 *
 * Answering in each request's OWN contract, rather than through one new global
 * "rate limited" event, is deliberate. Every refusal in this codebase is an
 * answer on the request's own response event with a stable code, so a second
 * refusal convention would be one more thing every future handler must
 * remember — and the client would need a map from that event to whichever
 * optimistic state to unwind. In-contract needs no such map: these payloads
 * flow into the settle/revert paths the client ALREADY has.
 *
 * Only handlers that ACTUALLY carry `@UseGuards(WsThrottlerGuard)` belong here:
 * an entry for an unthrottled handler is unreachable code that misrepresents the
 * wire contract. `uploadKeyBundle` was in this table for exactly that reason and
 * was removed.
 *
 * A handler that is not listed falls back to `error { message }`, which the
 * client already listens to and which already marks in-flight sends failed. So
 * an unlisted handler degrades to a visible error, never to silence.
 */
const THROTTLE_ANSWERS: Record<
  string,
  (data: unknown, retryAfterMs: number) => [string, Record<string, unknown>]
> = {
  // Reverts the optimistic edit through the existing `onEditMessageFailed`.
  editMessage: (data, retryAfterMs) => [
    'editMessageFailed',
    {
      messageId: (data as { messageId?: number } | null)?.messageId,
      reason: RATE_LIMITED,
      retryAfterMs,
    },
  ],
  // Reverts the optimistic pin through `onPinMessageFailed` (spec §12 (xxxvii)).
  //
  // A DEDICATED event, deliberately not `messagePinned`. This guard refuses
  // BEFORE the handler runs, so it holds only the inbound payload and cannot
  // know what was pinned before: answering `messagePinned` with a null id would
  // unpin a conversation that had a DIFFERENT message pinned, and echoing the
  // attempted id would confirm a pin that never happened. Only the pinning
  // device knows the state it overwrote, so only it can restore it — this
  // refusal is the trigger, not the new state.
  //
  // `unpinMessage` is deliberately ABSENT: it writes no optimistic state, so an
  // entry for it would be an answer no client code drives to a conclusion.
  pinMessage: (data, retryAfterMs) => [
    'messagePinFailed',
    {
      conversationId: (data as { conversationId?: number } | null)
        ?.conversationId,
      reason: RATE_LIMITED,
      retryAfterMs,
    },
  ],
  // Reverts the optimistic timer through `onDisappearingTimerFailed`.
  //
  // A DEDICATED event for the same reason as `messagePinFailed`: this guard
  // refuses before the handler runs, so it holds only the requested `seconds`
  // and cannot know the timer it displaced. Echoing `disappearingTimerUpdated`
  // with the attempted value would CONFIRM a change that never happened — and
  // this particular value is a safety promise, so a device left showing a timer
  // the server never accepted tells the user messages will vanish when they
  // will not.
  setDisappearingTimer: (data, retryAfterMs) => [
    'disappearingTimerFailed',
    {
      conversationId: (data as { conversationId?: number } | null)
        ?.conversationId,
      reason: RATE_LIMITED,
      retryAfterMs,
    },
  ],
  // The link ceremony: each stage answers its own ack, so a throttled stage
  // surfaces in the link UI instead of hanging it.
  openProvisioning: (_data, retryAfterMs) => [
    'provisioningOpened',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  provisioningHello: (_data, retryAfterMs) => [
    'provisioningHelloAck',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  provisionDevice: (_data, retryAfterMs) => [
    'provisionDeviceAck',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  provisioningComplete: (_data, retryAfterMs) => [
    'provisioningCompleted',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  cancelProvisioning: (_data, retryAfterMs) => [
    'provisioningCancelled',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  revokeDevice: (_data, retryAfterMs) => [
    'deviceRevocationCompleted',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  updateDeviceList: (_data, retryAfterMs) => [
    'deviceListUpdated',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  // Reaction-key distribution answers on its own events: a throttled upload
  // must not look like a successful publish (the peer would never get the
  // key), and a throttled fetch must not look like "this conversation has no
  // key" — the `error` field is what distinguishes a refusal from a null
  // ciphertext, so the caller retries instead of rendering placeholder chips
  // forever.
  uploadReactionKey: (_data, retryAfterMs) => [
    'reactionKeyUploaded',
    { success: false, error: RATE_LIMITED, retryAfterMs },
  ],
  fetchReactionKey: (data, retryAfterMs) => [
    'reactionKeyResponse',
    {
      conversationId: (data as { conversationId?: number } | null)
        ?.conversationId,
      success: false,
      error: RATE_LIMITED,
      retryAfterMs,
    },
  ],
};

/** One warn per (tracker, event) per this long; the rest go to debug. */
const REFUSAL_LOG_INTERVAL_MS = 60_000;

@Injectable()
export class WsThrottlerGuard extends ThrottlerGuard {
  private readonly wsLogger = new Logger(WsThrottlerGuard.name);

  /**
   * When each (tracker, event) pair was last logged at warn.
   *
   * Once a tracker crosses its limit, EVERY further request in the window is
   * refused — so logging each one at warn lets a flood amplify itself through
   * our logs, and the tracker falls back to a handshake address when the socket
   * is unauthenticated. The first refusal of a window is the interesting one;
   * the rest are debug.
   */
  private readonly lastRefusalLog = new Map<string, number>();

  protected getRequestResponse(context: ExecutionContext) {
    const client = context.switchToWs().getClient<Socket>();
    // ThrottlerGuard expects res.header() for rate-limit headers; Socket has no such method.
    // Provide mock res with no-op header() (returns this for chaining).
    const mockRes = {
      header: function (_name: string, _value?: string | number) {
        return this;
      },
    } as unknown as Record<string, unknown>;
    const req = {
      headers: client.handshake?.headers ?? {},
      ...client,
    } as unknown as Record<string, unknown>;
    return { req, res: mockRes };
  }

  protected async getTracker(req: Record<string, unknown>): Promise<string> {
    const socket = req as unknown as Socket;
    return (
      (socket.data?.user as { id?: number } | undefined)?.id?.toString() ??
      socket.handshake?.address ??
      'unknown'
    );
  }

  /**
   * ANSWER the caller, then refuse.
   *
   * The throw still happens, so the handler never runs and the limit keeps its
   * teeth; the emit only ensures the caller learns why. Emitting before the
   * throw (rather than from an exception filter) keeps the decision next to the
   * table that defines it.
   */
  protected async throwThrottlingException(
    context: ExecutionContext,
    detail: ThrottlerLimitDetail,
  ): Promise<void> {
    try {
      const client = context.switchToWs().getClient<Socket>();
      const event = Reflect.getMetadata(
        MESSAGE_METADATA,
        context.getHandler(),
      ) as string | undefined;
      // `timeToExpire` is seconds until the window rolls; the client needs it to
      // say "try again in N minutes" instead of guessing.
      const retryAfterMs = Math.max(0, (detail.timeToExpire ?? 0) * 1000);
      const answer = event ? THROTTLE_ANSWERS[event] : undefined;
      const [name, payload] = answer
        ? answer(context.switchToWs().getData(), retryAfterMs)
        : ['error', { message: RATE_LIMITED, event, retryAfterMs }];
      const userId = (client.data?.user as { id?: number } | undefined)?.id;
      const line = `[throttle] REFUSED event=${event ?? 'unknown'} userId=${userId ?? 'anon'} answeredWith=${name} retryAfterMs=${retryAfterMs}`;
      const logKey = `${detail.tracker}:${event ?? 'unknown'}`;
      const now = Date.now();
      const lastLogged = this.lastRefusalLog.get(logKey) ?? 0;
      if (now - lastLogged >= REFUSAL_LOG_INTERVAL_MS) {
        this.lastRefusalLog.set(logKey, now);
        // Bound the map: a flood from many trackers must not grow it forever.
        if (this.lastRefusalLog.size > 1000) {
          for (const [key, at] of this.lastRefusalLog) {
            if (now - at >= REFUSAL_LOG_INTERVAL_MS)
              this.lastRefusalLog.delete(key);
          }
        }
        this.wsLogger.warn(line);
      } else {
        this.wsLogger.debug(line);
      }
      client.emit(name, payload);
    } catch (error) {
      // Never let the courtesy answer mask the refusal itself.
      this.wsLogger.error(
        `[throttle] could not answer the caller: ${(error as Error).message}`,
      );
    }
    return super.throwThrottlingException(context, detail);
  }
}
