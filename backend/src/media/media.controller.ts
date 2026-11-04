import {
  Controller,
  Get,
  Res,
  Param,
  BadRequestException,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import * as path from 'path';
import type { Response } from 'express';

// Media is served directly by Node by default. Set MEDIA_X_ACCEL_REDIRECT=true ONLY when
// nginx is configured with an internal `/internal/media/` location to offload file serving;
// otherwise the response would be an empty 200 (the cause of "all media broken" in prod).
const useXAccel = process.env.MEDIA_X_ACCEL_REDIRECT === 'true';
const mediaDir = process.env.MEDIA_DIR ?? '/app/media';

/**
 * Public avatar serving only. There is no upload route here (avatars come in
 * through `POST /users/profile-picture`) and no `msgs/` route: old-path message
 * attachments were removed in Phase 4 step 5, and box media has its own
 * controller under `/box/media`.
 */
@Controller('media')
export class MediaController {
  @Get('avatars/:filename')
  @Throttle({ default: { limit: 60, ttl: 60000 } })
  async serveAvatars(
    @Param('filename') filename: string,
    @Res() res: Response,
  ) {
    const safeFilename = path.basename(filename);
    if (safeFilename !== filename)
      throw new BadRequestException('Invalid filename');
    if (!useXAccel) {
      return res.sendFile(path.join(mediaDir, 'avatars', safeFilename));
    }
    res.setHeader(
      'X-Accel-Redirect',
      `/internal/media/avatars/${safeFilename}`,
    );
    res.status(200).send();
  }
}
