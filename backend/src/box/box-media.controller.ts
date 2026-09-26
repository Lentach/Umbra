import {
  ArgumentsHost,
  Catch,
  Controller,
  ExceptionFilter,
  Get,
  HttpException,
  NotFoundException,
  Param,
  Post,
  Req,
  Res,
  StreamableFile,
  UseFilters,
} from '@nestjs/common';
import { Throttle, ThrottlerException } from '@nestjs/throttler';
import { randomBytes } from 'crypto';
import type { Request, Response } from 'express';
import { finished } from 'stream/promises';
import {
  BOX_LIMITS,
  BOX_MEDIA_ID_BYTES,
  BOX_MEDIA_LADDER,
  BOX_MEDIA_TTL_MS,
  BOX_SID_BYTES,
  BOX_THROTTLE_TTL_MS,
} from './box.constants';
import { BoxMediaStore } from './box-media.store';
import { boxTrackerFor, countRefusal } from './box-throttler.guard';
import { decodeFixedB64 } from './box-wire';
import { BoxService } from './box.service';

/**
 * The global `HttpThrottlerGuard` throttles these routes; this tracker makes
 * it key them like the box sockets (IPv6 widened to its /64).
 */
function boxHttpTracker(req: Record<string, unknown>): string {
  // An express request: `headers` is IncomingHttpHeaders, `ip` a string.
  const request = req as unknown as Request;
  return boxTrackerFor(request.headers, request.ip);
}

/** `429 {error:'rate_limited', retryAfterMs}` instead of Nest's default body. */
@Catch(ThrottlerException)
class BoxMediaThrottleFilter implements ExceptionFilter {
  catch(_exception: ThrottlerException, host: ArgumentsHost): void {
    const res = host.switchToHttp().getResponse<Response>();
    // ThrottlerGuard set Retry-After (seconds) on this response before throwing.
    const seconds = Number(res.getHeader('Retry-After')) || 0;
    res
      .status(429)
      .json({ error: 'rate_limited', retryAfterMs: seconds * 1000 });
  }
}

/**
 * Box media over HTTP (G3 surface A §1 "HTTP media", design §4.1).
 *
 * `POST /box/media` presents a sid in `Box-Sid` (never in the URL) and an
 * `application/octet-stream` body of exactly one ladder size (I5). The upload
 * is charged to that queue's daily byte budget and to the box's global media
 * ceiling (decision 30), and stored with NO link to the queue ("budget
 * without link"). Either quota refuses it `429 quota_exceeded` from the
 * headers. An unknown sid gets the same `201` with an id that is never
 * stored — or, at the ceiling, the same `429` — so the answer cannot test a
 * sid.
 *
 * NO body parser runs on this route. The body is an unauthenticated upload of
 * up to 32 MiB, so it is read only AFTER the global throttle guard, and only
 * when `Content-Length` already names a ladder rung — an off-rung size is
 * refused from the headers, before one body byte is read — and then STREAMED
 * to disk (or drained, for an unknown sid), never buffered in memory.
 *
 * `GET /box/media/:id` is a capability URL: `200` bytes with
 * `Cache-Control: no-store`, or `404`.
 */
@Controller('box/media')
@UseFilters(BoxMediaThrottleFilter)
export class BoxMediaController {
  constructor(
    private readonly box: BoxService,
    private readonly store: BoxMediaStore,
  ) {}

  @Post()
  @Throttle({
    default: {
      limit: BOX_LIMITS.mediaUpload,
      ttl: BOX_THROTTLE_TTL_MS,
      getTracker: boxHttpTracker,
    },
  })
  async upload(
    @Req() req: Request,
  ): Promise<{ id: string; bucket: string; expiresAt: string }> {
    // Headers only: an off-rung or unsized upload is refused before a
    // single byte of its body is read.
    const declared = Number(req.headers['content-length']);
    const rung = req.is('application/octet-stream')
      ? BOX_MEDIA_LADDER.find((r) => r.bytes === declared)
      : undefined;
    if (!rung) throw new HttpException({ error: 'bad_size' }, 413);
    const id = randomBytes(BOX_MEDIA_ID_BYTES);
    const expiresAt = new Date(Date.now() + BOX_MEDIA_TTL_MS);
    const answer = {
      id: id.toString('base64url'),
      bucket: rung.bucket,
      expiresAt: expiresAt.toISOString(),
    };
    const sid = decodeFixedB64(req.headers['box-sid'], BOX_SID_BYTES);
    // Row first, inside the charge: a crash before the write leaves a row
    // whose GET 404s and which the TTL sweep removes, never an unreferenced
    // file.
    const relative = this.store.newPath();
    const charge = await this.box.chargeMedia(sid, {
      id,
      path: relative,
      bucket: rung.bucket,
      bytes: rung.bytes,
      expiresAt,
    });
    if (charge === 'over_budget' || charge === 'over_ceiling') {
      // Counted, never traced (E11).
      countRefusal(
        charge === 'over_budget' ? 'mediaUpload:budget' : 'mediaUpload:ceiling',
      );
      throw new HttpException({ error: 'quota_exceeded' }, 429);
    }
    if (charge === 'unknown_sid') {
      // Read and drop it, as a stored upload is read: answering before the
      // body arrived would tell the sender its sid is dead.
      req.resume();
      await finished(req);
      return answer;
    }
    if (!(await this.store.writeFrom(relative, req, rung.bytes))) {
      await this.box.deleteMedia([id]);
      throw new HttpException({ error: 'bad_size' }, 413);
    }
    return answer;
  }

  @Get(':id')
  @Throttle({
    default: {
      limit: BOX_LIMITS.mediaDownload,
      ttl: BOX_THROTTLE_TTL_MS,
      getTracker: boxHttpTracker,
    },
  })
  async download(
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ): Promise<StreamableFile> {
    const bytes = decodeFixedB64(id, BOX_MEDIA_ID_BYTES);
    const relative = bytes ? await this.box.mediaPath(bytes) : null;
    const file = relative ? await this.store.open(relative) : null;
    if (!file) throw new NotFoundException();
    res.setHeader('Cache-Control', 'no-store');
    return new StreamableFile(file.stream, {
      type: 'application/octet-stream',
      length: file.size,
    });
  }
}
