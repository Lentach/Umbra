import { ArgumentsHost, Catch, ExceptionFilter, Logger } from '@nestjs/common';
import { ThrottlerException } from '@nestjs/throttler';
import type { BoxRefusal } from './box-wire';

/**
 * The backstop behind every `/box` handler. Without it Nest's
 * `BaseWsExceptionFilter` answers a throw with an `exception` event, which no
 * client listens to — the caller would wait out its timeout for nothing.
 *
 * - `ThrottlerException`: `BoxThrottlerGuard` already answered on the ack.
 * - No ack callback: the guard disconnected that socket; there is no channel.
 * - Anything else: `{ok:false, code:'internal'}` on the ack. This filter
 *   NEVER emits an event.
 */
@Catch()
export class BoxAckFilter implements ExceptionFilter {
  private readonly logger = new Logger(BoxAckFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    if (exception instanceof ThrottlerException) return;
    const arg: unknown = host.getArgs()[2];
    if (typeof arg !== 'function') return;
    // socket.io's ack callback takes the answer object.
    const ack = arg as (answer: BoxRefusal) => void;
    // The name only: a driver message can quote key values (ids).
    this.logger.warn(
      `[box] handler failed: ${exception instanceof Error ? exception.name : typeof exception}`,
    );
    ack({ ok: false, code: 'internal' });
  }
}
