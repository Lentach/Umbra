import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as fs from 'fs/promises';
import * as path from 'path';

/**
 * Self-hosted avatar storage under `MEDIA_DIR/avatars/`: delete only. Photos
 * no longer upload here (decision 138); the files that remain are the
 * migration source and go with account delete. Message attachments never
 * passed through this account-keyed store after Phase 4 step 5 and box media
 * lives under `MEDIA_DIR/box/` (its own store).
 */
@Injectable()
export class LocalStorageService {
  private readonly mediaDir: string;

  constructor(private configService: ConfigService) {
    this.mediaDir = configService.get<string>('MEDIA_DIR', '/app/media');
  }

  async deleteAvatar(publicId: string): Promise<void> {
    await this.deleteFile(publicId);
  }

  /** publicId = relative path like 'avatars/uuid.jpg'.
   *  Full Cloudinary URLs are skipped (legacy avatars). ENOENT is silently ignored. */
  async deleteFile(publicId: string): Promise<void> {
    if (publicId.startsWith('http')) return;
    // H-02 defense in depth: never unlink outside mediaDir, even if a crafted
    // publicId (e.g. '../../etc/passwd') slips past mediaUrl validation. Gate on
    // a resolved-path containment check; the unlink itself keeps using
    // path.join so the on-disk target is unchanged for legitimate ids.
    const root = path.resolve(this.mediaDir);
    const rel = path.relative(root, path.resolve(this.mediaDir, publicId));
    if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) {
      return;
    }
    try {
      await fs.unlink(path.join(this.mediaDir, publicId));
    } catch (err: any) {
      if (err?.code !== 'ENOENT') throw err;
    }
  }
}
